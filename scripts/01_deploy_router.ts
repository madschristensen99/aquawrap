import { createWalletClient, http, publicActions, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import { AQUA_REGISTRY, WETH, WSTETH, UNI_V3_WSTETH_WETH_POOL, CHAINLINK_STETH_ETH, envAddress } from "./src/addresses.js";
import { loadBytecode, saveDeployments } from "./src/deployments.js";

/**
 * Deploys the AquaWrap stack:
 *   - TWAPRateProvider  (Uniswap V3 wstETH/WETH TWAP, 30 min window)
 *   - WrapRateProvider  (wstETH.stEthPerToken() x Chainlink stETH/ETH)
 *   - AquaWrapRouter    (AquaSwapVMRouter + OracleSwap opcode 0x22)
 * Writes deployments.json.
 */
async function main() {
  const rpc = process.env.RPC_URL ?? "https://ethereum-rpc.publicnode.com";
  const pk = process.env.MAKER_PK ?? process.env.DEPLOYER_PK;
  if (!pk) throw new Error("set MAKER_PK (or DEPLOYER_PK)");

  const account = privateKeyToAccount(`0x${pk.replace(/^0x/, "")}`);
  const client = createWalletClient({ account, chain: mainnet, transport: http(rpc) }).extend(publicActions);

  const aqua = envAddress("AQUA_REGISTRY", AQUA_REGISTRY);
  const weth = envAddress("WETH", WETH);
  const wsteth = envAddress("WSTETH", WSTETH);
  const pool = envAddress("UNI_V3_WSTETH_WETH_POOL", UNI_V3_WSTETH_WETH_POOL);
  const feed = envAddress("CHAINLINK_STETH_ETH", CHAINLINK_STETH_ETH);

  console.log(`Deploying on chain ${await client.getChainId()} from ${account.address}`);
  console.log(`  Aqua registry: ${aqua}`);
  console.log(`  WETH: ${weth}  wstETH: ${wsteth}`);
  console.log(`  Uniswap V3 pool: ${pool}`);
  console.log(`  Chainlink stETH/ETH: ${feed}`);

  const twapAbi = parseAbi(["constructor(address _pool, address _baseToken, address _quoteToken, uint32 _twapWindow)"]);
  const wrapAbi = parseAbi(["constructor(address _wstETH, address _weth, address _stethEthFeed, uint256 _maxStaleness)"]);
  const routerAbi = parseAbi(["constructor(address aqua, address weth, address owner, string name, string version)"]);

  const twapHash = await client.deployContract({
    abi: twapAbi,
    bytecode: loadBytecode("TWAPRateProvider"),
    args: [pool, weth, wsteth, 1800],
  });
  const twap = (await client.waitForTransactionReceipt({ hash: twapHash })).contractAddress!;
  console.log(`TWAPRateProvider: ${twap}`);

  const wrapHash = await client.deployContract({
    abi: wrapAbi,
    bytecode: loadBytecode("WrapRateProvider"),
    args: [wsteth, weth, feed, 86400n],
  });
  const wrap = (await client.waitForTransactionReceipt({ hash: wrapHash })).contractAddress!;
  console.log(`WrapRateProvider: ${wrap}`);

  const routerHash = await client.deployContract({
    abi: routerAbi,
    bytecode: loadBytecode("AquaWrapRouter"),
    args: [aqua, weth, account.address, "AquaWrap", "1"],
  });
  const router = (await client.waitForTransactionReceipt({ hash: routerHash })).contractAddress!;
  console.log(`AquaWrapRouter: ${router}`);

  saveDeployments({ router, twapRateProvider: twap, wrapRateProvider: wrap, chainId: await client.getChainId() });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
