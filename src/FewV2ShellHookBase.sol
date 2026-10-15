// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast as OZSafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IFewWrappedToken} from "./interfaces/external/IFewWrappedToken.sol";
import {IFewFactory} from "./interfaces/external/IFewFactory.sol";
import {ISwapV2Pair, ISwapV2Factory} from "./interfaces/external/IFewV2.sol";
import {IV4FeeRecipient} from "./interfaces/external/IV4FeeRecipient.sol";
import {IAggregatorHook} from "./interfaces/IAggregatorHook.sol";
import {FewV2Math} from "./lib/FewV2Math.sol";
import {FewV2Price} from "./lib/FewV2Price.sol";

/// @title FewV2ShellHookBase
/// @notice Non-upgradeable Uniswap v4 Shell Hook that executes origin-token swaps through direct FewV2 pairs.
///         Swap behavior is fixed by immutable dependencies and the live state of the canonical FewV2 pairs.
///
///         Each v4 pool maps to one direct FewV2 pair. The Hook does not search intermediate tokens.
///         Native LP deposits use the PoolKey's underlying currencies and remain in PoolManager.
///         Swaps bypass native AMM liquidity, so these positions earn no fees from hook swaps.
///         Input settlement still requires sufficient PoolManager cash at the time of take().
///
/// @dev The `poolInitializer` may register new pools, but cannot change an existing route,
///      pause swaps, withdraw LP positions or move balances. There is no upgrade path or route setter.
///      `sweep(token)` is permissionless, but can only send this Hook's own residual balance to the
///      residual recipient; it cannot reach Shell LP assets held by PoolManager. This contract never
///      changes either address; `FewV2ShellHook` lets its owner replace both. Incident response
///      requires routers to stop selecting an affected pool and, if necessary, a new Hook.
contract FewV2ShellHookBase is BaseHook, DeltaResolver, ReentrancyGuard, IAggregatorHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    // ============ Errors ============
    error InvalidPoolKey();
    error UnauthorizedPoolInitializer(address caller);
    error UseFewTokenHookForWrapPairs();
    error UseNativeCurrencyForWeth();
    error UseWethCurrencyInsteadOfNative();
    error NoFewV2Route();
    error TokenMismatch(address pair);
    error EthForwardFailed();
    error ZeroAddress();
    error DependencyHasNoCode(address dependency);
    error QuoterPoolManagerMismatch(address expected, address actual);
    error WrapperUnderlyingMismatch(address wrapper, address expected, address actual);
    error NonCanonicalWrapper(address wrapper, address underlying, address canonicalWrapper);
    error WrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error UnwrapReturnMismatch(uint256 returnedAmount, uint256 expectedAmount);
    error TokenBalanceMismatch(address token, uint256 expectedBalance, uint256 actualBalance);
    error WrapperBackingDeltaMismatch(address wrapper, uint256 expectedBalance, uint256 actualBalance);
    error InsufficientConversionBalance(address token, uint256 available, uint256 required);
    error SettlementAmountMismatch(address token, uint256 paid, uint256 expected);
    error FewV2OutputMismatch(address token, uint256 expected, uint256 actual);
    error InvalidSwapAmount();
    error FewV2PriceLimitAlreadyExceeded(uint160 currentSqrtPriceX96, uint160 limitSqrtPriceX96);
    error FewV2PriceLimitOutOfBounds(uint160 limitSqrtPriceX96);
    error FewV2PriceLimitExceeded(uint160 resultingSqrtPriceX96, uint160 limitSqrtPriceX96);
    error InitializationPriceMismatch(uint160 provided, uint160 expected, int24 maxTickDeviation);
    error UnexpectedNativeSender(address sender);
    error DegeneratePair(address pair);
    error PairAlreadyRegistered(PoolId existingPoolId);
    error InsufficientPoolManagerInventory(address token, uint256 available, uint256 required);
    error InsufficientWrapperBacking(address fewToken, address underlying, uint256 available, uint256 required);
    error InvalidProtocolFeeRecipient();

    // ============ Constants ============
    /// @notice FewV2 uses the Uniswap V2 0.30% fee. The Shell Pool key mirrors that external fee.
    uint24 public constant CANONICAL_POOL_FEE = 3000;
    /// @notice Aggregator Hook pools do not execute against the v4 curve; use the canonical spacing of 1.
    int24 public constant CANONICAL_TICK_SPACING = 1;
    /// @notice Initialization and the live FewV2 price may differ by at most one tick index.
    /// @dev Because each price can sit at a different edge of its tick interval, the raw price
    ///      gap can approach two tick intervals even when the tick-index difference is one.
    ///      The Shell price is not used for execution, but keeping the marker close to the live
    ///      FewV2 price avoids publishing a misleading immutable slot0 value.
    int24 public constant MAX_INIT_TICK_DEVIATION = 1;
    /// @notice Matches Uniswap's Aggregator family fee scaling; the pool controller sets the rate.
    uint24 public constant protocolFeeMultiplier = 25;

    // ============ Immutable ============
    /// @notice Ring wrapper factory and FewV2 AMM factory used to derive canonical direct routes.
    /// @dev A factory migration requires a new Hook deployment; mutable routing authority is
    ///      intentionally excluded from this contract.
    IFewFactory public immutable fewFactory;
    ISwapV2Factory public immutable fewV2Factory;
    IWETH9 public immutable weth;
    IV4Quoter public immutable v4Quoter;
    /// @notice Chooses the one canonical representation of WETH-backed routes for this deployment.
    /// @dev true permits native ETH pools and rejects WETH aliases; false does the opposite.
    bool public immutable useNativeCurrencyForWeth;

    // ============ Storage ============
    /// @notice The only account allowed to register new Shell Pools.
    /// @dev This role cannot change existing routes, pause swaps, withdraw LP positions or move Hook balances.
    ///      This contract has no setter; `FewV2ShellHook` lets its owner replace it.
    address public poolInitializer;
    /// @notice Destination of the permissionless residual-balance `sweep`. This contract has no setter;
    ///         `FewV2ShellHook` lets its owner replace it.
    address public residualRecipient;

    /// @notice PoolId -> direct route registered during beforeInitialize. No admin can modify it later.
    mapping(PoolId => RegisteredRoute) internal _registeredRoutes;
    /// @notice External FewV2 pair -> canonical v4 poolId. Prevents duplicate shell pools from double-counting TVL.
    mapping(address => PoolId) public poolIdForFewV2Pair;
    mapping(address => bool) public fewV2PairRegistered;

    struct RegisteredRoute {
        address origin0;
        address origin1;
        address few0;
        address few1;
        address pair;
    }

    struct DirectRoute {
        address originIn;
        address fewIn;
        address fewOut;
        address pair;
    }

    // ============ Events ============
    event SwapAggregated(
        PoolId indexed poolId,
        address indexed router,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fwOutAmount
    );
    event Sweep(address indexed token, address indexed to, uint256 amount, address indexed triggeredBy);
    event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice Self-classifies as the same fee family as Uniswap's public Aggregator Hooks.
    function protocolFeeFlags() external pure returns (uint256) {
        return 1 << 11;
    }

    // ============ Constructor ============
    constructor(
        IPoolManager _pm,
        IFewFactory _fewFactory,
        ISwapV2Factory _fewV2Factory,
        IWETH9 _weth,
        IV4Quoter _v4Quoter,
        bool _useNativeCurrencyForWeth,
        address _poolInitializer,
        address _residualRecipient
    ) BaseHook(_pm) {
        if (address(_pm) == address(0)) revert ZeroAddress();
        if (address(_fewFactory) == address(0)) revert ZeroAddress();
        if (address(_fewV2Factory) == address(0)) revert ZeroAddress();
        if (address(_weth) == address(0)) revert ZeroAddress();
        if (address(_v4Quoter) == address(0)) revert ZeroAddress();
        if (_poolInitializer == address(0)) revert ZeroAddress();
        if (_residualRecipient == address(0)) revert ZeroAddress();

        _requireCode(address(_pm));
        _requireCode(address(_fewFactory));
        _requireCode(address(_fewV2Factory));
        _requireCode(address(_weth));
        _requireCode(address(_v4Quoter));
        address quoterPoolManager = address(_v4Quoter.poolManager());
        if (quoterPoolManager != address(_pm)) {
            revert QuoterPoolManagerMismatch(address(_pm), quoterPoolManager);
        }

        fewFactory = _fewFactory;
        fewV2Factory = _fewV2Factory;
        weth = _weth;
        v4Quoter = _v4Quoter;
        useNativeCurrencyForWeth = _useNativeCurrencyForWeth;
        poolInitializer = _poolInitializer;
        residualRecipient = _residualRecipient;
    }

    // ============ Hook permissions ============
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ DeltaResolver payment glue ============
    function _pay(
        Currency currency,
        address, /* payer */
        uint256 amount
    )
        internal
        override
    {
        currency.transfer(address(poolManager), amount);
    }

    // ============ beforeInitialize ============
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (sender != poolInitializer) revert UnauthorizedPoolInitializer(sender);
        if (key.fee != CANONICAL_POOL_FEE || key.tickSpacing != CANONICAL_TICK_SPACING) revert InvalidPoolKey();

        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _validateCanonicalWethRepresentation(t0, t1);

        // Refuse 1:1 wrap pairs — those belong to FewTokenHook, not this hook.
        if (_isFewTokenOf(t0, t1) || _isFewTokenOf(t1, t0)) revert UseFewTokenHookForWrapPairs();

        // Endpoint FewTokens and their direct FewV2 pair must exist at init time.
        (address fewA, address fewB) = _defaultFewPair(t0, t1);
        if (fewA == address(0) || fewB == address(0)) revert NoFewV2Route();
        _validateWrapper(fewA, _underlyingForCurrency(t0));
        _validateWrapper(fewB, _underlyingForCurrency(t1));
        if (fewA == fewB) revert InvalidPoolKey();
        address pair = fewV2Factory.getPair(fewA, fewB);
        if (pair == address(0)) revert NoFewV2Route();
        _requireCode(pair);
        _validateFewV2Pair(pair, fewA, fewB);

        uint160 expectedSqrtPriceX96 = FewV2Price.fromPair(ISwapV2Pair(pair), fewA, fewB);
        int24 providedTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 expectedTick = TickMath.getTickAtSqrtPrice(expectedSqrtPriceX96);
        int256 tickDifference = int256(providedTick) - int256(expectedTick);
        if (tickDifference < 0) tickDifference = -tickDifference;
        if (tickDifference > int256(MAX_INIT_TICK_DEVIATION)) {
            revert InitializationPriceMismatch(sqrtPriceX96, expectedSqrtPriceX96, MAX_INIT_TICK_DEVIATION);
        }

        PoolId poolId = key.toId();
        if (fewV2PairRegistered[pair]) revert PairAlreadyRegistered(poolIdForFewV2Pair[pair]);
        fewV2PairRegistered[pair] = true;
        poolIdForFewV2Pair[pair] = poolId;
        _registeredRoutes[poolId] = RegisteredRoute({origin0: t0, origin1: t1, few0: fewA, few1: fewB, pair: pair});

        emit AggregatorPoolRegistered(poolId);
        return IHooks.beforeInitialize.selector;
    }

    function _isFewTokenOf(address a, address b) internal view returns (bool) {
        if (b == address(0)) {
            address fewWETH = fewFactory.getWrappedToken(address(weth));
            return a == fewWETH && fewWETH != address(0);
        }
        return fewFactory.getWrappedToken(b) == a && a != address(0);
    }

    function _defaultFewPair(address t0, address t1) internal view returns (address fewA, address fewB) {
        address u0 = _underlyingForCurrency(t0);
        address u1 = _underlyingForCurrency(t1);
        fewA = fewFactory.getWrappedToken(u0);
        fewB = fewFactory.getWrappedToken(u1);
    }

    function _underlyingForCurrency(address currency) internal view returns (address) {
        return currency == address(0) ? address(weth) : currency;
    }

    function _validateCanonicalWethRepresentation(address t0, address t1) internal view {
        if (useNativeCurrencyForWeth) {
            if (t0 == address(weth) || t1 == address(weth)) revert UseNativeCurrencyForWeth();
        } else if (t0 == address(0) || t1 == address(0)) {
            revert UseWethCurrencyInsteadOfNative();
        }
    }

    function _validateWrapper(address wrapper, address expectedUnderlying) internal view {
        address canonicalWrapper = fewFactory.getWrappedToken(expectedUnderlying);
        if (canonicalWrapper != wrapper) {
            revert NonCanonicalWrapper(wrapper, expectedUnderlying, canonicalWrapper);
        }
        _requireCode(wrapper);
        address actualUnderlying = IFewWrappedToken(wrapper).token();
        if (actualUnderlying != expectedUnderlying) {
            revert WrapperUnderlyingMismatch(wrapper, expectedUnderlying, actualUnderlying);
        }
    }

    // ============ beforeSwap ============
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified == 0) revert InvalidSwapAmount();

        Currency inCurr = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outCurr = params.zeroForOne ? key.currency1 : key.currency0;

        PoolId poolId = key.toId();
        DirectRoute memory route = _resolveDirectRoute(poolId, params.zeroForOne);
        _validatePriceLimitBeforeSwap(params.zeroForOne, _executionSqrtPriceX96(poolId), params.sqrtPriceLimitX96);

        bool isExactInput = params.amountSpecified < 0;
        bytes4 selector;
        BeforeSwapDelta swapDelta;
        uint24 feeOverride;
        if (isExactInput) {
            (selector, swapDelta, feeOverride) = _swapExactInput(sender, poolId, inCurr, outCurr, params, route);
        } else {
            (selector, swapDelta, feeOverride) = _swapExactOutput(sender, poolId, inCurr, outCurr, params, route);
        }

        _validatePriceLimitAfterSwap(params.zeroForOne, _executionSqrtPriceX96(poolId), params.sqrtPriceLimitX96);
        return (selector, swapDelta, feeOverride);
    }

    function _validatePriceLimitBeforeSwap(bool zeroForOne, uint160 currentPrice, uint160 limit) internal pure {
        if (zeroForOne) {
            if (limit >= currentPrice) revert FewV2PriceLimitAlreadyExceeded(currentPrice, limit);
            if (limit <= TickMath.MIN_SQRT_PRICE) revert FewV2PriceLimitOutOfBounds(limit);
        } else {
            if (limit <= currentPrice) revert FewV2PriceLimitAlreadyExceeded(currentPrice, limit);
            if (limit >= TickMath.MAX_SQRT_PRICE) revert FewV2PriceLimitOutOfBounds(limit);
        }
    }

    function _validatePriceLimitAfterSwap(bool zeroForOne, uint160 resultingPrice, uint160 limit) internal pure {
        if ((zeroForOne && resultingPrice < limit) || (!zeroForOne && resultingPrice > limit)) {
            revert FewV2PriceLimitExceeded(resultingPrice, limit);
        }
    }

    // ============ Direct route resolution ============
    function _resolveDirectRoute(PoolId poolId, bool zeroForOne) internal view returns (DirectRoute memory route) {
        RegisteredRoute storage registered = _registeredRoute(poolId);
        route.originIn = zeroForOne ? registered.origin0 : registered.origin1;
        (route.fewIn, route.fewOut) =
            zeroForOne ? (registered.few0, registered.few1) : (registered.few1, registered.few0);
        route.pair = registered.pair;
    }

    // ============ Exact-input ============
    function _swapExactInput(
        address sender,
        PoolId poolId,
        Currency inCurr,
        Currency outCurr,
        SwapParams calldata params,
        DirectRoute memory route
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        (uint256 amountIn, int128 amountInDelta) = _exactInputAmount(params.amountSpecified);

        // The hook takes the origin input from PoolManager before the router settles it. Shell LP
        // supplies that physical inventory. Check it before touching the external FewV2 pair so a
        // reserve-only quote cannot advertise a route that is not executable with current cash.
        _requireSettlementInventory(route.originIn, amountIn);
        uint256 quotedAmountOut = _executeQuoteExactInput(route.pair, route.fewIn, route.fewOut, amountIn);
        _requireWrapperBacking(route.fewOut, quotedAmountOut);

        uint256 inputBaseline = inCurr.balanceOfSelf();
        uint256 outputBaseline = outCurr.balanceOfSelf();
        uint256 fewInBaseline = IERC20(route.fewIn).balanceOf(address(this));
        uint256 fewOutBaseline = IERC20(route.fewOut).balanceOf(address(this));
        _take(inCurr, address(this), amountIn);
        _wrapExactTo(inCurr, route.fewIn, route.pair, amountIn);
        uint256 fwOutAmount = _executeFewV2ExactInput(route.pair, route.fewIn, route.fewOut, amountIn);

        (uint256 protocolFeeAmount, uint24 protocolFee) =
            _protocolFeeAmount(poolId, params.zeroForOne, fwOutAmount, true);
        uint256 amountOut = fwOutAmount - protocolFeeAmount;
        if (amountOut == 0) revert InvalidSwapAmount();
        _unwrapAndSettleExact(route.fewOut, outCurr, fwOutAmount);
        _payProtocolFee(outCurr, protocolFeeAmount);

        _requireBalance(inCurr, inputBaseline);
        _requireBalance(outCurr, outputBaseline);
        _requireTokenBalance(route.fewIn, fewInBaseline);
        _requireTokenBalance(route.fewOut, fewOutBaseline);

        emit SwapAggregated(poolId, sender, params.zeroForOne, params.amountSpecified, amountIn, amountOut, fwOutAmount);
        _emitHookSwap(poolId, sender, params.zeroForOne, amountIn, amountOut, protocolFee);

        BeforeSwapDelta swapDelta = toBeforeSwapDelta(amountInDelta, -amountOut.toInt256().toInt128());
        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    // ============ Exact-output ============
    function _swapExactOutput(
        address sender,
        PoolId poolId,
        Currency inCurr,
        Currency outCurr,
        SwapParams calldata params,
        DirectRoute memory route
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        int128 amountOutDelta = params.amountSpecified.toInt128();
        uint256 amountOut = OZSafeCast.toUint256(int256(amountOutDelta));

        uint256 fwInRequired = _quoteAmountInForHop(route.pair, route.fewIn, route.fewOut, amountOut);
        (uint256 protocolFeeAmount, uint24 protocolFee) =
            _protocolFeeAmount(poolId, params.zeroForOne, fwInRequired, false);
        uint256 amountIn = fwInRequired + protocolFeeAmount;

        _requireSettlementInventory(route.originIn, amountIn);
        _requireWrapperBacking(route.fewOut, amountOut);

        uint256 inputBaseline = inCurr.balanceOfSelf();
        uint256 outputBaseline = outCurr.balanceOfSelf();
        uint256 fewInBaseline = IERC20(route.fewIn).balanceOf(address(this));
        uint256 fewOutBaseline = IERC20(route.fewOut).balanceOf(address(this));
        _take(inCurr, address(this), fwInRequired);
        _wrapExactTo(inCurr, route.fewIn, route.pair, fwInRequired);
        _executeFewV2ExactOutput(route.pair, route.fewIn, route.fewOut, fwInRequired, amountOut);

        _unwrapAndSettleExact(route.fewOut, outCurr, amountOut);
        _payProtocolFee(inCurr, protocolFeeAmount);

        _requireBalance(inCurr, inputBaseline);
        _requireBalance(outCurr, outputBaseline);
        _requireTokenBalance(route.fewIn, fewInBaseline);
        _requireTokenBalance(route.fewOut, fewOutBaseline);

        emit SwapAggregated(poolId, sender, params.zeroForOne, params.amountSpecified, amountIn, amountOut, amountOut);
        _emitHookSwap(poolId, sender, params.zeroForOne, amountIn, amountOut, protocolFee);

        BeforeSwapDelta swapDelta = toBeforeSwapDelta(-amountOutDelta, amountIn.toInt256().toInt128());
        return (IHooks.beforeSwap.selector, swapDelta, 0);
    }

    function _exactInputAmount(int256 amountSpecified) internal pure returns (uint256 amountIn, int128 amountInDelta) {
        int128 signedAmount = amountSpecified.toInt128();
        amountIn = OZSafeCast.toUint256(-int256(signedAmount));
        amountInDelta = amountIn.toInt128();
    }

    function _emitHookSwap(
        PoolId poolId,
        address sender,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint24 protocolFee
    ) internal {
        int256 signedIn = amountIn.toInt256();
        int256 signedOut = amountOut.toInt256();
        (int256 amount0, int256 amount1) = zeroForOne ? (signedIn, -signedOut) : (-signedOut, signedIn);
        // FewV2's 30 bps venue fee is already reflected in amountIn/amountOut. This field
        // reports the effective Uniswap protocol fee, not the external Pair's LP fee.
        emit HookSwap(poolId, sender, amount0, amount1, protocolFee);
    }

    /// @dev Fee math matches Uniswap/v4-hooks-public ProtocolFees: exact input pays from output;
    ///      exact output pays from grossed-up input. quote() simulates this same path, once.
    function _protocolFeeAmount(PoolId poolId, bool zeroForOne, uint256 amount, bool exactInput)
        internal
        view
        returns (uint256 feeAmount, uint24 rate)
    {
        (,, uint24 packed,) = poolManager.getSlot0(poolId);
        rate = (zeroForOne ? ProtocolFeeLibrary.getZeroForOneFee(packed) : ProtocolFeeLibrary.getOneForZeroFee(packed))
            * protocolFeeMultiplier;
        if (rate != 0) {
            uint256 denominator = exactInput ? 1_000_000 : 1_000_000 - rate;
            // Every executable v4 delta must fit positive int128. Check that bound before the
            // product: int128.max * uint24.max + 1e6 is below 2^152, so this cannot overflow.
            uint256 boundedAmount = uint128(amount.toInt128());
            unchecked {
                feeAmount = (boundedAmount * rate + denominator - 1) / denominator;
            }
        }
    }

    /// @dev The recipient comes only from Uniswap's current fee controller, never Hook governance.
    ///      Resolve every payment so controller/TokenJar rotations cannot leave a stale recipient.
    ///      A configured fee with no usable recipient fails closed instead of silently skipping it.
    function _payProtocolFee(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        address recipient = IV4FeeRecipient(poolManager.protocolFeeController()).TOKEN_JAR();
        if (recipient == address(0)) revert InvalidProtocolFeeRecipient();
        poolManager.take(currency, recipient, amount);
        emit ProtocolFeesCollected(recipient, currency, amount);
    }

    // ============ Wrap / unwrap ============
    function _wrapExactTo(Currency input, address fewToken, address receiver, uint256 amount) internal {
        uint256 inputBefore = input.balanceOfSelf();
        uint256 fewBefore = IERC20(fewToken).balanceOf(receiver);
        if (inputBefore < amount) {
            revert InsufficientConversionBalance(Currency.unwrap(input), inputBefore, amount);
        }

        address underlying = input.isAddressZero() ? address(weth) : Currency.unwrap(input);
        uint256 backingBefore = IERC20(underlying).balanceOf(fewToken);
        if (input.isAddressZero()) {
            uint256 wethBefore = IERC20(address(weth)).balanceOf(address(this));
            weth.deposit{value: amount}();
            _approveAndWrapTo(address(weth), fewToken, receiver, amount);
            _requireTokenBalance(address(weth), wethBefore);
        } else {
            _approveAndWrapTo(underlying, fewToken, receiver, amount);
        }

        _requireBalance(input, inputBefore - amount);
        _requireTokenBalanceAt(fewToken, receiver, fewBefore + amount);
        _requireWrapperBackingDelta(fewToken, backingBefore + amount);
    }

    function _approveAndWrapTo(address underlying, address fewToken, address receiver, uint256 amount) internal {
        IERC20(underlying).forceApprove(fewToken, amount);
        uint256 returnedAmount = IFewWrappedToken(fewToken).wrapTo(amount, receiver);
        IERC20(underlying).forceApprove(fewToken, 0);
        if (returnedAmount != amount) revert WrapReturnMismatch(returnedAmount, amount);
    }

    function _unwrapAndSettleExact(address fewToken, Currency output, uint256 amount) internal {
        uint256 fewBefore = IERC20(fewToken).balanceOf(address(this));
        if (fewBefore < amount) revert InsufficientConversionBalance(fewToken, fewBefore, amount);
        address underlying = IFewWrappedToken(fewToken).token();
        uint256 backingBefore = IERC20(underlying).balanceOf(fewToken);
        if (backingBefore < amount) {
            revert InsufficientWrapperBacking(fewToken, underlying, backingBefore, amount);
        }
        uint256 outputBefore = output.balanceOfSelf();

        if (output.isAddressZero()) {
            uint256 wethBefore = IERC20(address(weth)).balanceOf(address(this));
            uint256 returnedAmount = IFewWrappedToken(fewToken).unwrapTo(amount, address(this));
            if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
            _requireTokenBalance(fewToken, fewBefore - amount);
            _requireWrapperBackingDelta(fewToken, backingBefore - amount);
            _requireTokenBalance(address(weth), wethBefore + amount);
            weth.withdraw(amount);
            _requireTokenBalance(address(weth), wethBefore);
            _requireBalance(output, outputBefore + amount);
            _settleExact(output, amount);
        } else {
            uint256 poolManagerBefore = IERC20(underlying).balanceOf(address(poolManager));
            poolManager.sync(output);
            uint256 returnedAmount = IFewWrappedToken(fewToken).unwrapTo(amount, address(poolManager));
            if (returnedAmount != amount) revert UnwrapReturnMismatch(returnedAmount, amount);
            _requireTokenBalance(fewToken, fewBefore - amount);
            _requireWrapperBackingDelta(fewToken, backingBefore - amount);
            _requireTokenBalanceAt(underlying, address(poolManager), poolManagerBefore + amount);
            uint256 paid = poolManager.settle();
            if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(output), paid, amount);
        }

        _requireBalance(output, outputBefore);
    }

    function _settleExact(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        uint256 paid;
        if (currency.isAddressZero()) {
            paid = poolManager.settle{value: amount}();
        } else {
            currency.transfer(address(poolManager), amount);
            paid = poolManager.settle();
        }
        if (paid != amount) revert SettlementAmountMismatch(Currency.unwrap(currency), paid, amount);
    }

    function _requireBalance(Currency currency, uint256 expected) internal view {
        uint256 actual = currency.balanceOfSelf();
        if (actual != expected) revert TokenBalanceMismatch(Currency.unwrap(currency), expected, actual);
    }

    function _requireTokenBalance(address token, uint256 expected) internal view {
        _requireTokenBalanceAt(token, address(this), expected);
    }

    function _requireTokenBalanceAt(address token, address account, uint256 expected) internal view {
        uint256 actual = IERC20(token).balanceOf(account);
        if (actual != expected) revert TokenBalanceMismatch(token, expected, actual);
    }

    function _requireWrapperBackingDelta(address fewToken, uint256 expected) internal view {
        address underlying = IFewWrappedToken(fewToken).token();
        uint256 actual = IERC20(underlying).balanceOf(fewToken);
        if (actual != expected) revert WrapperBackingDeltaMismatch(fewToken, expected, actual);
    }

    // ============ FewV2 direct-pair execution ============
    function _executeFewV2ExactInput(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        (uint256 reserveIn, uint256 reserveOut, bool inputIsToken0) = _hopState(pair, tokenIn, tokenOut);

        amountOut = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
        (uint256 a0Out, uint256 a1Out) = inputIsToken0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

        uint256 outputBefore = IERC20(tokenOut).balanceOf(address(this));
        ISwapV2Pair(pair).swap(a0Out, a1Out, address(this), "");
        uint256 outputAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 actualOut = outputAfter >= outputBefore ? outputAfter - outputBefore : 0;
        if (actualOut != amountOut) revert FewV2OutputMismatch(tokenOut, amountOut, actualOut);
    }

    function _executeFewV2ExactOutput(
        address pair,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal {
        (uint256 reserveIn, uint256 reserveOut, bool inputIsToken0) = _hopState(pair, tokenIn, tokenOut);
        uint256 expectedInput = FewV2Math.getAmountIn(amountOut, reserveIn, reserveOut);
        if (expectedInput != amountIn) revert TokenBalanceMismatch(tokenIn, expectedInput, amountIn);

        (uint256 a0Out, uint256 a1Out) = inputIsToken0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        uint256 outputBefore = IERC20(tokenOut).balanceOf(address(this));
        ISwapV2Pair(pair).swap(a0Out, a1Out, address(this), "");
        uint256 outputAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 actualOut = outputAfter >= outputBefore ? outputAfter - outputBefore : 0;
        if (actualOut != amountOut) revert FewV2OutputMismatch(tokenOut, amountOut, actualOut);
    }

    function _quoteAmountInForHop(address pair, address tokenIn, address tokenOut, uint256 finalOut)
        internal
        view
        returns (uint256 amountIn)
    {
        (uint256 reserveIn, uint256 reserveOut,) = _hopState(pair, tokenIn, tokenOut);
        amountIn = FewV2Math.getAmountIn(finalOut, reserveIn, reserveOut);
    }

    function _hopState(address pair, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut, bool inputIsToken0)
    {
        address t0 = ISwapV2Pair(pair).token0();
        address t1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        if (tokenIn == t0 && tokenOut == t1) {
            inputIsToken0 = true;
            (reserveIn, reserveOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == t1 && tokenOut == t0) {
            (reserveIn, reserveOut) = (uint256(r1), uint256(r0));
        } else {
            revert TokenMismatch(pair);
        }

        // Reserve units depend on token decimals, so there is no universal economic-depth
        // threshold here. Zero reserves are non-executable; UniRoute applies its own USD TVL
        // filters to thin but nonzero pairs through pseudoTotalValueLocked().
        if (reserveIn == 0 || reserveOut == 0) revert DegeneratePair(pair);
    }

    function _validateFewV2Pair(address pair, address few0, address few1) internal view {
        address pairToken0 = ISwapV2Pair(pair).token0();
        address pairToken1 = ISwapV2Pair(pair).token1();
        if (!((pairToken0 == few0 && pairToken1 == few1) || (pairToken0 == few1 && pairToken1 == few0))) {
            revert TokenMismatch(pair);
        }
    }

    /// @dev PoolManager is a singleton, so this is the physical token balance available to the
    ///      whole manager rather than inventory reserved for one pool or NFT. The unlock cannot
    ///      finish unless all deltas settle back to zero, but the input cash must exist when the
    ///      hook calls `take()`.
    function _requireSettlementInventory(address originToken, uint256 amount) internal view {
        uint256 available = _settlementInventory(originToken);
        if (available < amount) revert InsufficientPoolManagerInventory(originToken, available, amount);
    }

    function _settlementInventory(address originToken) internal view returns (uint256) {
        return
            originToken == address(0)
                ? address(poolManager).balance
                : IERC20(originToken).balanceOf(address(poolManager));
    }

    /// @dev FewToken unwrap is 1:1, but the wrapper must physically hold the underlying output.
    ///      Checking this in both quote and execution avoids advertising a reserve-backed price
    ///      that cannot be redeemed into the origin token.
    function _requireWrapperBacking(address fewToken, uint256 amount) internal view {
        address underlying = IFewWrappedToken(fewToken).token();
        uint256 available = IERC20(underlying).balanceOf(fewToken);
        if (available < amount) revert InsufficientWrapperBacking(fewToken, underlying, available, amount);
    }

    // ============ Permissionless sweep ============

    /// @notice Sweep `token` balance to `residualRecipient`. Anyone may call.
    /// @param  token  ERC20 to sweep, or `address(0)` for native ETH.
    function sweep(address token) external nonReentrant {
        address recipient = residualRecipient;
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            if (amount > 0) {
                // Native ETH can only be swept to residualRecipient.
                (bool ok,) = payable(recipient).call{value: amount}("");
                if (!ok) revert EthForwardFailed();
            }
        } else {
            amount = IERC20(token).balanceOf(address(this));
            if (amount > 0) IERC20(token).safeTransfer(recipient, amount);
        }
        emit Sweep(token, recipient, amount, msg.sender);
    }

    // ============ Routing reads ============
    /// @notice Quotes the complete shell swap using the Uniswap aggregator-hook ABI.
    /// @dev Negative amountSpecified = exact-input; positive amountSpecified = exact-output.
    ///      V4Quoter simulates the actual shell pool callback, including PoolManager input cash,
    ///      FewToken output backing, wrapping, FewV2 fee math and full settlement.
    ///      Like the canonical quoter, all simulated state changes are reverted before returning.
    function quote(bool zeroForOne, int256 amountSpecified, PoolId poolId)
        external
        override
        returns (uint256 amountUnspecified)
    {
        if (amountSpecified == 0) revert InvalidSwapAmount();
        RegisteredRoute storage registered = _registeredRoute(poolId);
        PoolKey memory shellKey = PoolKey({
            currency0: Currency.wrap(registered.origin0),
            currency1: Currency.wrap(registered.origin1),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(this))
        });

        if (amountSpecified < 0) {
            (uint256 amountIn,) = _exactInputAmount(amountSpecified);
            (amountUnspecified,) = v4Quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: shellKey, zeroForOne: zeroForOne, exactAmount: amountIn.toUint128(), hookData: bytes("")
                })
            );
            return amountUnspecified;
        }

        int128 amountOutDelta = amountSpecified.toInt128();
        uint256 amountOut = OZSafeCast.toUint256(int256(amountOutDelta));
        (amountUnspecified,) = v4Quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: shellKey, zeroForOne: zeroForOne, exactAmount: amountOut.toUint128(), hookData: bytes("")
            })
        );
    }

    /// @notice Reports FewV2 reserves in the v4 pool token order for UniRoute external-liquidity discovery.
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        RegisteredRoute storage route = _registeredRoute(poolId);
        address pairToken0 = ISwapV2Pair(route.pair).token0();
        address pairToken1 = ISwapV2Pair(route.pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(route.pair).getReserves();

        if (route.few0 == pairToken0 && route.few1 == pairToken1) {
            (amount0, amount1) = (uint256(r0), uint256(r1));
        } else if (route.few0 == pairToken1 && route.few1 == pairToken0) {
            (amount0, amount1) = (uint256(r1), uint256(r0));
        } else {
            revert TokenMismatch(route.pair);
        }

        if (amount0 == 0 || amount1 == 0) return (0, 0);

        // FewV2 reserves are only useful to origin-token traders while the wrappers can redeem them
        // and PoolManager has enough physical origin-token cash for the Hook's flash take(). These
        // balances belong to the singleton PoolManager, not this PoolId, so quote() remains the final
        // executability check at the exact block and amount.
        uint256 backing0 = IERC20(IFewWrappedToken(route.few0).token()).balanceOf(route.few0);
        uint256 backing1 = IERC20(IFewWrappedToken(route.few1).token()).balanceOf(route.few1);
        uint256 settlement0 = _settlementInventory(route.origin0);
        uint256 settlement1 = _settlementInventory(route.origin1);
        if (amount0 > backing0) amount0 = backing0;
        if (amount1 > backing1) amount1 = backing1;
        if (amount0 > settlement0) amount0 = settlement0;
        if (amount1 > settlement1) amount1 = settlement1;
    }

    /// @notice Returns the current FewV2-derived price that should be supplied to PoolManager.initialize.
    function previewInitializationPrice(PoolKey calldata key) external view returns (uint160 sqrtPriceX96) {
        if (key.fee != CANONICAL_POOL_FEE || key.tickSpacing != CANONICAL_TICK_SPACING) revert InvalidPoolKey();
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _validateCanonicalWethRepresentation(t0, t1);
        if (_isFewTokenOf(t0, t1) || _isFewTokenOf(t1, t0)) revert UseFewTokenHookForWrapPairs();
        (address few0, address few1) = _defaultFewPair(t0, t1);
        if (few0 == address(0) || few1 == address(0)) revert NoFewV2Route();
        _validateWrapper(few0, _underlyingForCurrency(t0));
        _validateWrapper(few1, _underlyingForCurrency(t1));
        if (few0 == few1) revert InvalidPoolKey();
        address pair = fewV2Factory.getPair(few0, few1);
        if (pair == address(0)) revert NoFewV2Route();
        _requireCode(pair);
        _validateFewV2Pair(pair, few0, few1);
        return FewV2Price.fromPair(ISwapV2Pair(pair), few0, few1);
    }

    /// @notice Live executable sqrt price derived from the registered FewV2 pair, in Shell currency order.
    /// @dev Shell slot0 is only an initialization marker and does not move during full custom-accounting swaps.
    function executionSqrtPriceX96(PoolId poolId) external view returns (uint160) {
        return _executionSqrtPriceX96(poolId);
    }

    function _executionSqrtPriceX96(PoolId poolId) internal view returns (uint160) {
        RegisteredRoute storage route = _registeredRoute(poolId);
        return FewV2Price.fromPair(ISwapV2Pair(route.pair), route.few0, route.few1);
    }

    /// @notice Physical PoolManager cash available when this Hook calls take().
    /// @dev PoolManager is a singleton; these balances are not reserved for this PoolId.
    function availableSettlementInventory(PoolId poolId) external view returns (uint256 amount0, uint256 amount1) {
        RegisteredRoute storage route = _registeredRoute(poolId);
        amount0 = _settlementInventory(route.origin0);
        amount1 = _settlementInventory(route.origin1);
    }

    /// @notice Origin-token backing currently redeemable from each route wrapper.
    function availableWrapperBacking(PoolId poolId) external view returns (uint256 amount0, uint256 amount1) {
        RegisteredRoute storage route = _registeredRoute(poolId);
        amount0 = IERC20(IFewWrappedToken(route.few0).token()).balanceOf(route.few0);
        amount1 = IERC20(IFewWrappedToken(route.few1).token()).balanceOf(route.few1);
    }

    function registeredRouteFor(PoolId poolId) external view returns (address few0, address few1, address pair) {
        RegisteredRoute storage route = _registeredRoute(poolId);
        return (route.few0, route.few1, route.pair);
    }

    /// @notice The direct 1-hop FewV2 route derived from fewFactory for a pool.
    function defaultRouteFor(PoolKey calldata key) external view returns (address fewA, address fewB, address pair) {
        (fewA, fewB) = _defaultFewPair(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (fewA != address(0) && fewB != address(0)) {
            pair = fewV2Factory.getPair(fewA, fewB);
        }
    }

    function _registeredRoute(PoolId poolId) internal view returns (RegisteredRoute storage route) {
        route = _registeredRoutes[poolId];
        if (route.pair == address(0)) revert PoolDoesNotExist();
    }

    function _executeQuoteExactInput(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        (uint256 reserveIn, uint256 reserveOut,) = _hopState(pair, tokenIn, tokenOut);
        amountOut = FewV2Math.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function _requireCode(address dependency) internal view {
        if (dependency.code.length == 0) revert DependencyHasNoCode(dependency);
    }

    // ============ Native ETH receive ============
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(weth)) {
            revert UnexpectedNativeSender(msg.sender);
        }
    }
}
