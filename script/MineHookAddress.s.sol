// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {DeployMainnetBase} from "./DeployMainnetBase.sol";
import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";

/// @notice Mine a CREATE2 salt for FewV2ShellHook so its address encodes the
///         beforeInitialize | beforeSwap | beforeSwapReturnsDelta flags
///         (mask 0x2088) in the lowest 14 bits. The governance layer adds no liquidity callback,
///         so the permission mask is identical to the admin-less base hook.
///
///         Run BEFORE deployment day, with the SAME env that deployment will use (the owner,
///         guardian and genesis allowlist are part of the init code and therefore the
///         address):
///
///             RESIDUAL_RECIPIENT_ADDRESS=0x... \
///             POOL_INITIALIZER_ADDRESS=0x... \
///             HOOK_OWNER_ADDRESS=0x... \
///             GUARDIAN_ADDRESS=0x... \
///             USE_NATIVE_CURRENCY_FOR_WETH=true \
///             forge script script/MineHookAddress.s.sol --via-ir
///
///         Output the salt + predicted address into the matching mode-specific env vars,
///         then run DeployMainnetNativeEth or DeployMainnetWeth with the same env.
///         The address only needs the same `0x2088` v4 permission mask used by the
///         validated Shell route. Current public UniRoute treats that route as a normal
///         v4 Hook and does not require an Aggregator first-byte protocol ID.
///
/// @dev    The deployer used here is the canonical CREATE2 proxy
///         `0x4e59b44847b379578588920cA78FbF26c0B4956C`. Constructor dependencies are part
///         of init code, so mine separately whenever a chain uses different addresses.
contract MineHookAddress is DeployMainnetBase {
    function run() external view {
        bool useNativeCurrencyForWeth = vm.envOr("USE_NATIVE_CURRENCY_FOR_WETH", true);
        HookConfig memory c = _readHookConfig();

        // The three flags the contract subscribes to.
        // Bit positions (from v4-core/src/libraries/Hooks.sol):
        //   BEFORE_INITIALIZE_FLAG          = 1 << 13   = 0x2000
        //   BEFORE_SWAP_FLAG                = 1 <<  7   = 0x0080
        //   BEFORE_SWAP_RETURNS_DELTA_FLAG  = 1 <<  3   = 0x0008
        //   ─────────────────────────────────────────────────────
        //   Combined mask                                = 0x2088
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        bytes memory creationCode = type(FewV2ShellHook).creationCode;
        bytes memory ctorArgs = _hookCtorArgs(c, useNativeCurrencyForWeth);

        console2.log("=== Mining hook address ===");
        console2.log("CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("Pool manager:    ", c.poolManager);
        console2.log("Few factory:     ", c.fewFactory);
        console2.log("FewV2 factory:   ", c.fewV2Factory);
        console2.log("WETH:            ", c.weth);
        console2.log("V4 quoter:       ", c.v4Quoter);
        console2.log("Native ETH mode: ", useNativeCurrencyForWeth);
        console2.log("Pool initializer:", c.poolInitializer);
        console2.log("Residual target: ", c.residualRecipient);
        console2.log("Subsidy vault:  ", c.subsidyVault);
        console2.log("Owner:           ", c.owner);
        console2.log("Guardian:        ", c.guardian);
        console2.log("Genesis allowlist size:", c.initialAllowed.length);
        for (uint256 i = 0; i < c.initialAllowed.length; i++) {
            console2.log("  allow:", c.initialAllowed[i]);
        }
        console2.log("Flags (uint160): ", flags);
        console2.log("");

        (address mined, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, creationCode, ctorArgs);

        console2.log("=== Mining complete ===");
        console2.log("Hook address:    ", mined);
        console2.log("Salt:");
        console2.logBytes32(salt);
        console2.log("");
        if (useNativeCurrencyForWeth) {
            console2.log("Save as NATIVE_ETH_HOOK_SALT and NATIVE_ETH_EXPECTED_HOOK_ADDRESS.");
            console2.log("Then run DeployMainnetNativeEth.s.sol.");
        } else {
            console2.log("Save as WETH_HOOK_SALT and WETH_EXPECTED_HOOK_ADDRESS.");
            console2.log("Then run DeployMainnetWeth.s.sol.");
        }
    }
}
