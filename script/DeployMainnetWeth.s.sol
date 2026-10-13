// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {DeployMainnetBase} from "./DeployMainnetBase.sol";

/// @notice Deploy the Hook that supports WETH Shell Pools and rejects native ETH Shell Pools.
///
/// Required mode-specific inputs:
///   WETH_HOOK_SALT=0x...
///   WETH_EXPECTED_HOOK_ADDRESS=0x...
///
/// Example (simulate first, then add --broadcast):
///   forge script script/DeployMainnetWeth.s.sol:DeployMainnetWeth \
///     --rpc-url $ETH_RPC_URL --account <keystore-name> --sender <deployer-address>
contract DeployMainnetWeth is DeployMainnetBase {
    function run() external {
        _deploy(false, "WETH_HOOK_SALT", "WETH_EXPECTED_HOOK_ADDRESS");
    }
}
