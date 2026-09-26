// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "@1inch/swap-vm/libs/VM.sol";

import { IRateProvider } from "../interfaces/IRateProvider.sol";

/// @title OracleSwap
/// @notice SwapVM instruction: oracle-anchored constant-product curve for wrapped assets.
/// @dev Appended as the last opcode on AquaWrapRouter (index 34, byte 0x22). The deployed
///      AquaSwapVMRouter v1.0.2 has a 34-entry jump table (indices 0-33), so byte 0x22 is
///      out-of-bounds there (Panic 0x32) — programs carrying it only execute on our router.
///      This is explicitly allowed by the 1inch bounty rules: "redeployments of a modified
///      SwapVM contract is allowed."
///
///      Args layout (22 bytes):
///        [0:20]  rateProvider (address — IRateProvider)
///        [20:22] feeBps       (uint16 — LP fee in basis points, max 9999)
///
///      Why a plain XYC/PeggedSwap goes stale:
///        A constant-product pool prices at y/x (reserve ratio). A wrapped asset's exchange
///        rate (wstETH, cbETH, rETH...) drifts as rewards accrue, so a pool shipped at a
///        fixed ratio is arbitraged every time the wrap rate moves. Scaling balanceIn by the
///        rate does NOT help — the rate cancels out of the constant-product formula.
///
///      What this instruction actually does:
///        The curve is re-anchored to the oracle on every quote()/swap():
///          (x + x0) * y = k,  with x0 = y/r - x,  k = y^2/r
///        so the marginal price at the current reserves is ALWAYS exactly r (the live rate),
///        while slippage still scales with trade size vs. the output reserve — a real AMM,
///        not an RFQ. When the wrap rate drifts, the pool price tracks it immediately and
///        there is no stale-price arbitrage window.
///
///      Exact-in:  amountOut = y * r * net / (1e18 * y + r * net),  net = amountIn * (1 - fee)
///      Exact-out: amountIn  = y * b * 1e18 / (r * (y - b)) grossed up by the fee
contract OracleSwap {
    using Calldata for bytes;
    using ContextLib for Context;

    error OracleSwapBadArgsLength(uint256 length);
    error OracleSwapFeeTooHigh(uint256 feeBps);
    error OracleSwapZeroRate();
    error OracleSwapNoLiquidity(uint256 balanceOut);
    error OracleSwapOutExceedsBalance(uint256 amountOut, uint256 balanceOut);
    error OracleSwapRecomputeDetected();

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10000;

    /// @notice Pure pricing kernel — exact-in. Unit-testable without SwapVM Context.
    /// @param y          balanceOut (output reserve, raw units)
    /// @param amountIn   taker input (raw units)
    /// @param rate       tokenOut per tokenIn, 1e18
    /// @param feeBps     LP fee in basis points
    /// @return amountOut output in raw units, rounded DOWN (maker-favorable)
    function computeExactIn(uint256 y, uint256 amountIn, uint256 rate, uint256 feeBps) internal pure returns (uint256) {
        require(rate > 0, OracleSwapZeroRate());
        require(y > 0, OracleSwapNoLiquidity(y));
        require(feeBps < BPS, OracleSwapFeeTooHigh(feeBps));

        uint256 netAmountIn = (amountIn * (BPS - feeBps)) / BPS;
        uint256 scaledIn = rate * netAmountIn; // input in tokenOut units, 1e18-scaled
        return Math.mulDiv(y, scaledIn, ONE * y + scaledIn);
    }

    /// @notice Pure pricing kernel — exact-out. Unit-testable without SwapVM Context.
    /// @param y          balanceOut (output reserve, raw units)
    /// @param amountOut  taker output (raw units)
    /// @param rate       tokenOut per tokenIn, 1e18
    /// @param feeBps     LP fee in basis points
    /// @return amountIn input in raw units, rounded UP (maker-favorable)
    function computeExactOut(uint256 y, uint256 amountOut, uint256 rate, uint256 feeBps) internal pure returns (uint256) {
        require(rate > 0, OracleSwapZeroRate());
        require(y > 0, OracleSwapNoLiquidity(y));
        require(feeBps < BPS, OracleSwapFeeTooHigh(feeBps));
        require(amountOut < y, OracleSwapOutExceedsBalance(amountOut, y));

        uint256 netAmountIn = Math.mulDiv(y, amountOut * ONE, rate * (y - amountOut), Math.Rounding.Ceil);
        return Math.mulDiv(netAmountIn, BPS, BPS - feeBps, Math.Rounding.Ceil);
    }

    /// @notice SwapVM instruction entry point.
    /// @param ctx  VM context (balances, query direction, amounts)
    /// @param args [rateProvider (20) | feeBps (2)]
    function _oracleSwap(Context memory ctx, bytes calldata args) internal view {
        require(args.length == 22, OracleSwapBadArgsLength(args.length));

        address rateProvider = address(uint160(bytes20(args.slice(0, 20))));
        uint256 feeBps = uint256(uint16(bytes2(args.slice(20, 22))));

        uint256 rate = IRateProvider(rateProvider).getRate(ctx.query.tokenIn, ctx.query.tokenOut);

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, OracleSwapRecomputeDetected());
            ctx.swap.amountOut = computeExactIn(ctx.swap.balanceOut, ctx.swap.amountIn, rate, feeBps);
        } else {
            require(ctx.swap.amountIn == 0, OracleSwapRecomputeDetected());
            ctx.swap.amountIn = computeExactOut(ctx.swap.balanceOut, ctx.swap.amountOut, rate, feeBps);
        }
    }
}
