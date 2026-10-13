// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ISwapV2Pair} from "../../src/interfaces/external/IFewV2.sol";
import {FewV2Price} from "../../src/lib/FewV2Price.sol";

contract FewV2PriceTest is Test {
    // Wrapper addresses do not preserve their origin-token ordering. Here the wrapper
    // for Shell currency0 deliberately sorts after the wrapper for Shell currency1.
    address internal constant FEW_CURRENCY_0 = address(0x2000);
    address internal constant FEW_CURRENCY_1 = address(0x1000);

    FewV2PriceHarness internal harness;

    function setUp() public {
        harness = new FewV2PriceHarness();
    }

    function test_fromPair_reversesPairReservesIntoShellCurrencyOrder() public {
        MockFewV2Pair pair = new MockFewV2Pair(FEW_CURRENCY_1, FEW_CURRENCY_0, 30_000e6, 10 ether);

        (uint112 reserve0, uint112 reserve1) = harness.orderedReserves(pair, FEW_CURRENCY_0, FEW_CURRENCY_1);
        assertEq(reserve0, 10 ether);
        assertEq(reserve1, 30_000e6);
        assertEq(harness.fromPair(pair, FEW_CURRENCY_0, FEW_CURRENCY_1), harness.fromReserves(10 ether, 30_000e6));
    }

    function test_fromReserves_accountsForEthUsdcDecimalsExactly() public view {
        uint112 ethReserve = 10 ether;
        uint112 usdcReserve = 30_000e6;
        uint256 price = harness.fromReserves(ethReserve, usdcReserve);

        // Prove price is the exact floor of sqrt(usdcReserve / ethReserve) * 2^96.
        uint256 target = uint256(usdcReserve) << 192;
        assertLe(price * price * uint256(ethReserve), target);
        assertGt((price + 1) * (price + 1) * uint256(ethReserve), target);
        assertLt(price, 1 << 96, "raw USDC units are smaller than raw ETH units");
    }

    function test_fromReserves_oneToOneReturnsQ96() public view {
        assertEq(harness.fromReserves(1 ether, 1 ether), uint256(1) << 96);
    }

    function test_fromReserves_largeRatioUsesFullPrecisionPath() public view {
        // 2^110 is a perfect-square ratio whose Q96 square root is exactly 2^151.
        assertEq(harness.fromReserves(1, uint112(1) << 110), uint256(1) << 151);
    }

    function test_fromReserves_maximumHighRatioIsExactFloor() public view {
        _assertExactFloor(1, type(uint112).max);
    }

    function test_fromReserves_maximumLowRatioIsExactFloor() public view {
        _assertExactFloor(type(uint112).max, 1);
    }

    function testFuzz_fromReserves_isExactFloor(uint112 reserveCurrency0, uint112 reserveCurrency1) public view {
        reserveCurrency0 = uint112(bound(reserveCurrency0, 1, type(uint112).max));
        reserveCurrency1 = uint112(bound(reserveCurrency1, 1, type(uint112).max));
        _assertExactFloor(reserveCurrency0, reserveCurrency1);
    }

    function test_validate_acceptsTickMathBoundaries() public view {
        assertEq(harness.validate(TickMath.MIN_SQRT_PRICE), TickMath.MIN_SQRT_PRICE);
        assertEq(harness.validate(TickMath.MAX_SQRT_PRICE - 1), TickMath.MAX_SQRT_PRICE - 1);
    }

    function test_validate_revertsBelowMinimum() public {
        uint256 invalidPrice = uint256(TickMath.MIN_SQRT_PRICE) - 1;
        vm.expectRevert(abi.encodeWithSelector(FewV2Price.SqrtPriceOutOfRange.selector, invalidPrice));
        harness.validate(invalidPrice);
    }

    function test_validate_revertsAtMaximum() public {
        uint256 invalidPrice = TickMath.MAX_SQRT_PRICE;
        vm.expectRevert(abi.encodeWithSelector(FewV2Price.SqrtPriceOutOfRange.selector, invalidPrice));
        harness.validate(invalidPrice);
    }

    function test_fromReserves_revertsOnZeroCurrency0Reserve() public {
        vm.expectRevert(FewV2Price.ZeroReserve.selector);
        harness.fromReserves(0, 1);
    }

    function test_fromReserves_revertsOnZeroCurrency1Reserve() public {
        vm.expectRevert(FewV2Price.ZeroReserve.selector);
        harness.fromReserves(1, 0);
    }

    function test_fromPair_revertsOnUnexpectedPairTokens() public {
        MockFewV2Pair pair = new MockFewV2Pair(address(0x3000), address(0x4000), 1, 1);

        vm.expectRevert(abi.encodeWithSelector(FewV2Price.PairTokenMismatch.selector, address(pair)));
        harness.fromPair(pair, FEW_CURRENCY_0, FEW_CURRENCY_1);
    }

    function _assertExactFloor(uint112 reserveCurrency0, uint112 reserveCurrency1) internal view {
        uint256 price = harness.fromReserves(reserveCurrency0, reserveCurrency1);
        assertTrue(_priceFits(price, reserveCurrency0, reserveCurrency1), "reported price exceeds reserve ratio");
        assertFalse(_priceFits(price + 1, reserveCurrency0, reserveCurrency1), "reported price is not the floor");
    }

    function _priceFits(uint256 candidate, uint112 reserveCurrency0, uint112 reserveCurrency1)
        internal
        pure
        returns (bool)
    {
        (uint256 squareHigh, uint256 squareLow) = _fullMultiply(candidate, candidate);
        (uint256 productHigh, uint256 productLow) = _fullMultiply(squareLow, uint256(reserveCurrency0));
        productHigh += squareHigh * uint256(reserveCurrency0);

        uint256 targetHigh = uint256(reserveCurrency1) >> 64;
        uint256 targetLow = uint256(reserveCurrency1) << 192;
        return productHigh < targetHigh || (productHigh == targetHigh && productLow <= targetLow);
    }

    function _fullMultiply(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }
}

