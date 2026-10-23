// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {SubsidyForkTest} from "./SubsidyFork.t.sol";

/// @notice Covers how one shared budget is split across several Shell pools and several Hook
///         deployments.
/// @dev The budget is accounted per currency, not per pool. These cases pin the two consequences
///      of that choice: pools of the same currency compete for one balance, and a balance can
///      never be spent by another currency.
contract SubsidyMultiPoolForkTest is SubsidyForkTest {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WBTC_BUDGET = 1e8;
    uint256 internal constant WETH_BUDGET = 1 ether;

    function test_subsidy_twoPoolsShareOnePerCurrencyBudget() public onFork {
        _armAndFund();

        // Both pools are swapped in the direction that charges the protocol fee in USDC.
        int256 ethIn = -int256(0.001 ether);
        int256 wbtcIn = -int256(10_000);
        uint256 ethRaw = _rawQuote(true, ethIn, ethUsdc);
        uint256 wbtcRaw = _rawQuote(true, wbtcIn, wbtcUsdc);
        _protocolFeeOn(ethUsdc);
        _fee(wbtcUsdc, forward, reverse);

        uint256 ethFee = _expectedFee(true, ethRaw, true);
        uint256 wbtcFee = _expectedFee(true, wbtcRaw, true);
        assertGt(ethFee, 0, "the ETH/USDC pool charges a protocol fee");
        assertGt(wbtcFee, 0, "the WBTC/USDC pool charges a protocol fee");

        uint256 budgetBefore = vault.balance(USDC);

        _swap(ethUsdc, true, ethIn, 0.001 ether);
        _swap(wbtcUsdc, true, wbtcIn, 0);

        assertEq(budgetBefore - vault.balance(USDC), ethFee + wbtcFee, "both pools draw on the same USDC budget");
    }

    function test_subsidy_subsidyNeverCrossesCurrencies() public onFork {
        _armAndFund();
        deal(WBTC, address(this), WBTC_BUDGET);
        IERC20(WBTC).approve(address(vault), type(uint256).max);
        vault.fund(WBTC, WBTC_BUDGET);

        // The ETH/USDC pool charges its fee in USDC, the WBTC/USDC pool in WBTC.
        int256 ethIn = -int256(0.001 ether);
        int256 wbtcIn = -int256(1e6);
        uint256 ethRaw = _rawQuote(true, ethIn, ethUsdc);
        uint256 wbtcRaw = _rawQuote(false, wbtcIn, wbtcUsdc);
        _protocolFeeOn(ethUsdc);
        _fee(wbtcUsdc, forward, reverse);

        uint256 ethFee = _expectedFee(true, ethRaw, true);
        uint256 wbtcFee = _expectedFee(false, wbtcRaw, true);

        uint256 usdcBefore = vault.balance(USDC);
        uint256 ethBudgetBefore = vault.balance(address(0));
        uint256 wbtcBefore = vault.balance(WBTC);

        _swap(ethUsdc, true, ethIn, 0.001 ether);
        _swap(wbtcUsdc, false, wbtcIn, 0);

        assertEq(usdcBefore - vault.balance(USDC), ethFee, "only the ETH/USDC pool spent the USDC budget");
        assertEq(wbtcBefore - vault.balance(WBTC), wbtcFee, "only the WBTC/USDC pool spent the WBTC budget");
        assertEq(vault.balance(address(0)), ethBudgetBefore, "the ETH budget is untouched");
    }

    function test_subsidy_tokenTokenPoolSettlesTheErc20SubsidyPath() public onFork {
        _armAndFund();
        deal(WBTC, address(this), WBTC_BUDGET);
        IERC20(WBTC).approve(address(vault), type(uint256).max);
        vault.fund(WBTC, WBTC_BUDGET);

        // Swapped in reverse the token/token pool charges its fee in WBTC, an ERC20.
        int256 wbtcIn = -int256(1e6);
        uint256 wbtcRaw = _rawQuote(false, wbtcIn, wbtcUsdc);
        _fee(wbtcUsdc, forward, reverse);
        uint256 wbtcFee = _expectedFee(false, wbtcRaw, true);

        uint256 wbtcBefore = vault.balance(WBTC);
        uint256 vaultEthBefore = address(vault).balance;
        uint256 pmWbtcBefore = IERC20(WBTC).balanceOf(address(PM));

        _swap(wbtcUsdc, false, wbtcIn, 0);

        assertEq(wbtcBefore - vault.balance(WBTC), wbtcFee, "the WBTC budget paid the subsidy");
        assertEq(address(vault).balance, vaultEthBefore, "the ERC20 path moves no native ETH");
        assertEq(IERC20(WBTC).balanceOf(address(PM)), pmWbtcBefore, "the PoolManager WBTC inventory is restored");
    }

    function test_subsidy_eachHookDeploymentHasItsOwnVault() public onFork {
        _armAndFund();

        SubsidyVault wethVault = SubsidyVault(address(wethSubsidyVault));
        assertNotEq(address(vault), address(wethVault), "each Hook deployment owns its own vault");
        wethVault.setHook(address(wethHook));
        deal(WETH, address(this), WETH_BUDGET);
        IERC20(WETH).approve(address(wethVault), type(uint256).max);
        wethVault.fund(WETH, WETH_BUDGET);

        _protocolFeeOn(ethUsdc);
        _fee(wethUsdc, forward, reverse);

        uint256 nativeUsdcBefore = vault.balance(USDC);
        uint256 wethBudgetBefore = wethVault.balance(WETH);

        _swap(ethUsdc, true, -int256(0.001 ether), 0.001 ether);

        assertLt(vault.balance(USDC), nativeUsdcBefore, "the native vault paid its own subsidy");
        assertEq(wethVault.balance(WETH), wethBudgetBefore, "the WETH vault is untouched by the native pool");

        // Spending the native budget completely must not disable the other deployment.
        vault.drain(USDC, vault.balance(USDC), address(this));
        assertEq(vault.balance(USDC), 0, "the native budget is spent");

        _swap(wethUsdc, true, -int256(1e6), 0);

        assertLt(wethVault.balance(WETH), wethBudgetBefore, "the WETH vault paid its own subsidy");
        assertEq(vault.balance(USDC), 0, "the spent native vault stays empty");
    }
}
