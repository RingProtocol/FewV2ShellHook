// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Factory} from "../src/interfaces/external/IFewV2.sol";

/// @notice Shared CREATE2 deployment logic for the explicit native-ETH and WETH scripts.
/// @dev The executable scripts fix `useNativeCurrencyForWeth` in code so an environment
///      variable cannot silently deploy the wrong representation. The genesis allowlist and
///      constructor-argument encoding live here so the address miner and the deployer always
///      build byte-identical init code; a mismatch is caught by the expected-address check.
abstract contract DeployMainnetBase is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V4_QUOTER_DEFAULT = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant FEW_V2_FACTORY_DEFAULT = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;

    // Genesis allowlist underlyings (canonical Ethereum mainnet addresses). These cover the eight
    // recommended pools; everything else must go through the time-locked governance add path.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDR = 0x4EA40dcee961675683e0a2e1721Bd49CB9bca913;

    uint256 constant DEFAULT_ADD_TIMELOCK_DELAY = 48 hours;

    struct HookConfig {
        address poolManager;
        address weth;
        address v4Quoter;
        address fewFactory;
        address fewV2Factory;
        address poolInitializer;
        address residualRecipient;
        address owner;
        address guardian;
        uint256 addTimelockDelay;
        address[] initialAllowed;
    }

    /// @dev Genesis allowlist in a fixed order so the encoded constructor args are deterministic.
    ///      `weth` is passed in (env-overridable) to stay consistent with the resolved WETH address.
    function _genesisAllowlist(address weth) internal pure returns (address[] memory allowed) {
        allowed = new address[](6);
        allowed[0] = weth;
        allowed[1] = USDC;
        allowed[2] = USDT;
        allowed[3] = DAI;
        allowed[4] = WBTC;
        allowed[5] = USDR;
    }

    function _readHookConfig() internal view returns (HookConfig memory c) {
        c.poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        c.weth = vm.envOr("WETH", WETH_DEFAULT);
        c.v4Quoter = vm.envOr("V4_QUOTER", V4_QUOTER_DEFAULT);
        c.fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        c.fewV2Factory = vm.envOr("FEW_V2_FACTORY", FEW_V2_FACTORY_DEFAULT);
        c.poolInitializer = vm.envAddress("POOL_INITIALIZER_ADDRESS");
        c.residualRecipient = vm.envAddress("RESIDUAL_RECIPIENT_ADDRESS");
        c.owner = vm.envAddress("HOOK_OWNER_ADDRESS");
        c.guardian = vm.envAddress("GUARDIAN_ADDRESS");
        c.addTimelockDelay = vm.envOr("ADD_TIMELOCK_DELAY", DEFAULT_ADD_TIMELOCK_DELAY);
        c.initialAllowed = _genesisAllowlist(c.weth);
    }

    function _hookCtorArgs(HookConfig memory c, bool useNativeCurrencyForWeth) internal pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(c.poolManager),
            IFewFactory(c.fewFactory),
            ISwapV2Factory(c.fewV2Factory),
            IWETH9(c.weth),
            IV4Quoter(c.v4Quoter),
            useNativeCurrencyForWeth,
            c.poolInitializer,
            c.residualRecipient,
            c.owner,
            c.guardian,
            c.addTimelockDelay,
            c.initialAllowed
        );
    }

    function _deploy(
        bool useNativeCurrencyForWeth,
        string memory saltEnvironmentVariable,
        string memory expectedAddressEnvironmentVariable
    ) internal {
        HookConfig memory c = _readHookConfig();
        bytes32 salt = vm.envBytes32(saltEnvironmentVariable);
        address expectedAddr = vm.envAddress(expectedAddressEnvironmentVariable);
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        require(
            (uint160(expectedAddr) & uint160(Hooks.ALL_HOOK_MASK)) == flags, "expected Hook has wrong permission bits"
        );

        bytes memory creationCode = type(FewV2ShellHook).creationCode;
        bytes memory ctorArgs = _hookCtorArgs(c, useNativeCurrencyForWeth);
        bytes memory initCode = abi.encodePacked(creationCode, ctorArgs);
        address predictedAddr = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode)))))
        );
        require(predictedAddr == expectedAddr, "salt and constructor arguments predict a different Hook address");

        console2.log("=== Pre-flight ===");
        console2.log("CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("Expected hook:   ", expectedAddr);
        console2.log("Pool manager:    ", c.poolManager);
        console2.log("Pool initializer:", c.poolInitializer);
        console2.log("Residual target: ", c.residualRecipient);
        console2.log("Owner:           ", c.owner);
        console2.log("Guardian:        ", c.guardian);
        console2.log("Add timelock (s):", c.addTimelockDelay);
        console2.log("Native ETH mode: ", useNativeCurrencyForWeth);
        console2.log("Genesis allowlist size:", c.initialAllowed.length);
        for (uint256 i = 0; i < c.initialAllowed.length; i++) {
            console2.log("  allow:", c.initialAllowed[i]);
        }
        console2.log("Constructor args:");
        console2.logBytes(ctorArgs);

        // CREATE2 proxy ABI: abi.encodePacked(salt, init_code).
        bytes memory deployData = abi.encodePacked(salt, initCode);

        vm.startBroadcast();

        (bool ok,) = CREATE2_DEPLOYER.call(deployData);
        require(ok, "CREATE2 deployer call failed");

        // The release address was derived from this exact deployer, salt and init code above.
        // Verify code at that address instead of trusting a deployer-specific return encoding.
        address hookAddr = expectedAddr;
        require(hookAddr.code.length > 0, "Hook bytecode missing");
        require((uint160(hookAddr) & uint160(Hooks.ALL_HOOK_MASK)) == flags, "deployed Hook has wrong permission bits");

        FewV2ShellHook deployed = FewV2ShellHook(payable(hookAddr));
        require(deployed.residualRecipient() == c.residualRecipient, "residualRecipient mismatch in deployed hook");
        require(address(deployed.fewFactory()) == c.fewFactory, "fewFactory mismatch in deployed hook");
        require(address(deployed.fewV2Factory()) == c.fewV2Factory, "fewV2Factory mismatch in deployed hook");
        require(address(deployed.weth()) == c.weth, "weth mismatch in deployed hook");
        require(address(deployed.v4Quoter()) == c.v4Quoter, "v4Quoter mismatch in deployed hook");
        require(deployed.poolInitializer() == c.poolInitializer, "poolInitializer mismatch in deployed hook");
        require(
            deployed.useNativeCurrencyForWeth() == useNativeCurrencyForWeth,
            "useNativeCurrencyForWeth mismatch in deployed hook"
        );
        require(deployed.CANONICAL_POOL_FEE() == 3000, "CANONICAL_POOL_FEE must be 3000");
        require(deployed.protocolFeeFlags() == 1 << 11, "wrong Uniswap fee classification");
        require(deployed.protocolFeeMultiplier() == 25, "wrong Aggregator fee multiplier");

        // Governance configuration must match what the address was mined against.
        require(deployed.owner() == c.owner, "owner mismatch in deployed hook");
        require(deployed.guardian() == c.guardian, "guardian mismatch in deployed hook");
        require(deployed.addTimelockDelay() == c.addTimelockDelay, "addTimelockDelay mismatch in deployed hook");
        for (uint256 i = 0; i < c.initialAllowed.length; i++) {
            require(deployed.allowedUnderlying(c.initialAllowed[i]), "genesis underlying not allowlisted");
        }

        console2.log("=== Hook deployed ===");
        console2.log("Address:", hookAddr);
        console2.log("Runtime codehash:");
        console2.logBytes32(hookAddr.codehash);
        console2.log("State asserts: all passed");

        vm.stopBroadcast();

        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify source and immutable configuration on Etherscan");
        console2.log("     Use the constructor args printed above for forge verify-contract");
        console2.log("  2. Initialize pools from the poolInitializer account");
        console2.log("  3. Submit this Hook address to the Uniswap Hook Registry and UniRoute process");
        console2.log("  4. Confirm Quote API discovery and run a bounded smoke swap after approval");
    }
}
