import { createWalletClient, http, publicActions, parseAbi, formatUnits, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import { AQUA_REGISTRY, WETH, WSTETH, envAddress } from "./src/addresses.js";
import { loadDeployments } from "./src/deployments.js";
import { encodeOracleSwapProgram } from "./src/program.js";
import { buildMakerOrder, buildTakerTraits } from "./src/order.js";
import { aquaAbi, routerAbi, rateProviderAbi, erc20Abi } from "./src/abis.js";

/**
 * The demo: read the live oracle rate, quote a 1 WETH -> wstETH swap, then execute it
 * ONCHAIN (taker approves the router, router pushes WETH to the maker's Aqua balance and
 * pulls wstETH from the maker to the taker).
 *
 * Usage: MAKER_PK=... TAKER_PK=... npm run demo -- <amountWeth>
 */
async function main() {
  const rpc = process.env.RPC_URL ?? "https://ethereum-rpc.publicnode.com";
  const makerPk = process.env.MAKER_PK;
  const takerPk = process.env.TAKER_PK;
  if (!makerPk || !takerPk) throw new Error("set MAKER_PK and TAKER_PK");

  const [amountWeth = "1"] = process.argv.slice(2);
  const maker = privateKeyToAccount(`0x${makerPk.replace(/^0x/, "")}`);
  const taker = privateKeyToAccount(`0x${takerPk.replace(/^0x/, "")}`);
  const client = createWalletClient({ account: taker, chain: mainnet, transport: http(rpc) }).extend(publicActions);

  const aqua = envAddress("AQUA_REGISTRY", AQUA_REGISTRY);
  const weth = envAddress("WETH", WETH);
  const wsteth = envAddress("WSTETH", WSTETH);
  const { router, twapRateProvider } = loadDeployments();

  const amount = BigInt(Math.round(parseFloat(amountWeth) * 1e18));

  // 1. Live oracle rate
  const rate = await client.readContract({ address: twapRateProvider, abi: rateProviderAbi, functionName: "getRate", args: [weth, wsteth] });
  console.log(`Live TWAP rate: ${formatUnits(rate, 18)} wstETH per WETH`);

  // 2. Build the order (same program the maker shipped)
  const program = encodeOracleSwapProgram({ rateProvider: twapRateProvider, feeBps: 30 });
  const order = buildMakerOrder({ maker: maker.address, program });
  const orderHash = await client.readContract({ address: router, abi: routerAbi, functionName: "hash", args: [order] });

  // 3. Quote
  const quoteTakerData = buildTakerTraits({ taker: taker.address, isExactIn: true });
  const [qIn, qOut] = await client.readContract({
    address: router,
    abi: routerAbi,
    functionName: "quote",
    args: [order, weth, wsteth, amount, quoteTakerData],
  });
  console.log(`Quote: ${formatUnits(qIn, 18)} WETH -> ${formatUnits(qOut, 18)} wstETH`);
  console.log(`Effective price: ${formatUnits((qOut * 10n ** 18n) / qIn, 18)} wstETH/WETH`);

  // 4. Execute the swap with a min-output threshold = quoted output
  const takerData = buildTakerTraits({ taker: taker.address, isExactIn: true, threshold: qOut });

  // taker approves the router (router pushes WETH into the maker's Aqua balance)
  const allowance = await client.readContract({ address: weth, abi: erc20Abi, functionName: "allowance", args: [taker.address, router] });
  if (allowance < amount) {
    const tx = await client.writeContract({ address: weth, abi: erc20Abi, functionName: "approve", args: [router, 2n ** 256n - 1n] });
    await client.waitForTransactionReceipt({ hash: tx });
    console.log("Taker approved router for WETH");
  }

  const swapTx = await client.writeContract({
    address: router,
    abi: routerAbi,
    functionName: "swap",
    args: [order, weth, wsteth, amount, takerData],
  });
  const receipt = await client.waitForTransactionReceipt({ hash: swapTx });
  console.log(`\nSwap executed in tx ${receipt.transactionHash}`);

  const takerWsteth = await client.readContract({ address: wsteth, abi: erc20Abi, functionName: "balanceOf", args: [taker.address] });
  const [balWeth, balWsteth] = await client.readContract({
    address: aqua,
    abi: aquaAbi,
    functionName: "safeBalances",
    args: [maker.address, router, orderHash, weth, wsteth],
  });
  console.log(`Taker wstETH balance: ${formatUnits(takerWsteth, 18)}`);
  console.log(`Maker Aqua reserves: ${formatUnits(balWeth, 18)} WETH + ${formatUnits(balWsteth, 18)} wstETH`);
  console.log(`Strategy hash: ${orderHash}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
