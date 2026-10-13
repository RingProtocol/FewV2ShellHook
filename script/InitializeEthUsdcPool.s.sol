// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";

/// @notice Initializes the deployed FewV2ShellHook ETH/USDC v4 pool only.
/// @dev    This script never deploys the hook. Use after FewV2ShellHook has
///         been deployed and source-verified.
///
/// Required:
///   HOOK_ADDRESS=0x...
///
/// Optional execution mode:
///   BROADCAST_INITIALIZATION=false (default: print calldata only)
///
/// If poolInitializer is a contract wallet, leave BROADCAST_INITIALIZATION=false
/// and execute the printed PoolManager calldata through that wallet.
///
/// Optional defaults are Ethereum mainnet:
///   V4_POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
///   FEW_FACTORY=0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD
///   FEW_V2_FACTORY=0xeb2A625B704d73e82946D8d026E1F588Eed06416
///   WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
///   USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
contract InitializeEthUsdcPool is Script {
    using PoolIdLibrary for PoolKey;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_DEFAULT = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant FEW_V2_FACTORY_DEFAULT = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 1;

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address weth = vm.envOr("WETH", WETH_DEFAULT);
        address usdc = vm.envOr("USDC", USDC_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address fewV2Factory = vm.envOr("FEW_V2_FACTORY", FEW_V2_FACTORY_DEFAULT);
        bool broadcastInitialization = vm.envOr("BROADCAST_INITIALIZATION", false);

        require(hook.code.length > 0, "HOOK_ADDRESS has no code");
        require(poolManager.code.length > 0, "V4_POOL_MANAGER has no code");

        FewV2ShellHook deployed = FewV2ShellHook(payable(hook));
        require(address(deployed.poolManager()) == poolManager, "poolManager mismatch");
        require(address(deployed.fewFactory()) == fewFactory, "fewFactory mismatch");
        require(address(deployed.fewV2Factory()) == fewV2Factory, "fewV2Factory mismatch");
        require(address(deployed.weth()) == weth, "weth mismatch");
        require(deployed.useNativeCurrencyForWeth(), "hook must use native ETH");
        address initializer = deployed.poolInitializer();
        console2.log("Pool initializer:", initializer);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        PoolId poolId = key.toId();
        (address fewEth, address fewUsdc, address pair) = deployed.defaultRouteFor(key);
        require(fewEth != address(0), "fwETH missing");
        require(fewUsdc != address(0), "fwUSDC missing");
        require(pair != address(0), "FewV2 ETH/USDC pair missing");
        uint160 canonicalSqrtPriceX96 = deployed.previewInitializationPrice(key);

        (uint160 beforeSqrtPriceX96, int24 beforeTick,,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);

        console2.log("=== FewV2ShellHook ETH/USDC init-only ===");
        console2.log("Pool manager:", poolManager);
        console2.log("Hook:        ", hook);
        console2.log("USDC:        ", usdc);
        console2.log("fwETH:       ", fewEth);
        console2.log("fwUSDC:      ", fewUsdc);
        console2.log("FewV2 pair:  ", pair);
        console2.log("FewV2 price: ", canonicalSqrtPriceX96);
        console2.logBytes32(PoolId.unwrap(poolId));

        if (beforeSqrtPriceX96 != 0) {
            console2.log("Pool already initialized; no transaction sent.");
            console2.log("sqrtPriceX96:", beforeSqrtPriceX96);
            console2.log("tick:        ", beforeTick);
            return;
        }

        bytes memory initializeCalldata = abi.encodeCall(IPoolManager.initialize, (key, canonicalSqrtPriceX96));
        console2.log("Initialization target:", poolManager);
        console2.log("Initialization calldata:");
        console2.logBytes(initializeCalldata);

        if (!broadcastInitialization) {
            console2.log("Preview only. Execute the calldata from poolInitializer.");
            return;
        }

        require(_isEoa(initializer), "contract initializer: use printed calldata");
        vm.startBroadcast(initializer);
        int24 tick = IPoolManager(poolManager).initialize(key, canonicalSqrtPriceX96);
        vm.stopBroadcast();

        (uint160 afterSqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        require(afterSqrtPriceX96 == canonicalSqrtPriceX96, "post-init sqrtPrice mismatch");

        console2.log("=== Initialized ===");
        console2.log("sqrtPriceX96:", afterSqrtPriceX96);
        console2.log("tick:        ", tick);
    }

    /// @dev An EIP-7702 delegated EOA still signs its own transactions; its code is the 23-byte
    ///      designator 0xef0100 || delegate.
    function _isEoa(address account) internal view returns (bool) {
        bytes memory code = account.code;
        return code.length == 0 || (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00);
    }
}
