# Architecture

AquaWrap extends the deployed 1inch SwapVM router with one appended opcode while leaving
the official Aqua registry untouched.

## Component diagram

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

## The opcode table trick

`AquaOpcodes._opcodes()` builds a jump table of internal function pointers. The deployed
v1.0.2 router has 34 entries (indices 0–33). `AquaWrapOpcodes` overrides `_opcodes()` and
appends `_oracleSwap` at index 34 — byte `0x22`:

```solidity
function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
    function(Context memory, bytes calldata) internal[] memory base = super._opcodes();
    result = new function(Context memory, bytes calldata) internal[](base.length + 1);
    for (uint256 i = 0; i < base.length; i++) {
        result[i] = base[i];
    }
    result[base.length] = _oracleSwap;
}
```

Every existing opcode keeps its index, so all existing Aqua programs behave identically.
Byte `0x22` is out-of-bounds on the deployed router (`Panic(0x32)`), so OracleSwap programs
only execute on `AquaWrapRouter`.

## The pricing kernel

The curve is re-anchored to the oracle on every `quote()`/`swap()`:

```
(x + x0) * y = k,   with x0 = y/r − x,   k = y²/r
```

- Marginal price at current reserves is always exactly `r` (the live rate).
- Slippage still scales with trade size vs. the output reserve — a real AMM, not an RFQ.
- When the wrap rate drifts, the pool price tracks it immediately; no stale-price arb window.

```
Exact-in:  amountOut = y·r·net / (1e18·y + r·net),   net = amountIn·(1 − fee)
Exact-out: amountIn  = y·b·1e18 / (r·(y − b)) grossed up by the fee
```

> **Why not scale `balanceIn` by the rate?** The rate cancels out of the constant-product
> formula (`amountOut = a·y/(x+a)` is independent of `r`), so the oracle would be
> decorative. OracleSwap anchors the curve *through* the rate instead.

## Rate providers

| Provider | Source | Notes |
|---|---|---|
| `TWAPRateProvider` | Uniswap V3 `observe()` | 30 min window, manipulation-resistant |
| `WrapRateProvider` | `wstETH.stEthPerToken()` × Chainlink stETH/ETH | 18-decimal feed, 24 h heartbeat |

Both implement `IRateProvider.getRate(tokenIn, tokenOut) → 1e18` and are `view` calls, so
`quote()` and `swap()` return identical amounts within a block (parity is fuzz-tested).

## Program layout

OracleSwap program bytes (24 total):

```
[0x22] [0x16 = 22] [20 bytes rateProvider] [2 bytes feeBps]
```
