// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IRateProvider } from "../../src/interfaces/IRateProvider.sol";

/// @title MockRateProvider
/// @notice Test rate provider with a settable rate (quoteToken per baseToken, 1e18).
contract MockRateProvider is IRateProvider {
    error MockUnsupportedPair(address tokenIn, address tokenOut);

    address public immutable baseToken;
    address public immutable quoteToken;
    uint256 public rate;

    constructor(address _baseToken, address _quoteToken, uint256 _rate) {
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        rate = _rate;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    /// @inheritdoc IRateProvider
    function getRate(address tokenIn, address tokenOut) external view override returns (uint256) {
        if (tokenIn == baseToken && tokenOut == quoteToken) return rate;
        if (tokenIn == quoteToken && tokenOut == baseToken) return 1e36 / rate;
        revert MockUnsupportedPair(tokenIn, tokenOut);
    }
}
