// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IRateProvider
/// @notice Returns the live exchange rate between two tokens, in 1e18 fixed-point.
/// @dev Implemented by TWAPRateProvider (Uniswap V3 TWAP), WrapRateProvider
///      (wrap-contract rate fn + Chainlink) or MockRateProvider (tests).
interface IRateProvider {
    /// @notice Returns how many tokenOut you get for 1 tokenIn, scaled by 1e18.
    /// @param tokenIn  The token being sold.
    /// @param tokenOut The token being bought.
    /// @return rate tokenOut per tokenIn, 1e18 fixed-point.
    function getRate(address tokenIn, address tokenOut) external view returns (uint256);
}
