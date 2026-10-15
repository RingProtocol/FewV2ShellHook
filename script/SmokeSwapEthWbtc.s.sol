// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";
import {UpdateEthWbtcProtocolFee} from "./UpdateEthWbtcProtocolFee.s.sol";

interface ISmokeUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Builds an official Universal Router V4_SWAP for a tiny ETH->WBTC canary.
/// @dev Preview-only by default. This proves the candidate's standard v4 calldata shape;
///      it does not prove that the production Quote API or Uniswap App selected the route.
contract SmokeSwapEthWbtc is Script {
    using PoolIdLibrary for PoolKey;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V4_QUOTER_DEFAULT = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant UNIVERSAL_ROUTER_DEFAULT = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant WBTC_DEFAULT = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    uint256 constant DEFAULT_SMOKE_ETH_IN = 0.0001 ether;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 1;

    function run() external {
        address hook = vm.envAddress("HOOK_ADDRESS");
        address poolManager = vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT);
        address quoterAddress = vm.envOr("V4_QUOTER", V4_QUOTER_DEFAULT);
        address routerAddress = vm.envOr("UNIVERSAL_ROUTER", UNIVERSAL_ROUTER_DEFAULT);
        address wbtc = vm.envOr("WBTC", WBTC_DEFAULT);
        uint256 amountIn = vm.envOr("SMOKE_ETH_IN", DEFAULT_SMOKE_ETH_IN);
        bool broadcastSmoke = vm.envOr("BROADCAST_SMOKE", false);
        uint256 deadline = vm.envOr("SMOKE_DEADLINE", block.timestamp + 20 minutes);

        require(hook.code.length > 0, "HOOK_ADDRESS has no code");
        require(poolManager.code.length > 0, "V4_POOL_MANAGER has no code");
        require(quoterAddress.code.length > 0, "V4_QUOTER has no code");
        require(routerAddress.code.length > 0, "UNIVERSAL_ROUTER has no code");
        require(amountIn > 0 && amountIn <= type(uint128).max, "invalid SMOKE_ETH_IN");
        // Safe after the explicit bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 amountIn128 = uint128(amountIn);

        FewV2ShellHook deployed = FewV2ShellHook(payable(hook));
        require(address(deployed.poolManager()) == poolManager, "poolManager mismatch");
        require(address(deployed.v4Quoter()) == quoterAddress, "V4Quoter mismatch");
        require(deployed.useNativeCurrencyForWeth(), "Hook is not in native ETH mode");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(wbtc),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        require(sqrtPriceX96 != 0, "ETH/WBTC Shell Pool not initialized");

        UpdateEthWbtcProtocolFee feeCheck = new UpdateEthWbtcProtocolFee();
        UpdateEthWbtcProtocolFee.FeeUpdatePlan memory feePlan = feeCheck.preview(hook, poolManager, wbtc);
        feeCheck.requireCurrentPolicy(feePlan);
        console2.log("Protocol-fee controller:", feePlan.controller);
        console2.log("Protocol-fee recipient:", feePlan.recipient);
        console2.log("Active packed protocol fee:", uint256(feePlan.currentFee));

        IV4Quoter.QuoteExactSingleParams memory quoteParams = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: true, exactAmount: amountIn128, hookData: bytes("")
        });
        (uint256 quotedOut,) = IV4Quoter(quoterAddress).quoteExactInputSingle(quoteParams);
        uint256 hookQuotedOut = deployed.quote(true, -int256(amountIn), poolId);
        require(quotedOut == hookQuotedOut, "Hook and official V4Quoter disagree");
        require(quotedOut <= type(uint128).max, "quote exceeds Universal Router amount range");

        uint256 minOut = vm.envOr("SMOKE_MIN_WBTC_OUT", (quotedOut * 9950) / 10_000);
        require(minOut > 0 && minOut <= quotedOut, "invalid SMOKE_MIN_WBTC_OUT");
        // Safe after quotedOut is bounded above and minOut <= quotedOut.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 minOut128 = uint128(minOut);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key.currency0, amountIn, true);
        params[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: amountIn128, amountOutMinimum: minOut128, hookData: ""
            })
        );
        params[2] = abi.encode(key.currency1, minOut);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        bytes memory commands = hex"10";
        bytes memory routerCalldata = abi.encodeCall(ISmokeUniversalRouter.execute, (commands, inputs, deadline));

        console2.log("=== ETH/WBTC Universal Router canary ===");
        console2.log("Universal Router:", routerAddress);
        console2.log("PoolManager:     ", poolManager);
        console2.log("Hook:            ", hook);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("ETH in:          ", amountIn);
        console2.log("Official quote:  ", quotedOut);
        console2.log("Minimum WBTC out:", minOut);
        console2.log("Deadline:        ", deadline);
        console2.log("Router calldata:");
        console2.logBytes(routerCalldata);

        if (!broadcastSmoke) {
            console2.log("Preview only. Set BROADCAST_SMOKE=true only after simulation and approval.");
            return;
        }

        vm.startBroadcast();
        ISmokeUniversalRouter(routerAddress).execute{value: amountIn}(commands, inputs, deadline);
        vm.stopBroadcast();
        console2.log("Canary submitted through the official Universal Router.");
    }
}
