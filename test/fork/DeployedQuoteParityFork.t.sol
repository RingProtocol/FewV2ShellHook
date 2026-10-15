// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FewV2ShellHook} from "../../src/FewV2ShellHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {console2} from "forge-std/console2.sol";

interface IReviewUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Regression for test-router cash contamination and optional-return USDT approval.
/// @dev This historical deployment fixture always uses block 26197122, independently of
///      TEST_FORK_BLOCK: the old Hook did not exist at the suite's older baseline block.
contract DeployedQuoteParityForkTest is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    address constant HOOK_ADDR = 0x59255CbC688e402eF980B84668bA1d1c708b6088;
    address constant V4_PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant INITIALIZER = 0x61E75d5c5deE4205a5bBCD9fBc40498b693197ad;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USER = address(0xBEEF);
    bool forked;
    FewV2ShellHook hook;
    PoolSwapTest swapRouter;
    PoolKey ethUsdcKey;
    PoolKey ethUsdtKey;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, 26197122);
        forked = true;
        hook = FewV2ShellHook(payable(HOOK_ADDR));
        swapRouter = new PoolSwapTest(IPoolManager(V4_PM));
        ethUsdcKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 1, IHooks(HOOK_ADDR));
        ethUsdtKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDT), 3000, 1, IHooks(HOOK_ADDR));
    }

    modifier requireFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _initializeEthUsdt() internal {
        uint160 price = hook.previewInitializationPrice(ethUsdtKey);
        vm.prank(INITIALIZER);
        IPoolManager(V4_PM).initialize(ethUsdtKey, price);
    }

    address constant OFFICIAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function test_deployed_USDC_excessEqualsPreexistingRouterCash() public requireFork {
        uint256 amountIn = 2000e6;
        uint256 quoted = hook.quote(false, -int256(amountIn), ethUsdcKey.toId());
        uint256 priorRouterEth = address(swapRouter).balance;
        assertEq(priorRouterEth, 577_021_548_053_172, "the exact unexplained amount exists before the swap");
        deal(USDC, USER, amountIn);
        vm.prank(USER);
        IERC20(USDC).forceApprove(address(swapRouter), type(uint256).max);
        uint256 userBefore = USER.balance;
        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap(
            ethUsdcKey,
            SwapParams(false, -int256(amountIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(uint256(uint128(delta.amount0())), quoted, "Hook/PoolManager output equals quote exactly");
        assertEq(USER.balance - userBefore, quoted + priorRouterEth, "wallet increase includes unrelated router refund");
        assertEq(address(swapRouter).balance, 0);
        console2.log("USDC quoted ETH", quoted);
        console2.log("PoolManager output ETH", uint256(uint128(delta.amount0())));
        console2.log("unrelated router refund ETH", priorRouterEth);
    }

    function test_deployed_USDC_onlyZeroRouterCashMakesOriginalAssertionPass() public requireFork {
        vm.deal(address(swapRouter), 0);
        uint256 amountIn = 2000e6;
        uint256 quoted = hook.quote(false, -int256(amountIn), ethUsdcKey.toId());
        deal(USDC, USER, amountIn);
        vm.prank(USER);
        IERC20(USDC).forceApprove(address(swapRouter), type(uint256).max);
        uint256 beforeEth = USER.balance;
        vm.prank(USER);
        swapRouter.swap(
            ethUsdcKey,
            SwapParams(false, -int256(amountIn), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(USER.balance - beforeEth, quoted, "clean router preserves exact quote/output equality");
    }

    function test_deployed_USDC2000_officialRouter_matchesQuoteExactly() public requireFork {
        _officialExactIn(USDC, ethUsdcKey);
    }

    function test_deployed_USDT2000_officialRouter_matchesQuoteExactly() public requireFork {
        _initializeEthUsdt();
        _officialExactIn(USDT, ethUsdtKey);
    }

    function test_deployed_usdt_approveReturnsNoBoolAndSafeApprovalWorks() public requireFork {
        vm.prank(USER);
        (bool ok, bytes memory returned) =
            USDT.call(abi.encodeCall(IERC20.approve, (address(swapRouter), type(uint256).max)));
        assertTrue(ok, "USDT approve succeeds at the token level");
        assertEq(returned.length, 0, "a bool-returning IERC20 call cannot decode this result");
        vm.prank(USER);
        IERC20(USDT).forceApprove(address(swapRouter), type(uint256).max);
        assertEq(IERC20(USDT).allowance(USER, address(swapRouter)), type(uint256).max);
    }

    function _officialExactIn(address token, PoolKey memory key) internal {
        uint128 amountIn = 2000e6;
        uint256 quoted = hook.quote(false, -int256(uint256(amountIn)), key.toId());
        assertGt(quoted, 0);
        assertLe(quoted, type(uint128).max);
        deal(token, USER, amountIn);
        vm.startPrank(USER);
        IERC20(token).forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(token, OFFICIAL_ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();

        uint256 userEth = USER.balance;
        uint256 userInput = IERC20(token).balanceOf(USER);
        uint256 pmInput = IERC20(token).balanceOf(V4_PM);
        uint256 pmEth = V4_PM.balance;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key.currency1, uint256(amountIn), true);
        params[1] = abi.encode(IV4Router.ExactInputSingleParams(key, false, amountIn, uint128(quoted), ""));
        params[2] = abi.encode(key.currency0, quoted);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL)),
            params
        );
        vm.prank(USER);
        IReviewUniversalRouter(OFFICIAL_ROUTER).execute(hex"10", inputs, block.timestamp + 1 days);
        assertEq(USER.balance - userEth, quoted, "official router real native output equals quote exactly");
        assertEq(userInput - IERC20(token).balanceOf(USER), amountIn, "exactly 2000 tokens spent");
        assertEq(IERC20(token).balanceOf(V4_PM), pmInput, "PoolManager input inventory restored");
        assertEq(V4_PM.balance, pmEth, "PoolManager ETH inventory restored");
        assertEq(address(hook).balance, 0, "no Hook ETH residue");
        assertEq(IERC20(token).balanceOf(address(hook)), 0, "no Hook token residue");
        console2.log("official router token", token);
        console2.log("official router quote and actual native output", quoted);
    }
}
