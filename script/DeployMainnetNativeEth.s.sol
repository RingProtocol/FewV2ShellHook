// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {DeployMainnetBase} from "./DeployMainnetBase.sol";

/// @notice Deploy the Hook that supports native ETH Shell Pools and rejects WETH Shell Pools.
///
/// Required mode-specific inputs:
///   NATIVE_ETH_HOOK_SALT=0x...
///   NATIVE_ETH_EXPECTED_HOOK_ADDRESS=0x...
///
/// Example (simulate first, then add --broadcast):
///   forge script script/DeployMainnetNativeEth.s.sol:DeployMainnetNativeEth \
///     --rpc-url $ETH_RPC_URL --account <keystore-name> --sender <deployer-address>
contract DeployMainnetNativeEth is DeployMainnetBase {
    function run() external {
        _deploy(true, "NATIVE_ETH_HOOK_SALT", "NATIVE_ETH_EXPECTED_HOOK_ADDRESS");
    }
}
