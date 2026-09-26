# AquaWrap — Oracle-Priced Wrapped Asset Liquidity

A custom [1inch SwapVM](https://github.com/1inch/swap-vm) instruction that reads a live
rate oracle (Uniswap V3 TWAP or wrap-contract rate) on every `quote()` / `swap()`,
continuously re-centering the AMM curve so wrapped-asset liquidity (wstETH, cbETH, rETH…)
stays accurate to real market prices.

## The problem

SwapVM's built-in `PeggedSwap` and `XYCSwap` fix the price at ship time. Wrapped assets
have exchange rates that drift as rewards accrue, so a pool left at a stale ratio gets
arbitraged — LPs bleed value every time the wrap rate moves.

| Approach | wstETH rate drifts 0.855 → 0.803 | Result |
|---|---|---|
| Plain `XYCSwap` (constant product) | Price = reserve ratio, disconnected from the real rate | Stale-price arb |
| Plain `PeggedSwap` (fixed ratio) | Price stuck at ship-time anchor | Stale-price arb |
| **`OracleSwap` (this project)** | Price = live oracle rate on every quote/swap | No stale-price arb |

## How it works

The curve is re-anchored to the oracle on every call:

```
(x + x0) * y = k,   x0 = y/r − x,   k = y²/r
```

so the marginal price at the current reserves is **always exactly r** (the live rate),
while slippage still scales with trade size vs. the output reserve — a real AMM, not an
RFQ. When the wrap rate drifts, the pool price tracks it immediately.

```
Exact-in:  amountOut = y·r·net / (1e18·y + r·net),   net = amountIn·(1 − fee)
Exact-out: amountIn  = y·b·1e18 / (r·(y − b)) grossed up by the fee
```

> **Why not just scale `balanceIn` by the rate?** The rate cancels out of the constant
> product formula (`amountOut = a·y/(x+a)` regardless of r), so the oracle would be
> decorative. OracleSwap anchors the curve *through* the rate instead.

## Architecture

```
Official Aqua registry (unchanged)          Redeployed SwapVM router
┌─────────────────────────────┐             ┌──────────────────────────────────┐
│ Aqua.sol 0x1111…a90a        │◄──────────►│ AquaWrapRouter                   │
│ ship / dock / pull / push   │  balances   │ = AquaSwapVMRouter + OracleSwap │
└─────────────────────────────┘             │   opcode 0x22 (appended)        │
                                            └───────────────┬──────────────────┘
                                                            │ getRate()
                                            ┌───────────────▼──────────────────┐
                                            │ TWAPRateProvider (Uniswap V3)    │
                                            │ WrapRateProvider (wstETH+Chainlink)│
                                            └──────────────────────────────────┘
```

- **Official Aqua registry used unchanged** — only the SwapVM router (the "app" address)
  is redeployed, which the 1inch bounty rules explicitly allow.
- **Append-only opcode table** — OracleSwap is appended at index 34 (byte `0x22`), the
  first out-of-bounds index of the deployed v1.0.2 router's 34-entry table. Every existing
  opcode keeps its index; existing programs behave identically. Byte `0x22` reverts with
  `Panic(0x32)` on the deployed router, so OracleSwap programs only execute on
  `AquaWrapRouter`.
- **Quote/swap parity** — the rate provider is a `view` call returning the same value
  within a block, and the pricing kernel is pure, so `quote()` == `swap()`.

## Repository layout

```
contracts/
├── src/
│   ├── interfaces/IRateProvider.sol        # getRate(tokenIn, tokenOut) → 1e18
│   ├── instructions/OracleSwap.sol         # the custom opcode + pricing kernel
│   ├── opcodes/AquaWrapOpcodes.sol         # base table + OracleSwap appended
│   ├── routers/AquaWrapRouter.sol          # redeployed router
│   └── oracles/
│       ├── TWAPRateProvider.sol            # Uniswap V3 TWAP (30 min window)
│       └── WrapRateProvider.sol            # wstETH.stEthPerToken() × Chainlink
├── test/
│   ├── OracleSwapMath.t.sol                # pure math unit tests (13)
│   ├── AquaWrapLocal.t.sol                 # ship → quote → swap → dock, drift, parity (9)
│   ├── AquaWrapFork.t.sol                  # mainnet fork vs real registry/oracle (5)
│   └── mocks/MockRateProvider.sol
scripts/                                    # viem scripts (deploy, ship, demo, compare)
ui/                                         # static HTML/CSS/JS dashboard (no build step)
```

## Quick start

### 1. Build & test (no RPC needed for unit + local suites)

```bash
forge build
forge test --match-path "contracts/test/OracleSwapMath.t.sol"
forge test --match-path "contracts/test/AquaWrapLocal.t.sol"
```

### 2. Mainnet fork tests (needs an RPC)

```bash
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path "contracts/test/AquaWrapFork.t.sol"
```

The fork suite skips automatically when `MAINNET_RPC_URL` is unset.

### 3. Local demo (anvil fork + scripts + UI)

```bash
# terminal 1 — anvil mainnet fork
anvil --fork-url https://ethereum-rpc.publicnode.com --port 8545

# terminal 2 — deploy + ship + compare (ships OracleSwap AND XYC strategies)
cd scripts && npm install
RPC_URL=http://127.0.0.1:8545 MAKER_PK=<anvil-key-0> npm run deploy
RPC_URL=http://127.0.0.1:8545 MAKER_PK=<anvil-key-0> npm run ship -- 100 85
RPC_URL=http://127.0.0.1:8545 MAKER_PK=<anvil-key-0> npm run compare -- 100 100

# fund the taker with WETH on the fork (impersonate the Uniswap pool), then:
RPC_URL=http://127.0.0.1:8545 MAKER_PK=<anvil-key-0> TAKER_PK=<anvil-key-1> npm run demo -- 1

# terminal 3 — the UI (points at the fork by default)
cd ui && python3 -m http.server 3000   # open http://127.0.0.1:3000
```

Expected `compare` output (live TWAP ≈ 0.803 wstETH/WETH):

```
OracleSwap price: 0.8034… wstETH/WETH   |Δ vs live|:      0 bps
XYCSwap    price: 0.9999… wstETH/WETH   |Δ vs live|:   2446 bps
```

### 4. Real mainnet

1. `cd scripts && npm install`
2. `cp .env.example .env` and fill in `RPC_URL`, `MAKER_PK`, `TAKER_PK`
3. `npm run deploy` → writes `deployments.json`
4. `npm run ship -- 100 85` — maker ships 100 WETH + 85 wstETH (maker must hold the tokens
   and approve the Aqua registry; `ship()` records virtual balances, tokens stay in the
   maker's wallet until a swap pulls them)
5. `npm run demo -- 1` — taker swaps 1 WETH → wstETH onchain
6. Point `ui/config.js` at mainnet + your deployed addresses, serve `ui/`

## Key addresses (Ethereum mainnet)

| Contract | Address |
|---|---|
| Aqua registry | `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| Uniswap V3 wstETH/WETH 0.01% pool | `0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa` |
| Chainlink stETH/ETH feed | `0x86392dC19c0b719886221c78AB11eb8Cf5c52812` |

## Dependencies (pinned)

| Dependency | Version |
|---|---|
| [1inch/swap-vm](https://github.com/1inch/swap-vm) | `v1.0.2` (matches the deployed router) |
| [1inch/aqua](https://github.com/1inch/aqua) | `v1.0.0` |
| [1inch/solidity-utils](https://github.com/1inch/solidity-utils) | `6.9.10` |
| openzeppelin-contracts | `v5.4.0` |
| forge-std | `v1.11.0` |
| Uniswap/v3-core | `v1.0.0` (interface only; TickMath inlined for solc 0.8.30) |

## Notes / corrections vs. the original concept

- The concept's pool address (`0x1098…2438C`) was wrong — the real wstETH/WETH 0.01% pool
  is `0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa`.
- The concept's rate direction was inverted: 1 WETH ≈ **0.855** wstETH (not 1.18).
- The concept's math scaled `balanceIn` by the rate, which cancels out of constant product;
  OracleSwap anchors the curve through the rate instead (see "How it works").
- The concept's opcode `0x22` was right for the deployed v1.0.2 router (34-entry table,
  indices 0–33), but the dispatch model is a jump table (`_opcodes()`), not a `_dispatch`
  override — `AquaWrapOpcodes` appends to the table.
- The Chainlink stETH/ETH feed is 18 decimals (not 8) and has a 24 h heartbeat.
