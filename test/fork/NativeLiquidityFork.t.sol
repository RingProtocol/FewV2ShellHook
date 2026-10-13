// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";

interface INativeLiquidityUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface ISyncableFewV2Pair {
    function sync() external;
}

/// @notice Fixed-block local research only. No broadcast and no production discovery claim.
contract NativeLiquidityForkTest is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IV4Quoter constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    address constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    IAllowanceTransfer constant PERMIT = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FW_ETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FW_USDC = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address constant PAIR = 0x54222F404dcfAc705322045F01D100380b871450;
    address constant LP = address(0xA110C);
    address constant USER = address(0xB0B);
    address constant ATTACKER = address(0xA11CE);
    address constant RESIDUAL_RECIPIENT = address(0xFEE);
    uint256 constant BLOCK = 25_934_149;
    uint128 constant ETH_CAP = 0.0025 ether;
    uint128 constant USDC_CAP = 5e6;
    int24 constant LOWER = -887270;
    int24 constant UPPER = 887270;

    FewV2ShellHookBase hook;
    PoolKey key;
    uint160 initialPrice;
    uint128 liquidity;
    uint256 nft;
    uint256 ethDeposited;
    uint256 usdcDeposited;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("TEST_FORK_BLOCK", BLOCK));
        forked = true;
        bytes memory args = abi.encode(
            PM,
            IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD),
            ISwapV2Factory(0xeb2A625B704d73e82946D8d026E1F588Eed06416),
            IWETH9(WETH),
            QUOTER,
            true,
            address(this),
            RESIDUAL_RECIPIENT
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV2ShellHookBase).creationCode, args);
        hook = new FewV2ShellHookBase{salt: salt}(
            PM,
            IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD),
            ISwapV2Factory(0xeb2A625B704d73e82946D8d026E1F588Eed06416),
            IWETH9(WETH),
            QUOTER,
            true,
            address(this),
            RESIDUAL_RECIPIENT
        );
        assertEq(address(hook), predicted);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 1, IHooks(address(hook)));
        (uint112 r0, uint112 r1,) = ISwapV2Pair(PAIR).getReserves();
        (uint256 ethReserve, uint256 usdcReserve) =
            ISwapV2Pair(PAIR).token0() == FW_ETH ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        initialPrice = uint160(Math.sqrt(FullMath.mulDiv(usdcReserve, 1 << 192, ethReserve)));
        PM.initialize(key, initialPrice);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialPrice, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), ETH_CAP, USDC_CAP
        );
        vm.deal(LP, 1 ether);
        deal(USDC, LP, 100e6);
        _approve(LP, address(POSM), USDC_CAP);
        vm.deal(USER, 1 ether);
        deal(USDC, USER, 100e6);
        _approve(USER, ROUTER, 100e6);
    }

    modifier onFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_nativeLP_discoverySnapshotAndRecovery() public onFork {
        vm.recordLogs();
        _mint();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (uint160 sqrtPrice, int24 tick,,) = PM.getSlot0(key.toId());
        vm.serializeUint("nativeLP", "block", block.number);
        vm.serializeAddress("nativeLP", "hook", address(hook));
        vm.serializeBytes32("nativeLP", "poolId", PoolId.unwrap(key.toId()));
        vm.serializeBytes("nativeLP", "poolKeyAbi", abi.encode(key));
        vm.serializeString("nativeLP", "sqrtPriceX96", vm.toString(sqrtPrice));
        vm.serializeInt("nativeLP", "tick", tick);
        vm.serializeString("nativeLP", "liquidity", vm.toString(PM.getLiquidity(key.toId())));
        vm.serializeString("nativeLP", "ethDeposited", vm.toString(ethDeposited));
        vm.serializeString("nativeLP", "usdcDeposited", vm.toString(usdcDeposited));
        vm.serializeUint("nativeLP", "nft", nft);
        vm.serializeAddress("nativeLP", "owner", IERC721(address(POSM)).ownerOf(nft));
        string memory snapshot = vm.serializeBytes("nativeLP", "mintLogsAbi", abi.encode(entries));
        emit log_string(snapshot);
        _burnAndCheck();
    }

    function _approve(address owner, address spender, uint160 amount) internal {
        vm.startPrank(owner);
        IERC20(USDC).approve(address(PERMIT), amount);
        PERMIT.approve(USDC, spender, amount, uint48(block.timestamp + 1 hours));
        vm.stopPrank();
    }

    function _mint() internal {
        uint256 ethBefore = LP.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(LP);
        uint256 pmEthBefore = address(PM).balance;
        uint256 pmUsdcBefore = IERC20(USDC).balanceOf(address(PM));
        nft = POSM.nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, LOWER, UPPER, uint256(liquidity), ETH_CAP, USDC_CAP, LP, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, LP);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        vm.prank(LP);
        POSM.modifyLiquidities{value: ETH_CAP}(abi.encode(actions, params), block.timestamp + 60);
        ethDeposited = ethBefore - LP.balance;
        usdcDeposited = usdcBefore - IERC20(USDC).balanceOf(LP);
        assertGt(ethDeposited, 0);
        assertGt(usdcDeposited, 0);
        assertLe(ethDeposited, ETH_CAP);
        assertLe(usdcDeposited, USDC_CAP);
        assertEq(IERC721(address(POSM)).ownerOf(nft), LP);
        assertEq(PM.getLiquidity(key.toId()), liquidity);
        assertEq(address(PM).balance - pmEthBefore, ethDeposited);
        assertEq(IERC20(USDC).balanceOf(address(PM)) - pmUsdcBefore, usdcDeposited);
        _assertClosed();
    }

    function _burnData() internal view returns (bytes memory) {
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(nft, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, LP);
        return abi.encode(abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params);
    }

    function _burnAndCheck() internal {
        uint256 ethBefore = LP.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(LP);
        vm.prank(LP);
        POSM.modifyLiquidities(_burnData(), block.timestamp + 60);
        assertApproxEqAbs(LP.balance - ethBefore, ethDeposited, 1);
        assertApproxEqAbs(IERC20(USDC).balanceOf(LP) - usdcBefore, usdcDeposited, 1);
        assertEq(PM.getLiquidity(key.toId()), 0);
        _assertClosed();
    }

    function _quote(bool dir, bool exactOut, uint128 amount) internal returns (uint256 result) {
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams(key, dir, amount, "");
        if (exactOut) (result,) = QUOTER.quoteExactOutputSingle(params);
        else (result,) = QUOTER.quoteExactInputSingle(params);
    }

    function _swap(bool dir, bool exactOut, uint128 amount, uint128 limit) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = exactOut
            ? abi.encode(IV4Router.ExactOutputSingleParams(key, dir, amount, limit, ""))
            : abi.encode(IV4Router.ExactInputSingleParams(key, dir, amount, limit, ""));
        Currency input = dir ? key.currency0 : key.currency1;
        Currency output = dir ? key.currency1 : key.currency0;
        params[1] = abi.encode(input, exactOut ? limit : amount);
        params[2] = abi.encode(output, exactOut ? amount : limit);
        bytes memory actions = abi.encodePacked(
            uint8(exactOut ? Actions.SWAP_EXACT_OUT_SINGLE : Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(USER);
        INativeLiquidityUniversalRouter(ROUTER).execute{value: dir ? (exactOut ? limit : amount) : 0}(
            hex"10", inputs, block.timestamp + 60
        );
    }

    function _swapExactInputSettleFirst(bool dir, uint128 amountIn, uint128 minimumAmountOut) internal {
        Currency input = dir ? key.currency0 : key.currency1;
        Currency output = dir ? key.currency1 : key.currency0;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(input, uint256(amountIn), true);
        params[1] = abi.encode(IV4Router.ExactInputSingleParams(key, dir, amountIn, minimumAmountOut, ""));
        params[2] = abi.encode(output, minimumAmountOut);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(USER);
        INativeLiquidityUniversalRouter(ROUTER).execute{value: dir ? amountIn : 0}(
            hex"10", inputs, block.timestamp + 60
        );
    }

    function _assertClosed() internal view {
        assertEq(PM.getNonzeroDeltaCount(), 0);
        assertFalse(PM.isUnlocked());
    }

    function _assertFewV2ExecutionAndShellAccounting(
        Vm.Log[] memory entries,
        uint128 originAmountIn,
        uint128 originAmountOut,
        uint160 shellPrice,
        int24 shellTick,
        uint128 shellLiquidity
    ) internal view {
        bytes32 fewV2SwapTopic = keccak256("Swap(address,uint256,uint256,uint256,uint256,address)");
        bytes32 poolManagerSwapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 hookSwapTopic = keccak256("HookSwap(bytes32,address,int256,int256,uint24)");
        uint256 fewV2SwapCount;
        uint256 poolManagerSwapCount;
        uint256 hookSwapCount;

        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.topics.length == 0) continue;

            if (entry.emitter == PAIR && entry.topics[0] == fewV2SwapTopic) {
                ++fewV2SwapCount;
                (uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out) =
                    abi.decode(entry.data, (uint256, uint256, uint256, uint256));
                if (ISwapV2Pair(PAIR).token0() == FW_USDC) {
                    assertEq(amount0In, originAmountIn, "FewV2 receives wrapped origin input");
                    assertEq(amount1Out, originAmountOut, "FewV2 sends exact wrapped output");
                    assertEq(amount1In + amount0Out, 0, "FewV2 swap has one input and one output");
                } else {
                    assertEq(amount1In, originAmountIn, "FewV2 receives wrapped origin input");
                    assertEq(amount0Out, originAmountOut, "FewV2 sends exact wrapped output");
                    assertEq(amount0In + amount1Out, 0, "FewV2 swap has one input and one output");
                }
            } else if (entry.emitter == address(PM) && entry.topics[0] == poolManagerSwapTopic) {
                if (entry.topics.length < 2 || entry.topics[1] != PoolId.unwrap(key.toId())) continue;
                ++poolManagerSwapCount;
                (
                    int128 amount0,
                    int128 amount1,
                    uint160 sqrtPriceX96,
                    uint128 eventLiquidity,
                    int24 eventTick,
                    uint24 eventFee
                ) = abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(amount0, 0, "Shell v4 curve handles no token0 amount");
                assertEq(amount1, 0, "Shell v4 curve handles no token1 amount");
                assertEq(sqrtPriceX96, shellPrice, "Shell event keeps marker price");
                assertEq(eventTick, shellTick, "Shell event keeps marker tick");
                assertEq(eventLiquidity, shellLiquidity, "Shell event keeps origin LP liquidity");
                assertEq(eventFee, 3000, "Shell event reports configured v4 fee only");
            } else if (entry.emitter == address(hook) && entry.topics[0] == hookSwapTopic) {
                if (entry.topics.length < 2 || entry.topics[1] != PoolId.unwrap(key.toId())) continue;
                ++hookSwapCount;
                (int256 amount0, int256 amount1, uint24 hookFee) = abi.decode(entry.data, (int256, int256, uint24));
                assertEq(amount0, -int256(uint256(originAmountOut)), "HookSwap records origin ETH output");
                assertEq(amount1, int256(uint256(originAmountIn)), "HookSwap records origin USDC input");
                assertEq(hookFee, 0, "HookSwap records no extra Hook fee");
            }
        }

        assertEq(fewV2SwapCount, 1, "one real Ring Swap v2 trade");
        assertEq(poolManagerSwapCount, 1, "one Shell settlement event");
        assertEq(hookSwapCount, 1, "one indexer-facing HookSwap event");
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _pairK() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = ISwapV2Pair(PAIR).getReserves();
        return uint256(reserve0) * uint256(reserve1);
    }

    function _donateFewUsdc(uint256 amount) internal {
        deal(USDC, ATTACKER, amount);
        vm.startPrank(ATTACKER);
        IERC20(USDC).forceApprove(FW_USDC, amount);
        IFewWrappedToken(FW_USDC).wrap(amount);
        IERC20(FW_USDC).safeTransfer(PAIR, amount);
        vm.stopPrank();
        assertEq(IERC20(FW_USDC).balanceOf(ATTACKER), 0, "donor retains no fwUSDC");
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint112 r0, uint112 r1, uint32 ts) = ISwapV2Pair(PAIR).getReserves();
        return keccak256(
            abi.encode(
                r0,
                r1,
                ts,
                USER.balance,
                IERC20(USDC).balanceOf(USER),
                address(PM).balance,
                IERC20(USDC).balanceOf(address(PM)),
                PM.getLiquidity(key.toId()),
                IERC20(FW_ETH).balanceOf(address(hook)),
                IERC20(FW_USDC).balanceOf(address(hook))
            )
        );
    }

    function test_nativeLP_depositAndWithdrawThroughOfficialPositionManager() public onFork {
        assertEq(PM.getLiquidity(key.toId()), 0);
        _mint();
        emit log_named_uint("ETH deposited (wei)", ethDeposited);
        emit log_named_uint("USDC deposited (raw)", usdcDeposited);
        emit log_named_uint("Native liquidity", liquidity);
        _burnAndCheck();
    }

    function test_nativeLP_deployedBaselineRejectsSameFundingFlow() public onFork {
        address deployed = 0x3Dd864a80cc5Dc3d6e3F4E1A6aF92B0D2047e888;
        PoolKey memory existing = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 500, 10, IHooks(deployed));
        assertEq(PM.getLiquidity(existing.toId()), 0);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(existing, LOWER, UPPER, uint256(liquidity), ETH_CAP, USDC_CAP, LP, bytes(""));
        params[1] = abi.encode(existing.currency0, existing.currency1);
        bytes memory data =
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params);
        uint256 ethBefore = LP.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(LP);
        vm.prank(LP);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                deployed,
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(bytes4(keccak256("LiquidityNotAllowed()"))),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        POSM.modifyLiquidities{value: ETH_CAP}(data, block.timestamp + 60);
        assertEq(LP.balance, ethBefore);
        assertEq(IERC20(USDC).balanceOf(LP), usdcBefore);
        assertEq(PM.getLiquidity(existing.toId()), 0);
        _assertClosed();
    }

    function test_nativeLP_allSwapModesPreserveLPAndNativePrice() public onFork {
        _mint();
        (uint160 priceBefore, int24 tickBefore,,) = PM.getSlot0(key.toId());
        (uint112 reserve0Before, uint112 reserve1Before,) = ISwapV2Pair(PAIR).getReserves();
        for (uint256 i; i < 4; ++i) {
            bool dir = i < 2;
            bool exactOut = i % 2 == 1;
            uint128 amount = dir == exactOut ? uint128(1e6) : uint128(0.0001 ether);
            uint256 quoted = _quote(dir, exactOut, amount);
            assertEq(
                quoted,
                uint256(hook.quote(dir, exactOut ? int256(uint256(amount)) : -int256(uint256(amount)), key.toId()))
            );
            uint256 beforeInput = dir ? USER.balance : IERC20(USDC).balanceOf(USER);
            uint256 beforeOutput = dir ? IERC20(USDC).balanceOf(USER) : USER.balance;
            uint256 hookEthBefore = address(hook).balance;
            uint256 hookUsdcBefore = IERC20(USDC).balanceOf(address(hook));
            uint256 hookFwEthBefore = IERC20(FW_ETH).balanceOf(address(hook));
            uint256 hookFwUsdcBefore = IERC20(FW_USDC).balanceOf(address(hook));
            uint256 pmEthBefore = address(PM).balance;
            uint256 pmUsdcBefore = IERC20(USDC).balanceOf(address(PM));
            _swap(dir, exactOut, amount, uint128(quoted));
            assertEq(beforeInput - (dir ? USER.balance : IERC20(USDC).balanceOf(USER)), exactOut ? quoted : amount);
            assertEq((dir ? IERC20(USDC).balanceOf(USER) : USER.balance) - beforeOutput, exactOut ? amount : quoted);
            (uint160 price, int24 tick,,) = PM.getSlot0(key.toId());
            assertEq(price, priceBefore);
            assertEq(tick, tickBefore);
            assertEq(PM.getLiquidity(key.toId()), liquidity);
            assertEq(address(PM).balance, pmEthBefore);
            assertEq(IERC20(USDC).balanceOf(address(PM)), pmUsdcBefore);
            assertEq(address(hook).balance, hookEthBefore);
            assertEq(IERC20(USDC).balanceOf(address(hook)), hookUsdcBefore);
            assertEq(IERC20(FW_ETH).balanceOf(address(hook)), hookFwEthBefore);
            assertEq(IERC20(FW_USDC).balanceOf(address(hook)), hookFwUsdcBefore);
            _assertClosed();
            vm.serializeBytes32("nativeSwap", "poolId", PoolId.unwrap(key.toId()));
            vm.serializeAddress("nativeSwap", "hook", address(hook));
            vm.serializeBool("nativeSwap", "zeroForOne", dir);
            vm.serializeBool("nativeSwap", "exactOutput", exactOut);
            vm.serializeString("nativeSwap", "amountIn", vm.toString(exactOut ? quoted : amount));
            vm.serializeString("nativeSwap", "amountOut", vm.toString(exactOut ? amount : quoted));
            emit log_string(vm.serializeString("nativeSwap", "liquidityAfter", vm.toString(liquidity)));
        }
        (uint112 reserve0After, uint112 reserve1After,) = ISwapV2Pair(PAIR).getReserves();
        assertTrue(reserve0After != reserve0Before || reserve1After != reserve1Before);
        (uint256 fee0, uint256 fee1) = PM.getFeeGrowthGlobals(key.toId());
        assertEq(fee0, 0);
        assertEq(fee1, 0);
        _burnAndCheck();
    }

    /// @notice One end-to-end proof of the Shell model inherited from FewV4ShellHook.
    /// @dev The origin-token position makes the Shell Pool non-zero and supplies recoverable
    ///      settlement inventory. Price, depth and the real swap still come only from FewV2.
    function test_shellParity_originLPDiscoveryAndFewV2ExecutionOnly() public onFork {
        assertEq(PM.getLiquidity(key.toId()), 0, "Shell starts with zero v4 liquidity");
        (uint256 depth0Before, uint256 depth1Before) = hook.pseudoTotalValueLocked(key.toId());
        assertGt(depth0Before, 0, "FewV2 supplies token0 depth before Shell LP");
        assertGt(depth1Before, 0, "FewV2 supplies token1 depth before Shell LP");

        _mint();

        (,, address registeredPair) = hook.registeredRouteFor(key.toId());
        assertEq(registeredPair, PAIR, "execution source is the canonical Ring Swap v2 pair");
        assertGt(PM.getLiquidity(key.toId()), 0, "originToken LP makes the Shell Pool non-zero");

        (uint160 shellPriceBefore, int24 shellTickBefore,,) = PM.getSlot0(key.toId());
        uint128 shellLiquidityBefore = PM.getLiquidity(key.toId());
        (uint256 shellFee0Before, uint256 shellFee1Before) = PM.getFeeGrowthGlobals(key.toId());
        (uint112 pairReserve0Before, uint112 pairReserve1Before,) = ISwapV2Pair(PAIR).getReserves();
        uint256 pmEthBefore = address(PM).balance;
        uint256 pmUsdcBefore = IERC20(USDC).balanceOf(address(PM));
        uint256 hookEthBefore = address(hook).balance;
        uint256 hookUsdcBefore = IERC20(USDC).balanceOf(address(hook));

        // Exact-output is swap-first in the tested Universal Router flow, so this leg genuinely
        // exercises the USDC inventory supplied by the originToken Shell position.
        uint128 ethOut = 0.0001 ether;
        uint128 usdcIn = uint128(_quote(false, true, ethOut));
        uint256 userEthBefore = USER.balance;
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        vm.recordLogs();
        _swap(false, true, ethOut, usdcIn);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        _assertFewV2ExecutionAndShellAccounting(
            entries, usdcIn, ethOut, shellPriceBefore, shellTickBefore, shellLiquidityBefore
        );
        assertEq(userUsdcBefore - IERC20(USDC).balanceOf(USER), usdcIn, "user pays quoted origin USDC");
        assertEq(USER.balance - userEthBefore, ethOut, "user receives exact origin ETH");

        (uint112 pairReserve0After, uint112 pairReserve1After,) = ISwapV2Pair(PAIR).getReserves();
        assertTrue(
            pairReserve0After != pairReserve0Before || pairReserve1After != pairReserve1Before,
            "FewV2 reserves and price move"
        );
        (uint256 depth0After, uint256 depth1After) = hook.pseudoTotalValueLocked(key.toId());
        assertTrue(depth0After != depth0Before || depth1After != depth1Before, "reported FewV2 depth moves");

        (uint160 shellPriceAfter, int24 shellTickAfter,,) = PM.getSlot0(key.toId());
        (uint256 shellFee0After, uint256 shellFee1After) = PM.getFeeGrowthGlobals(key.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "Shell price is only an entry marker");
        assertEq(shellTickAfter, shellTickBefore, "Shell tick does not price the trade");
        assertEq(PM.getLiquidity(key.toId()), shellLiquidityBefore, "originToken LP is not consumed");
        assertEq(shellFee0After, shellFee0Before, "Shell LP earns no Hook swap fee in token0");
        assertEq(shellFee1After, shellFee1Before, "Shell LP earns no Hook swap fee in token1");
        assertEq(address(PM).balance, pmEthBefore, "PoolManager ETH inventory restored");
        assertEq(IERC20(USDC).balanceOf(address(PM)), pmUsdcBefore, "PoolManager USDC inventory restored");
        assertEq(address(hook).balance, hookEthBefore, "Hook retains no ETH");
        assertEq(IERC20(USDC).balanceOf(address(hook)), hookUsdcBefore, "Hook retains no USDC");
        assertEq(IERC20(FW_ETH).balanceOf(address(hook)), 0, "Hook retains no fwETH");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "Hook retains no fwUSDC");
        _assertClosed();

        _burnAndCheck();
    }

    /// @notice Shell LP is recoverable working capital: without it both directions fail, while
    ///         minting it enables swaps and burning it cleanly removes that capacity again.
    function test_nativeLP_zeroCashMintSwapBurnLifecycleBothDirections() public onFork {
        vm.deal(address(PM), 0);
        deal(USDC, address(PM), 0);

        uint128 ethIn = 0.00005 ether;
        uint128 usdcIn = 0.2e6;
        vm.expectRevert();
        hook.quote(true, -int256(uint256(ethIn)), key.toId());
        vm.expectRevert();
        hook.quote(false, -int256(uint256(usdcIn)), key.toId());

        _mint();
        assertEq(address(PM).balance, ethDeposited, "Shell LP supplies PoolManager ETH cash");
        assertEq(IERC20(USDC).balanceOf(address(PM)), usdcDeposited, "Shell LP supplies PoolManager USDC cash");

        uint128 usdcOut = uint128(hook.quote(true, -int256(uint256(ethIn)), key.toId()));
        _swap(true, false, ethIn, usdcOut);
        uint128 ethOut = uint128(hook.quote(false, -int256(uint256(usdcIn)), key.toId()));
        _swap(false, false, usdcIn, ethOut);

        assertEq(address(PM).balance, ethDeposited, "ETH working capital returns after both swaps");
        assertEq(IERC20(USDC).balanceOf(address(PM)), usdcDeposited, "USDC working capital returns after both swaps");
        _burnAndCheck();
        assertLe(address(PM).balance, 1, "burn removes Shell-supplied ETH cash apart from rounding dust");
        assertLe(
            IERC20(USDC).balanceOf(address(PM)), 1, "burn removes Shell-supplied USDC cash apart from rounding dust"
        );

        vm.expectRevert();
        hook.quote(true, -int256(uint256(ethIn)), key.toId());
        vm.expectRevert();
        hook.quote(false, -int256(uint256(usdcIn)), key.toId());
    }

    function test_nativeLP_settleFirstExactInputMatchesUniRouteActionOrder() public onFork {
        _mint();
        _assertSettleFirstExactInput(true, 0.0001 ether);
        _assertSettleFirstExactInput(false, 1e6);
        _burnAndCheck();
    }

    function _assertSettleFirstExactInput(bool dir, uint128 amountIn) internal {
        uint128 quotedOut = uint128(_quote(dir, false, amountIn));
        Currency input = dir ? key.currency0 : key.currency1;
        Currency output = dir ? key.currency1 : key.currency0;
        uint256 userInputBefore = _balance(input, USER);
        uint256 userOutputBefore = _balance(output, USER);
        uint256 pmInputBefore = _balance(input, address(PM));
        uint256 pmOutputBefore = _balance(output, address(PM));

        _swapExactInputSettleFirst(dir, amountIn, quotedOut);

        assertEq(userInputBefore - _balance(input, USER), amountIn, "settle-first input");
        assertEq(_balance(output, USER) - userOutputBefore, quotedOut, "settle-first output");
        assertEq(_balance(input, address(PM)), pmInputBefore, "PoolManager input restored");
        assertEq(_balance(output, address(PM)), pmOutputBefore, "PoolManager output restored");
        _assertClosed();
    }

    function test_adversarial_pairDonationWithoutSync_doesNotChangeQuoteOrLeakValue() public onFork {
        _mint();
        uint128 ethIn = 0.0001 ether;
        uint256 quoteBefore = hook.quote(true, -int256(uint256(ethIn)), key.toId());
        // Large enough to cross the integer quote boundary at this fixed block.
        _donateFewUsdc(20_000e6);
        uint256 quoteAfterDonation = hook.quote(true, -int256(uint256(ethIn)), key.toId());
        assertEq(quoteAfterDonation, quoteBefore, "unsynced donation does not change reserve-based quote");

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        _swap(true, false, ethIn, uint128(quoteAfterDonation));
        assertEq(
            IERC20(USDC).balanceOf(USER) - userUsdcBefore,
            quoteAfterDonation,
            "execution still matches the pre-donation quote"
        );
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "donated pair balance cannot leak through Hook");
        assertEq(IERC20(USDC).balanceOf(ATTACKER), 0, "donor cannot recover value through the victim swap");
        _burnAndCheck();
    }

    function test_adversarial_pairDonationWithSync_quoteAndExecutionRemainConsistent() public onFork {
        _mint();
        uint128 ethIn = 0.0001 ether;
        uint256 quoteBefore = hook.quote(true, -int256(uint256(ethIn)), key.toId());
        // Large enough to cross the integer quote boundary at this fixed block.
        _donateFewUsdc(20_000e6);
        ISyncableFewV2Pair(PAIR).sync();
        uint256 quoteAfterSync = hook.quote(true, -int256(uint256(ethIn)), key.toId());
        assertGt(quoteAfterSync, quoteBefore, "synced output donation improves the live reserve price");

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        _swap(true, false, ethIn, uint128(quoteAfterSync));
        assertEq(IERC20(USDC).balanceOf(USER) - userUsdcBefore, quoteAfterSync, "post-sync quote equals execution");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "Hook retains no donated FewToken");
        _burnAndCheck();
    }

    function test_adversarial_hookBalancePoisoning_doesNotChangeSwapsOrRewardCaller() public onFork {
        _mint();
        vm.deal(address(hook), 5 ether);
        deal(USDC, address(hook), 5e6);
        deal(FW_USDC, address(hook), 3e6);

        uint128 ethIn = 0.0001 ether;
        uint128 usdcIn = 1e6;
        uint128 usdcOut = uint128(hook.quote(true, -int256(uint256(ethIn)), key.toId()));
        _swap(true, false, ethIn, usdcOut);
        uint128 ethOut = uint128(hook.quote(false, -int256(uint256(usdcIn)), key.toId()));
        _swap(false, false, usdcIn, ethOut);

        assertEq(address(hook).balance, 5 ether, "preloaded ETH is not consumed by settlement");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 5e6, "preloaded USDC is not consumed by settlement");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 3e6, "preloaded fwUSDC is not sold to the user");

        uint256 recipientEthBefore = RESIDUAL_RECIPIENT.balance;
        uint256 recipientUsdcBefore = IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT);
        uint256 recipientFwUsdcBefore = IERC20(FW_USDC).balanceOf(RESIDUAL_RECIPIENT);
        uint256 attackerEthBefore = ATTACKER.balance;
        vm.startPrank(ATTACKER);
        hook.sweep(address(0));
        hook.sweep(USDC);
        hook.sweep(FW_USDC);
        vm.stopPrank();
        assertEq(
            RESIDUAL_RECIPIENT.balance - recipientEthBefore, 5 ether, "forced ETH only reaches immutable recipient"
        );
        assertEq(
            IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT) - recipientUsdcBefore,
            5e6,
            "forced origin token only reaches immutable recipient"
        );
        assertEq(
            IERC20(FW_USDC).balanceOf(RESIDUAL_RECIPIENT) - recipientFwUsdcBefore,
            3e6,
            "forced FewToken only reaches immutable recipient"
        );
        assertEq(ATTACKER.balance, attackerEthBefore, "sweep caller receives no reward");
        _burnAndCheck();
    }

    function test_adversarial_roundingAndMixedSwaps_neverDecreaseFewV2K() public onFork {
        _mint();
        vm.expectRevert();
        hook.quote(true, -int256(1), key.toId());

        uint256 previousK = _pairK();
        for (uint256 i; i < 20; ++i) {
            uint128 requiredEth = uint128(hook.quote(true, int256(1), key.toId()));
            _swap(true, true, 1, requiredEth);
            uint256 currentK = _pairK();
            assertGe(currentK, previousK, "minimal exact-output loop cannot drain the FewV2 pair");
            previousK = currentK;
        }

        uint128[4] memory amounts = [uint128(0.0001 ether), uint128(1e6), uint128(1000), uint128(0.00001 ether)];
        bool[4] memory directions = [true, false, true, false];
        bool[4] memory exactOutputs = [false, false, true, true];
        for (uint256 i; i < amounts.length; ++i) {
            uint128 quote = uint128(
                hook.quote(
                    directions[i],
                    exactOutputs[i] ? int256(uint256(amounts[i])) : -int256(uint256(amounts[i])),
                    key.toId()
                )
            );
            _swap(directions[i], exactOutputs[i], amounts[i], quote);
            uint256 currentK = _pairK();
            assertGe(currentK, previousK, "mixed routed swaps cannot reduce the FewV2 invariant");
            previousK = currentK;
        }
        _burnAndCheck();
    }

    function test_nativeLP_unapprovedCallerCannotWithdrawNFT() public onFork {
        _mint();
        bytes memory data = _burnData();
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, USER));
        POSM.modifyLiquidities(data, block.timestamp + 60);
        assertEq(IERC721(address(POSM)).ownerOf(nft), LP);
        _burnAndCheck();
    }

    function test_nativeLP_sweepCannotTouchPoolManagerCapital() public onFork {
        _mint();
        uint256 ethBefore = address(PM).balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(PM));
        vm.startPrank(USER);
        hook.sweep(address(0));
        hook.sweep(USDC);
        vm.stopPrank();
        assertEq(address(PM).balance, ethBefore);
        assertEq(IERC20(USDC).balanceOf(address(PM)), usdcBefore);
        _burnAndCheck();
    }

    function test_nativeLP_smallSellUsesRecoverableDepositedCash() public onFork {
        _mint();
        // Isolate this LP's contribution; this is a fork-only inventory scenario, not a donation.
        deal(USDC, address(PM), usdcDeposited);
        uint256 out = _quote(false, false, 1e6);
        _swap(false, false, 1e6, uint128(out));
        assertEq(IERC20(USDC).balanceOf(address(PM)), usdcDeposited);
        _burnAndCheck();
    }

    function test_nativeLP_largeSellStillFailsWithBoundedCash() public onFork {
        _mint();
        uint128 amount = uint128(usdcDeposited + 1);
        uint256 reserveQuote = uint256(hook.quote(false, -int256(uint256(amount)), key.toId()));
        assertGt(reserveQuote, 0);
        deal(USDC, address(PM), usdcDeposited);
        bytes32 beforeState = _stateDigest();
        // V4Quoter wraps the hook's inventory error in its revert-based quote envelope.
        vm.expectRevert();
        hook.quote(false, -int256(uint256(amount)), key.toId());
        vm.expectRevert();
        this.quoteExternal(false, false, amount);
        vm.expectRevert();
        this.swapExternal(false, false, amount, uint128(reserveQuote));
        assertEq(_stateDigest(), beforeState);
        _assertClosed();
        _burnAndCheck();
    }

    function test_nativeLP_zeroCashIsNotFixedByAllowingLiquidity() public onFork {
        _mint();
        uint256 balance = IERC20(USDC).balanceOf(address(PM));
        uint256 fundedQuote = uint256(hook.quote(false, -int256(1e6), key.toId()));
        assertGt(fundedQuote, 0);
        deal(USDC, address(PM), 0);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert();
        hook.quote(false, -int256(1e6), key.toId());
        vm.expectRevert();
        this.quoteExternal(false, false, 1e6);
        vm.expectRevert();
        this.swapExternal(false, false, 1e6, 1);
        assertEq(_stateDigest(), beforeState);
        // Undo the artificial external inventory deletion before checking normal withdrawal.
        deal(USDC, address(PM), balance);
        _burnAndCheck();
    }

    function test_nativeLP_exactOutputBeyondCashRevertsAtomically() public onFork {
        _mint();
        uint128 amount = 0.004 ether;
        uint256 reserveQuote = hook.quote(false, int256(uint256(amount)), key.toId());
        assertGt(reserveQuote, usdcDeposited);
        deal(USDC, address(PM), usdcDeposited);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert();
        hook.quote(false, int256(uint256(amount)), key.toId());
        vm.expectRevert();
        this.quoteExternal(false, true, amount);
        vm.expectRevert();
        this.swapExternal(false, true, amount, uint128(reserveQuote));
        assertEq(_stateDigest(), beforeState);
        _assertClosed();
        _burnAndCheck();
    }

    function test_nativeLP_quoteAndSwapRejectInsufficientWrapperBacking() public onFork {
        _mint();
        uint128 amount = 0.0001 ether;
        uint256 fundedQuote = hook.quote(true, -int256(uint256(amount)), key.toId());
        assertGt(fundedQuote, 0);

        uint256 backing = IERC20(USDC).balanceOf(FW_USDC);
        deal(USDC, FW_USDC, 0);
        bytes32 beforeState = _stateDigest();

        vm.expectRevert();
        hook.quote(true, -int256(uint256(amount)), key.toId());
        vm.expectRevert();
        this.quoteExternal(true, false, amount);
        vm.expectRevert();
        this.swapExternal(true, false, amount, uint128(fundedQuote));

        assertEq(_stateDigest(), beforeState);
        _assertClosed();
        deal(USDC, FW_USDC, backing);
        _burnAndCheck();
    }

    function test_nativeLP_omittedPaymentCannotConsumeLPCapital() public onFork {
        _mint();
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, true, 0.0001 ether, 0, ""));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE)), params);
        bytes32 beforeState = _stateDigest();
        vm.prank(USER);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        INativeLiquidityUniversalRouter(ROUTER).execute(hex"10", inputs, block.timestamp + 60);
        assertEq(_stateDigest(), beforeState);
        _assertClosed();
        _burnAndCheck();
    }

    function test_nativeLP_slippageFailureRollsBackExternalTrade() public onFork {
        _mint();
        uint128 amount = 0.0001 ether;
        uint128 quote = uint128(_quote(true, false, amount));
        bytes32 beforeState = _stateDigest();
        vm.expectRevert();
        this.swapExternal(true, false, amount, quote + 1);
        assertEq(_stateDigest(), beforeState);
        _assertClosed();
        _burnAndCheck();
    }

    function quoteExternal(bool dir, bool exactOut, uint128 amount) external returns (uint256) {
        require(msg.sender == address(this));
        return _quote(dir, exactOut, amount);
    }

    function swapExternal(bool dir, bool exactOut, uint128 amount, uint128 limit) external {
        require(msg.sender == address(this));
        _swap(dir, exactOut, amount, limit);
    }
}
