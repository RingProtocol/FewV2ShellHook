// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter as ICanonicalV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {IAggregatorHook} from "../../src/interfaces/IAggregatorHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {FewV2Price} from "../../src/lib/FewV2Price.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
}

// ════════════════════════════════════════════════════════════════════════════
// Adversarial test helpers
// ════════════════════════════════════════════════════════════════════════════

/// @dev Force-feeds ETH to a target via selfdestruct. Same-tx selfdestruct still
///      transfers balance to target post-Cancun.
contract SelfDestructAttacker {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Reentrant `receive()` that tries to re-enter `hook.sweep`. nonReentrant must block.
contract ReentrantSweepReceiver {
    FewV2ShellHookBase public immutable hookContract;

    constructor(address _hook) {
        hookContract = FewV2ShellHookBase(payable(_hook));
    }

    receive() external payable {
        hookContract.sweep(address(0));
    }
}

interface IPublicFewFactory {
    function createToken(address originalToken) external returns (address);
}

interface IPublicFewV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IFewV2LiquidityPair {
    function mint(address to) external returns (uint256);
}

/// @dev An untrusted underlying: anyone can mint it, and transfers can call the Hook.
///      Factory identity must not be confused with approval of this token's behavior.
contract AdversarialOriginToken is ERC20 {
    address public callbackHook;
    address public callbackAsset;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackReason;

    constructor() ERC20("Untrusted Origin", "BAD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armCallback(address hook_, address asset_) external {
        callbackHook = hook_;
        callbackAsset = asset_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (msg.sender == callbackHook && callbackHook != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded, callbackReason) =
                callbackHook.call(abi.encodeCall(FewV2ShellHookBase.sweep, (callbackAsset)));
        }
    }
}

contract RegistrationForwarder {
    function initialize(IPoolManager manager, PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }
}

/// @dev Test-only subclass that skips BaseHook's address-bit validation, so we can
///      deploy at any address to exercise constructor-body reverts (zero-address checks).
contract HookNoAddressCheck is FewV2ShellHookBase {
    constructor(
        IPoolManager _pm,
        IFewFactory _fewFactory,
        ISwapV2Factory _fewV2Factory,
        IWETH9 _weth,
        ICanonicalV4Quoter _v4Quoter,
        bool _useNativeCurrencyForWeth,
        address _poolInitializer,
        address _residualRecipient,
        ISubsidyVault _subsidyVault
    )
        FewV2ShellHookBase(
            _pm,
            _fewFactory,
            _fewV2Factory,
            _weth,
            _v4Quoter,
            _useNativeCurrencyForWeth,
            _poolInitializer,
            _residualRecipient,
            _subsidyVault
        )
    {}
    function validateHookAddress(BaseHook) internal pure override {}

    function exposedExactInputAmount(int256 amountSpecified) external pure returns (uint256, int128) {
        return _exactInputAmount(amountSpecified);
    }
}

