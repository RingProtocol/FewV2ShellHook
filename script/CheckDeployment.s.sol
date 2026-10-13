// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DeployMainnetBase} from "./DeployMainnetBase.sol";
import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";

/// @notice Read-only post-deployment check of a FewV2ShellHook. Sends no transaction.
/// @dev Uses the same role and dependency environment as MineHookAddress and the deploy scripts:
///
///   POOL_INITIALIZER_ADDRESS, RESIDUAL_RECIPIENT_ADDRESS, HOOK_OWNER_ADDRESS, GUARDIAN_ADDRESS
///   (constructor values), plus the optional dependency overrides and ADD_TIMELOCK_DELAY.
///
/// Required:
///   HOOK_ADDRESS=0x...          deployed Hook
///   EXPECT_NATIVE_ETH=true      deployment mode the Hook must have
///
/// Optional:
///   HOOK_SALT=0x...             recompute the CREATE2 address from the locally built init code;
///                               a match proves the on-chain contract was created from this exact
///                               source and constructor configuration
///   EXPECT_OWNER=0x...          current owner (default HOOK_OWNER_ADDRESS; set after rotation)
///   EXPECT_GUARDIAN=0x...       current guardian (default GUARDIAN_ADDRESS)
///   EXPECT_POOL_INITIALIZER=0x...    current pool initializer (default POOL_INITIALIZER_ADDRESS)
///   EXPECT_RESIDUAL_RECIPIENT=0x...  current residual recipient (default RESIDUAL_RECIPIENT_ADDRESS)
///   EXPECT_PAUSED=false
///   EXPECT_GENESIS_ALLOWLIST=true
///
///   forge script script/CheckDeployment.s.sol:CheckDeployment --rpc-url $ETH_RPC_URL
///
/// Every mismatch reverts. The report also prints the state of the eight recommended Shell Pools.
contract CheckDeployment is DeployMainnetBase {
    using PoolIdLibrary for PoolKey;

    struct PoolSpec {
        string label;
        address tokenA;
        address tokenB;
    }

    function run() external view {
        HookConfig memory c = _readHookConfig();
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        bool expectNative = vm.envBool("EXPECT_NATIVE_ETH");
        address expectOwner = vm.envOr("EXPECT_OWNER", c.owner);
        address expectGuardian = vm.envOr("EXPECT_GUARDIAN", c.guardian);
        address expectPoolInitializer = vm.envOr("EXPECT_POOL_INITIALIZER", c.poolInitializer);
        address expectResidualRecipient = vm.envOr("EXPECT_RESIDUAL_RECIPIENT", c.residualRecipient);
        bool expectPaused = vm.envOr("EXPECT_PAUSED", false);
        bool expectGenesisAllowlist = vm.envOr("EXPECT_GENESIS_ALLOWLIST", true);

        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        require(hookAddr.code.length > 0, "HOOK_ADDRESS has no code");
        require((uint160(hookAddr) & uint160(Hooks.ALL_HOOK_MASK)) == flags, "wrong v4 permission bits");

        bytes32 salt = vm.envOr("HOOK_SALT", bytes32(0));
        if (salt != bytes32(0)) {
            bytes memory initCode = abi.encodePacked(type(FewV2ShellHook).creationCode, _hookCtorArgs(c, expectNative));
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode)))))
            );
            require(predicted == hookAddr, "local init code and HOOK_SALT do not reproduce HOOK_ADDRESS");
        }

        FewV2ShellHook hook = FewV2ShellHook(payable(hookAddr));
        require(address(hook.poolManager()) == c.poolManager, "poolManager mismatch");
        require(address(hook.fewFactory()) == c.fewFactory, "fewFactory mismatch");
        require(address(hook.fewV2Factory()) == c.fewV2Factory, "fewV2Factory mismatch");
        require(address(hook.weth()) == c.weth, "weth mismatch");
        require(address(hook.v4Quoter()) == c.v4Quoter, "v4Quoter mismatch");
        require(hook.useNativeCurrencyForWeth() == expectNative, "native ETH mode mismatch");
        require(hook.poolInitializer() == expectPoolInitializer, "poolInitializer mismatch");
        require(hook.residualRecipient() == expectResidualRecipient, "residualRecipient mismatch");
        require(hook.CANONICAL_POOL_FEE() == 3000, "CANONICAL_POOL_FEE must be 3000");
        require(hook.CANONICAL_TICK_SPACING() == 1, "CANONICAL_TICK_SPACING must be 1");
        require(hook.addTimelockDelay() == c.addTimelockDelay, "addTimelockDelay mismatch");
        require(hook.owner() == expectOwner, "owner mismatch");
        require(hook.guardian() == expectGuardian, "guardian mismatch");
        require(hook.paused() == expectPaused, "paused state mismatch");

        console2.log("=== FewV2ShellHook check: PASS ===");
        console2.log("Hook:             ", hookAddr);
        console2.log("CREATE2 verified: ", salt != bytes32(0));
        console2.log("Native ETH mode:  ", expectNative);
        console2.log("Owner:            ", hook.owner());
        console2.log("Pending owner:    ", hook.pendingOwner());
        console2.log("Guardian:         ", hook.guardian());
        console2.log("Paused:           ", hook.paused());
        console2.log("Add timelock (s): ", hook.addTimelockDelay());
        console2.log("Pool initializer: ", hook.poolInitializer());
        console2.log("Residual target:  ", hook.residualRecipient());
        console2.log("Runtime codehash:");
        console2.logBytes32(hookAddr.codehash);

        console2.log("Genesis allowlist:");
        for (uint256 i = 0; i < c.initialAllowed.length; i++) {
            bool allowed = hook.allowedUnderlying(c.initialAllowed[i]);
            console2.log("  ", c.initialAllowed[i], allowed);
            if (expectGenesisAllowlist) require(allowed, "genesis underlying not allowlisted");
        }

        _reportPools(hook, IPoolManager(c.poolManager), expectNative ? address(0) : c.weth);
    }

    function _reportPools(FewV2ShellHook hook, IPoolManager poolManager, address ethCurrency) internal view {
        PoolSpec[8] memory specs = [
            PoolSpec({label: "ETH-or-WETH/USDC", tokenA: ethCurrency, tokenB: USDC}),
            PoolSpec({label: "ETH-or-WETH/USDT", tokenA: ethCurrency, tokenB: USDT}),
            PoolSpec({label: "ETH-or-WETH/DAI", tokenA: ethCurrency, tokenB: DAI}),
            PoolSpec({label: "ETH-or-WETH/WBTC", tokenA: ethCurrency, tokenB: WBTC}),
            PoolSpec({label: "WBTC/USDC", tokenA: WBTC, tokenB: USDC}),
            PoolSpec({label: "WBTC/USDT", tokenA: WBTC, tokenB: USDT}),
            PoolSpec({label: "WBTC/DAI", tokenA: WBTC, tokenB: DAI}),
            PoolSpec({label: "ETH-or-WETH/USDR", tokenA: ethCurrency, tokenB: USDR})
        ];

        console2.log("");
        console2.log("=== Recommended Shell Pools (fee 3000, tickSpacing 1) ===");
        for (uint256 i = 0; i < specs.length; i++) {
            (address currency0, address currency1) = uint160(specs[i].tokenA) < uint160(specs[i].tokenB)
                ? (specs[i].tokenA, specs[i].tokenB)
                : (specs[i].tokenB, specs[i].tokenA);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(currency0),
                currency1: Currency.wrap(currency1),
                fee: 3000,
                tickSpacing: 1,
                hooks: IHooks(address(hook))
            });
            PoolId poolId = key.toId();
            (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

            console2.log("");
            console2.log(specs[i].label);
            console2.logBytes32(PoolId.unwrap(poolId));
            if (sqrtPriceX96 == 0) {
                console2.log("  not initialized");
                continue;
            }

            (address few0, address few1, address pair) = hook.registeredRouteFor(poolId);
            require(pair != address(0), "initialized pool has no registered route");
            (uint256 depth0, uint256 depth1) = hook.pseudoTotalValueLocked(poolId);
            (uint256 backing0, uint256 backing1) = hook.availableWrapperBacking(poolId);
            (uint256 cash0, uint256 cash1) = hook.availableSettlementInventory(poolId);

            console2.log("  few0 / few1:    ", few0, few1);
            console2.log("  FewV2 pair:     ", pair);
            console2.log("  Shell liquidity:", StateLibrary.getLiquidity(poolManager, poolId));
            console2.log("  depth0 / depth1:", depth0, depth1);
            console2.log("  backing0 / 1:   ", backing0, backing1);
            console2.log("  PM cash0 / 1:   ", cash0, cash1);
        }
    }
}
