// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { OracleSwap } from "../src/instructions/OracleSwap.sol";

contract OracleSwapHarness is OracleSwap {
    function exactIn(uint256 y, uint256 a, uint256 r, uint256 feeBps) external pure returns (uint256) {
        return computeExactIn(y, a, r, feeBps);
    }

    function exactOut(uint256 y, uint256 b, uint256 r, uint256 feeBps) external pure returns (uint256) {
        return computeExactOut(y, b, r, feeBps);
    }
}

contract OracleSwapMathTest is Test {
    OracleSwapHarness internal h;

    uint256 internal constant RATE = 1.2e18;
    uint256 internal constant Y = 120e18; // balanced pool: x = 100e18, y = 120e18, r = 1.2

    function setUp() public {
        h = new OracleSwapHarness();
    }

    function test_exactIn_pricesAtOracleRate() public view {
        uint256 out = h.exactIn(Y, 1e18, RATE, 0);
        // amountOut = y*r*a/(1e18*y + r*a)
        uint256 expected = uint256(Y * RATE * 1e18) / uint256(1e18 * Y + RATE * 1e18);
        assertEq(out, expected);
        assertApproxEqRel(out * 1e18 / 1e18, RATE, 0.02e18); // within 2% of oracle rate (slippage)
    }

    function test_exactIn_marginalPriceIsRate() public view {
        // tiny trade -> effective price approaches the oracle rate exactly
        uint256 out = h.exactIn(Y, 1e12, RATE, 0);
        uint256 price = out * 1e18 / 1e12;
        assertApproxEqRel(price, RATE, 0.0001e18);
    }

    function test_exactIn_feeReducesOutput() public view {
        uint256 noFee = h.exactIn(Y, 1e18, RATE, 0);
        uint256 withFee = h.exactIn(Y, 1e18, RATE, 30);
        assertLt(withFee, noFee);
        // fee is applied on input: net = a*(1-fee)
        uint256 net = 1e18 * 9970 / 10000;
        uint256 expected = uint256(Y * RATE * net) / uint256(1e18 * Y + RATE * net);
        assertEq(withFee, expected);
    }

    function test_exactIn_slippageScalesWithTradeSize() public view {
        uint256 small = h.exactIn(Y, 1e18, RATE, 0);
        uint256 large = h.exactIn(Y, 10e18, RATE, 0);
        // average price worsens with size
        assertLt(large * 1e18 / 10e18, small * 1e18 / 1e18);
    }

    function test_exactIn_neverExceedsReserve() public view {
        uint256 out = h.exactIn(Y, type(uint96).max, RATE, 0);
        assertLt(out, Y); // curve asymptote: can never drain the full reserve
    }

    function test_exactIn_rateDriftMovesPrice() public view {
        uint256 outLow = h.exactIn(Y, 1e18, 1.18e18, 0);
        uint256 outHigh = h.exactIn(Y, 1e18, 1.22e18, 0);
        // higher rate (more tokenOut per tokenIn) -> more output
        assertGt(outHigh, outLow);
    }

    function test_exactOut_pricesAtOracleRate() public view {
        uint256 in_ = h.exactOut(Y, 1e18, RATE, 0);
        // amountIn = y*b*1e18/(r*(y-b))
        uint256 expected = uint256(Y * 1e18 * 1e18) / uint256(RATE * (Y - 1e18));
        assertApproxEqRel(in_, expected, 0.0001e18);
        assertApproxEqRel(1e18 * 1e18 / in_, RATE, 0.01e18);
    }

    function test_exactOut_roundingFavorsMaker() public view {
        // exactIn(exactOut(b)) must give at least b back (maker keeps the rounding dust)
        for (uint256 b = 1e15; b < 1e19; b += 1e15) {
            uint256 a = h.exactOut(Y, b, RATE, 30);
            uint256 back = h.exactIn(Y, a, RATE, 30);
            assertGe(back, b);
        }
    }

    function test_exactOut_feeGrossUp() public view {
        uint256 noFee = h.exactOut(Y, 1e18, RATE, 0);
        uint256 withFee = h.exactOut(Y, 1e18, RATE, 30);
        assertGt(withFee, noFee);
        // gross = net * 10000 / (10000 - fee)
        uint256 expected = (noFee * 10000) / 9970;
        assertApproxEqRel(withFee, expected, 0.0001e18);
    }

    function test_revert_zeroRate() public {
        vm.expectRevert(OracleSwap.OracleSwapZeroRate.selector);
        h.exactIn(Y, 1e18, 0, 0);
        vm.expectRevert(OracleSwap.OracleSwapZeroRate.selector);
        h.exactOut(Y, 1e18, 0, 0);
    }

    function test_revert_noLiquidity() public {
        vm.expectRevert(abi.encodeWithSelector(OracleSwap.OracleSwapNoLiquidity.selector, 0));
        h.exactIn(0, 1e18, RATE, 0);
        vm.expectRevert(abi.encodeWithSelector(OracleSwap.OracleSwapNoLiquidity.selector, 0));
        h.exactOut(0, 1e18, RATE, 0);
    }

    function test_revert_outExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(OracleSwap.OracleSwapOutExceedsBalance.selector, Y, Y));
        h.exactOut(Y, Y, RATE, 0);
    }

    function test_revert_feeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(OracleSwap.OracleSwapFeeTooHigh.selector, 10000));
        h.exactIn(Y, 1e18, RATE, 10000);
        vm.expectRevert(abi.encodeWithSelector(OracleSwap.OracleSwapFeeTooHigh.selector, 10000));
        h.exactOut(Y, 1e18, RATE, 10000);
    }
}