contract FewV2PriceHarness {
    function orderedReserves(ISwapV2Pair pair, address fewCurrency0, address fewCurrency1)
        external
        view
        returns (uint112, uint112)
    {
        return FewV2Price.orderedReserves(pair, fewCurrency0, fewCurrency1);
    }

    function fromPair(ISwapV2Pair pair, address fewCurrency0, address fewCurrency1) external view returns (uint160) {
        return FewV2Price.fromPair(pair, fewCurrency0, fewCurrency1);
    }

    function fromReserves(uint112 reserveCurrency0, uint112 reserveCurrency1) external pure returns (uint160) {
        return FewV2Price.fromReserves(reserveCurrency0, reserveCurrency1);
    }

    function validate(uint256 sqrtPriceX96) external pure returns (uint160) {
        return FewV2Price.validate(sqrtPriceX96);
    }
}

contract MockFewV2Pair is ISwapV2Pair {
    address internal immutable TOKEN_0;
    address internal immutable TOKEN_1;
    uint112 internal immutable RESERVE_0;
    uint112 internal immutable RESERVE_1;

    constructor(address token0_, address token1_, uint112 reserve0_, uint112 reserve1_) {
        TOKEN_0 = token0_;
        TOKEN_1 = token1_;
        RESERVE_0 = reserve0_;
        RESERVE_1 = reserve1_;
    }

    function token0() external view override returns (address) {
        return TOKEN_0;
    }

    function token1() external view override returns (address) {
        return TOKEN_1;
    }

    function getReserves() external view override returns (uint112, uint112, uint32) {
        return (RESERVE_0, RESERVE_1, 0);
    }

    function swap(uint256, uint256, address, bytes calldata) external pure override {}
}
