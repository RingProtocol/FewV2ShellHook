// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter as ICanonicalV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";

// ════════════════════════════════════════════════════════════════════════════
// Permissionless Ring / Few plumbing used to admit an untrusted underlying
// ════════════════════════════════════════════════════════════════════════════

interface IPublicFewFactory {
    function createToken(address originalToken) external returns (address);
}

interface IPublicFewV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IFewV2LiquidityPair {
    function mint(address to) external returns (uint256);
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

interface IReenterTarget {
    function reenter() external;
}

// ════════════════════════════════════════════════════════════════════════════
// Malicious underlyings that pass the canonical FewToken checks at registration
// ════════════════════════════════════════════════════════════════════════════

/// @dev Fee-on-transfer: the sender is debited `value`, the recipient credited
///      `value - fee`. `wrapTo`/`unwrapTo` still mint/burn face value, so the gap
///      shows up only as a balance/backing shortfall at the Hook's exact checks.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 _feeBps) ERC20("Fee Origin", "FEEBAD") {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee);
    }
}

/// @dev Reports a phantom balance on top of the real one and silently delivers only
///      the real amount on transfer (never reverts on a shortfall). This is the
///      strongest "lying balance": it corrupts every balanceOf-based read.
contract PhantomBalanceToken is ERC20 {
    mapping(address => uint256) public phantom;

    constructor() ERC20("Phantom Origin", "PBAD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPhantom(address account, uint256 amount) external {
        phantom[account] = amount;
    }

    function realBalanceOf(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + phantom[account];
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            uint256 real = super.balanceOf(from);
            if (value > real) value = real; // deliver less, never revert
        }
        super._update(from, to, value);
    }
}

/// @dev Fires an attacker callback on every transfer once armed. Models an
///      ERC777/ERC1363-style hook that re-enters during the Hook's wrap/unwrap.
contract ReentrantToken is ERC20 {
    IReenterTarget public attacker;
    bool public armed;

    constructor() ERC20("Reentrant Origin", "REBAD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(IReenterTarget target) external {
        attacker = target;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && address(attacker) != address(0)) attacker.reenter();
    }
}

