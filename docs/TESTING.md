# Testing

27 tests across three suites, all passing.

## Suites

| Suite | File | What it covers |
|---|---|---|
| Math unit tests | `contracts/test/OracleSwapMath.t.sol` | 13 tests on the pure pricing kernels: exact-in/exact-out, fee handling, rounding direction (maker-favorable), edge cases (zero rate, no liquidity, out > balance, fee ≥ 100%) |
| Local full-flow | `contracts/test/AquaWrapLocal.t.sol` | 9 tests: ship → quote → swap → dock against a local Aqua registry, rate-drift re-centering, quote/swap parity fuzz, fee accounting, `Panic(0x32)` on the base router |
| Mainnet fork | `contracts/test/AquaWrapFork.t.sol` | 5 tests against the real Aqua registry (`0x1111…a90a`), real wstETH/WETH Uniswap V3 pool, and Chainlink feed |

## Running

```bash
# unit + local (no RPC needed)
forge test --match-path "contracts/test/OracleSwapMath.t.sol"
forge test --match-path "contracts/test/AquaWrapLocal.t.sol"

# fork suite (needs MAINNET_RPC_URL; skips automatically when unset)
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path "contracts/test/AquaWrapFork.t.sol"

# everything
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test
```

## What the drift test proves

The local suite ships two strategies with identical reserves — one OracleSwap, one plain
XYCSwap — then moves the mock rate provider by ~6%. OracleSwap's quoted price tracks the
new rate immediately (0 bps deviation), while XYCSwap stays stuck at the ship-time reserve
ratio. This is the core value proposition: no stale-price arbitrage window for wrapped
assets.

## Parity fuzz

`testFuzz_quoteMatchesSwap` runs random reserves, amounts, rates, and fees, asserting that
`quote()` and `swap()` return identical `amountIn`/`amountOut` — guaranteed by the pure
pricing kernel and the `view` rate provider, and enforced here so future edits can't break
it.
