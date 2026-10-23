// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {IAggregatorHook} from "../../src/interfaces/IAggregatorHook.sol";
import {ISubsidyVault} from "../../src/interfaces/ISubsidyVault.sol";
import {ISwapV2Pair} from "../../src/interfaces/external/IFewV2.sol";
import {ProtocolFeesForkTest} from "./ProtocolFeesFork.t.sol";

/// @dev A Shell Hook deployment whose only purpose is to prove the zero-vault constructor check.
///      The vault is a parameter so that the harness still has a reachable constructor path.
contract ZeroVaultHarness is FewV2ShellHookBase {
    constructor(FewV2ShellHookBase source, ISubsidyVault vault)
        FewV2ShellHookBase(
            source.poolManager(),
            source.fewFactory(),
            source.fewV2Factory(),
            source.weth(),
            source.v4Quoter(),
            true,
            address(this),
            address(this),
            vault
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice Verifies that the shared subsidy budget refunds the Uniswap protocol fee to the trader.
/// @dev The invariant under test is that a fully funded vault makes a Shell swap economically
///      identical to the same swap on a pool with the protocol fee switched off. That is stronger
///      than "the trader receives some refund": it pins the refund to exactly the protocol fee.
contract SubsidyForkTest is ProtocolFeesForkTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SubsidyVault internal vault;
    uint256 internal constant USDC_BUDGET = 50_000e6;
    uint256 internal constant ETH_BUDGET = 5 ether;

    bytes32 internal constant SWAP_AGGREGATED_TOPIC =
        keccak256("SwapAggregated(bytes32,address,bool,int256,uint256,uint256,uint256)");
    bytes32 internal constant HOOK_SWAP_TOPIC = keccak256("HookSwap(bytes32,address,int256,int256,uint24)");

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

    // ============ Protocol fee state ============

    function test_subsidy_zeroProtocolFeePaysNothingEvenWhenTheVaultIsFunded() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        _fee(ethUsdc, 0, 0);

        uint256 quoted = nativeHook.quote(true, specified, ethUsdc.toId());
        uint256 budgetBefore = vault.balance(USDC);
        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        uint256 jarBefore = IERC20(USDC).balanceOf(jar);

        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, quoted, "the trader receives the whole output");
        assertEq(IERC20(USDC).balanceOf(jar), jarBefore, "no protocol fee is collected");
        assertEq(vault.balance(USDC), budgetBefore, "a funded vault is not touched without a protocol fee");
    }

    function test_subsidy_subsidyFollowsTheProtocolFeeWhenItIsDisabled() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);
        assertGt(expectedFee, 0, "protocol fee must be non-zero for this case");

        _swap(ethUsdc, true, specified, 0.001 ether);
        assertEq(vault.balance(USDC), USDC_BUDGET - expectedFee, "the first swap is subsidized in full");

        // Switching the protocol fee off stops the subsidy without touching the budget.
        _fee(ethUsdc, 0, 0);
        uint256 budgetBefore = vault.balance(USDC);
        uint256 jarBefore = IERC20(USDC).balanceOf(jar);

        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(vault.balance(USDC), budgetBefore, "a disabled protocol fee stops the subsidy");
        assertEq(IERC20(USDC).balanceOf(jar), jarBefore, "no protocol fee is collected anymore");
    }

    function test_subsidy_subsidyStartsWhenTheProtocolFeeIsEnabled() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        _fee(ethUsdc, 0, 0);

        uint256 budgetBefore = vault.balance(USDC);
        _swap(ethUsdc, true, specified, 0.001 ether);
        assertEq(vault.balance(USDC), budgetBefore, "no subsidy without a protocol fee");

        _protocolFeeOn(ethUsdc);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        _swap(ethUsdc, true, specified, 0.001 ether);
        assertEq(vault.balance(USDC), budgetBefore - expectedFee, "the subsidy starts with the protocol fee");
    }

    // ============ Budget state ============

    function test_subsidy_revertsWhenTheVaultAccountingExceedsItsTokenBalance() public onFork {
        _armAndFund();
        _protocolFeeOn(ethUsdc);
        int256 specified = -int256(0.001 ether);

        // Keep the recorded budget but remove the tokens it claims to hold.
        deal(USDC, address(vault), 0);

        uint256 budgetBefore = vault.balance(USDC);
        uint256 userBefore = IERC20(USDC).balanceOf(USER);

        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.001 ether}(
            ethUsdc,
            SwapParams(true, specified, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertEq(vault.balance(USDC), budgetBefore, "a failed settlement rolls the budget back");
        assertEq(IERC20(USDC).balanceOf(USER), userBefore, "the trader keeps their USDC");
    }

    function test_subsidy_repeatedSwapsDrainTheBudgetExactly() public onFork {
        _armAndFund();
        _protocolFeeOn(ethUsdc);
        int256 specified = -int256(0.001 ether);

        uint256 budgetBefore = vault.balance(USDC);
        uint256 totalFee;
        uint256 totalSubsidy;

        for (uint256 i; i < 5; ++i) {
            vm.recordLogs();
            _swap(ethUsdc, true, specified, 0.001 ether);
            (uint256 feeAmount, uint256 subsidyAmount) = _subsidyPaid(vm.getRecordedLogs());
            totalFee += feeAmount;
            totalSubsidy += subsidyAmount;
        }

        assertGt(totalFee, 0, "the protocol fee must be charged");
        assertEq(totalSubsidy, totalFee, "every swap is refunded in full");
        assertEq(vault.balance(USDC), budgetBefore - totalFee, "the budget is drained exactly by the fees");
    }

    function test_subsidy_ownerRotationKeepsTheBudgetOperational() public onFork {
        _armAndFund();
        address newOwner = address(0xC0FFEE);

        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        // The previous owner can no longer move the budget.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.drain(USDC, 1e6, address(this));

        // The new owner can still drain and pause.
        uint256 budgetBefore = vault.balance(USDC);
        vm.prank(newOwner);
        vault.drain(USDC, 1e6, newOwner);
        assertEq(vault.balance(USDC), budgetBefore - 1e6, "the new owner can drain the budget");

        vm.prank(newOwner);
        vault.setPaused(true);
        assertTrue(vault.paused(), "the new owner can pause the subsidy");
    }

    // ============ Swap direction ============

    function test_subsidy_exactInputReverseDirectionRefundsTheProtocolFee() public onFork {
        _armAndFund();
        // zeroForOne = false: the input is USDC and the output is native ETH.
        bool zeroForOne = false;
        int256 specified = -int256(1e6);
        uint256 rawQuote = _rawQuote(zeroForOne, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);

        uint256 expectedFee = _expectedFee(zeroForOne, rawQuote, true);
        assertGt(expectedFee, 0, "protocol fee must be non-zero for this case");

        // The fee follows the swap direction, so it is charged in the output currency: native ETH.
        uint256 ethBudgetBefore = vault.balance(address(0));
        uint256 usdcBudgetBefore = vault.balance(USDC);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 userEthBefore = USER.balance;

        _swap(ethUsdc, zeroForOne, specified, 0);

        assertEq(IERC20(USDC).balanceOf(USER) - userUsdcBefore, 1e6, "the trader pays the quoted input");
        assertEq(USER.balance - userEthBefore, rawQuote, "the trader receives the gross output");
        assertEq(vault.balance(address(0)), ethBudgetBefore - expectedFee, "the ETH budget paid the subsidy");
        assertEq(vault.balance(USDC), usdcBudgetBefore, "the USDC budget is untouched");
    }

    function test_subsidy_exactOutputReverseDirectionRefundsTheProtocolFee() public onFork {
        _armAndFund();
        // zeroForOne = false: the input is USDC and the output is native ETH.
        bool zeroForOne = false;
        int256 specified = int256(0.0001 ether);
        uint256 rawQuote = _rawQuote(zeroForOne, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);

        uint256 expectedFee = _expectedFee(zeroForOne, rawQuote, false);
        assertGt(expectedFee, 0, "protocol fee must be non-zero for this case");

        // Exact output charges the fee on the input currency, so it is charged in USDC here.
        uint256 ethBudgetBefore = vault.balance(address(0));
        uint256 usdcBudgetBefore = vault.balance(USDC);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 userEthBefore = USER.balance;

        _swap(ethUsdc, zeroForOne, specified, 0);

        assertEq(IERC20(USDC).balanceOf(USER) - userUsdcBefore, rawQuote, "the trader pays the zero-fee input");
        assertEq(USER.balance - userEthBefore, 0.0001 ether, "the trader receives the exact output");
        assertEq(vault.balance(USDC), usdcBudgetBefore - expectedFee, "the USDC budget paid the subsidy");
        assertEq(vault.balance(address(0)), ethBudgetBefore, "the ETH budget is untouched");
    }

    // ============ Quote parity ============

    function test_subsidy_quoteAndExecutionAgreeOnTheSubsidizedAmount() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        uint256 quoted = nativeHook.quote(true, specified, ethUsdc.toId());
        assertEq(quoted, rawQuote, "a funded vault quotes the zero-fee output");

        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, quoted, "the execution matches the quote");
        assertEq(vault.balance(USDC), USDC_BUDGET - expectedFee, "the vault paid the whole fee");
    }

    function test_subsidy_quoteReportsThePartialSubsidyWhenTheBudgetIsShort() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        uint256 partialBudget = expectedFee / 2;
        vault.drain(USDC, vault.balance(USDC) - partialBudget, address(this));
        assertEq(vault.balance(USDC), partialBudget, "the budget holds a partial subsidy");

        uint256 quoted = nativeHook.quote(true, specified, ethUsdc.toId());
        assertEq(quoted, rawQuote - expectedFee + partialBudget, "the quote reports the partial subsidy");

        uint256 userBefore = IERC20(USDC).balanceOf(USER);
        _swap(ethUsdc, true, specified, 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(USER) - userBefore, quoted, "the execution matches the partial quote");
        assertEq(vault.balance(USDC), 0, "the budget is spent");
    }

    // ============ Side effects ============

    function test_subsidy_eventsCarryTheSubsidizedAmounts() public onFork {
        _armAndFund();
        int256 specified = -int256(0.001 ether);
        uint256 rawQuote = _rawQuote(true, specified, ethUsdc);
        _protocolFeeOn(ethUsdc);
        uint256 expectedFee = _expectedFee(true, rawQuote, true);

        // A partial budget makes the subsidized amount differ from the gross amount.
        uint256 partialBudget = expectedFee / 2;
        vault.drain(USDC, vault.balance(USDC) - partialBudget, address(this));
        uint256 expectedOut = rawQuote - expectedFee + partialBudget;

        vm.recordLogs();
        _swap(ethUsdc, true, specified, 0.001 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            bool found,
            bool zeroForOne,
            int256 amountSpecified,
            uint256 amountIn,
            uint256 amountOut,
            uint256 fwOutAmount
        ) = _swapAggregated(logs);
        assertTrue(found, "the Shell Hook must emit SwapAggregated");
        assertTrue(zeroForOne, "the aggregated event keeps the swap direction");
        assertEq(amountSpecified, specified, "the aggregated event keeps the amount");
        assertEq(amountIn, 0.001 ether, "the aggregated input is the gross input");
        assertEq(amountOut, expectedOut, "the aggregated output includes the subsidy");
        assertEq(fwOutAmount, rawQuote, "the aggregated gross output is the FewV2 output");

        (bool swapFound, int256 amount0, int256 amount1, uint24 swapFee) = _hookSwap(logs);
        assertTrue(swapFound, "the Shell Hook must emit HookSwap");
        assertEq(amount0, int256(0.001 ether), "amount0 reports the input");
        assertEq(amount1, -int256(expectedOut), "amount1 carries the subsidy");
        assertEq(swapFee, forward * 25, "the reported fee is the Uniswap protocol fee");
    }

    function test_subsidy_subsidyDoesNotMoveTheShellPoolState() public onFork {
        _armAndFund();
        _protocolFeeOn(ethUsdc);
        PoolId poolId = ethUsdc.toId();

        (uint160 sqrtPriceBefore, int24 tickBefore, uint24 feeBefore, uint24 lpFeeBefore) = PM.getSlot0(poolId);
        uint128 liquidityBefore = PM.getLiquidity(poolId);
        (uint256 feeGrowth0Before, uint256 feeGrowth1Before) = PM.getFeeGrowthGlobals(poolId);

        _swap(ethUsdc, true, -int256(0.001 ether), 0.001 ether);

        (uint160 sqrtPriceAfter, int24 tickAfter, uint24 feeAfter, uint24 lpFeeAfter) = PM.getSlot0(poolId);
        assertEq(sqrtPriceAfter, sqrtPriceBefore, "the shell sqrt price must not move");
        assertEq(tickAfter, tickBefore, "the shell tick must not move");
        assertEq(feeAfter, feeBefore, "the shell protocol fee must not move");
        assertEq(lpFeeAfter, lpFeeBefore, "the shell lp fee must not move");
        assertEq(PM.getLiquidity(poolId), liquidityBefore, "the shell liquidity must not move");

        (uint256 feeGrowth0After, uint256 feeGrowth1After) = PM.getFeeGrowthGlobals(poolId);
        assertEq(feeGrowth0After, feeGrowth0Before, "the fee growth of currency0 must not move");
        assertEq(feeGrowth1After, feeGrowth1Before, "the fee growth of currency1 must not move");
    }

    function test_subsidy_subsidyDoesNotChangeTheFewV2ExecutionPrice() public onFork {
        _armAndFund();
        _protocolFeeOn(ethUsdc);
        int256 specified = -int256(0.001 ether);
        (,, address pair) = nativeHook.registeredRouteFor(ethUsdc.toId());

        uint256 snapshot = vm.snapshotState();
        _swap(ethUsdc, true, specified, 0.001 ether);
        (uint112 subsidizedReserve0, uint112 subsidizedReserve1,) = ISwapV2Pair(pair).getReserves();
        uint160 subsidizedPrice = nativeHook.executionSqrtPriceX96(ethUsdc.toId());
        assertTrue(vm.revertToStateAndDelete(snapshot), "state snapshot rollback");

        // The same trade without a subsidy must move the FewV2 pair in exactly the same way.
        vault.drain(USDC, vault.balance(USDC), address(this));
        _swap(ethUsdc, true, specified, 0.001 ether);
        (uint112 plainReserve0, uint112 plainReserve1,) = ISwapV2Pair(pair).getReserves();

        assertEq(plainReserve0, subsidizedReserve0, "the FewV2 reserve0 must not depend on the subsidy");
        assertEq(plainReserve1, subsidizedReserve1, "the FewV2 reserve1 must not depend on the subsidy");
        assertEq(
            nativeHook.executionSqrtPriceX96(ethUsdc.toId()),
            subsidizedPrice,
            "the execution price must not depend on the subsidy"
        );
    }

    function test_subsidy_failedSwapLeavesTheBudgetUntouched() public onFork {
        _armAndFund();
        _protocolFeeOn(ethUsdc);
        int256 specified = -int256(0.001 ether);

        uint160 priceBefore = nativeHook.executionSqrtPriceX96(ethUsdc.toId());
        uint256 budgetBefore = vault.balance(USDC);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 userEthBefore = USER.balance;

        // A limit just below the live price is accepted before the swap and broken after it.
        vm.prank(USER);
        vm.expectPartialRevert(FewV2ShellHookBase.FewV2PriceLimitExceeded.selector);
        swapRouter.swap{value: 0.001 ether}(
            ethUsdc, SwapParams(true, specified, priceBefore - 1), PoolSwapTest.TestSettings(false, false), ""
        );

        assertEq(vault.balance(USDC), budgetBefore, "a failed swap leaves the budget untouched");
        assertEq(IERC20(USDC).balanceOf(USER), userUsdcBefore, "a failed swap leaves the trader untouched");
        assertEq(USER.balance, userEthBefore, "a failed swap returns the ETH");
    }

    // ============ Construction ============

    function test_subsidy_hookRejectsAZeroAddressVault() public onFork {
        vm.expectRevert(FewV2ShellHookBase.ZeroAddress.selector);
        new ZeroVaultHarness(nativeHook, ISubsidyVault(address(0)));
    }

    function test_subsidy_vaultRejectsAZeroAddressPoolManager() public onFork {
        vm.expectRevert(SubsidyVault.ZeroAddress.selector);
        new SubsidyVault(IPoolManager(address(0)), address(this));
    }

    function test_subsidy_vaultRejectsAZeroAddressOwner() public onFork {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SubsidyVault(PM, address(0));
    }

    // ============ Event helpers ============

    /// @dev The fee and the subsidy the vault reported for the last swap.
    function _subsidyPaid(Vm.Log[] memory logs) internal view returns (uint256 feeAmount, uint256 subsidyAmount) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != bytes32(SubsidyVault.SubsidyPaid.selector)) continue;
            (feeAmount, subsidyAmount) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    function _swapAggregated(Vm.Log[] memory logs)
        internal
        view
        returns (
            bool found,
            bool zeroForOne,
            int256 amountSpecified,
            uint256 amountIn,
            uint256 amountOut,
            uint256 fwOutAmount
        )
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nativeHook)) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != SWAP_AGGREGATED_TOPIC) continue;
            (zeroForOne, amountSpecified, amountIn, amountOut, fwOutAmount) =
                abi.decode(logs[i].data, (bool, int256, uint256, uint256, uint256));
            found = true;
        }
    }

    function _hookSwap(Vm.Log[] memory logs)
        internal
        view
        returns (bool found, int256 amount0, int256 amount1, uint24 swapFee)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nativeHook)) continue;
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != HOOK_SWAP_TOPIC) continue;
            (amount0, amount1, swapFee) = abi.decode(logs[i].data, (int256, int256, uint24));
            found = true;
        }
    }
}
