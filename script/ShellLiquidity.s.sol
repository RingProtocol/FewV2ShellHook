// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {FewV2ShellHook} from "../src/FewV2ShellHook.sol";

/// @notice Adds or fully withdraws originToken Shell liquidity through the official v4 PositionManager.
/// @dev Shell liquidity is the discoverable depth and PoolManager working inventory behind Hook
///      swaps. Hook swaps never move it and it earns no swap fee; it stays withdrawable while the
///      Hook is paused. Preview-only by default: without BROADCAST_LP=true the script prints every
///      transaction (target, value, calldata) for execution through a contract wallet.
///
/// Common:
///   HOOK_ADDRESS=0x...
///   LP_ACTION=mint | burn
///   LP_EXECUTOR=0x...            account that sends the transactions (default: script sender)
///   LP_DEADLINE=<unix seconds>   default now + 20 minutes; extend for multisig signing
///   BROADCAST_LP=false
///
/// Mint:
///   LP_TOKEN_A=0x..., LP_TOKEN_B=0x...         0x0000000000000000000000000000000000000000 = native ETH
///   LP_AMOUNT_A_MAX=..., LP_AMOUNT_B_MAX=...   raw token units; caps, not targets
///   LP_TICK_LOWER, LP_TICK_UPPER               default full range
///   LP_PERMIT2_EXPIRY_SECONDS=3600
///
/// Burn (withdraws the whole position and burns the NFT):
///   LP_TOKEN_ID=...
///   LP_MIN_OUT_BPS=9950                        minimum share of each expected amount
///
/// The position NFT, unused native ETH and withdrawn tokens go to the executing account.
contract ShellLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    address constant V4_PM_DEFAULT = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER_DEFAULT = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2_DEFAULT = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 1;

    struct Context {
        FewV2ShellHook hook;
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
        address executor;
        uint256 deadline;
        bool broadcastLp;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function run() external {
        Context memory ctx;
        ctx.hook = FewV2ShellHook(payable(vm.envAddress("HOOK_ADDRESS")));
        ctx.poolManager = IPoolManager(vm.envOr("V4_POOL_MANAGER", V4_PM_DEFAULT));
        ctx.positionManager = IPositionManager(vm.envOr("V4_POSITION_MANAGER", POSITION_MANAGER_DEFAULT));
        ctx.permit2 = IAllowanceTransfer(vm.envOr("PERMIT2", PERMIT2_DEFAULT));
        ctx.executor = vm.envOr("LP_EXECUTOR", msg.sender);
        ctx.deadline = vm.envOr("LP_DEADLINE", block.timestamp + 20 minutes);
        ctx.broadcastLp = vm.envOr("BROADCAST_LP", false);

        require(address(ctx.hook).code.length > 0, "HOOK_ADDRESS has no code");
        require(address(ctx.hook.poolManager()) == address(ctx.poolManager), "poolManager mismatch");
        require(address(ctx.positionManager).code.length > 0, "V4_POSITION_MANAGER has no code");
        require(!ctx.broadcastLp || ctx.executor == msg.sender, "LP_EXECUTOR must be the broadcaster");

        bytes32 action = keccak256(bytes(vm.envString("LP_ACTION")));
        bool isMint = action == keccak256("mint");
        require(isMint || action == keccak256("burn"), "LP_ACTION must be mint or burn");

        uint256 tokenId;
        uint128 expectedLiquidity;
        PoolKey memory key;
        Call[] memory calls;
        if (isMint) {
            tokenId = ctx.positionManager.nextTokenId();
            (calls, key, expectedLiquidity) = _mintCalls(ctx);
        } else {
            tokenId = vm.envUint("LP_TOKEN_ID");
            (calls, key) = _burnCalls(ctx, tokenId);
        }

        console2.log("");
        console2.log("Transactions from:", ctx.executor);
        for (uint256 i = 0; i < calls.length; i++) {
            console2.log("");
            console2.log("tx", i + 1);
            console2.log("  target:", calls[i].target);
            console2.log("  value: ", calls[i].value);
            console2.log("  data:");
            console2.logBytes(calls[i].data);
        }
        if (!ctx.broadcastLp) {
            console2.log("");
            console2.log("Preview only. Set BROADCAST_LP=true to send from the broadcaster.");
            return;
        }

        uint256 before0 = _balance(key.currency0, ctx.executor);
        uint256 before1 = _balance(key.currency1, ctx.executor);
        vm.startBroadcast();
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
            require(ret.length == 0 || abi.decode(ret, (bool)), "call returned false");
        }
        vm.stopBroadcast();
        uint256 after0 = _balance(key.currency0, ctx.executor);
        uint256 after1 = _balance(key.currency1, ctx.executor);

        console2.log("");
        if (isMint) {
            require(IERC721(address(ctx.positionManager)).ownerOf(tokenId) == ctx.executor, "NFT owner mismatch");
            require(ctx.positionManager.getPositionLiquidity(tokenId) == expectedLiquidity, "liquidity mismatch");
            console2.log("=== Minted Shell position ===");
            // forge prints the simulation; another mint can land before the broadcast transaction.
            console2.log("predicted tokenId:", tokenId);
            console2.log("Confirm the tokenId from the PositionManager Transfer event in the mint receipt.");
            console2.log("liquidity:", expectedLiquidity);
            console2.log("spent0:   ", before0 - after0);
            console2.log("spent1:   ", before1 - after1);
        } else {
            require(ctx.positionManager.getPositionLiquidity(tokenId) == 0, "position still has liquidity");
            console2.log("=== Withdrew and burned Shell position ===");
            console2.log("tokenId:  ", tokenId);
            console2.log("received0:", after0 - before0);
            console2.log("received1:", after1 - before1);
        }
    }

    function _mintCalls(Context memory ctx)
        internal
        view
        returns (Call[] memory calls, PoolKey memory key, uint128 liquidity)
    {
        address tokenA = vm.envAddress("LP_TOKEN_A");
        address tokenB = vm.envAddress("LP_TOKEN_B");
        uint256 amountAMax = vm.envUint("LP_AMOUNT_A_MAX");
        uint256 amountBMax = vm.envUint("LP_AMOUNT_B_MAX");
        int256 lower = vm.envOr("LP_TICK_LOWER", int256(TickMath.minUsableTick(TICK_SPACING)));
        int256 upper = vm.envOr("LP_TICK_UPPER", int256(TickMath.maxUsableTick(TICK_SPACING)));
        uint256 permitExpiry = block.timestamp + vm.envOr("LP_PERMIT2_EXPIRY_SECONDS", uint256(1 hours));

        require(tokenA != tokenB, "duplicate currencies");
        require(lower >= TickMath.MIN_TICK && upper <= TickMath.MAX_TICK && lower < upper, "invalid tick range");
        require(permitExpiry <= type(uint48).max, "invalid LP_PERMIT2_EXPIRY_SECONDS");
        (address c0, address c1, uint256 max0, uint256 max1) = uint160(tokenA) < uint160(tokenB)
            ? (tokenA, tokenB, amountAMax, amountBMax)
            : (tokenB, tokenA, amountBMax, amountAMax);
        require(max0 <= type(uint128).max && max1 <= type(uint128).max, "amount exceeds uint128");

        key = _shellKey(ctx, c0, c1);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(ctx.poolManager, key.toId());
        require(sqrtPriceX96 != 0, "Shell Pool not initialized");

        // Safe after the explicit tick bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (int24 tickLower, int24 tickUpper) = (int24(lower), int24(upper));
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), max0, max1
        );
        require(liquidity > 0, "caps give zero liquidity");
        (uint256 need0, uint256 need1) = _amountsForLiquidity(sqrtPriceX96, tickLower, tickUpper, liquidity, true);

        console2.log("=== Shell liquidity mint ===");
        console2.log("Hook:       ", address(ctx.hook));
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("currency0:  ", c0);
        console2.log("currency1:  ", c1);
        console2.log("tickLower:  ", tickLower);
        console2.log("tickUpper:  ", tickUpper);
        console2.log("liquidity:  ", liquidity);
        console2.log("max0 / need0:", max0, need0);
        console2.log("max1 / need1:", max1, need1);

        // Safe after the uint128 bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint128 cap0, uint128 cap1) = (uint128(max0), uint128(max1));
        bool native0 = c0 == address(0);
        bytes[] memory params = new bytes[](native0 ? 3 : 2);
        params[0] =
            abi.encode(key, tickLower, tickUpper, uint256(liquidity), cap0, cap1, ActionConstants.MSG_SENDER, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        bytes memory actions;
        if (native0) {
            params[2] = abi.encode(key.currency0, ActionConstants.MSG_SENDER);
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        } else {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        }

        Call[] memory approvals0 = native0 ? new Call[](0) : _permit2Approvals(ctx, c0, max0, permitExpiry);
        Call[] memory approvals1 = _permit2Approvals(ctx, c1, max1, permitExpiry);
        calls = new Call[](approvals0.length + approvals1.length + 1);
        for (uint256 i = 0; i < approvals0.length; i++) {
            calls[i] = approvals0[i];
        }
        for (uint256 i = 0; i < approvals1.length; i++) {
            calls[approvals0.length + i] = approvals1[i];
        }
        calls[calls.length - 1] = Call({
            target: address(ctx.positionManager),
            value: native0 ? max0 : 0,
            data: abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), ctx.deadline))
        });
    }

    function _burnCalls(Context memory ctx, uint256 tokenId)
        internal
        view
        returns (Call[] memory calls, PoolKey memory key)
    {
        uint256 minOutBps = vm.envOr("LP_MIN_OUT_BPS", uint256(9950));
        require(minOutBps <= 10_000, "LP_MIN_OUT_BPS above 10000");

        PositionInfo info;
        (key, info) = ctx.positionManager.getPoolAndPositionInfo(tokenId);
        require(address(key.hooks) == address(ctx.hook), "LP_TOKEN_ID is not a Shell position of HOOK_ADDRESS");
        require(
            IERC721(address(ctx.positionManager)).ownerOf(tokenId) == ctx.executor,
            "LP_EXECUTOR does not own LP_TOKEN_ID"
        );
        uint128 liquidity = ctx.positionManager.getPositionLiquidity(tokenId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(ctx.poolManager, key.toId());
        (uint256 expected0, uint256 expected1) =
            _amountsForLiquidity(sqrtPriceX96, info.tickLower(), info.tickUpper(), liquidity, false);
        uint256 min0 = (expected0 * minOutBps) / 10_000;
        uint256 min1 = (expected1 * minOutBps) / 10_000;

        console2.log("=== Shell liquidity withdrawal ===");
        console2.log("Hook:       ", address(ctx.hook));
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("tokenId:    ", tokenId);
        console2.log("liquidity:  ", liquidity);
        console2.log("expected0 / min0:", expected0, min0);
        console2.log("expected1 / min1:", expected1, min1);

        bytes[] memory params = new bytes[](2);
        // Expected amounts derive from uint128 liquidity, and min <= expected.
        // forge-lint: disable-next-line(unsafe-typecast)
        params[0] = abi.encode(tokenId, uint128(min0), uint128(min1), "");
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));

        calls = new Call[](1);
        calls[0] = Call({
            target: address(ctx.positionManager),
            value: 0,
            data: abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), ctx.deadline))
        });
    }

    /// @dev Exact-amount, short-lived allowances. Tokens such as USDT revert when an existing
    ///      non-zero allowance is changed to another non-zero value, so it is reset to zero first.
    function _permit2Approvals(Context memory ctx, address token, uint256 amount, uint256 expiry)
        internal
        view
        returns (Call[] memory calls)
    {
        uint256 current = IERC20(token).allowance(ctx.executor, address(ctx.permit2));
        calls = new Call[](current >= amount ? 1 : current == 0 ? 2 : 3);
        uint256 i;
        if (current < amount) {
            if (current != 0) {
                calls[i++] =
                    Call({target: token, value: 0, data: abi.encodeCall(IERC20.approve, (address(ctx.permit2), 0))});
            }
            calls[i++] =
                Call({target: token, value: 0, data: abi.encodeCall(IERC20.approve, (address(ctx.permit2), amount))});
        }
        // Both values are bounded by the caller: amount <= uint128 and expiry <= uint48.
        // forge-lint: disable-next-line(unsafe-typecast)
        (uint160 amount160, uint48 expiry48) = (uint160(amount), uint48(expiry));
        calls[i] = Call({
            target: address(ctx.permit2),
            value: 0,
            data: abi.encodeCall(IAllowanceTransfer.approve, (token, address(ctx.positionManager), amount160, expiry48))
        });
    }

    function _shellKey(Context memory ctx, address currency0, address currency1)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(ctx.hook))
        });
    }

    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        }
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }
}
