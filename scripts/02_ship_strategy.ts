import { createWalletClient, http, publicActions, parseAbi, encodeAbiParameters, parseAbiParameters, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import { AQUA_REGISTRY, WETH, WSTETH, envAddress } from "./src/addresses.js";
import { loadDeployments } from "./src/deployments.js";
import { encodeOracleSwapProgram } from "./src/program.js";
import { buildMakerOrder, type MakerOrder } from "./src/order.js";
import { aquaAbi, erc20Abi } from "./src/abis.js";

/**
 * Maker ships an OracleSwap strategy on Aqua: virtual balances are recorded on the
 * registry (tokens stay in the maker's wallet until a swap pulls them).
 *
 * Usage: MAKER_PK=... npm run ship -- <balanceWeth> <balanceWsteth> [feeBps]
 */
async function main() {
  const rpc = process.env.RPC_URL ?? "https://ethereum-rpc.publicnode.com";
  const pk = process.env.MAKER_PK;
  if (!pk) throw new Error("set MAKER_PK");

  const [balWeth = "100", balWsteth = "85", feeBps = "30"] = process.argv.slice(2);
  const account = privateKeyToAccount(`0x${pk.replace(/^0x/, "")}`);
  const client = createWalletClient({ account, chain: mainnet, transport: http(rpc) }).extend(publicActions);

  const aqua = envAddress("AQUA_REGISTRY", AQUA_REGISTRY);
  const weth = envAddress("WETH", WETH);
  const wsteth = envAddress("WSTETH", WSTETH);
  const { router, twapRateProvider } = loadDeployments();

  const program = encodeOracleSwapProgram({ rateProvider: twapRateProvider, feeBps: Number(feeBps) });
  const order = buildMakerOrder({ maker: account.address, program });
  const orderHash = await client.readContract({ address: router, abi: routerAbi(), functionName: "hash", args: [order] });

  console.log(`Shipping OracleSwap strategy from ${account.address}`);
  console.log(`  Router: ${router}`);
  console.log(`  Rate provider: ${twapRateProvider}`);
  console.log(`  Reserves: ${balWeth} WETH + ${balWsteth} wstETH, fee ${feeBps} bps`);
  console.log(`  Program: ${program}`);
  console.log(`  Order hash: ${orderHash}`);

  // maker must approve the Aqua registry so pull() can move tokens during swaps
  for (const token of [weth, wsteth]) {
    const allowance = await client.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [account.address, aqua] });
    if (allowance === 0n) {
      const tx = await client.writeContract({ address: token, abi: erc20Abi, functionName: "approve", args: [aqua, 2n ** 256n - 1n] });
      await client.waitForTransactionReceipt({ hash: tx });
      console.log(`  Approved ${token} -> Aqua`);
    }
  }

  // abi.encode(order) encodes the struct as a dynamic tuple (leading offset included)
  const strategy = encodeAbiParameters(parseAbiParameters("(address,uint256,bytes)"), [[order.maker, order.traits, order.data]]);
  const tx = await client.writeContract({
    address: aqua,
    abi: aquaAbi,
    functionName: "ship",
    args: [router, strategy, [weth, wsteth], [BigInt(parseFloat(balWeth) * 1e18), BigInt(parseFloat(balWsteth) * 1e18)]],
  });
  const receipt = await client.waitForTransactionReceipt({ hash: tx });
  console.log(`  Shipped in tx ${receipt.transactionHash}`);
  console.log(`  Strategy hash: ${orderHash}`);
}

function routerAbi() {
  return parseAbi([
    "function hash((address maker,uint256 traits,bytes data) order) view returns (bytes32)",
  ]);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
