// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DeployMainnetBase} from "./DeployMainnetBase.sol";
import {SubsidyVault} from "../src/SubsidyVault.sol";

/// @notice Deploy the SubsidyVault that holds the shared protocol-fee subsidy budget.
///
/// Required inputs:
///   SUBSIDY_VAULT_OWNER_ADDRESS=0x...   two-step owner that funds the budget and arms the vault
///
/// Optional:
///   V4_POOL_MANAGER=0x...                defaults to the Ethereum mainnet PoolManager
///
/// The vault address is part of the Hook init code, so the vault must exist before the Hook is
/// mined and deployed. Run this script first, then set SUBSIDY_VAULT_ADDRESS and re-run
/// MineHookAddress: the mined Hook address changes with the vault address.
///
/// The vault is deployed unarmed. Until the owner calls `setHook`, and until the budget holds
/// funds, every subsidy request returns zero and the Shell route behaves exactly as before.
///
/// Example (simulate first, then add --broadcast):
///   forge script script/DeploySubsidyVault.s.sol:DeploySubsidyVault \
///     --rpc-url $ETH_RPC_URL --account <keystore-name> --sender <deployer-address>
contract DeploySubsidyVault is DeployMainnetBase {
    function run() external {
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address owner = vm.envAddress("SUBSIDY_VAULT_OWNER_ADDRESS");

        console2.log("=== Pre-flight ===");
        console2.log("Pool manager: ", poolManager);
        console2.log("Vault owner: ", owner);

        vm.startBroadcast();
        SubsidyVault vault = new SubsidyVault(IPoolManager(poolManager), owner);
        vm.stopBroadcast();

        require(address(vault.poolManager()) == poolManager, "poolManager mismatch in deployed vault");
        require(vault.owner() == owner, "owner mismatch in deployed vault");
        require(vault.hook() == address(0), "a fresh vault must not be armed");
        require(!vault.hookLocked(), "a fresh vault must not be locked");

        console2.log("=== SubsidyVault deployed ===");
        console2.log("Address:", address(vault));
        console2.log("Runtime codehash:");
        console2.logBytes32(address(vault).codehash);
        console2.log("State asserts: all passed");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Set SUBSIDY_VAULT_ADDRESS to the address above");
        console2.log("  2. Re-run MineHookAddress: the vault address is part of the Hook init code");
        console2.log("  3. Deploy the Hook, then bind it with ArmSubsidyVault.s.sol");
    }
}
