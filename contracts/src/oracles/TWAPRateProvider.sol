// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import { IRateProvider } from "../interfaces/IRateProvider.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title TWAPRateProvider
/// @notice Reads a Uniswap V3 time-weighted average price for a wrapped-asset pair.
/// @dev twapWindow should be >= 30 minutes for manipulation resistance.
///      baseToken = the "base" token (e.g. WETH), quoteToken = the wrapped token (e.g. wstETH).
///      getRate() returns quoteToken per baseToken, 1e18 scale, and inverts on request.
contract TWAPRateProvider is IRateProvider {
    error TWAPUnsupportedPair(address tokenIn, address tokenOut);
    error TWAPZeroRate();

    IUniswapV3Pool public immutable pool;
    address public immutable baseToken;
    address public immutable quoteToken;
    uint32 public immutable twapWindow;

    address public immutable token0;
    address public immutable token1;
    uint8 public immutable decimals0;
    uint8 public immutable decimals1;

    constructor(address _pool, address _baseToken, address _quoteToken, uint32 _twapWindow) {
        pool = IUniswapV3Pool(_pool);
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        twapWindow = _twapWindow;

        token0 = pool.token0();
        token1 = pool.token1();
        decimals0 = IERC20Decimals(token0).decimals();
        decimals1 = IERC20Decimals(token1).decimals();
    }

    /// @inheritdoc IRateProvider
    function getRate(address tokenIn, address tokenOut) external view override returns (uint256) {
        uint256 twap = _twapQuotePerBase();
        if (tokenIn == baseToken && tokenOut == quoteToken) return twap;
        if (tokenIn == quoteToken && tokenOut == baseToken) return 1e36 / twap;
        revert TWAPUnsupportedPair(tokenIn, tokenOut);
    }

    /// @notice Time-weighted average of quoteToken per baseToken, 1e18 scale.
    function _twapQuotePerBase() internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

        // tick = (tickCumulatives[1] - tickCumulatives[0]) / twapWindow
        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 tick = int24(tickDelta / int56(uint56(twapWindow)));

        // sqrtPriceX96 = 1.0001^(tick/2); price = token1 per token0 in X96
        uint160 sqrtPriceX96 = _getSqrtRatioAtTick(tick);
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;

        // Convert to 1e18 with decimal adjustment: price_1e18 = price_raw * 1e18 * 10^(d0 - d1)
        uint256 numerator = priceX96 * 1e18;
        if (decimals0 >= decimals1) {
            numerator *= 10 ** (decimals0 - decimals1);
            priceX96 = numerator >> 96;
        } else {
            priceX96 = (numerator / 10 ** (decimals1 - decimals0)) >> 96;
        }

        // priceX96 is now token1 per token0 in 1e18. Orient to quoteToken per baseToken.
        uint256 twap = token0 == baseToken ? priceX96 : 1e36 / priceX96;
        require(twap > 0, TWAPZeroRate());
        return twap;
    }

    /// @dev sqrt(1.0001^tick) * 2^96. Inlined from Uniswap v3-core TickMath (GPL-2.0)
    ///      because v3-core v1.0.0's version does not compile under solc 0.8.30.
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        int24 MAX_TICK = 887272;
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}
