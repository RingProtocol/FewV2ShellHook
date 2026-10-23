// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ProtocolFeesForkTest} from "./ProtocolFeesFork.t.sol";

/// @notice Verifies that the shared subsidy budget refunds the Uniswap protocol fee to the trader.
/// @dev The invariant under test is that a fully funded vault makes a Shell swap economically
///      identical to the same swap on a pool with the protocol fee switched off. That is stronger
///      than "the trader receives some refund": it pins the refund to exactly the protocol fee.
contract SubsidyForkTest is ProtocolFeesForkTest {
    using PoolIdLibrary for PoolKey;

    SubsidyVault internal vault;
    uint256 internal constant USDC_BUDGET = 50_000e6;
    uint256 internal constant ETH_BUDGET = 5 ether;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        vault = SubsidyVault(address(nativeSubsidyVault));
    }

    /// @dev Arms the shared vault and funds both budgets.
    ///      This is deliberately not done in setUp: the inherited protocol-fee suite asserts
    ///      that the fee is charged exactly once, which only holds while the vault is unarmed.
    function _armAndFund() internal {
        vault.setHook(address(nativeHook));

        deal(USDC, address(this), USDC_BUDGET);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        vault.fund(USDC, USDC_BUDGET);

        vm.deal(address(this), ETH_BUDGET);
        vault.fundNative{value: ETH_BUDGET}();
    }

    // ============ Helpers ============

    /// @dev The quote of a swap on the same pool with the protocol fee switched off.
    function _rawQuote(bool zeroForOne, int256 specified, PoolKey memory key) internal returns (uint256) {
        _fee(key, 0, 0);
        return nativeHook.quote(zeroForOne, specified, key.toId());
    }

    function _protocolFeeOn(PoolKey memory key) internal {
        _fee(key, forward, reverse);
    }

    /// @dev The protocol fee the Hook charges on `amount`, using the production helper's rounding.
    function _expectedFee(bool zeroForOne, uint256 amount, bool exactInput) internal view returns (uint256) {
        uint256 rate = uint256(zeroForOne ? forward : reverse) * 25;
        if (rate == 0) return 0;
        uint256 denominator = exactInput ? 1_000_000 : 1_000_000 - rate;
        return (amount * rate + denominator - 1) / denominator;
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 specified, uint256 value) internal {
        vm.prank(USER);
        swapRouter.swap{value: value}(
            key,
            SwapParams(zeroForOne, specified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    // ============ Tests ============

    function test_subsidy_exactInput_refundsTheWholeProtocolFee() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);

        uint256 expectedFee = _expectedFee(true, rawQuote, true);
        assertGt(expectedFee, 0, "protocol fee must be non-zero for this case");

        // A funded vault must reproduce the zero-fee quote exactly.
        assertEq(nativeHook.quote(true, specified, ethUsdc.toId()), rawQuote, "subsidy restores the zero-fee quote");

        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        uint256 jarBefore = IERC20(USDC).balanceOf(jar);
        uint256 pmBefore = IERC20(USDC).balanceOf(address(PM));
        uint256 vaultBefore = vault.balance(USDC);

        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, rawQuote, "trader receives the zero-fee output");
        assertEq(IERC20(USDC).balanceOf(jar) - jarBefore, expectedFee, "protocol fee is still collected");
        assertEq(vault.balance(USDC), vaultBefore - expectedFee, "vault paid exactly the protocol fee");
        assertEq(IERC20(USDC).balanceOf(address(PM)), pmBefore, "PoolManager output inventory restored");
        assertEq(IERC20(USDC).balanceOf(address(nativeHook)), 0, "no residue in the Hook");
    }

    function test_subsidy_exactOutput_refundsTheWholeProtocolFee() public onFork {
        _armAndFund();
        int256 specified = int256(1e6);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);

        uint256 expectedFee = _expectedFee(true, rawQuote, false);
        assertGt(expectedFee, 0, "protocol fee must be non-zero for this case");

        assertEq(nativeHook.quote(true, specified, ethUsdc.toId()), rawQuote, "subsidy restores the zero-fee quote");

        uint256 userEthBefore = USER.balance;
        uint256 jarEthBefore = jar.balance;
        uint256 pmEthBefore = address(PM).balance;
        uint256 vaultBefore = vault.balance(address(0));

        _swap(ethUsdc, true, specified, rawQuote);

        assertEq(userEthBefore - USER.balance, rawQuote, "trader pays the zero-fee input");
        assertEq(jar.balance - jarEthBefore, expectedFee, "protocol fee is still collected");
        assertEq(vault.balance(address(0)), vaultBefore - expectedFee, "vault paid exactly the protocol fee");
        assertEq(address(PM).balance, pmEthBefore, "PoolManager input inventory restored");
        assertEq(address(nativeHook).balance, 0, "no residue in the Hook");
    }

    function test_subsidy_emptyBudgetFailsOpenAndStillExecutes() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);

        // Drain the budget so the vault can pay nothing.
        vault.drain(USDC, vault.balance(USDC), address(this));
        assertEq(vault.balance(USDC), 0, "budget is empty");

        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);
        assertEq(nativeHook.quote(true, specified, ethUsdc.toId()), rawQuote - expectedFee, "no subsidy is reported");

        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        uint256 jarBefore = IERC20(USDC).balanceOf(jar);

        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, rawQuote - expectedFee, "trader pays the protocol fee");
        assertEq(IERC20(USDC).balanceOf(jar) - jarBefore, expectedFee, "protocol fee is still collected");
        assertEq(IERC20(USDC).balanceOf(address(nativeHook)), 0, "no residue in the Hook");
    }

    function test_subsidy_partialBudgetPaysTheAvailableShareOnly() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        uint256 partialBudget = expectedFee / 2;
        vault.drain(USDC, vault.balance(USDC) - partialBudget, address(this));
        assertEq(vault.balance(USDC), partialBudget, "budget holds a partial subsidy");

        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        uint256 pmBefore = IERC20(USDC).balanceOf(address(PM));

        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(
            IERC20(USDC).balanceOf(USER) - userBefore,
            rawQuote - expectedFee + partialBudget,
            "only the available share is refunded"
        );
        assertEq(IERC20(USDC).balanceOf(address(PM)), pmBefore, "PoolManager output inventory restored");
        assertEq(vault.balance(USDC), 0, "budget is spent");
    }

    function test_subsidy_pausedVaultPaysNothingButKeepsTheRouteAlive() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        vault.setPaused(true);

        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        uint256 vaultBefore = vault.balance(USDC);

        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, rawQuote - expectedFee, "no subsidy while paused");
        assertEq(vault.balance(USDC), vaultBefore, "a paused vault spends nothing");
    }

    function test_subsidy_unarmedVaultPaysNothing() public onFork {
        // The vault was never armed, so the Hook must behave as if no subsidy existed.
        assertEq(SubsidyVault(address(nativeSubsidyVault)).hook(), address(0), "the vault is not armed");

        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        assertEq(nativeHook.quote(true, specified, ethUsdc.toId()), rawQuote - expectedFee, "no subsidy without arming");
    }

    function test_subsidy_quoteDoesNotConsumeTheBudget() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        _protocolFeeOn(ethUsdc);
        uint256 before = vault.balance(USDC);
        nativeHook.quote(true, specified, ethUsdc.toId());
        assertEq(vault.balance(USDC), before, "quoting does not spend the budget");
    }

    function test_subsidy_vaultRefusesCallersOtherThanTheHook() public onFork {
        _armAndFund();
        vm.expectRevert(abi.encodeWithSelector(SubsidyVault.NotHook.selector, address(this)));
        vault.settleSubsidy(ethUsdc.toId(), USDC, 1e6);
    }

    function test_subsidy_hookBindingIsPermanent() public onFork {
        _armAndFund();
        vm.expectRevert(SubsidyVault.HookAlreadySet.selector);
        vault.setHook(address(0xBAD));
    }

    function test_subsidy_vaultRejectsZeroAddressHook() public onFork {
        SubsidyVault fresh = new SubsidyVault(PM, address(this));
        vm.expectRevert(SubsidyVault.ZeroAddress.selector);
        fresh.setHook(address(0));
    }

    function test_subsidy_budgetCannotBeOverdrawn() public onFork {
        vm.expectRevert(
            abi.encodeWithSelector(
                SubsidyVault.InsufficientBudget.selector, USDC, vault.balance(USDC), type(uint256).max
            )
        );
        vault.drain(USDC, type(uint256).max, address(this));
    }
}
