// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";

/// @notice Fixed-block execution matrix for every origin-token shape supported by the Hook.
/// @dev Covers 3 markets x 2 directions x exact-input/exact-output = 12 executed swaps.
contract ExecutionMatrixForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    IFewFactory internal constant FEW_FACTORY = IFewFactory(0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD);
    ISwapV2Factory internal constant FEWV2_FACTORY = ISwapV2Factory(0xeb2A625B704d73e82946D8d026E1F588Eed06416);

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USER = address(0xBEEF);
    address internal constant RESIDUAL_RECIPIENT = address(0xFEE);

    uint256 internal constant BLOCK = 25_934_149;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 1;

    bool internal forked;
    PoolSwapTest internal swapRouter;
    FewV2ShellHookBase internal nativeHook;
    FewV2ShellHookBase internal wethHook;
    /// @dev The unarmed subsidy vault bound to each Hook. The subsidy suite arms them.
    ISubsidyVault internal nativeSubsidyVault;
    ISubsidyVault internal wethSubsidyVault;
    PoolKey internal ethUsdc;
    PoolKey internal wethUsdc;
    PoolKey internal wbtcUsdc;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("TEST_FORK_BLOCK", BLOCK));
        forked = true;

        nativeHook = _deployHook(true);
        wethHook = _deployHook(false);
        swapRouter = new PoolSwapTest(PM);

        ethUsdc = _poolKey(address(0), USDC, nativeHook);
        wbtcUsdc = _poolKey(WBTC, USDC, nativeHook);
        wethUsdc = _poolKey(WETH, USDC, wethHook);
        _initialize(nativeHook, ethUsdc);
        _initialize(nativeHook, wbtcUsdc);
        _initialize(wethHook, wethUsdc);

        vm.deal(USER, 10 ether);
        deal(WETH, USER, 10 ether);
        deal(USDC, USER, 100_000e6);
        deal(WBTC, USER, 10e8);
        vm.startPrank(USER);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20(WBTC).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    modifier onFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_matrix_nativeETH_token_bothDirections_exactInAndOut() public onFork {
        // currency0=ETH, currency1=USDC
        _runFour(nativeHook, ethUsdc, 0.001 ether, 1e6, 1e6, 0.0001 ether);
    }

    function test_matrix_WETH_token_bothDirections_exactInAndOut() public onFork {
        // currency0=USDC, currency1=WETH
        _runFour(wethHook, wethUsdc, 1e6, 0.0001 ether, 0.001 ether, 1e6);
    }

    function test_matrix_token_token_bothDirections_exactInAndOut() public onFork {
        // currency0=WBTC, currency1=USDC
        _runFour(nativeHook, wbtcUsdc, 10_000, 1e6, 1e6, 10_000);
    }

    function test_matrix_nativeETH_token_smallExactOutputBoundaries_bothDirections() public onFork {
        _runSmallExactOutputBoundaries(nativeHook, ethUsdc);
    }

    function test_matrix_WETH_token_smallExactOutputBoundaries_bothDirections() public onFork {
        _runSmallExactOutputBoundaries(wethHook, wethUsdc);
    }

    function test_matrix_token_token_smallExactOutputBoundaries_bothDirections() public onFork {
        _runSmallExactOutputBoundaries(nativeHook, wbtcUsdc);
    }

    function test_modes_rejectNonCanonicalWethRepresentation() public onFork {
        PoolKey memory wrongForNative = _poolKey(WETH, USDC, nativeHook);
        vm.expectRevert(FewV2ShellHookBase.UseNativeCurrencyForWeth.selector);
        nativeHook.previewInitializationPrice(wrongForNative);

        PoolKey memory wrongForWeth = _poolKey(address(0), USDC, wethHook);
        vm.expectRevert(FewV2ShellHookBase.UseWethCurrencyInsteadOfNative.selector);
        wethHook.previewInitializationPrice(wrongForWeth);
    }

    function test_matrix_customPriceLimits_bothDirections_exactInAndOut() public onFork {
        _runFourAtCustomLimits(nativeHook, ethUsdc, 0.001 ether, 1e6, 1e6, 0.0001 ether);
        _runFourAtCustomLimits(wethHook, wethUsdc, 1e6, 0.0001 ether, 0.001 ether, 1e6);
        _runFourAtCustomLimits(nativeHook, wbtcUsdc, 10_000, 1e6, 1e6, 10_000);
    }

    function test_matrix_crossedPriceLimitsRevertFewV2TradeAtomically() public onFork {
        _assertFourCrossedPriceLimits(nativeHook, ethUsdc, 0.001 ether, 1e6, 1e6, 0.0001 ether);
        _assertFourCrossedPriceLimits(wethHook, wethUsdc, 1e6, 0.0001 ether, 0.001 ether, 1e6);
        _assertFourCrossedPriceLimits(nativeHook, wbtcUsdc, 10_000, 1e6, 1e6, 10_000);
    }

    function _assertCrossedPriceLimitReverts(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        (,, address pair) = hook.registeredRouteFor(key.toId());
        (uint112 reserve0Before, uint112 reserve1Before,) = ISwapV2Pair(pair).getReserves();
        uint160 priceBefore = hook.executionSqrtPriceX96(key.toId());
        uint160 limit = zeroForOne ? priceBefore - 1 : priceBefore + 1;
        uint256 nativeValue = _nativeInputValue(hook, key, zeroForOne, amountSpecified);

        uint256 snapshot = vm.snapshotState();
        SwapParams memory permissiveParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.prank(USER);
        swapRouter.swap{value: nativeValue}(key, permissiveParams, PoolSwapTest.TestSettings(false, false), "");
        uint160 resultingPrice = hook.executionSqrtPriceX96(key.toId());
        assertTrue(vm.revertToStateAndDelete(snapshot), "state snapshot rollback");

        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit});
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FewV2ShellHookBase.FewV2PriceLimitExceeded.selector, resultingPrice, limit),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(USER);
        swapRouter.swap{value: nativeValue}(key, params, PoolSwapTest.TestSettings(false, false), "");

        (uint112 reserve0After, uint112 reserve1After,) = ISwapV2Pair(pair).getReserves();
        assertEq(reserve0After, reserve0Before, "FewV2 reserve0 rollback");
        assertEq(reserve1After, reserve1Before, "FewV2 reserve1 rollback");
        assertEq(hook.executionSqrtPriceX96(key.toId()), priceBefore, "FewV2 price rollback");
    }

    function _runFourAtCustomLimits(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        uint128 currency0ExactIn,
        uint128 currency1ExactOut,
        uint128 currency1ExactIn,
        uint128 currency0ExactOut
    ) internal {
        _runExactInputAtLimit(hook, key, true, currency0ExactIn, _permissivePriceLimit(hook, key, true));
        _runExactOutputAtLimit(hook, key, true, currency1ExactOut, _permissivePriceLimit(hook, key, true));
        _runExactInputAtLimit(hook, key, false, currency1ExactIn, _permissivePriceLimit(hook, key, false));
        _runExactOutputAtLimit(hook, key, false, currency0ExactOut, _permissivePriceLimit(hook, key, false));
    }

    function _assertFourCrossedPriceLimits(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        uint128 currency0ExactIn,
        uint128 currency1ExactOut,
        uint128 currency1ExactIn,
        uint128 currency0ExactOut
    ) internal {
        _assertCrossedPriceLimitReverts(hook, key, true, -int256(uint256(currency0ExactIn)));
        _assertCrossedPriceLimitReverts(hook, key, true, int256(uint256(currency1ExactOut)));
        _assertCrossedPriceLimitReverts(hook, key, false, -int256(uint256(currency1ExactIn)));
        _assertCrossedPriceLimitReverts(hook, key, false, int256(uint256(currency0ExactOut)));
    }

    function _nativeInputValue(FewV2ShellHookBase hook, PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        if (!_isNative(input)) return 0;
        if (amountSpecified < 0) return uint256(-amountSpecified);
        return hook.quote(zeroForOne, amountSpecified, key.toId());
    }

    function _runFour(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        uint128 currency0ExactIn,
        uint128 currency1ExactOut,
        uint128 currency1ExactIn,
        uint128 currency0ExactOut
    ) internal {
        (,, address pair) = hook.registeredRouteFor(key.toId());
        (uint112 reserve0Before, uint112 reserve1Before,) = ISwapV2Pair(pair).getReserves();
        (uint160 shellPriceBefore, int24 shellTickBefore,,) = PM.getSlot0(key.toId());

        _runExactInput(hook, key, true, currency0ExactIn);
        _runExactOutput(hook, key, true, currency1ExactOut);
        _runExactInput(hook, key, false, currency1ExactIn);
        _runExactOutput(hook, key, false, currency0ExactOut);

        (uint112 reserve0After, uint112 reserve1After,) = ISwapV2Pair(pair).getReserves();
        assertTrue(reserve0After != reserve0Before || reserve1After != reserve1Before, "FewV2 reserves must move");
        (uint160 shellPriceAfter, int24 shellTickAfter,,) = PM.getSlot0(key.toId());
        assertEq(shellPriceAfter, shellPriceBefore, "Shell sqrt price must remain an entry-point marker");
        assertEq(shellTickAfter, shellTickBefore, "Shell tick must remain unchanged");
    }

    function _runSmallExactOutputBoundaries(FewV2ShellHookBase hook, PoolKey memory key) internal {
        uint128[7] memory targets = [uint128(1), 1998, 1999, 2000, 3998, 3999, 4000];
        for (uint256 i; i < targets.length; ++i) {
            _runExactOutput(hook, key, true, targets[i]);
            _runExactOutput(hook, key, false, targets[i]);
        }
    }

    function _runExactInput(FewV2ShellHookBase hook, PoolKey memory key, bool zeroForOne, uint128 amountIn) internal {
        _runExactInputAtLimit(
            hook, key, zeroForOne, amountIn, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _runExactInputAtLimit(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint160 sqrtPriceLimitX96
    ) internal {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 amountOut = hook.quote(zeroForOne, -int256(uint256(amountIn)), key.toId());
        uint256 inputBefore = _balance(input, USER);
        uint256 outputBefore = _balance(output, USER);
        uint256 pmInputBefore = _balance(input, address(PM));
        uint256 pmOutputBefore = _balance(output, address(PM));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(uint256(amountIn)), sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: _isNative(input) ? amountIn : 0}(
            key, params, PoolSwapTest.TestSettings(false, false), ""
        );

        assertEq(inputBefore - _balance(input, USER), amountIn, "exact-in user input");
        assertEq(_balance(output, USER) - outputBefore, amountOut, "exact-in user output");
        _assertDelta(delta, zeroForOne, amountIn, amountOut);
        _assertClosedAndClean(hook, key, zeroForOne, pmInputBefore, pmOutputBefore);
    }

    function _runExactOutput(FewV2ShellHookBase hook, PoolKey memory key, bool zeroForOne, uint128 amountOut) internal {
        _runExactOutputAtLimit(
            hook, key, zeroForOne, amountOut, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _runExactOutputAtLimit(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint160 sqrtPriceLimitX96
    ) internal {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 amountIn = hook.quote(zeroForOne, int256(uint256(amountOut)), key.toId());
        uint256 inputBefore = _balance(input, USER);
        uint256 outputBefore = _balance(output, USER);
        uint256 pmInputBefore = _balance(input, address(PM));
        uint256 pmOutputBefore = _balance(output, address(PM));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: int256(uint256(amountOut)), sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: _isNative(input) ? amountIn : 0}(
            key, params, PoolSwapTest.TestSettings(false, false), ""
        );

        assertEq(inputBefore - _balance(input, USER), amountIn, "exact-out user input");
        assertEq(_balance(output, USER) - outputBefore, amountOut, "exact-out user output");
        _assertDelta(delta, zeroForOne, amountIn, amountOut);
        _assertClosedAndClean(hook, key, zeroForOne, pmInputBefore, pmOutputBefore);
    }

    function _permissivePriceLimit(FewV2ShellHookBase hook, PoolKey memory key, bool zeroForOne)
        internal
        view
        returns (uint160)
    {
        uint160 current = hook.executionSqrtPriceX96(key.toId());
        if (zeroForOne) {
            uint160 minimum = TickMath.MIN_SQRT_PRICE + 1;
            return uint160(uint256(minimum) + ((uint256(current) - uint256(minimum)) / 2));
        }

        uint160 maximum = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(uint256(current) + ((uint256(maximum) - uint256(current)) / 2));
    }

    function _assertClosedAndClean(
        FewV2ShellHookBase hook,
        PoolKey memory key,
        bool zeroForOne,
        uint256 pmInputBefore,
        uint256 pmOutputBefore
    ) internal view {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        (address few0, address few1,) = hook.registeredRouteFor(key.toId());
        address fewIn = zeroForOne ? few0 : few1;
        address inputUnderlying = IFewWrappedToken(fewIn).token();

        assertEq(_balance(input, address(PM)), pmInputBefore, "PoolManager input inventory must be restored");
        assertEq(_balance(output, address(PM)), pmOutputBefore, "PoolManager output inventory must be restored");
        assertEq(_balance(input, address(hook)), 0, "Hook origin input residue");
        assertEq(_balance(output, address(hook)), 0, "Hook origin output residue");
        assertEq(IERC20(few0).balanceOf(address(hook)), 0, "Hook few0 residue");
        assertEq(IERC20(few1).balanceOf(address(hook)), 0, "Hook few1 residue");
        assertEq(IERC20(inputUnderlying).allowance(address(hook), fewIn), 0, "wrapper allowance must reset");
    }

    function _assertDelta(BalanceDelta delta, bool zeroForOne, uint256 amountIn, uint256 amountOut) internal pure {
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());
        if (zeroForOne) {
            assertEq(amount0, -int256(amountIn), "amount0 delta");
            assertEq(amount1, int256(amountOut), "amount1 delta");
        } else {
            assertEq(amount0, int256(amountOut), "amount0 delta");
            assertEq(amount1, -int256(amountIn), "amount1 delta");
        }
    }

    function _deployHook(bool useNative) internal returns (FewV2ShellHookBase deployed) {
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        ISubsidyVault vault = new SubsidyVault(PM, address(this));
        if (useNative) {
            nativeSubsidyVault = vault;
        } else {
            wethSubsidyVault = vault;
        }
        bytes memory args = abi.encode(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, useNative, address(this), RESIDUAL_RECIPIENT, vault
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FewV2ShellHookBase).creationCode, args);
        deployed = new FewV2ShellHookBase{salt: salt}(
            PM, FEW_FACTORY, FEWV2_FACTORY, IWETH9(WETH), QUOTER, useNative, address(this), RESIDUAL_RECIPIENT, vault
        );
        assertEq(address(deployed), predicted, "mined Hook address");
    }

    function _initialize(FewV2ShellHookBase hook, PoolKey memory key) internal {
        PM.initialize(key, hook.previewInitializationPrice(key));
    }

    function _poolKey(address tokenA, address tokenB, FewV2ShellHookBase hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address token0, address token1) = uint160(tokenA) < uint160(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }
}
