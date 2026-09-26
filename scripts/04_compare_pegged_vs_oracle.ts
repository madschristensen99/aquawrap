import { createWalletClient, http, publicActions, parseAbi, encodeAbiParameters, parseAbiParameters, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import { AQUA_REGISTRY, WETH, WSTETH, envAddress } from "./src/addresses.js";
import { loadDeployments } from "./src/deployments.js";
import { encodeOracleSwapProgram, encodeXycProgram } from "./src/program.js";
import { buildMakerOrder, buildTakerTraits } from "./src/order.js";
import { aquaAbi, routerAbi, rateProviderAbi, erc20Abi } from "./src/abis.js";

/**
 * Ships two identical strategies (OracleSwap vs plain XYCSwap) with the same reserves and
 * quotes both against the live TWAP. Demonstrates that OracleSwap tracks the live rate
 * while XYC stays stuck at the ship-time reserve ratio.
 *
 * Usage: MAKER_PK=... npm run compare -- <balanceWeth> <balanceWsteth>
 */
async function main() {
  const rpc = process.env.RPC_URL ?? "https://ethereum-rpc.publicnode.com";
  const pk = process.env.MAKER_PK;
  if (!pk) throw new Error("set MAKER_PK");

  const [balWeth = "100", balWsteth = "100"] = process.argv.slice(2);
  const account = privateKeyToAccount(`0x${pk.replace(/^0x/, "")}`);
  const client = createWalletClient({ account, chain: mainnet, transport: http(rpc) }).extend(publicActions);

  const aqua = envAddress("AQUA_REGISTRY", AQUA_REGISTRY);
  const weth = envAddress("WETH", WETH);
  const wsteth = envAddress("WSTETH", WSTETH);
  const { router, twapRateProvider } = loadDeployments();

  const liveRate = await client.readContract({ address: twapRateProvider, abi: rateProviderAbi, functionName: "getRate", args: [weth, wsteth] });
  console.log(`Live TWAP rate: ${formatUnits(liveRate, 18)} wstETH per WETH\n`);

  const orders = [
    { name: "OracleSwap", program: encodeOracleSwapProgram({ rateProvider: twapRateProvider, feeBps: 0 }) },
    { name: "XYCSwap", program: encodeXycProgram() },
  ];

  const taker = account.address;
  const takerData = buildTakerTraits({ taker, isExactIn: true });

  for (const { name, program } of orders) {
    const order = buildMakerOrder({ maker: account.address, program });
    const orderHash = await client.readContract({ address: router, abi: routerAbi, functionName: "hash", args: [order] });

    // approve Aqua if needed (pull() moves maker tokens during swaps)
    for (const token of [weth, wsteth]) {
      const allowance = await client.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [account.address, aqua] });
      if (allowance === 0n) {
        const tx = await client.writeContract({ address: token, abi: erc20Abi, functionName: "approve", args: [aqua, 2n ** 256n - 1n] });
        await client.waitForTransactionReceipt({ hash: tx });
      }
    }

    // abi.encode(order) encodes the struct as a dynamic tuple (leading offset included)
    const strategy = encodeAbiParameters(parseAbiParameters("(address,uint256,bytes)"), [[order.maker, order.traits, order.data]]);
    const tx = await client.writeContract({
      address: aqua,
      abi: aquaAbi,
      functionName: "ship",
      args: [router, strategy, [weth, wsteth], [BigInt(Math.round(parseFloat(balWeth) * 1e18)), BigInt(Math.round(parseFloat(balWsteth) * 1e18))]],
    });
    await client.waitForTransactionReceipt({ hash: tx });

    const [, qOut] = await client.readContract({
      address: router,
      abi: routerAbi,
      functionName: "quote",
      args: [order, weth, wsteth, 10n ** 15n, takerData], // tiny trade: negligible slippage
    });
    const price = (qOut * 10n ** 18n) / 10n ** 15n;
    const diff = price > liveRate ? price - liveRate : liveRate - price;
    const diffBps = (diff * 10000n) / liveRate;

    console.log(`${name.padEnd(10)} price: ${formatUnits(price, 18).padStart(12)} wstETH/WETH   |Δ vs live|: ${diffBps.toString().padStart(6)} bps   (strategy ${orderHash.slice(0, 10)}…)`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
