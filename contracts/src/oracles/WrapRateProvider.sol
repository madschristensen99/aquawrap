// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IRateProvider } from "../interfaces/IRateProvider.sol";

interface IWstETH {
    /// @return stETH per 1 wstETH, 1e18 scale
    function stEthPerToken() external view returns (uint256);
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title WrapRateProvider
/// @notice Rate provider for wstETH/WETH: combines the wrap contract's own exchange-rate
///         function with a Chainlink stETH/ETH feed.
/// @dev rate = wstETH per WETH, 1e18 scale:
///        1 wstETH = stEthPerToken() stETH = stEthPerToken() * ethPerStETH / 10^d ETH
///        wstETH per WETH = 10^d * 1e18 / (stEthPerToken() * ethPerStETH)
///        where d = feed decimals (18 for the stETH/ETH feed).
contract WrapRateProvider is IRateProvider {
    error WrapUnsupportedPair(address tokenIn, address tokenOut);
    error WrapStaleFeed(uint256 currentTime, uint256 updatedAt, uint256 maxStaleness);
    error WrapNonPositivePrice(int256 price);

    IWstETH public immutable wstETH;
    address public immutable weth;
    IAggregatorV3 public immutable stethEthFeed;
    uint256 public immutable maxStaleness;
    uint8 public immutable feedDecimals;

    constructor(address _wstETH, address _weth, address _stethEthFeed, uint256 _maxStaleness) {
        wstETH = IWstETH(_wstETH);
        weth = _weth;
        stethEthFeed = IAggregatorV3(_stethEthFeed);
        maxStaleness = _maxStaleness;
        feedDecimals = stethEthFeed.decimals();
    }

    /// @inheritdoc IRateProvider
    function getRate(address tokenIn, address tokenOut) external view override returns (uint256) {
        uint256 rate = _wstEthPerWeth();
        if (tokenIn == weth && tokenOut == address(wstETH)) return rate;
        if (tokenIn == address(wstETH) && tokenOut == weth) return 1e36 / rate;
        revert WrapUnsupportedPair(tokenIn, tokenOut);
    }

    function _wstEthPerWeth() internal view returns (uint256) {
        uint256 stEthPerWstEth = wstETH.stEthPerToken();

        (, int256 ethPerStEth, , uint256 updatedAt, ) = stethEthFeed.latestRoundData();
        require(block.timestamp - updatedAt <= maxStaleness, WrapStaleFeed(block.timestamp, updatedAt, maxStaleness));
        require(ethPerStEth > 0, WrapNonPositivePrice(ethPerStEth));

        // 10^feedDecimals normalizes the feed answer; 1e36 = 1e18 (stEthPerToken) * 1e18 (output scale)
        return (10 ** feedDecimals * 1e36) / (stEthPerWstEth * uint256(ethPerStEth));
    }
}
