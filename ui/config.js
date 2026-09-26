// ─────────────────────────────────────────────────────────────────────────────
// AquaWrap UI configuration.
//
// Out of the box this points at a local anvil mainnet fork (see README "Local
// demo"): start anvil, run `npm run deploy` + `npm run ship`, then open index.html.
//
// For a real mainnet deployment: set rpcUrl to a mainnet RPC and replace the
// router/provider addresses with your deployments (scripts/deployments.json).
// ─────────────────────────────────────────────────────────────────────────────
export const CONFIG = {
  rpcUrl: "http://127.0.0.1:8545",

  // Canonical mainnet contracts
  aqua: "0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a",
  weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  wsteth: "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
  pool: "0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa",

  // Deployed by scripts/01_deploy_router.ts
  router: "0xad7feeca9cf47e95d5a3644c4fdf5578b53491f0",
  twapProvider: "0x7f21f37a026b13d9946561b24d1b6885f3976e6d",
  wrapProvider: "0x7fc6cdcf0d2f9fd65bfcf64d6fd1bdfbaddd7c7b",

  // Maker whose shipped strategy this UI displays
  maker: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",

  // OracleSwap program parameters (must match what the maker shipped)
  feeBps: 30,
  twapWindow: 1800,
};