/// @notice Mainnet fork e2e for FewV2ShellHookBase (admin-less variant).
///         Coverage scope: core swap correctness, ETH abuse + sweep, mocked-external
///         pair attacks and constructor zero-address checks. NO owner / pause / route-management
///         tests, since V1 has no such surface.
///         Skipped if `ETH_RPC_URL` is not set.
contract FewV2ShellHookBaseForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Mainnet addresses
    address constant V4_PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant FW_ETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FW_USDC = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address constant FW_WBTC = 0x2078f336Fdd260f708BEc4a20c82b063274E1b23;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant FW_USDS = 0xD777151C92C05fEa839b2c21b345a78e1F1163Fe;
    address constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant RING_FACTORY = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;
    address constant FEWV2_PAIR = 0x54222F404dcfAc705322045F01D100380b871450;
    address constant FEWV2_WBTC_USDC_PAIR = 0x6C8f21f578AC94eAb4F650CeC890fFA9C9d305E2;
    uint160 constant INIT_PRICE = 79228162514264337593543950336;
    uint24 constant CANONICAL_POOL_FEE = 3000;
    int24 constant CANONICAL_TICK_SPACING = 1;

    address constant RESIDUAL_RECIPIENT = address(0xFEE);
    address constant USER = address(0xBEEF);
    bool forked;
    FewV2ShellHookBase hook;
    /// @dev Shared by the constructor-revert harness. It is deployed in setUp so that
    ///      `vm.expectRevert` still targets the Hook deployment and not a vault deployment.
    ISubsidyVault internal harnessVault;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyRouter;
    PoolKey ethUsdcKey;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forked = false;
            return;
        }
        uint256 forkBlock = vm.envOr("TEST_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        forked = true;

        // 1. Mine a salt for the hook permission flags.
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCode = type(FewV2ShellHookBase).creationCode;
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        harnessVault = new SubsidyVault(IPoolManager(V4_PM), address(this));
        bytes memory ctorArgs = abi.encode(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            harnessVault
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, ctorArgs);

        // 3. Deploy the hook using CREATE2 with mined salt.
        hook = new FewV2ShellHookBase{salt: salt}(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            harnessVault
        );
        require(address(hook) == mined, "Hook address mismatch");

        // 3. V4 test helpers.
        swapRouter = new PoolSwapTest(IPoolManager(V4_PM));
        modifyRouter = new PoolModifyLiquidityTest(IPoolManager(V4_PM));

        // 4. Pool key for ETH/USDC.
        ethUsdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // 5. Initialize the pool.
        IPoolManager(V4_PM).initialize(ethUsdcKey, hook.previewInitializationPrice(ethUsdcKey));
    }

    modifier requireFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function _v2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / ((reserveIn * 1000) + amountInWithFee);
    }

    function _v2AmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return ((reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997)) + 1;
    }

    function _quoteHopExactInput(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bool ok, uint256 amountOut)
    {
        if (pair == address(0) || amountIn == 0) return (false, 0);
        address token0 = ISwapV2Pair(pair).token0();
        address token1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        if (tokenIn == token0 && tokenOut == token1) {
            (reserveIn, reserveOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == token1 && tokenOut == token0) {
            (reserveIn, reserveOut) = (uint256(r1), uint256(r0));
        } else {
            return (false, 0);
        }

        if (reserveIn == 0 || reserveOut == 0) return (false, 0);
        amountOut = _v2AmountOut(amountIn, reserveIn, reserveOut);
        ok = amountOut != 0;
    }

    function _quoteHopExactOutput(address pair, address tokenIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (bool ok, uint256 amountIn)
    {
        if (pair == address(0) || amountOut == 0) return (false, 0);
        address token0 = ISwapV2Pair(pair).token0();
        address token1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();

        uint256 reserveIn;
        uint256 reserveOut;
        if (tokenIn == token0 && tokenOut == token1) {
            (reserveIn, reserveOut) = (uint256(r0), uint256(r1));
        } else if (tokenIn == token1 && tokenOut == token0) {
            (reserveIn, reserveOut) = (uint256(r1), uint256(r0));
        } else {
            return (false, 0);
        }

        if (reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) {
            return (false, 0);
        }
        amountIn = _v2AmountIn(amountOut, reserveIn, reserveOut);
        ok = amountIn != 0;
    }

    function _bestDefaultExactInput(address fewIn, address fewOut, uint256 amountIn)
        internal
        view
        returns (uint256 bestAmountOut)
    {
        address pair = ISwapV2Factory(RING_FACTORY).getPair(fewIn, fewOut);
        (bool found, uint256 amountOut) = _quoteHopExactInput(pair, fewIn, fewOut, amountIn);
        require(found, "no direct exact-in route");
        return amountOut;
    }

    function _bestDefaultExactOutput(address fewIn, address fewOut, uint256 amountOut)
        internal
        view
        returns (uint256 bestAmountIn)
    {
        address pair = ISwapV2Factory(RING_FACTORY).getPair(fewIn, fewOut);
        (bool found, uint256 amountIn) = _quoteHopExactOutput(pair, fewIn, fewOut, amountOut);
        require(found, "no direct exact-out route");
        return amountIn;
    }

    // ─────────── Sanity ───────────

    function test_fork_setUpInitializedHookPool() public requireFork {
        assertEq(address(ethUsdcKey.hooks), address(hook));
        assertEq(hook.poolInitializer(), address(this));
    }

    function test_fork_defaultRouteResolves() public requireFork {
        (address fewA, address fewB, address pair) = hook.defaultRouteFor(ethUsdcKey);
        assertEq(fewA, FW_ETH, "fewA == fwETH");
        assertEq(fewB, FW_USDC, "fewB == fwUSDC");
        assertEq(pair, FEWV2_PAIR, "pair == real fewV2 pair");
    }

    function test_fork_registeredRouteResolves() public requireFork {
        (address few0, address few1, address pair) = hook.registeredRouteFor(ethUsdcKey.toId());
        assertEq(few0, FW_ETH, "registered few0 == fwETH");
        assertEq(few1, FW_USDC, "registered few1 == fwUSDC");
        assertEq(pair, FEWV2_PAIR, "registered pair == real fewV2 pair");
        assertTrue(hook.fewV2PairRegistered(FEWV2_PAIR), "pair registered");
        assertEq(PoolId.unwrap(hook.poolIdForFewV2Pair(FEWV2_PAIR)), PoolId.unwrap(ethUsdcKey.toId()));
    }

    function test_fork_previewInitializationPrice_matchesCanonicalFewV2Pair() public requireFork {
        uint160 expected = FewV2Price.fromPair(ISwapV2Pair(FEWV2_PAIR), FW_ETH, FW_USDC);
        assertEq(hook.previewInitializationPrice(ethUsdcKey), expected);
        assertEq(hook.executionSqrtPriceX96(ethUsdcKey.toId()), expected);
    }

    function test_fork_availableInventoryAndBackingViews_matchLiveBalances() public requireFork {
        (uint256 inventory0, uint256 inventory1) = hook.availableSettlementInventory(ethUsdcKey.toId());
        (uint256 backing0, uint256 backing1) = hook.availableWrapperBacking(ethUsdcKey.toId());

        assertEq(inventory0, V4_PM.balance);
        assertEq(inventory1, IERC20(USDC).balanceOf(V4_PM));
        assertEq(backing0, IERC20(WETH).balanceOf(FW_ETH));
        assertEq(backing1, IERC20(USDC).balanceOf(FW_USDC));
    }

    function test_fork_pseudoTotalValueLocked_capsExplicitUnderbacking() public requireFork {
        deal(USDC, FW_USDC, 1234);
        (, uint256 amount1) = hook.pseudoTotalValueLocked(ethUsdcKey.toId());
        assertEq(amount1, 1234, "pTVL must not advertise unredeemable fwUSDC reserves");
    }

    function test_fork_pseudoTotalValueLocked_capsPoolManagerSettlementInventory() public requireFork {
        vm.deal(V4_PM, 1234);
        deal(USDC, V4_PM, 5678);

        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(ethUsdcKey.toId());

        assertEq(amount0, 1234, "pTVL must not exceed PoolManager ETH cash");
        assertEq(amount1, 5678, "pTVL must not exceed PoolManager USDC cash");
    }

    function test_fork_pseudoTotalValueLocked_capsFewV2ReservesByWrapperBacking() public requireFork {
        (uint256 tvl0, uint256 tvl1) = hook.pseudoTotalValueLocked(ethUsdcKey.toId());
        address pairToken0 = ISwapV2Pair(FEWV2_PAIR).token0();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();

        uint256 reserve0 = pairToken0 == FW_ETH ? uint256(r0) : uint256(r1);
        uint256 reserve1 = pairToken0 == FW_USDC ? uint256(r0) : uint256(r1);
        uint256 expected0 = Math.min(Math.min(reserve0, IERC20(WETH).balanceOf(FW_ETH)), V4_PM.balance);
        uint256 expected1 = Math.min(Math.min(reserve1, IERC20(USDC).balanceOf(FW_USDC)), IERC20(USDC).balanceOf(V4_PM));

        assertEq(tvl0, expected0, "pseudo TVL token0");
        assertEq(tvl1, expected1, "pseudo TVL token1");
        assertGt(tvl0, 0, "nonzero token0 TVL");
        assertGt(tvl1, 0, "nonzero token1 TVL");
    }

    function test_fork_aggregatorQuote_matchesDirectQuote_exactInput() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);

        uint256 quotedAmountOut = hook.quote(true, -int256(amountIn), ethUsdcKey.toId());

        assertEq(quotedAmountOut, expectedOut, "aggregator quote exact-in");
    }

    function test_fork_aggregatorQuote_matchesDirectQuote_exactOutput() public requireFork {
        uint256 amountOut = 10_000;
        uint256 expectedIn = _bestDefaultExactOutput(FW_ETH, FW_USDC, amountOut);

        uint256 quotedAmountIn = hook.quote(true, int256(amountOut), ethUsdcKey.toId());

        assertEq(quotedAmountIn, expectedIn, "aggregator quote exact-out");
    }

    function test_fork_aggregatorQuote_unknownPool_reverts() public requireFork {
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -int256(1), PoolId.wrap(bytes32(uint256(1))));
    }

    function test_fork_aggregatorQuote_zeroAmount_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.InvalidSwapAmount.selector);
        hook.quote(true, 0, ethUsdcKey.toId());
    }

    function test_fork_emptyHookData_directRoute_matchesDirectQuote_exactInput() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);

        vm.deal(USER, amountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, "");

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(received, expectedOut, "empty hookData used direct route");
    }

    function test_fork_v4Quoter_emptyHookData_matchesActualSwap_exactInput() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);

        (uint256 quotedAmountOut, uint256 gasEstimate) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: ethUsdcKey, zeroForOne: true, exactAmount: uint128(amountIn), hookData: ""
                })
            );
        assertEq(quotedAmountOut, expectedOut, "V4Quoter sees direct route");
        assertGt(gasEstimate, 0, "V4Quoter returns gas estimate");

        vm.deal(USER, amountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, "");

        uint256 actualAmountOut = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(quotedAmountOut, actualAmountOut, "V4Quoter quote matches actual swap");
    }

    function test_fork_v4Quoter_emptyHookData_matchesActualSwap_exactOutput() public requireFork {
        uint256 amountOut = 10_000;
        uint256 expectedIn = _bestDefaultExactOutput(FW_ETH, FW_USDC, amountOut);

        (uint256 quotedAmountIn, uint256 gasEstimate) = IV4Quoter(V4_QUOTER)
            .quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: ethUsdcKey, zeroForOne: true, exactAmount: uint128(amountOut), hookData: ""
                })
            );
        assertEq(quotedAmountIn, expectedIn, "V4Quoter sees direct exact-out route");
        assertGt(gasEstimate, 0, "V4Quoter returns gas estimate");

        vm.deal(USER, quotedAmountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: quotedAmountIn}(ethUsdcKey, params, settings, "");

        uint256 actualAmountOut = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(actualAmountOut, amountOut, "actual swap returns exact output");
        assertEq(uint256(uint128(-delta.amount0())), quotedAmountIn, "V4Quoter quote matches actual input");
    }

    function test_fork_revertsInitWithoutDirectFewV2Pair() public requireFork {
        assertEq(ISwapV2Factory(RING_FACTORY).getPair(FW_ETH, FW_USDS), address(0), "test assumes no direct pair");

        PoolKey memory ethUsdsKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDS),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert();
        IPoolManager(V4_PM).initialize(ethUsdsKey, INIT_PRICE);
    }

    // ─────────── Initialize is rejected for invalid configs ───────────

    function test_fork_revertsInitOnNonCanonicalFee() public requireFork {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        IPoolManager(V4_PM).initialize(badKey, INIT_PRICE);
    }

    function test_fork_revertsInitOnFewWrapPair() public requireFork {
        // ETH/fwETH would be a 1:1 wrapper pair — beforeInitialize must refuse.
        PoolKey memory wrapKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(FW_ETH),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        IPoolManager(V4_PM).initialize(wrapKey, INIT_PRICE);
    }

    function test_fork_revertsInitDuplicateFewV2Pair() public requireFork {
        PoolKey memory duplicateKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // BaseHook wraps hook reverts when called through PoolManager.initialize.
        vm.expectRevert();
        IPoolManager(V4_PM).initialize(duplicateKey, INIT_PRICE);
        assertEq(PoolId.unwrap(hook.poolIdForFewV2Pair(FEWV2_PAIR)), PoolId.unwrap(ethUsdcKey.toId()));
    }

    function test_fork_revertsInitWhenPriceIsMoreThanOneTickFromFewV2() public requireFork {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(USDC),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 expected = hook.previewInitializationPrice(key);
        int24 expectedTick = TickMath.getTickAtSqrtPrice(expected);
        uint160 provided = TickMath.getSqrtPriceAtTick(expectedTick + hook.MAX_INIT_TICK_DEVIATION() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                FewV2ShellHookBase.InitializationPriceMismatch.selector,
                provided,
                expected,
                hook.MAX_INIT_TICK_DEVIATION()
            )
        );
        vm.prank(V4_PM);
        hook.beforeInitialize(address(this), key, provided);
        assertFalse(hook.fewV2PairRegistered(FEWV2_WBTC_USDC_PAIR));
    }

    function test_fork_revertsInitFromUnauthorizedAccount() public requireFork {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(USDC),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        uint160 expected = hook.previewInitializationPrice(key);
        address unauthorized = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(FewV2ShellHookBase.UnauthorizedPoolInitializer.selector, unauthorized));
        vm.prank(V4_PM);
        hook.beforeInitialize(unauthorized, key, expected);
        assertFalse(hook.fewV2PairRegistered(FEWV2_WBTC_USDC_PAIR));
    }

    function _createUntrustedCanonicalPair()
        internal
        returns (AdversarialOriginToken token, address wrapper, address pair, PoolKey memory key, uint160 price)
    {
        address attacker = address(0xBAD);
        token = new AdversarialOriginToken();
        vm.startPrank(attacker);
        wrapper = IPublicFewFactory(FEW_FACTORY).createToken(address(token));
        pair = IPublicFewV2Factory(RING_FACTORY).createPair(wrapper, FW_ETH);
        token.mint(attacker, 1_000 ether);
        token.approve(wrapper, 1_000 ether);
        IFewWrappedToken(wrapper).wrapTo(1_000 ether, pair);
        vm.deal(attacker, 1 ether);
        IWETH9(WETH).deposit{value: 1 ether}();
        IERC20(WETH).approve(FW_ETH, 1 ether);
        IFewWrappedToken(FW_ETH).wrapTo(1 ether, pair);
        IFewV2LiquidityPair(pair).mint(attacker);
        vm.stopPrank();

        assertEq(IFewFactory(FEW_FACTORY).getWrappedToken(address(token)), wrapper);
        assertEq(ISwapV2Factory(RING_FACTORY).getPair(wrapper, FW_ETH), pair);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        price = hook.previewInitializationPrice(key);
    }

    function _expectUnauthorizedInitialization(address caller) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FewV2ShellHookBase.UnauthorizedPoolInitializer.selector, caller),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_attack_publicWrapperAndPairCreationCannotRegisterCustomTokenRoute() public requireFork {
        (,, address pair, PoolKey memory key, uint160 price) = _createUntrustedCanonicalPair();
        uint256 managerEth = V4_PM.balance;
        uint256 managerUsdc = IERC20(USDC).balanceOf(V4_PM);
        uint256 wethBacking = IERC20(WETH).balanceOf(FW_ETH);
        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();

        address attacker = address(0xBAD);
        _expectUnauthorizedInitialization(attacker);
        vm.prank(attacker);
        IPoolManager(V4_PM).initialize(key, price);

        assertFalse(hook.fewV2PairRegistered(pair));
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.registeredRouteFor(key.toId());
        (,, address existingPair) = hook.registeredRouteFor(ethUsdcKey.toId());
        assertEq(existingPair, FEWV2_PAIR);
        assertEq(V4_PM.balance, managerEth);
        assertEq(IERC20(USDC).balanceOf(V4_PM), managerUsdc);
        assertEq(IERC20(WETH).balanceOf(FW_ETH), wethBacking);
        (uint112 after0, uint112 after1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();
        assertEq(after0, r0);
        assertEq(after1, r1);
    }

    function test_attack_registrationForwarderCannotSpoofInitializer() public requireFork {
        (,, address pair, PoolKey memory key, uint160 price) = _createUntrustedCanonicalPair();
        RegistrationForwarder forwarder = new RegistrationForwarder();
        // Even a transaction originating from the initializer does not authorize this intermediary.
        // PoolManager supplies its actual msg.sender to beforeInitialize, not caller-controlled data.
        _expectUnauthorizedInitialization(address(forwarder));
        vm.prank(address(this), address(this));
        forwarder.initialize(IPoolManager(V4_PM), key, price);
        assertFalse(hook.fewV2PairRegistered(pair));
    }

    function test_attack_initializerCanAdmitUntrustedTokenDespiteCanonicalChecks() public requireFork {
        (AdversarialOriginToken token,, address pair, PoolKey memory key, uint160 price) =
            _createUntrustedCanonicalPair();
        // Counterexample: canonical factories do not provide an underlying-token allowlist.
        IPoolManager(V4_PM).initialize(key, price);
        assertTrue(hook.fewV2PairRegistered(pair));
        (,, address registeredPair) = hook.registeredRouteFor(key.toId());
        assertEq(registeredPair, pair);
        token.mint(address(0xBAD), 1_000_000 ether);
        assertEq(token.balanceOf(address(0xBAD)), 1_000_000 ether, "unbounded mint remains possible after admission");
        (,, address originalPair) = hook.registeredRouteFor(ethUsdcKey.toId());
        assertEq(originalPair, FEWV2_PAIR);
    }

    function test_attack_hookDataCannotRedirectToCustomTokenPair() public requireFork {
        (AdversarialOriginToken token, address wrapper, address pair,,) = _createUntrustedCanonicalPair();
        (uint112 custom0, uint112 custom1,) = ISwapV2Pair(pair).getReserves();
        uint256 customBacking = token.balanceOf(wrapper);
        uint256 amountIn = 0.01 ether;
        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);
        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        bytes memory hookData = abi.encode(pair, wrapper, address(token), address(0xBAD));
        vm.deal(USER, amountIn);
        vm.prank(USER);
        swapRouter.swap{value: amountIn}(
            ethUsdcKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            hookData
        );
        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, expectedOut);
        (uint112 after0, uint112 after1,) = ISwapV2Pair(pair).getReserves();
        assertEq(after0, custom0);
        assertEq(after1, custom1);
        assertEq(token.balanceOf(wrapper), customBacking);
        (,, address existingPair) = hook.registeredRouteFor(ethUsdcKey.toId());
        assertEq(existingPair, FEWV2_PAIR);
    }

    function test_attack_unregisteredTokenSweepCallbackCannotSweepOtherAsset() public requireFork {
        AdversarialOriginToken token = new AdversarialOriginToken();
        token.mint(address(hook), 1 ether);
        token.armCallback(address(hook), USDC);
        deal(USDC, address(hook), 100e6);
        vm.deal(address(hook), 1 ether);
        uint256 recipientBefore = IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT);
        uint256 managerBefore = IERC20(USDC).balanceOf(V4_PM);
        vm.prank(address(0xBAD));
        hook.sweep(address(token));

        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackReason(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(token.balanceOf(RESIDUAL_RECIPIENT), 1 ether);
        assertEq(IERC20(USDC).balanceOf(address(hook)), 100e6);
        assertEq(address(hook).balance, 1 ether);
        assertEq(IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT), recipientBefore);
        assertEq(IERC20(USDC).balanceOf(V4_PM), managerBefore);
    }

    function test_fork_beforeSwapRejectsAlreadyExceededFewV2PriceLimit() public requireFork {
        uint160 current = hook.executionSqrtPriceX96(ethUsdcKey.toId());
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: current});

        vm.expectRevert(
            abi.encodeWithSelector(FewV2ShellHookBase.FewV2PriceLimitAlreadyExceeded.selector, current, current)
        );
        vm.prank(V4_PM);
        hook.beforeSwap(address(swapRouter), ethUsdcKey, params, "");
    }

    function test_fork_beforeSwapRejectsOutOfBoundsFewV2PriceLimit() public requireFork {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE});

        vm.expectRevert(
            abi.encodeWithSelector(FewV2ShellHookBase.FewV2PriceLimitOutOfBounds.selector, TickMath.MIN_SQRT_PRICE)
        );
        vm.prank(V4_PM);
        hook.beforeSwap(address(swapRouter), ethUsdcKey, params, "");
    }

    function test_fork_beforeSwapRejectsZeroAmount() public requireFork {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(FewV2ShellHookBase.InvalidSwapAmount.selector);
        vm.prank(V4_PM);
        hook.beforeSwap(address(swapRouter), ethUsdcKey, params, "");
    }

    // ─────────── e2e × 4: ExactIn/Out × zeroForOne/oneForZero ───────────

    function test_fork_e2e_ETH_to_USDC_exactInput() public requireFork {
        uint256 amountIn = 0.5 ether;
        vm.deal(USER, 1 ether);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, "");

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertGt(received, 0, "user must receive USDC");

        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Hook USDC residue should be 0");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d0), -int256(amountIn), "delta.amount0 mismatch");
        assertEq(int256(d1), int256(received), "delta.amount1 mismatch");
    }

    function test_fork_e2e_USDC_to_ETH_exactInput() public requireFork {
        uint256 amountIn = 2000e6;
        deal(USDC, USER, amountIn);
        vm.prank(USER);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);

        uint256 userEthBefore = USER.balance;

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap(ethUsdcKey, params, settings, "");

        uint256 received = USER.balance - userEthBefore;
        assertGt(received, 0, "user must receive ETH");

        assertEq(IERC20(FW_ETH).balanceOf(address(hook)), 0, "Hook fwETH residue should be 0");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "Hook fwUSDC residue should be 0");
        assertEq(address(hook).balance, 0, "Hook ETH residue should be 0");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d1), -int256(amountIn), "delta.amount1 mismatch");
        assertApproxEqAbs(int256(d0), int256(received), 10, "delta.amount0 within 10 wei of received");
    }

    function test_fork_e2e_ETH_to_USDC_exactOutput() public requireFork {
        uint256 amountOut = 500e6;

        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();
        bool fwEthIsToken0 = ISwapV2Pair(FEWV2_PAIR).token0() == FW_ETH;
        (uint256 reserveIn, uint256 reserveOut) =
            fwEthIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 expectedIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
        require(expectedIn < 1 ether, "Expected < 1 ETH for 500 USDC - reserves too thin?");

        uint256 ethBudget = expectedIn + 0.05 ether;
        vm.deal(USER, ethBudget);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: ethBudget}(ethUsdcKey, params, settings, "");

        uint256 usdcReceived = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertGe(usdcReceived, amountOut, "Should receive at least exact USDC amount");
        assertLe(usdcReceived, amountOut + 10, "USDC received within 10 wei of target");

        assertEq(address(hook).balance, 0, "Hook ETH residue should be 0");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d1), int256(amountOut), "delta.amount1 should be +amountOut");
        assertLt(int256(d0), 0, "delta.amount0 should be negative");
    }

    function test_fork_e2e_USDC_to_ETH_exactOutput() public requireFork {
        uint256 amountOut = 0.2 ether;

        (uint112 r0, uint112 r1,) = ISwapV2Pair(FEWV2_PAIR).getReserves();
        bool fwEthIsToken0 = ISwapV2Pair(FEWV2_PAIR).token0() == FW_ETH;
        (uint256 reserveIn, uint256 reserveOut) =
            fwEthIsToken0 ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        uint256 expectedIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;

        uint256 usdcBudget = expectedIn * 101 / 100;
        deal(USDC, USER, usdcBudget);
        vm.prank(USER);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);

        uint256 userEthBefore = USER.balance;

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap(ethUsdcKey, params, settings, "");

        uint256 ethReceived = USER.balance - userEthBefore;
        assertGe(ethReceived, amountOut, "Should receive at least exact ETH amount");
        assertLe(ethReceived, amountOut + 10, "ETH received within 10 wei of target");

        assertEq(address(hook).balance, 0, "exact-out must not leave native-token dust");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        assertEq(int256(d0), int256(amountOut), "delta.amount0 should be +amountOut");
        assertLt(int256(d1), 0, "delta.amount1 should be negative");
    }

    // ─────────── Non-empty hookData is ignored in direct-only mode ───────────

    function test_fork_nonEmptyHookData_ETH_to_USDC_exactInput_usesDirectRoute() public requireFork {
        uint256 amountIn = 0.01 ether;
        bytes memory hookData = hex"01";
        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);

        vm.deal(USER, amountIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: amountIn}(ethUsdcKey, params, settings, hookData);

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(received, expectedOut, "non-empty hookData still uses direct route");
        assertEq(int256(delta.amount0()), -int256(amountIn), "delta.amount0 mismatch");
        assertEq(int256(delta.amount1()), int256(received), "delta.amount1 mismatch");
    }

    function test_fork_nonEmptyHookData_ETH_to_USDC_exactOutput_usesDirectRoute() public requireFork {
        uint256 amountOut = 10_000;
        bytes memory hookData = hex"01";

        vm.deal(USER, 1 ether);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: 1 ether}(ethUsdcKey, params, settings, hookData);

        uint256 received = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(received, amountOut, "user receives exact output through direct route");
        assertEq(int256(delta.amount1()), int256(amountOut), "delta.amount1 mismatch");
        assertLt(int256(delta.amount0()), 0, "delta.amount0 should be negative");
    }

    // ─────────── Native liquidity ───────────

    function test_fork_modifyLiquidity_acceptsFundedPosition() public requireFork {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(CANONICAL_TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(CANONICAL_TICK_SPACING),
            liquidityDelta: 1e9,
            salt: bytes32(0)
        });
        deal(USDC, USER, 100e6);
        vm.deal(USER, 1 ether);
        vm.startPrank(USER);
        IERC20(USDC).approve(address(modifyRouter), 100e6);
        BalanceDelta delta = modifyRouter.modifyLiquidity{value: 1 ether}(ethUsdcKey, params, "");
        vm.stopPrank();
        assertLt(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);
        assertEq(StateLibrary.getLiquidity(IPoolManager(V4_PM), ethUsdcKey.toId()), 1e9);
    }

    function test_fork_modifyLiquidityReverts_removeMissingPosition() public requireFork {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)});
        vm.expectRevert();
        modifyRouter.modifyLiquidity(ethUsdcKey, params, "");
    }

    // ─────────── Permissionless sweep ───────────

    function test_fork_sweep_isPermissionlessAndSendsToResidualRecipient() public requireFork {
        deal(USDC, address(hook), 1234e6);
        vm.deal(address(hook), 0.5 ether);

        uint256 residualRecipientUsdcBefore = IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT);
        uint256 residualRecipientEthBefore = RESIDUAL_RECIPIENT.balance;

        address randomCaller = address(0xDEADBEEF);
        vm.prank(randomCaller);
        hook.sweep(USDC);

        vm.prank(randomCaller);
        hook.sweep(address(0));

        assertEq(
            IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT) - residualRecipientUsdcBefore,
            1234e6,
            "RESIDUAL_RECIPIENT receives swept USDC"
        );
        assertEq(
            RESIDUAL_RECIPIENT.balance - residualRecipientEthBefore, 0.5 ether, "RESIDUAL_RECIPIENT receives swept ETH"
        );
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "Hook USDC drained");
        assertEq(address(hook).balance, 0, "Hook ETH drained");
    }

    function test_fork_sweep_zeroBalanceNoOps() public requireFork {
        vm.prank(address(0xBEEF));
        hook.sweep(USDC);
        vm.prank(address(0xBEEF));
        hook.sweep(address(0));
    }

    // ─────────── Immutable invariants (compile-time guarantees) ───────────

    function test_fork_baseHasNoRoleSetters() public requireFork {
        (bool initializerSet,) = address(hook).call(abi.encodeWithSignature("setPoolInitializer(address)", USER));
        (bool recipientSet,) = address(hook).call(abi.encodeWithSignature("setResidualRecipient(address)", USER));
        assertFalse(initializerSet, "base exposes no poolInitializer setter");
        assertFalse(recipientSet, "base exposes no residualRecipient setter");
        assertEq(hook.poolInitializer(), address(this));
        assertEq(hook.residualRecipient(), RESIDUAL_RECIPIENT);
    }

    function test_fork_canonicalPoolParametersAreConstant() public requireFork {
        assertEq(uint256(hook.CANONICAL_POOL_FEE()), CANONICAL_POOL_FEE);
        assertEq(int256(hook.CANONICAL_TICK_SPACING()), int256(CANONICAL_TICK_SPACING));
    }

    // ════════════════════════════════════════════════════════════════════════
    // ADVERSARIAL / RED-TEAM
    // ════════════════════════════════════════════════════════════════════════

    // ─── A. Direct-call attacks (verify onlyPoolManager) ───
    // Defends against Cork Protocol $11M (2025-05): beforeSwap without onlyPoolManager.

    function test_attack_directBeforeSwap_revertsNotPoolManager() public requireFork {
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), ethUsdcKey, p, "");
    }

    function test_attack_directBeforeInitialize_revertsNotPoolManager() public requireFork {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(this), ethUsdcKey, INIT_PRICE);
    }

    function test_attack_exactInputAmount_rejectsUnrepresentableDeltas() public requireFork {
        HookNoAddressCheck harness = new HookNoAddressCheck(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            new SubsidyVault(IPoolManager(V4_PM), address(this))
        );

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        harness.exposedExactInputAmount(type(int256).min);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        harness.exposedExactInputAmount(int256(type(int128).min));
    }

    // ─── B. ETH abuse (verify sweep recovers + no fund loss) ───

    function test_attack_unsolicitedETH_isRejected() public requireFork {
        address attacker = address(0xBAD);
        vm.deal(attacker, 5 ether);

        vm.prank(attacker);
        (bool ok,) = payable(address(hook)).call{value: 5 ether}("");
        assertFalse(ok);
        assertEq(address(hook).balance, 0);
        assertEq(attacker.balance, 5 ether);
    }

    function test_attack_selfdestructForcedETH_isSweepable() public requireFork {
        vm.deal(address(this), 3 ether);
        new SelfDestructAttacker{value: 3 ether}(payable(address(hook)));

        assertEq(address(hook).balance, 3 ether);

        uint256 residualBefore = RESIDUAL_RECIPIENT.balance;
        hook.sweep(address(0));
        assertEq(address(hook).balance, 0);
        assertEq(RESIDUAL_RECIPIENT.balance, residualBefore + 3 ether);
    }

    // ─── C. Mocked-external-return attacks ───

    function test_attack_wrapReturnsLess_revertsWrapMismatch() public requireFork {
        vm.mockCall(FW_ETH, abi.encodeWithSelector(IFewWrappedToken.wrapTo.selector), abi.encode(uint256(0)));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_wrapReturnsMore_revertsWrapMismatch() public requireFork {
        vm.mockCall(FW_ETH, abi.encodeWithSelector(IFewWrappedToken.wrapTo.selector), abi.encode(type(uint256).max));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_unwrapReturnsLess_revertsUnwrapMismatch() public requireFork {
        vm.mockCall(FW_USDC, abi.encodeWithSelector(IFewWrappedToken.unwrapTo.selector), abi.encode(uint256(0)));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_wrapReturnsCorrectAmountWithoutMovingBalances_reverts() public requireFork {
        uint256 amountIn = 0.5 ether;
        vm.mockCall(
            FW_ETH, abi.encodeWithSelector(IFewWrappedToken.wrapTo.selector, amountIn, FEWV2_PAIR), abi.encode(amountIn)
        );

        vm.deal(USER, amountIn);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, PoolSwapTest.TestSettings(false, false), "");

        vm.clearMockedCalls();
    }

    function test_attack_feeOnTransferStyleInputBackingShortfall_revertsAtomically() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 backingBefore = IERC20(WETH).balanceOf(FW_ETH);
        bytes[] memory mockedBacking = new bytes[](2);
        mockedBacking[0] = abi.encode(backingBefore);
        mockedBacking[1] = abi.encode(backingBefore + amountIn - 1);
        vm.mockCalls(WETH, abi.encodeWithSelector(IERC20.balanceOf.selector, FW_ETH), mockedBacking);

        vm.deal(USER, amountIn);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, PoolSwapTest.TestSettings(false, false), "");

        vm.clearMockedCalls();
        assertEq(IERC20(WETH).allowance(address(hook), FW_ETH), 0, "failed wrap leaves no approval");
        assertEq(IERC20(FW_ETH).balanceOf(address(hook)), 0, "failed wrap leaves no FewToken");
        assertEq(address(hook).balance, 0, "failed wrap leaves no native token");
    }

    function test_attack_unwrapReturnsCorrectAmountWithoutMovingBalances_reverts() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 amountOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);
        vm.mockCall(
            FW_USDC, abi.encodeWithSelector(IFewWrappedToken.unwrapTo.selector, amountOut, V4_PM), abi.encode(amountOut)
        );

        vm.deal(USER, amountIn);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, PoolSwapTest.TestSettings(false, false), "");

        vm.clearMockedCalls();
    }

    function test_attack_feeOnTransferStyleOutputShortfall_revertsAtomically() public requireFork {
        uint256 amountIn = 0.01 ether;
        uint256 amountOut = _bestDefaultExactInput(FW_ETH, FW_USDC, amountIn);
        uint256 poolManagerBefore = IERC20(USDC).balanceOf(V4_PM);
        bytes[] memory mockedSettlementBalances = new bytes[](4);
        mockedSettlementBalances[0] = abi.encode(poolManagerBefore);
        mockedSettlementBalances[1] = abi.encode(poolManagerBefore);
        mockedSettlementBalances[2] = abi.encode(poolManagerBefore + amountOut - 1);
        mockedSettlementBalances[3] = abi.encode(poolManagerBefore + amountOut - 1);
        vm.mockCalls(USDC, abi.encodeWithSelector(IERC20.balanceOf.selector, V4_PM), mockedSettlementBalances);

        vm.deal(USER, amountIn);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(ethUsdcKey, params, PoolSwapTest.TestSettings(false, false), "");

        vm.clearMockedCalls();
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "failed unwrap leaves no FewToken");
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "failed settlement leaves no origin token");
        assertEq(address(hook).balance, 0, "failed swap leaves no native token");
    }

    // ─── D. Pair sanity attacks (DegeneratePair / TokenMismatch) ───

    function test_attack_pairZeroReserves_swapReverts() public requireFork {
        vm.mockCall(
            FEWV2_PAIR,
            abi.encodeWithSelector(ISwapV2Pair.getReserves.selector),
            abi.encode(uint112(0), uint112(0), uint32(block.timestamp))
        );

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_pairOneSideZero_revertsDegeneratePair() public requireFork {
        vm.mockCall(
            FEWV2_PAIR,
            abi.encodeWithSelector(ISwapV2Pair.getReserves.selector),
            abi.encode(uint112(0), uint112(1e18), uint32(block.timestamp))
        );

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    function test_attack_pairLiesAboutToken0_revertsTokenMismatch() public requireFork {
        vm.mockCall(FEWV2_PAIR, abi.encodeWithSelector(ISwapV2Pair.token0.selector), abi.encode(address(0xDEAD)));

        vm.deal(USER, 1 ether);
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.5 ether}(ethUsdcKey, p, s, "");

        vm.clearMockedCalls();
    }

    // ─── E. Reentrancy ───

    function test_attack_sweepReentrancy_blockedByNonReentrant() public requireFork {
        ReentrantSweepReceiver template = new ReentrantSweepReceiver(address(hook));
        vm.etch(RESIDUAL_RECIPIENT, address(template).code);

        vm.deal(address(hook), 1 ether);

        vm.expectRevert();
        hook.sweep(address(0));

        assertEq(address(hook).balance, 1 ether, "ETH safe in hook, no partial drain");
    }

    // ─── F. Constructor zero-address checks ───

    function _deployRaw(
        address fewFactory_,
        address fewV2Factory_,
        address weth_,
        address v4Quoter_,
        address residualRecipient_
    ) internal {
        _deployRawWithInitializer(fewFactory_, fewV2Factory_, weth_, v4Quoter_, address(this), residualRecipient_);
    }

    function _deployRawWithInitializer(
        address fewFactory_,
        address fewV2Factory_,
        address weth_,
        address v4Quoter_,
        address poolInitializer_,
        address residualRecipient_
    ) internal {
        new HookNoAddressCheck(
            IPoolManager(V4_PM),
            IFewFactory(fewFactory_),
            ISwapV2Factory(fewV2Factory_),
            IWETH9(weth_),
            ICanonicalV4Quoter(v4Quoter_),
            true,
            poolInitializer_,
            residualRecipient_,
            harnessVault
        );
    }

    function test_attack_constructor_zeroFewFactory_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        _deployRaw(address(0), RING_FACTORY, WETH, V4_QUOTER, RESIDUAL_RECIPIENT);
    }

    function test_attack_constructor_zeroFewV2Factory_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, address(0), WETH, V4_QUOTER, RESIDUAL_RECIPIENT);
    }

    function test_attack_constructor_zeroWeth_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, RING_FACTORY, address(0), V4_QUOTER, RESIDUAL_RECIPIENT);
    }

    function test_attack_constructor_zeroResidualRecipient_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, RING_FACTORY, WETH, V4_QUOTER, address(0));
    }

    function test_attack_constructor_zeroV4Quoter_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        _deployRaw(FEW_FACTORY, RING_FACTORY, WETH, address(0), RESIDUAL_RECIPIENT);
    }

    function test_attack_constructor_zeroPoolInitializer_reverts() public requireFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        _deployRawWithInitializer(FEW_FACTORY, RING_FACTORY, WETH, V4_QUOTER, address(0), RESIDUAL_RECIPIENT);
    }

    function test_attack_constructor_quoterForWrongPoolManager_reverts() public requireFork {
        address wrongPoolManager = address(0xBAD);
        vm.mockCall(V4_QUOTER, abi.encodeWithSignature("poolManager()"), abi.encode(wrongPoolManager));
        vm.expectRevert(
            abi.encodeWithSelector(FewV2ShellHookBase.QuoterPoolManagerMismatch.selector, V4_PM, wrongPoolManager)
        );
        _deployRaw(FEW_FACTORY, RING_FACTORY, WETH, V4_QUOTER, RESIDUAL_RECIPIENT);
        vm.clearMockedCalls();
    }

    function test_attack_previewRejectsWrapperUnderlyingMismatch() public requireFork {
        vm.mockCall(FW_USDC, abi.encodeWithSelector(IFewWrappedToken.token.selector), abi.encode(address(0xBAD)));
        vm.expectRevert(
            abi.encodeWithSelector(FewV2ShellHookBase.WrapperUnderlyingMismatch.selector, FW_USDC, USDC, address(0xBAD))
        );
        hook.previewInitializationPrice(ethUsdcKey);
        vm.clearMockedCalls();
    }

    function test_attack_previewRejectsWrapperWithoutCode() public requireFork {
        vm.etch(FW_USDC, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(FewV2ShellHookBase.DependencyHasNoCode.selector, FW_USDC));
        hook.previewInitializationPrice(ethUsdcKey);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Fee-free direct FewV2 behavior
    // ════════════════════════════════════════════════════════════════════════

    function test_fork_noAdditionalFee_exactInputReceivesFullFewV2Output() public requireFork {
        uint256 ethIn = 0.5 ether;
        vm.deal(USER, ethIn);

        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, ethIn);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");

        uint256 userReceived = IERC20(USDC).balanceOf(USER) - userUsdcBefore;
        assertEq(userReceived, expectedOut, "user receives the full FewV2 output");
        assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "hook retains no output dust");
    }

    function test_fork_noAdditionalFee_exactOutputUsesDirectFewV2Input() public requireFork {
        uint256 usdcTarget = 100e6;
        uint256 expectedInput = _bestDefaultExactOutput(FW_ETH, FW_USDC, usdcTarget);
        vm.deal(USER, expectedInput);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: int256(usdcTarget), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        BalanceDelta delta = swapRouter.swap{value: expectedInput}(ethUsdcKey, p, s, "");

        uint256 userReceived = IERC20(USDC).balanceOf(USER) - userUsdcBefore;

        assertEq(userReceived, usdcTarget, "user must receive exact amountOut target");
        assertEq(uint256(uint128(-delta.amount0())), expectedInput, "user pays direct FewV2 input only");
    }

    function test_fork_exactOutput_rawUnitBoundaries_leaveNoHookDust() public requireFork {
        uint256[6] memory targets = [uint256(1), 1998, 1999, 2000, 3998, 3999];
        for (uint256 i; i < targets.length; ++i) {
            uint256 target = targets[i];
            uint256 quotedInput = hook.quote(true, int256(target), ethUsdcKey.toId());
            uint256 userBefore = IERC20(USDC).balanceOf(USER);
            vm.deal(USER, quotedInput);

            SwapParams memory params = SwapParams({
                zeroForOne: true, amountSpecified: int256(target), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            vm.prank(USER);
            swapRouter.swap{value: quotedInput}(ethUsdcKey, params, PoolSwapTest.TestSettings(false, false), "");

            assertEq(IERC20(USDC).balanceOf(USER) - userBefore, target, "exact target");
            assertEq(address(hook).balance, 0, "native dust");
            assertEq(IERC20(FW_USDC).balanceOf(address(hook)), 0, "fewToken dust");
        }
    }

    function test_fork_exactInput_leavesNoFewTokenDust() public requireFork {
        uint256 ethIn = 0.3 ether;
        vm.deal(USER, ethIn);

        uint256 hookFwBefore = IERC20(FW_USDC).balanceOf(address(hook));

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");

        uint256 hookFwDelta = IERC20(FW_USDC).balanceOf(address(hook)) - hookFwBefore;

        assertEq(hookFwDelta, 0, "hook must not retain fwUSDC dust on exact-in");
    }

    /// @notice Official aggregator-hook event is emitted for UniRoute/subgraph compatibility.
    function test_fork_emitsHookSwapEvent_exactInput() public requireFork {
        uint256 ethIn = 0.1 ether;
        uint256 expectedOut = _bestDefaultExactInput(FW_ETH, FW_USDC, ethIn);
        vm.deal(USER, ethIn);

        vm.expectEmit(true, true, false, true, address(hook));
        emit IAggregatorHook.HookSwap(ethUsdcKey.toId(), address(swapRouter), int256(ethIn), -int256(expectedOut), 0);

        SwapParams memory p = SwapParams({
            zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings(false, false);

        vm.prank(USER);
        swapRouter.swap{value: ethIn}(ethUsdcKey, p, s, "");
    }
}
