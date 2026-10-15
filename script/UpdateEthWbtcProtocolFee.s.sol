// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";

interface IReleaseFeeAdapter {
    function TOKEN_JAR() external view returns (address);
    function getFee(PoolKey memory key) external view returns (uint24);
    function triggerFeeUpdate(PoolKey calldata key) external;
}

/// @notice Previews the permissionless official fee update for the native ETH/WBTC release.
/// @dev Default is calldata-only. BROADCAST_PROTOCOL_FEE_UPDATE=true permits the script call;
///      Foundry still requires --broadcast and a signer to send a mainnet transaction.
///      This script never selects a rate or recipient and never changes Hook governance.
contract UpdateEthWbtcProtocolFee is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WBTC_DEFAULT = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    struct FeeUpdatePlan {
        PoolKey key;
        address controller;
        address recipient;
        uint24 currentFee;
        uint24 policyFee;
    }

    function preview(address hookAddress, address managerAddress, address wbtc)
        public
        view
        returns (FeeUpdatePlan memory plan)
    {
        require(hookAddress.code.length > 0, "HOOK_ADDRESS has no code");
        require(managerAddress.code.length > 0, "V4_POOL_MANAGER has no code");
        FewV2ShellHook hook = FewV2ShellHook(payable(hookAddress));
        require(address(hook.poolManager()) == managerAddress, "poolManager mismatch");
        require(hook.useNativeCurrencyForWeth(), "Hook must use native ETH");
        require(hook.protocolFeeFlags() == 1 << 11, "wrong fee classification");
        require(hook.protocolFeeMultiplier() == 25, "wrong fee multiplier");
        plan.key = PoolKey(Currency.wrap(address(0)), Currency.wrap(wbtc), 3000, 1, IHooks(hookAddress));
        IPoolManager manager = IPoolManager(managerAddress);
        (uint160 price,, uint24 current,) = manager.getSlot0(plan.key.toId());
        require(price != 0, "ETH/WBTC Shell Pool not initialized");
        plan.currentFee = current;
        plan.controller = manager.protocolFeeController();
        require(plan.controller.code.length > 0, "fee controller unavailable");
        IReleaseFeeAdapter adapter = IReleaseFeeAdapter(plan.controller);
        plan.recipient = adapter.TOKEN_JAR();
        require(plan.recipient != address(0), "TokenJar unavailable");
        plan.policyFee = adapter.getFee(plan.key);
        require(ProtocolFeeLibrary.isValidProtocolFee(plan.policyFee), "invalid policy fee");
    }

    /// @dev A zero policy fee stops this release's fee-payment proof, without inventing a fee.
    ///      Reconcile an intentional zero with Uniswap before changing the release requirements.
    function requireCurrentPolicy(FeeUpdatePlan memory plan) public pure {
        require(plan.policyFee != 0, "zero policy fee: stop release for review");
        require(plan.currentFee == plan.policyFee, "official fee update required before canary");
    }

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        address manager = vm.envOr("V4_POOL_MANAGER", PM_DEFAULT);
        address wbtc = vm.envOr("WBTC", WBTC_DEFAULT);
        FeeUpdatePlan memory plan = preview(hook, manager, wbtc);
        console2.log("=== Official ETH/WBTC protocol-fee update ===");
        console2.log("Controller:", plan.controller);
        console2.log("TokenJar:", plan.recipient);
        console2.log("Current packed fee:", uint256(plan.currentFee));
        console2.log("Policy packed fee:", uint256(plan.policyFee));
        console2.log("Effective ETH->WBTC pips:", uint256(plan.policyFee & 0xFFF) * 25);
        console2.log("Effective WBTC->ETH pips:", uint256(plan.policyFee >> 12) * 25);
        console2.log("Update calldata:");
        console2.logBytes(abi.encodeCall(IReleaseFeeAdapter.triggerFeeUpdate, (plan.key)));
        require(plan.policyFee != 0, "zero policy fee: stop release for review");
        if (plan.currentFee == plan.policyFee) {
            console2.log("PoolManager already matches the official policy; no update needed.");
            return;
        }
        if (!vm.envOr("BROADCAST_PROTOCOL_FEE_UPDATE", false)) {
            console2.log("Preview only. Execute the calldata against the printed controller.");
            return;
        }
        vm.startBroadcast();
        IReleaseFeeAdapter(plan.controller).triggerFeeUpdate(plan.key);
        vm.stopBroadcast();
        FeeUpdatePlan memory afterUpdate = preview(hook, manager, wbtc);
        require(afterUpdate.controller == plan.controller, "controller changed; review release again");
        requireCurrentPolicy(afterUpdate);
        console2.log("PoolManager fee readback matches the current official policy.");
    }
}
