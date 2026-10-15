// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Read-only ABI exposed by Uniswap's protocol-fee adapter.
interface IV4FeeRecipient {
    function TOKEN_JAR() external view returns (address);
}
