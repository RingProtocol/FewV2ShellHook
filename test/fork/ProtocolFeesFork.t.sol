// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ISwapV2Pair} from "../../src/interfaces/external/IFewV2.sol";
import {IV4FeeRecipient} from "../../src/interfaces/external/IV4FeeRecipient.sol";
import {FewV2ShellHookBase} from "../../src/FewV2ShellHookBase.sol";
import {SubsidyVault} from "../../src/SubsidyVault.sol";
import {ExecutionMatrixForkTest} from "./ExecutionMatrixFork.t.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

interface IManagerOwner {
    function owner() external view returns (address);
}

contract FeeAdapterMock {
    address public TOKEN_JAR;

    constructor(address recipient) {
        TOKEN_JAR = recipient;
    }

    function setTokenJar(address recipient) external {
        TOKEN_JAR = recipient;
    }
}

/// @dev Exercises the production fee helper directly against a configured real pool.
contract FeeMathHarness is FewV2ShellHookBase {
    constructor(FewV2ShellHookBase source)
        FewV2ShellHookBase(
            source.poolManager(),
            source.fewFactory(),
            source.fewV2Factory(),
            source.weth(),
            source.v4Quoter(),
            true,
            address(this),
            address(this),
            new SubsidyVault(source.poolManager(), address(this))
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function feeAmount(PoolId id, bool z, uint256 amount, bool exactInput) external view returns (uint256, uint24) {
        return _protocolFeeAmount(id, z, amount, exactInput);
    }
}

/// @notice Checks fees in origin currency, complete quote/execution parity and atomic failure.
/// @dev The inherited execution tests also run with zero protocol fees on the new implementation.
contract ProtocolFeesForkTest is ExecutionMatrixForkTest {
    using PoolIdLibrary for PoolKey;

    FeeAdapterMock internal adapter;
    FeeMathHarness internal feeMath;
    address internal originalController;
    address internal jar = address(0xCAFE);
    uint24 internal forward = 40;
    uint24 internal reverse = 12;

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        originalController = PM.protocolFeeController();
        adapter = new FeeAdapterMock(jar);
        _setController(address(adapter));
        // The test router refunds its entire ETH balance; isolate its own initial cash.
        vm.deal(address(swapRouter), 0);
        feeMath = new FeeMathHarness(nativeHook);
    }

    function _setController(address controller) internal {
        vm.prank(IManagerOwner(address(PM)).owner());
        PM.setProtocolFeeController(controller);
    }

    function _fee(PoolKey memory key, uint24 zeroForOne, uint24 oneForZero) internal {
        vm.prank(PM.protocolFeeController());
        PM.setProtocolFee(key, zeroForOne | (oneForZero << 12));
    }

    function _case(FewV2ShellHookBase hook, PoolKey memory key, bool z, int256 specified) internal {
        _fee(key, 0, 0);
        uint256 rawQuote = hook.quote(z, specified, key.toId());
        _fee(key, forward, reverse);
        uint256 rate = uint256(z ? forward : reverse) * 25;
        bool exactInput = specified < 0;
        uint256 fee =
            rate == 0 ? 0 : Math.mulDiv(rawQuote, rate, exactInput ? 1_000_000 : 1_000_000 - rate, Math.Rounding.Ceil);
        uint256 quote = hook.quote(z, specified, key.toId());
        assertEq(quote, exactInput ? rawQuote - fee : rawQuote + fee, "quote includes fee exactly once");
        if (!exactInput) {
            assertEq(quote, Math.mulDiv(rawQuote, 1_000_000, 1_000_000 - rate, Math.Rounding.Ceil));
        }

        Currency input = z ? key.currency0 : key.currency1;
        Currency output = z ? key.currency1 : key.currency0;
        Currency feeCurrency = exactInput ? output : input;
        uint256 inputBefore = _balance(input, USER);
        uint256 outputBefore = _balance(output, USER);
        uint256 jarBefore = _balance(feeCurrency, jar);
        uint256 pmInputBefore = _balance(input, address(PM));
        uint256 pmOutputBefore = _balance(output, address(PM));
        uint256 totalIn = exactInput ? uint256(-specified) : quote;
        uint256 totalOut = exactInput ? quote : uint256(specified);

        vm.prank(USER);
        swapRouter.swap{value: Currency.unwrap(input) == address(0) ? totalIn : 0}(
            key,
            SwapParams(z, specified, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(inputBefore - _balance(input, USER), totalIn, "user pays gross quoted input");
        assertEq(_balance(output, USER) - outputBefore, totalOut, "user receives exact net output");
        assertEq(_balance(feeCurrency, jar) - jarBefore, fee, "canonical jar receives origin-token fee");
        assertEq(_balance(input, address(PM)), pmInputBefore, "PM input inventory restored");
        assertEq(_balance(output, address(PM)), pmOutputBefore, "PM output inventory restored");
        assertEq(_balance(input, address(hook)), 0, "no input residue");
        assertEq(_balance(output, address(hook)), 0, "no output residue");
        (address f0, address f1,) = hook.registeredRouteFor(key.toId());
        assertEq(IERC20(f0).balanceOf(address(hook)), 0);
        assertEq(IERC20(f1).balanceOf(address(hook)), 0);
    }

    function _four(FewV2ShellHookBase hook, PoolKey memory key, uint256 input0, uint256 input1) internal {
        _case(hook, key, true, -int256(input0));
        _case(hook, key, false, -int256(input1));
        _case(hook, key, true, int256(input1));
        _case(hook, key, false, int256(input0));
    }

    function test_fees_classificationAndScaling() public onFork {
        assertEq(nativeHook.protocolFeeFlags(), 1 << 11);
        assertEq(nativeHook.protocolFeeMultiplier(), 25);
    }

    function testFuzz_feeMath_matchesFullPrecisionReference(uint128 seed, uint16 rawRate, bool exactInput)
        public
        onFork
    {
        uint24 raw = uint24(rawRate % 1000) + 1;
        _fee(ethUsdc, raw, raw);
        uint256 amount = uint256(seed) % (uint256(uint128(type(int128).max)) + 1);
        (uint256 actual, uint24 rate) = feeMath.feeAmount(ethUsdc.toId(), true, amount, exactInput);
        assertEq(rate, raw * 25);
        uint256 expected = Math.mulDiv(amount, rate, exactInput ? 1_000_000 : 1_000_000 - rate, Math.Rounding.Ceil);
        assertEq(actual, expected);
    }

    function test_fees_mathRejectsAmountBeyondV4SignedDelta() public onFork {
        _fee(ethUsdc, forward, reverse);
        vm.expectRevert();
        feeMath.feeAmount(ethUsdc.toId(), true, uint256(uint128(type(int128).max)) + 1, false);
    }

    function test_fees_nativeBothDirectionsExactInOut() public onFork {
        _four(nativeHook, ethUsdc, 0.001 ether, 1e6);
    }

    function test_fees_currentMainnetAdapterAndTokenJar() public onFork {
        _setController(originalController);
        jar = IV4FeeRecipient(originalController).TOKEN_JAR();
        assertTrue(jar.code.length > 0, "mainnet TokenJar must be a deployed contract");
        _four(nativeHook, ethUsdc, 0.001 ether, 1e6);
    }

    function test_fees_wethBothDirectionsExactInOut() public onFork {
        _four(wethHook, wethUsdc, 1e6, 0.001 ether);
    }

    function test_fees_tokenTokenBothDirectionsExactInOut() public onFork {
        _four(nativeHook, wbtcUsdc, 10_000, 1e6);
    }

    function test_fees_maximumControllerRatesAndRounding() public onFork {
        forward = 1000;
        reverse = 999;
        _four(nativeHook, ethUsdc, 0.001 ether, 1e6);
        _case(nativeHook, ethUsdc, true, 1); // one raw USDC exact output, rounded-up input fee
    }

    function test_fees_zeroRateDoesNotRequireAdapter() public onFork {
        forward = 0;
        reverse = 0;
        _setController(address(0xBAD));
        _four(nativeHook, ethUsdc, 0.001 ether, 1e6);
    }

    function test_fees_recipientRotationTakesEffectWithoutPolling() public onFork {
        _case(nativeHook, ethUsdc, true, -int256(0.001 ether));
        address previous = jar;
        uint256 previousBalance = IERC20(USDC).balanceOf(previous);
        jar = address(0xCAFF);
        adapter.setTokenJar(jar);
        _case(nativeHook, ethUsdc, true, -int256(0.001 ether));
        assertEq(IERC20(USDC).balanceOf(previous), previousBalance);
        previous = jar;
        previousBalance = IERC20(USDC).balanceOf(previous);
        jar = address(0xCB00);
        _setController(address(new FeeAdapterMock(jar)));
        _case(nativeHook, ethUsdc, true, -int256(0.001 ether));
        assertEq(IERC20(USDC).balanceOf(previous), previousBalance);
    }

    function _assertInvalidRecipientAtomic() internal {
        (,, address pair) = nativeHook.registeredRouteFor(ethUsdc.toId());
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();
        uint256 userEth = USER.balance;
        uint256 userUsdc = IERC20(USDC).balanceOf(USER);
        uint256 jarUsdc = IERC20(USDC).balanceOf(jar);
        vm.prank(USER);
        vm.expectRevert();
        swapRouter.swap{value: 0.001 ether}(
            ethUsdc,
            SwapParams(true, -int256(0.001 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (uint112 after0, uint112 after1,) = ISwapV2Pair(pair).getReserves();
        assertEq(after0, r0);
        assertEq(after1, r1);
        assertEq(USER.balance, userEth);
        assertEq(IERC20(USDC).balanceOf(USER), userUsdc);
        assertEq(IERC20(USDC).balanceOf(jar), jarUsdc);
        vm.expectRevert();
        nativeHook.quote(true, -int256(0.001 ether), ethUsdc.toId());
    }

    function test_fees_missingRecipientFailsClosedAndRollsBackPair() public onFork {
        _fee(ethUsdc, forward, reverse);
        adapter.setTokenJar(address(0));
        _assertInvalidRecipientAtomic();
    }

    function test_fees_missingGetterFailsClosedAndRollsBackPair() public onFork {
        _fee(ethUsdc, forward, reverse);
        _setController(address(0xBAD));
        _assertInvalidRecipientAtomic();
    }

    function test_fees_exactOutputInventoryIncludesFee() public onFork {
        uint256 rawInput = nativeHook.quote(true, int256(1e6), ethUsdc.toId());
        _fee(ethUsdc, forward, reverse);
        vm.deal(address(PM), rawInput);
        vm.expectRevert();
        nativeHook.quote(true, int256(1e6), ethUsdc.toId());
    }

    function test_fees_tinyNetOutputFailsAtomically() public onFork {
        uint256 rawInput = nativeHook.quote(true, int256(1), ethUsdc.toId());
        assertEq(nativeHook.quote(true, -int256(rawInput), ethUsdc.toId()), 1);
        _fee(ethUsdc, forward, reverse);
        vm.expectRevert();
        nativeHook.quote(true, -int256(rawInput), ethUsdc.toId());
    }
}
