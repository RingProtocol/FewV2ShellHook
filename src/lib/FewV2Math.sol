// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @title FewV2Math
/// @notice Pricing helpers for FewV2 pairs (Uniswap V2 fork with 30bps fee).
/// @dev Identical math to UniswapV2Library.getAmountOut / getAmountIn.
///      `getAmountOut` is the same formula used in Phase E's
///      `contracts/ring-uniswapx-filler/src/lib/FewV2Library.sol`.
///      `getAmountIn` is added here for V4 exact-output support.
library FewV2Math {
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    error InsufficientAmount();
    error InsufficientLiquidity();

    /// @notice Output for a given input. Classic V2 formula using `FEE_NUMERATOR` / `FEE_DENOMINATOR`.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;
        amountOut = numerator / denominator;
        if (amountOut == 0) revert InsufficientAmount();
    }

    /// @notice Input required for a given output. Classic V2 formula using `FEE_NUMERATOR` / `FEE_DENOMINATOR`.
    /// @dev The trailing `+1` is the Uniswap V2 exact-output convention; it over-supplies
    ///      by at most one wei after integer floor division, preventing under-sourcing.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * FEE_NUMERATOR;
        amountIn = (numerator / denominator) + 1;
    }
}