/// @dev Negative rebase: balances shrink out from under holders with no transfer.
///      `rebaseDown` strips real backing from the wrapper and real inventory from
///      PoolManager, modeling the worst case of a rebasing underlying.
contract RebaseToken is ERC20 {
    constructor() ERC20("Rebase Origin", "RBAD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function rebaseDown(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

/// @dev Re-enters `sweep` during the malicious token's transfer callback. The Hook
///      shares one ReentrancyGuard across `_beforeSwap` and `sweep`, so this must revert.
contract SweepReenterAttacker is IReenterTarget {
    FewV2ShellHookBase public immutable hook;

    constructor(address _hook) {
        hook = FewV2ShellHookBase(payable(_hook));
    }

    function reenter() external override {
        hook.sweep(address(0));
    }
}

/// @dev Grabs PoolManager inventory mid-swap without settling it. The leftover
///      negative delta must make the whole unlock revert (CurrencyNotSettled).
contract TakeReenterAttacker is IReenterTarget {
    IPoolManager public immutable manager;
    uint256 public immutable amount;

    constructor(address _manager, uint256 _amount) {
        manager = IPoolManager(_manager);
        amount = _amount;
    }

    function reenter() external override {
        manager.take(Currency.wrap(address(0)), address(this), amount);
    }

    receive() external payable {}
}

/// @dev Defense proposal: an immutable underlying allowlist set at construction.
///      Registration is refused unless both pool underlyings are explicitly trusted,
///      which the canonical FewFactory checks cannot express (createToken is permissionless).
contract StaticAllowlistShellHook is FewV2ShellHookBase {
    error UnderlyingNotAllowlisted(address underlying);

    mapping(address => bool) public allowedUnderlying;

    constructor(
        IPoolManager _pm,
        IFewFactory _fewFactory,
        ISwapV2Factory _fewV2Factory,
        IWETH9 _weth,
        ICanonicalV4Quoter _v4Quoter,
        bool _useNativeCurrencyForWeth,
        address _poolInitializer,
        address _residualRecipient,
        ISubsidyVault _subsidyVault,
        address[] memory _allowed
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
    {
        for (uint256 i = 0; i < _allowed.length; i++) {
            allowedUnderlying[_allowed[i]] = true;
        }
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        address u0 = Currency.unwrap(key.currency0) == address(0) ? address(weth) : Currency.unwrap(key.currency0);
        address u1 = Currency.unwrap(key.currency1) == address(0) ? address(weth) : Currency.unwrap(key.currency1);
        if (!allowedUnderlying[u0]) revert UnderlyingNotAllowlisted(u0);
        if (!allowedUnderlying[u1]) revert UnderlyingNotAllowlisted(u1);
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }
}

/// @notice Mainnet fork suite that reproduces what a malicious underlying can and
///         cannot do once the pool initializer admits it, and demonstrates the
///         immutable-allowlist defense. Skipped when `ETH_RPC_URL` is unset.
contract MaliciousUnderlyingForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address constant V4_PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FW_ETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FW_USDC = 0x0492560FA7Cfd6A85E50D8bE3F77318994F8f429;
    address constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant RING_FACTORY = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;
    address constant FEWV2_PAIR = 0x54222F404dcfAc705322045F01D100380b871450;

    uint24 constant CANONICAL_POOL_FEE = 3000;
    int24 constant CANONICAL_TICK_SPACING = 1;
    address constant RESIDUAL_RECIPIENT = address(0xFEE);
    address constant USER = address(0xBEEF);
    address constant SEEDER = address(0xBAD);

    bool forked;
    FewV2ShellHookBase hook;
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

        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCode = type(FewV2ShellHookBase).creationCode;
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        ISubsidyVault vault = new SubsidyVault(IPoolManager(V4_PM), address(this));
        bytes memory ctorArgs = abi.encode(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, ctorArgs);
        hook = new FewV2ShellHookBase{salt: salt}(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault
        );
        require(address(hook) == mined, "hook address mismatch");

        swapRouter = new PoolSwapTest(IPoolManager(V4_PM));
        modifyRouter = new PoolModifyLiquidityTest(IPoolManager(V4_PM));

        ethUsdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        IPoolManager(V4_PM).initialize(ethUsdcKey, hook.previewInitializationPrice(ethUsdcKey));
    }

    modifier requireFork() {
        if (!forked) vm.skip(true);
        _;
    }

    /// @dev Accept native refunds from the liquidity router (excess ETH on add).
    receive() external payable {}

    // ───────────────────────── helpers ─────────────────────────

    /// @dev Attacker-built canonical wrapper + FewV2 pair for `token`, seeded with
    ///      `badAmount` of the token and `ethAmount` of real fwETH. Mirrors how any
    ///      outsider can make an arbitrary token look canonical to the Hook.
    function _createCanonicalWrapperAndPair(address token, uint256 badAmount, uint256 ethAmount)
        internal
        returns (address wrapper, address pair)
    {
        wrapper = IPublicFewFactory(FEW_FACTORY).createToken(token);
        pair = IPublicFewV2Factory(RING_FACTORY).createPair(wrapper, FW_ETH);

        IMintable(token).mint(SEEDER, badAmount);
        vm.startPrank(SEEDER);
        IERC20(token).approve(wrapper, badAmount);
        IFewWrappedToken(wrapper).wrapTo(badAmount, pair);
        vm.deal(SEEDER, ethAmount);
        IWETH9(WETH).deposit{value: ethAmount}();
        IERC20(WETH).approve(FW_ETH, ethAmount);
        IFewWrappedToken(FW_ETH).wrapTo(ethAmount, pair);
        IFewV2LiquidityPair(pair).mint(SEEDER);
        vm.stopPrank();

        assertEq(IFewFactory(FEW_FACTORY).getWrappedToken(token), wrapper, "wrapper is canonical");
        assertEq(ISwapV2Factory(RING_FACTORY).getPair(wrapper, FW_ETH), pair, "pair is canonical");
    }

    function _shellKey(address hookAddress, address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
    }

    /// @dev Registers an ETH/token shell pool on the main hook (test is poolInitializer).
    function _registerShellPool(address token, uint256 badAmount, uint256 ethAmount)
        internal
        returns (address wrapper, address pair, PoolKey memory key)
    {
        (wrapper, pair) = _createCanonicalWrapperAndPair(token, badAmount, ethAmount);
        key = _shellKey(address(hook), token);
        IPoolManager(V4_PM).initialize(key, hook.previewInitializationPrice(key));
        assertTrue(hook.fewV2PairRegistered(pair), "pool admitted by initializer");
    }

    function _swapEthForToken(PoolKey memory key, uint256 amountIn) internal {
        vm.deal(USER, amountIn);
        vm.prank(USER);
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev Proves the canonical ETH/USDC route is untouched by the adjacent attack.
    function _assertEthUsdcRouteWorks() internal {
        uint256 amountIn = 0.01 ether;
        vm.deal(USER, amountIn);
        uint256 before = IERC20(USDC).balanceOf(USER);
        vm.prank(USER);
        swapRouter.swap{value: amountIn}(
            ethUsdcKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(IERC20(USDC).balanceOf(USER) - before, 0, "canonical ETH/USDC route must stay intact");
    }

    // ───────────────────────── baseline ─────────────────────────

    /// @notice The user's proposal — "only allow FewToken routes/FewTokens" — is already
    ///         enforced, and is insufficient on its own: createToken is permissionless, so
    ///         any underlying can be made canonical and admitted by the pool initializer.
    function test_canonicalFewTokenChecksDoNotVetTokenBehavior() public requireFork {
        RebaseToken bad = new RebaseToken();
        (address wrapper, address pair, PoolKey memory key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);

        assertEq(IFewWrappedToken(wrapper).token(), address(bad), "canonical fwBAD points at BAD");
        (,, address registeredPair) = hook.registeredRouteFor(key.toId());
        assertEq(registeredPair, pair, "arbitrary token admitted purely via canonical checks");

        // The ETH/USDC route is unrelated to this admission.
        (,, address ethUsdcPair) = hook.registeredRouteFor(ethUsdcKey.toId());
        assertEq(ethUsdcPair, FEWV2_PAIR);
    }

    // ───────────────────────── fee-on-transfer ─────────────────────────

    /// @notice A fee-on-transfer underlying registers, but the swap reverts closed: the
    ///         wrapper redeems `amountOut` yet PoolManager receives less, so the Hook's
    ///         exact recipient-balance check fails and nothing leaks.
    function test_feeOnTransfer_registersButSwapRevertsClosed() public requireFork {
        FeeOnTransferToken bad = new FeeOnTransferToken(500); // 5%
        (,, PoolKey memory key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);

        uint256 pmEthBefore = V4_PM.balance;
        uint256 pmUsdcBefore = IERC20(USDC).balanceOf(V4_PM);

        vm.deal(USER, 0.01 ether);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.01 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(0.01 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertEq(V4_PM.balance, pmEthBefore, "PoolManager ETH untouched");
        assertEq(IERC20(USDC).balanceOf(V4_PM), pmUsdcBefore, "PoolManager USDC untouched");
        _assertEthUsdcRouteWorks();
    }

    // ───────────────────────── fake / phantom balances ─────────────────────────

    /// @notice A lying balanceOf inflates the Hook's read-only backing view, but physical
    ///         settlement still moves only real tokens: a swap within real backing delivers
    ///         exactly the real amount and PoolManager is credited exactly that amount.
    function test_phantomBalance_inflatesBackingViewButSettlesExactRealValue() public requireFork {
        PhantomBalanceToken bad = new PhantomBalanceToken();
        (address wrapper, address pair, PoolKey memory key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);

        bad.setPhantom(wrapper, 1e30);
        (, uint256 backingView1) = hook.availableWrapperBacking(key.toId());
        assertGe(backingView1, 1e30, "backing view is corrupted by the phantom balance");
        assertEq(bad.realBalanceOf(wrapper), 1_000 ether, "real backing is only the seeded amount");

        uint256 amountIn = 0.001 ether;
        (, uint256 quotedOut) = _quoteHop(pair, FW_ETH, wrapper, amountIn);
        assertGt(quotedOut, 0, "route quotes a nonzero output");
        assertLt(quotedOut, 1_000 ether, "swap stays within real backing");

        uint256 pmRealBadBefore = bad.realBalanceOf(V4_PM);
        uint256 userRealBefore = bad.realBalanceOf(USER);

        _swapEthForToken(key, amountIn);

        assertEq(bad.realBalanceOf(USER) - userRealBefore, quotedOut, "user receives exactly the real output");
        assertEq(bad.realBalanceOf(V4_PM), pmRealBadBefore, "PoolManager keeps no residual real BAD");
        _assertEthUsdcRouteWorks();
    }

    /// @notice A phantom balance cannot conjure real ETH out: a BAD->ETH swap backed by a
    ///         fake balance reverts at the Hook's own balance-conservation / backing-delta
    ///         checks, and real fwETH backing plus PoolManager ETH are untouched.
    function test_phantomBalance_cannotExtractRealEthWithFakeBalance() public requireFork {
        PhantomBalanceToken bad = new PhantomBalanceToken();
        (address wrapper, PoolKey memory key) = _registerCanonicalThenPhantom(bad);

        uint256 pmEthBefore = V4_PM.balance;
        uint256 fwEthBackingBefore = IERC20(WETH).balanceOf(FW_ETH);
        uint256 realWrapperBad = bad.realBalanceOf(wrapper);

        uint256 amountIn = 50 ether; // "paid" entirely from the phantom balance
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertEq(V4_PM.balance, pmEthBefore, "PoolManager ETH untouched by fake-balance extraction");
        assertEq(IERC20(WETH).balanceOf(FW_ETH), fwEthBackingBefore, "fwETH backing untouched");
        assertEq(bad.realBalanceOf(wrapper), realWrapperBad, "no real BAD moved into the wrapper");
        _assertEthUsdcRouteWorks();
    }

    function _registerCanonicalThenPhantom(PhantomBalanceToken bad)
        internal
        returns (address wrapper, PoolKey memory key)
    {
        address pair;
        (wrapper, pair, key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);
        // Make PoolManager and the Hook appear to hold vast BAD inventory out of thin air.
        bad.setPhantom(V4_PM, 1e30);
        bad.setPhantom(address(hook), 1e30);
        bad.setPhantom(wrapper, 1e30);
    }

    // ───────────────────────── transfer callbacks ─────────────────────────

    /// @notice A transfer callback that re-enters `sweep` during the swap is blocked by the
    ///         shared ReentrancyGuard, so the entire swap reverts and no funds move.
    function test_transferCallback_reentrantSweepIsBlocked() public requireFork {
        ReentrantToken bad = new ReentrantToken();
        (,, PoolKey memory key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);

        SweepReenterAttacker attacker = new SweepReenterAttacker(address(hook));
        bad.arm(attacker);

        uint256 pmEthBefore = V4_PM.balance;
        vm.deal(USER, 0.01 ether);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.01 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(0.01 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertEq(V4_PM.balance, pmEthBefore, "PoolManager ETH untouched");
        _assertEthUsdcRouteWorks();
    }

    /// @notice A transfer callback that grabs PoolManager ETH mid-swap without settling it
    ///         leaves a nonzero delta, so the unlock reverts (CurrencyNotSettled) atomically.
    function test_transferCallback_crossPoolTakeLeavesUnsettledDeltaAndReverts() public requireFork {
        ReentrantToken bad = new ReentrantToken();
        (,, PoolKey memory key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);

        TakeReenterAttacker attacker = new TakeReenterAttacker(V4_PM, 1);
        bad.arm(attacker);

        uint256 pmEthBefore = V4_PM.balance;
        vm.deal(USER, 0.01 ether);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.01 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(0.01 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertEq(V4_PM.balance, pmEthBefore, "mid-swap take cannot keep PoolManager ETH");
        assertEq(address(attacker).balance, 0, "attacker keeps nothing");
        _assertEthUsdcRouteWorks();
    }

    // ───────────────────────── rebase ─────────────────────────

    /// @notice A negative rebase under-backs the wrapper and strips PoolManager inventory:
    ///         swaps revert closed and a naive full shell-LP removal reverts (funds stranded),
    ///         but the damage is confined to the rebased token's own pool.
    function test_negativeRebase_underBacksWrapperAndStrandsLpButIsolated() public requireFork {
        RebaseToken bad = new RebaseToken();
        (address wrapper,, PoolKey memory key) = _registerShellPool(address(bad), 1_000 ether, 1 ether);

        // Fund a shell-LP position with real ETH + real BAD.
        bad.mint(address(this), 1_000_000 ether);
        bad.approve(address(modifyRouter), type(uint256).max);
        vm.deal(address(this), 50 ether);
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(CANONICAL_TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(CANONICAL_TICK_SPACING),
            liquidityDelta: 1e18,
            salt: bytes32(0)
        });
        modifyRouter.modifyLiquidity{value: 50 ether}(key, addParams, "");
        uint256 pooledBad = bad.balanceOf(V4_PM);
        assertGt(pooledBad, 0, "shell LP deposited real BAD into PoolManager");

        uint256 pmUsdcBefore = IERC20(USDC).balanceOf(V4_PM);

        // Negative rebase: strip the wrapper backing and the pooled inventory.
        bad.rebaseDown(wrapper, bad.balanceOf(wrapper));
        bad.rebaseDown(V4_PM, pooledBad);
        assertEq(bad.balanceOf(wrapper), 0, "wrapper now under-backed");

        // Swaps against the rebased token revert closed.
        vm.deal(USER, 0.01 ether);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.01 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(0.01 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        // A naive full removal reverts because PoolManager can no longer return the BAD side.
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(CANONICAL_TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(CANONICAL_TICK_SPACING),
            liquidityDelta: -1e18,
            salt: bytes32(0)
        });
        vm.expectRevert();
        modifyRouter.modifyLiquidity(key, removeParams, "");

        assertEq(IERC20(USDC).balanceOf(V4_PM), pmUsdcBefore, "USDC inventory untouched");
        _assertEthUsdcRouteWorks();
    }

    // ───────────────────────── root cause ─────────────────────────

    /// @notice The Hook is not the vulnerability: once real value is paired against a bad
    ///         token in the FewV2 pair, that value is drainable with a direct pair swap and
    ///         no Hook, no v4 pool, and no pool initializer involved.
    function test_rootCause_valuePairedAgainstBadTokenDrainsWithoutHook() public requireFork {
        PhantomBalanceToken bad = new PhantomBalanceToken();
        (address wrapper, address pair) = _createCanonicalWrapperAndPair(address(bad), 1_000 ether, 5 ether);

        // Attacker mints fwBAD for free by wrapping a phantom balance, then swaps it for the
        // real fwETH someone paired into the pool.
        bad.setPhantom(SEEDER, 1e30);
        uint256 attackerFwEthBefore = IERC20(FW_ETH).balanceOf(SEEDER);
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();
        address pairToken0 = ISwapV2Pair(pair).token0();
        (uint256 reserveBad, uint256 reserveFwEth) =
            pairToken0 == wrapper ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 fwBadIn = 100 ether;
        uint256 fwEthOut = _v2AmountOut(fwBadIn, reserveBad, reserveFwEth);
        assertGt(fwEthOut, 0, "pair quotes a real fwETH payout");

        vm.startPrank(SEEDER);
        IERC20(bad).approve(wrapper, fwBadIn);
        IFewWrappedToken(wrapper).wrapTo(fwBadIn, pair); // mints real fwBAD into the pair, no real BAD delivered
        (uint256 amount0Out, uint256 amount1Out) =
            pairToken0 == wrapper ? (uint256(0), fwEthOut) : (fwEthOut, uint256(0));
        ISwapV2Pair(pair).swap(amount0Out, amount1Out, SEEDER, "");
        vm.stopPrank();

        assertEq(
            IERC20(FW_ETH).balanceOf(SEEDER) - attackerFwEthBefore,
            fwEthOut,
            "pooled fwETH drained directly through FewV2, no Hook involved"
        );
    }

    // ───────────────────────── defense: immutable underlying allowlist ─────────────────────────

    /// @notice An immutable underlying allowlist refuses the bad token at registration while
    ///         still admitting the canonical ETH/USDC pool. This is the gate the permissionless
    ///         FewFactory cannot provide.
    function test_defense_immutableUnderlyingAllowlistBlocksBadButAllowsCanonical() public requireFork {
        address[] memory allowed = new address[](2);
        allowed[0] = WETH;
        allowed[1] = USDC;
        StaticAllowlistShellHook gated = _deployAllowlistedHook(allowed);

        // Canonical ETH/USDC still registers under the allowlist.
        PoolKey memory okKey = _shellKey(address(gated), USDC);
        IPoolManager(V4_PM).initialize(okKey, gated.previewInitializationPrice(okKey));
        assertTrue(gated.fewV2PairRegistered(FEWV2_PAIR), "canonical pool still admitted");

        // The bad token is blocked up front, even though its canonical wrapper/pair exist.
        RebaseToken bad = new RebaseToken();
        (, address badPair) = _createCanonicalWrapperAndPair(address(bad), 1_000 ether, 1 ether);
        PoolKey memory badKey = _shellKey(address(gated), address(bad));
        uint160 badPrice = gated.previewInitializationPrice(badKey);

        vm.expectRevert();
        IPoolManager(V4_PM).initialize(badKey, badPrice);
        assertFalse(gated.fewV2PairRegistered(badPair), "bad token refused at registration");
    }

    function _deployAllowlistedHook(address[] memory allowed) internal returns (StaticAllowlistShellHook gated) {
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCode = type(StaticAllowlistShellHook).creationCode;
        // The vault is deliberately left unarmed, so this suite pays no subsidy.
        ISubsidyVault vault = new SubsidyVault(IPoolManager(V4_PM), address(this));
        bytes memory ctorArgs = abi.encode(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault,
            allowed
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, ctorArgs);
        gated = new StaticAllowlistShellHook{salt: salt}(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault,
            allowed
        );
        require(address(gated) == mined, "gated hook address mismatch");
    }

    // ───────────────────────── local v2 math ─────────────────────────

    function _v2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / ((reserveIn * 1000) + amountInWithFee);
    }

    function _quoteHop(address pair, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bool ok, uint256 amountOut)
    {
        address token0 = ISwapV2Pair(pair).token0();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            tokenIn == token0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) return (false, 0);
        amountOut = _v2AmountOut(amountIn, reserveIn, reserveOut);
        ok = amountOut != 0;
        tokenOut; // silence unused parameter
    }
}
