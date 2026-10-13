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
import {ISwapV2Pair} from "../src/interfaces/external/IFewV2.sol";
import {FewV2Price} from "../src/lib/FewV2Price.sol";

/// @notice Initializes the recommended Ethereum mainnet FewV2ShellHook pools.
/// @dev    Initialize only after reviewing the matching direct FewV2 pair. originToken
///         Shell liquidity is added separately through the standard PositionManager.
///
/// Required:
///   HOOK_ADDRESS=0x...
///
/// Optional execution mode:
///   BROADCAST_INITIALIZATION=false (default: print calldata only)
///
/// If poolInitializer is a contract wallet, leave BROADCAST_INITIALIZATION=false
/// and execute each printed PoolManager calldata through that wallet.
///
/// Optional:
///   V4_POOL_MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
///   FEW_FACTORY=0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD
///   FEW_V2_FACTORY=0xeb2A625B704d73e82946D8d026E1F588Eed06416
///   WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
///   INCLUDE_USDR=true
contract InitializeRecommendedPools is Script {
    using PoolIdLibrary for PoolKey;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FEW_FACTORY_DEFAULT = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant FEW_V2_FACTORY_DEFAULT = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;

    address constant WETH_DEFAULT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDR = 0x4EA40dcee961675683e0a2e1721Bd49CB9bca913;

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 1;

    struct PoolSpec {
        string label;
        address tokenA;
        address tokenB;
        bool isUsdrPool;
    }

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address fewFactory = vm.envOr("FEW_FACTORY", FEW_FACTORY_DEFAULT);
        address fewV2Factory = vm.envOr("FEW_V2_FACTORY", FEW_V2_FACTORY_DEFAULT);
        address weth = vm.envOr("WETH", WETH_DEFAULT);
        bool includeUsdr = vm.envOr("INCLUDE_USDR", true);
        bool broadcastInitialization = vm.envOr("BROADCAST_INITIALIZATION", false);

        require(hook.code.length > 0, "HOOK_ADDRESS has no code");
        require(poolManager.code.length > 0, "V4_POOL_MANAGER has no code");

        FewV2ShellHook deployed = FewV2ShellHook(payable(hook));
        require(address(deployed.poolManager()) == poolManager, "poolManager mismatch");
        require(address(deployed.fewFactory()) == fewFactory, "fewFactory mismatch");
        require(address(deployed.fewV2Factory()) == fewV2Factory, "fewV2Factory mismatch");
        require(address(deployed.weth()) == weth, "weth mismatch");
        bool nativeEthMode = deployed.useNativeCurrencyForWeth();
        address ethCurrency = nativeEthMode ? address(0) : weth;

        console2.log("=== FewV2ShellHook recommended pool init ===");
        console2.log("Pool manager:", poolManager);
        console2.log("Hook:        ", hook);
        address initializer = deployed.poolInitializer();
        console2.log("Initializer: ", initializer);
        console2.log("Native ETH mode:", nativeEthMode);
        console2.log("INCLUDE_USDR:", includeUsdr);
        console2.log("Broadcast:   ", broadcastInitialization);

        PoolSpec[8] memory specs = [
            PoolSpec({label: "ETH-or-WETH/USDC", tokenA: ethCurrency, tokenB: USDC, isUsdrPool: false}),
            PoolSpec({label: "ETH-or-WETH/USDT", tokenA: ethCurrency, tokenB: USDT, isUsdrPool: false}),
            PoolSpec({label: "ETH-or-WETH/DAI", tokenA: ethCurrency, tokenB: DAI, isUsdrPool: false}),
            PoolSpec({label: "ETH-or-WETH/WBTC", tokenA: ethCurrency, tokenB: WBTC, isUsdrPool: false}),
            PoolSpec({label: "WBTC/USDC", tokenA: WBTC, tokenB: USDC, isUsdrPool: false}),
            PoolSpec({label: "WBTC/USDT", tokenA: WBTC, tokenB: USDT, isUsdrPool: false}),
            PoolSpec({label: "WBTC/DAI", tokenA: WBTC, tokenB: DAI, isUsdrPool: false}),
            PoolSpec({label: "ETH-or-WETH/USDR", tokenA: ethCurrency, tokenB: USDR, isUsdrPool: true})
        ];

        if (broadcastInitialization) {
            require(_isEoa(initializer), "contract initializer: use printed calldata");
            vm.startBroadcast(initializer);
        }
        for (uint256 i = 0; i < specs.length; i++) {
            if (specs[i].isUsdrPool && !includeUsdr) {
                console2.log("skip", specs[i].label, "(INCLUDE_USDR=false)");
                continue;
            }
            _initializeIfNeeded(deployed, IPoolManager(poolManager), IHooks(hook), specs[i], broadcastInitialization);
        }
        if (broadcastInitialization) {
            vm.stopBroadcast();
        }
    }

    function _initializeIfNeeded(
        FewV2ShellHook deployed,
        IPoolManager poolManager,
        IHooks hook,
        PoolSpec memory spec,
        bool broadcastInitialization
    ) internal {
        (address currency0, address currency1) = _sortCurrencies(spec.tokenA, spec.tokenB);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        PoolId poolId = key.toId();
        (address few0, address few1, address pair) = deployed.defaultRouteFor(key);
        require(few0 != address(0), "fewToken0 missing");
        require(few1 != address(0), "fewToken1 missing");
        require(pair != address(0), "FewV2 pair missing");

        (uint112 reserve0, uint112 reserve1) = FewV2Price.orderedReserves(ISwapV2Pair(pair), few0, few1);
        require(reserve0 > 0 && reserve1 > 0, "FewV2 pair has zero reserve");
        uint160 canonicalSqrtPriceX96 = deployed.previewInitializationPrice(key);

        (uint160 beforeSqrtPriceX96, int24 beforeTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        console2.log("");
        console2.log("Pool:", spec.label);
        console2.log("currency0:", currency0);
        console2.log("currency1:", currency1);
        console2.log("few0:     ", few0);
        console2.log("few1:     ", few1);
        console2.log("pair:     ", pair);
        console2.log("reserve0: ", reserve0);
        console2.log("reserve1: ", reserve1);
        console2.log("FewV2 price:", canonicalSqrtPriceX96);
        console2.logBytes32(PoolId.unwrap(poolId));

        if (beforeSqrtPriceX96 != 0) {
            console2.log("already initialized; skipping");
            console2.log("sqrtPriceX96:", beforeSqrtPriceX96);
            console2.log("tick:        ", beforeTick);
            return;
        }

        bytes memory initializeCalldata = abi.encodeCall(poolManager.initialize, (key, canonicalSqrtPriceX96));
        console2.log("Initialization target:", address(poolManager));
        console2.log("Initialization calldata:");
        console2.logBytes(initializeCalldata);

        if (!broadcastInitialization) {
            console2.log("preview only; execute from poolInitializer");
            return;
        }

        int24 tick = poolManager.initialize(key, canonicalSqrtPriceX96);
        (uint160 afterSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(afterSqrtPriceX96 == canonicalSqrtPriceX96, "post-init sqrtPrice mismatch");
        console2.log("initialized");
        console2.log("tick:", tick);
    }

    function _sortCurrencies(address tokenA, address tokenB)
        internal
        pure
        returns (address currency0, address currency1)
    {
        require(tokenA != tokenB, "duplicate currencies");
        return uint160(tokenA) < uint160(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @dev An EIP-7702 delegated EOA still signs its own transactions; its code is the 23-byte
    ///      designator 0xef0100 || delegate.
    function _isEoa(address account) internal view returns (bool) {
        bytes memory code = account.code;
        return code.length == 0 || (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00);
    }
}
