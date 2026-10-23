// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SubsidyVault} from "../src/SubsidyVault.sol";

/// @notice Bind a deployed SubsidyVault to its Hook. Callable exactly once.
///
/// Required inputs:
///   SUBSIDY_VAULT_ADDRESS=0x...    the deployed vault
///   HOOK_ADDRESS=0x...              the deployed Hook
///
/// The broadcaster must be the vault owner, because `setHook` is `onlyOwner`. The binding is
/// permanent: a later owner rotation cannot redirect the budget to a different Hook, and the
/// vault cannot be re-armed. Run this after the Hook is deployed and verified, and after the
/// budget has been funded; an armed but empty vault is safe, it simply pays nothing.
///
/// Example (simulate first, then add --broadcast):
///   forge script script/ArmSubsidyVault.s.sol:ArmSubsidyVault \
///     --rpc-url $ETH_RPC_URL --account <vault-owner-keystore> --sender <vault-owner-address>
contract ArmSubsidyVault is Script {
    function run() external {
        address vaultAddr = vm.envAddress("SUBSIDY_VAULT_ADDRESS");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");

        require(vaultAddr.code.length > 0, "SUBSIDY_VAULT_ADDRESS has no code");
        require(hookAddr.code.length > 0, "HOOK_ADDRESS has no code");

        SubsidyVault vault = SubsidyVault(payable(vaultAddr));
        require(!vault.hookLocked(), "the vault is already armed");
        require(vault.hook() == address(0), "the vault already has a hook");

        console2.log("=== Pre-flight ===");
        console2.log("Vault:        ", vaultAddr);
        console2.log("Hook:         ", hookAddr);
        console2.log("Vault owner:  ", vault.owner());
        console2.log("Vault paused: ", vault.paused());

        vm.startBroadcast();
        vault.setHook(hookAddr);
        vm.stopBroadcast();

        require(vault.hook() == hookAddr, "the vault did not record the hook");
        require(vault.hookLocked(), "the vault is not locked");

        console2.log("=== SubsidyVault armed ===");
        console2.log("Vault:", vaultAddr);
        console2.log("Hook: ", vault.hook());
        console2.log("State asserts: all passed");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Fund the budget per currency: fund(currency, amount) / fundNative()");
        console2.log("  2. Verify a quote against the same pool with the protocol fee switched off");
    }
}
