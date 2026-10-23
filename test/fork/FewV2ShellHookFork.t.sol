// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IV4Quoter as ICanonicalV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {FewV2ShellHook} from "../../src/FewV2ShellHook.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../../src/interfaces/external/IFewWrappedToken.sol";
import {ISwapV2Pair, ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";

interface IPublicFewFactory {
    function createToken(address originalToken) external returns (address);
}

interface IPublicFewV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IFewV2LiquidityPair {
    function mint(address to) external returns (uint256);
}

contract MockUnderlying is ERC20 {
    constructor() ERC20("Mock Underlying", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer token reused to prove runtime fail-closed even after an allowlist mistake.
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

/// @notice Mainnet fork suite for the governance layer added in FewV2ShellHook:
///         immutable underlying allowlist, pause split, 2-step ownership,
///         compromised-owner bounds, and runtime fail-closed defense-in-depth. Skipped without RPC.
contract FewV2ShellHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address constant V4_PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FW_ETH = 0xa250CC729Bb3323e7933022a67B52200fE354767;
    address constant FEW_FACTORY = 0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD;
    address constant RING_FACTORY = 0xeb2A625B704d73e82946D8d026E1F588Eed06416;
    address constant FEWV2_PAIR = 0x54222F404dcfAc705322045F01D100380b871450;

    uint24 constant CANONICAL_POOL_FEE = 3000;
    int24 constant CANONICAL_TICK_SPACING = 1;
    address constant RESIDUAL_RECIPIENT = address(0xFEE);
    address constant USER = address(0xBEEF);
    address constant SEEDER = address(0xBAD);
    address constant GUARDIAN = address(0x6A5D);
    address constant STRANGER = address(0x57A2);

    bool forked;
    FewV2ShellHook hook;
    PoolSwapTest swapRouter;
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

        address[] memory allowed = new address[](2);
        allowed[0] = WETH;
        allowed[1] = USDC;
        hook = _deployHook(allowed);

        swapRouter = new PoolSwapTest(IPoolManager(V4_PM));

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

    receive() external payable {}

    function _deployHook(address[] memory allowed) internal returns (FewV2ShellHook deployed) {
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory creationCode = type(FewV2ShellHook).creationCode;
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
            address(this),
            GUARDIAN,
            allowed
        );
        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, ctorArgs);
        deployed = new FewV2ShellHook{salt: salt}(
            IPoolManager(V4_PM),
            IFewFactory(FEW_FACTORY),
            ISwapV2Factory(RING_FACTORY),
            IWETH9(WETH),
            ICanonicalV4Quoter(V4_QUOTER),
            true,
            address(this),
            RESIDUAL_RECIPIENT,
            vault,
            address(this),
            GUARDIAN,
            allowed
        );
        require(address(deployed) == mined, "hook address mismatch");
    }

    function _allowlistWith(address extra) internal pure returns (address[] memory allowed) {
        allowed = new address[](3);
        allowed[0] = WETH;
        allowed[1] = USDC;
        allowed[2] = extra;
    }

    function _createCanonicalWrapperAndPair(address token, uint256 badAmount, uint256 ethAmount)
        internal
        returns (address wrapper, address pair)
    {
        wrapper = IPublicFewFactory(FEW_FACTORY).createToken(token);
        pair = IPublicFewV2Factory(RING_FACTORY).createPair(wrapper, FW_ETH);

        // Both mocks expose mint(address,uint256); call generically so either can be seeded.
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", SEEDER, badAmount));
        require(ok, "mint failed");

        vm.startPrank(SEEDER);
        IERC20(token).approve(wrapper, badAmount);
        IFewWrappedToken(wrapper).wrapTo(badAmount, pair);
        vm.deal(SEEDER, ethAmount);
        IWETH9(WETH).deposit{value: ethAmount}();
        IERC20(WETH).approve(FW_ETH, ethAmount);
        IFewWrappedToken(FW_ETH).wrapTo(ethAmount, pair);
        IFewV2LiquidityPair(pair).mint(SEEDER);
        vm.stopPrank();
    }

    function _shellKey(address token) internal view returns (PoolKey memory) {
        return _shellKeyFor(hook, token);
    }

    function _shellKeyFor(FewV2ShellHook target, address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: CANONICAL_POOL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: IHooks(address(target))
        });
    }

    function _swapEthForUsdc() internal returns (uint256 received) {
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
        received = IERC20(USDC).balanceOf(USER) - before;
    }

    // ───────────────────────── genesis + registration gate ─────────────────────────

    function test_genesis_allowlistedUnderlyingsRegister_andAreSeeded() public requireFork {
        assertTrue(hook.allowedUnderlying(WETH), "WETH allowlisted at genesis");
        assertTrue(hook.allowedUnderlying(USDC), "USDC allowlisted at genesis");
        assertFalse(hook.allowedUnderlying(address(0xDEAD)), "token outside the genesis set is not allowlisted");
        assertEq(hook.owner(), address(this), "owner set");
        assertEq(hook.guardian(), GUARDIAN, "guardian set");
        assertTrue(hook.fewV2PairRegistered(FEWV2_PAIR), "canonical ETH/USDC admitted");
    }

    function test_registration_revertsForNonAllowlistedUnderlying() public requireFork {
        MockUnderlying token = new MockUnderlying();
        _createCanonicalWrapperAndPair(address(token), 1_000 ether, 1 ether);
        PoolKey memory key = _shellKey(address(token));
        uint160 price = hook.previewInitializationPrice(key);

        assertFalse(hook.allowedUnderlying(address(token)), "token not allowlisted");
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FewV2ShellHook.UnderlyingNotAllowlisted.selector, address(token)),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        IPoolManager(V4_PM).initialize(key, price);
    }

    // ───────────────────────── immutable allowlist ─────────────────────────

    /// @notice The allowlist is the complete token set of this deployment. The removed governance
    ///         selectors must not exist on the contract at all, so neither the owner nor the
    ///         guardian can widen or narrow it.
    function test_allowlist_noGovernanceSelectorsExist() public requireFork {
        address token = address(0xA11CE);

        (bool ok,) = address(hook).call(abi.encodeWithSignature("proposeUnderlying(address)", token));
        assertFalse(ok, "proposeUnderlying must not exist");
        (ok,) = address(hook).call(abi.encodeWithSignature("commitUnderlying(address)", token));
        assertFalse(ok, "commitUnderlying must not exist");
        (ok,) = address(hook).call(abi.encodeWithSignature("removeUnderlying(address)", token));
        assertFalse(ok, "removeUnderlying must not exist");

        assertFalse(hook.allowedUnderlying(token), "token stays outside the allowlist");
        assertTrue(hook.allowedUnderlying(USDC), "USDC stays inside the allowlist");
    }

    /// @notice An allowlisted underlying still registers normally: the gate rejects outsiders, it
    ///         does not block the genesis set.
    function test_allowlist_allowlistedUnderlyingRegistersNormally() public requireFork {
        MockUnderlying token = new MockUnderlying();
        _createCanonicalWrapperAndPair(address(token), 1_000 ether, 1 ether);

        FewV2ShellHook wide = _deployHook(_allowlistWith(address(token)));
        assertTrue(wide.allowedUnderlying(address(token)), "token allowlisted at genesis");

        PoolKey memory key = _shellKeyFor(wide, address(token));
        IPoolManager(V4_PM).initialize(key, wide.previewInitializationPrice(key));
        (,, address registeredPair) = wide.registeredRouteFor(key.toId());
        assertTrue(registeredPair != address(0), "allowlisted pool registered");
    }

    /// @notice A live pool keeps swapping and its endpoint stays allowlisted: there is no way to
    ///         strand a registered pool by removing an entry.
    function test_allowlist_entryCannotBeRemovedAndLivePoolKeepsSwapping() public requireFork {
        assertGt(_swapEthForUsdc(), 0, "swap works");

        (bool ok,) = address(hook).call(abi.encodeWithSignature("removeUnderlying(address)", USDC));
        assertFalse(ok, "removeUnderlying must not exist");
        assertTrue(hook.allowedUnderlying(USDC), "USDC still allowlisted");
        assertGt(_swapEthForUsdc(), 0, "already-registered pool keeps swapping");
    }

    // ───────────────────────── pause (guardian pauses, owner unpauses) ─────────────────────────

    function test_pause_guardianCanPauseSwaps_ownerUnpauses() public requireFork {
        vm.prank(GUARDIAN);
        hook.pause();
        assertTrue(hook.paused(), "paused by guardian");

        uint256 amountIn = 0.01 ether;
        vm.deal(USER, amountIn);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(
            ethUsdcKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        hook.unpause();
        assertFalse(hook.paused(), "unpaused by owner");
        assertGt(_swapEthForUsdc(), 0, "swaps resume after unpause");
    }

    function test_pause_strangerCannotPause() public requireFork {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(FewV2ShellHook.NotGuardianOrOwner.selector, STRANGER));
        hook.pause();
    }

    function test_pause_guardianCannotUnpause() public requireFork {
        vm.prank(GUARDIAN);
        hook.pause();
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        hook.unpause();
    }

    // ───────────────────────── access control / compromised-owner bounds ─────────────────────────

    function test_access_ownerOnlyPowers() public requireFork {
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setGuardian(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setPoolInitializer(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setResidualRecipient(STRANGER);
        // pause() is the only guardian-or-owner action left.
        vm.expectRevert(abi.encodeWithSelector(FewV2ShellHook.NotGuardianOrOwner.selector, STRANGER));
        hook.pause();
        vm.stopPrank();
    }

    function test_guardian_canOnlyPause() public requireFork {
        // Guardian can pause.
        vm.prank(GUARDIAN);
        hook.pause();
        assertTrue(hook.paused(), "guardian paused");

        // Guardian cannot unpause.
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        hook.unpause();

        // Guardian cannot rotate the roles either.
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        hook.setGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        hook.setPoolInitializer(GUARDIAN);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        hook.setResidualRecipient(GUARDIAN);

        // The allowlist is out of every role's reach.
        assertTrue(hook.allowedUnderlying(USDC), "USDC allowlisted");

        // The owner can always lift the guardian's pause.
        hook.unpause();
        assertFalse(hook.paused(), "owner can still unpause");
    }

    function test_ownership_twoStepTransfer() public requireFork {
        hook.transferOwnership(STRANGER);
        assertEq(hook.owner(), address(this), "owner unchanged until accept");
        assertEq(hook.pendingOwner(), STRANGER, "pending owner set");

        // Pending owner cannot yet exercise owner powers.
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setResidualRecipient(STRANGER);

        vm.prank(STRANGER);
        hook.acceptOwnership();
        assertEq(hook.owner(), STRANGER, "ownership transferred");

        // Old owner can no longer exercise owner-only powers.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setResidualRecipient(address(this));
    }

    function test_ownership_cannotBeRenounced() public requireFork {
        vm.expectRevert(FewV2ShellHook.RenounceDisabled.selector);
        hook.renounceOwnership();

        vm.prank(STRANGER);
        vm.expectRevert(FewV2ShellHook.RenounceDisabled.selector);
        hook.renounceOwnership();

        // Even while paused, the owner stays in place and can lift the guardian's pause.
        vm.prank(GUARDIAN);
        hook.pause();
        vm.expectRevert(FewV2ShellHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(this), "owner persists");
        hook.unpause();
        assertFalse(hook.paused(), "owner can still unpause");
    }

    function test_setGuardian_updatesPauseAuthority() public requireFork {
        hook.setGuardian(STRANGER);
        assertEq(hook.guardian(), STRANGER, "guardian updated");

        // Old guardian loses pause power.
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(FewV2ShellHook.NotGuardianOrOwner.selector, GUARDIAN));
        hook.pause();

        vm.prank(STRANGER);
        hook.pause();
        assertTrue(hook.paused(), "new guardian can pause");
    }

    function test_setPoolInitializer_movesRegistrationAuthority() public requireFork {
        MockUnderlying token = new MockUnderlying();
        _createCanonicalWrapperAndPair(address(token), 1_000 ether, 1 ether);

        // A dedicated deployment whose genesis allowlist covers the mock token.
        FewV2ShellHook wide = _deployHook(_allowlistWith(address(token)));
        address newInitializer = address(0x1A17);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        wide.setPoolInitializer(GUARDIAN);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        wide.setPoolInitializer(STRANGER);
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        wide.setPoolInitializer(address(0));

        vm.expectEmit(true, true, true, true, address(wide));
        emit FewV2ShellHook.PoolInitializerUpdated(address(this), newInitializer);
        wide.setPoolInitializer(newInitializer);
        assertEq(wide.poolInitializer(), newInitializer, "initializer replaced");

        PoolKey memory key = _shellKeyFor(wide, address(token));
        uint160 price = wide.previewInitializationPrice(key);

        // The previous initializer is still the owner, but can no longer register pools.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(wide),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FewV2ShellHookBase.UnauthorizedPoolInitializer.selector, address(this)),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        IPoolManager(V4_PM).initialize(key, price);

        vm.prank(newInitializer);
        IPoolManager(V4_PM).initialize(key, price);
        (,, address registeredPair) = wide.registeredRouteFor(key.toId());
        assertTrue(registeredPair != address(0), "new initializer registered the pool");
        assertGt(_swapEthForUsdc(), 0, "existing route unaffected");
    }

    function test_setResidualRecipient_redirectsSweep() public requireFork {
        address newRecipient = address(0x5EE9);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        hook.setResidualRecipient(GUARDIAN);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setResidualRecipient(STRANGER);
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        hook.setResidualRecipient(address(0));

        vm.expectEmit(true, true, true, true, address(hook));
        emit FewV2ShellHook.ResidualRecipientUpdated(RESIDUAL_RECIPIENT, newRecipient);
        hook.setResidualRecipient(newRecipient);
        assertEq(hook.residualRecipient(), newRecipient, "recipient replaced");

        vm.deal(address(hook), 1 ether);
        deal(USDC, address(hook), 5e6);
        uint256 oldEth = RESIDUAL_RECIPIENT.balance;
        uint256 oldUsdc = IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT);
        uint256 newEth = newRecipient.balance;
        uint256 newUsdc = IERC20(USDC).balanceOf(newRecipient);

        vm.startPrank(STRANGER);
        hook.sweep(address(0));
        hook.sweep(USDC);
        vm.stopPrank();

        assertEq(newRecipient.balance - newEth, 1 ether, "ETH swept to the new recipient");
        assertEq(IERC20(USDC).balanceOf(newRecipient) - newUsdc, 5e6, "USDC swept to the new recipient");
        assertEq(RESIDUAL_RECIPIENT.balance, oldEth, "old recipient received no ETH");
        assertEq(IERC20(USDC).balanceOf(RESIDUAL_RECIPIENT), oldUsdc, "old recipient received no USDC");
    }

    // ───────────────────────── defense-in-depth ─────────────────────────

    /// @notice Even if governance mistakenly allowlists a malicious underlying, the base Hook's runtime
    ///         checks still fail closed: the allowlist is a filter, not the only line of defense.
    function test_defenseInDepth_allowlistedFeeOnTransferStillRevertsClosed() public requireFork {
        FeeOnTransferToken bad = new FeeOnTransferToken(500); // 5%
        _createCanonicalWrapperAndPair(address(bad), 1_000 ether, 1 ether);

        // A dedicated deployment whose genesis allowlist covers the bad token.
        FewV2ShellHook wide = _deployHook(_allowlistWith(address(bad)));

        PoolKey memory key = _shellKeyFor(wide, address(bad));
        IPoolManager(V4_PM).initialize(key, wide.previewInitializationPrice(key));

        uint256 pmEthBefore = V4_PM.balance;
        uint256 amountIn = 0.01 ether;
        vm.deal(USER, amountIn);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(V4_PM.balance, pmEthBefore, "PoolManager ETH untouched by allowlisted-but-bad token");
        assertGt(_swapEthForUsdc(), 0, "canonical ETH/USDC route intact");
    }
}
