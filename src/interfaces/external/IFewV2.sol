// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice FewV2 = a Uniswap V2 fork with 30bps swap fee, hosting Ring's fewToken liquidity.
///         These interfaces are the minimal subset the aggregator hook needs.

interface ISwapV2Factory {
    /// @notice Returns the pair address for two fewTokens (any order), or address(0).
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface ISwapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Pair reserves and last-update timestamp. Read inside beforeSwap to price the swap.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice V2 swap. Caller must transfer `amountIn` of input token to the pair beforehand.
    /// @dev For a single direction, the unused output amount is 0.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
