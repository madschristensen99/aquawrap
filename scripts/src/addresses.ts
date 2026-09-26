import { type Address } from "viem";

// Canonical mainnet addresses (verified against 1inch docs + explorers)
export const AQUA_REGISTRY: Address = "0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a";
export const WETH: Address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
export const WSTETH: Address = "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0";
// Uniswap V3 wstETH/WETH 0.01% pool (token0 = wstETH, token1 = WETH)
export const UNI_V3_WSTETH_WETH_POOL: Address = "0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa";
// Chainlink stETH/ETH feed (ETH per stETH, 18 decimals, 24h heartbeat)
export const CHAINLINK_STETH_ETH: Address = "0x86392dC19c0b719886221c78AB11eb8Cf5c52812";

export function envAddress(name: string, fallback: Address): Address {
  const v = process.env[name];
  return (v ?? fallback) as Address;
}
