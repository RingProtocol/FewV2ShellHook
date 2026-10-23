// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice The Shell Hook's only dependency on the shared subsidy budget.
/// @dev The Hook passes the Uniswap protocol fee amount it just collected for this swap.
///      The vault pays that same amount back to the trader, capped by its own balance,
///      so the effective subsidy rate can never exceed the protocol fee rate.
interface ISubsidyVault {
    /// @notice Credit up to `feeAmount` of `currency` back to the trader of `poolId`.
    /// @param poolId The Shell pool the swap ran in.
    /// @param currency The token the subsidy is paid in. `address(0)` means native ETH.
    /// @param feeAmount The Uniswap protocol fee amount charged on this swap.
    /// @return subsidyAmount The amount actually credited back. May be less than `feeAmount`.
    function settleSubsidy(PoolId poolId, address currency, uint256 feeAmount) external returns (uint256 subsidyAmount);
}
