// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice ABI used by UniRoute for hooks that expose external liquidity.
/// @dev Mirrors Uniswap's public IAggregatorHook interface. Hook permissions are intentionally
///      not part of this interface; Shell pools use native v4 liquidity as settlement inventory.
interface IAggregatorHook {
    error UnspecifiedAmountExceeded();
    error PoolDoesNotExist();
    error LiquidityNotAllowed();

    event AggregatorPoolRegistered(PoolId indexed poolId);
    event HookSwap(PoolId indexed poolId, address indexed sender, int256 amount0, int256 amount1, uint24 swapFee);

    /// @param zeroToOne True for currency0 to currency1.
    /// @param amountSpecified Negative for exact-input and positive for exact-output.
    /// @return amountUnspecified Positive output for exact-input or positive input for exact-output.
    function quote(bool zeroToOne, int256 amountSpecified, PoolId poolId) external returns (uint256 amountUnspecified);

    /// @return amount0 External-liquidity depth in raw currency0 units.
    /// @return amount1 External-liquidity depth in raw currency1 units.
    function pseudoTotalValueLocked(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
}
