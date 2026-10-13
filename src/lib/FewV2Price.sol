// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISwapV2Pair} from "../interfaces/external/IFewV2.sol";

/// @notice Converts canonical FewV2 reserves into a Uniswap v4 sqrt price.
/// @dev `fewCurrency0` and `fewCurrency1` must follow the corresponding Shell Pool currency order.
///      The calculation uses raw token units, so token decimal differences are included automatically.
library FewV2Price {
    error PairTokenMismatch(address pair);
    error ZeroReserve();
    error SqrtPriceOutOfRange(uint256 sqrtPriceX96);

    uint256 private constant Q128 = 1 << 128;
    uint256 private constant Q192 = 1 << 192;

    /// @notice Reads a FewV2 pair and returns reserves in Shell Pool currency0/currency1 order.
    function orderedReserves(ISwapV2Pair pair, address fewCurrency0, address fewCurrency1)
        internal
        view
        returns (uint112 reserveCurrency0, uint112 reserveCurrency1)
    {
        address pairToken0 = pair.token0();
        address pairToken1 = pair.token1();
        (uint112 pairReserve0, uint112 pairReserve1,) = pair.getReserves();

        if (pairToken0 == fewCurrency0 && pairToken1 == fewCurrency1) {
            return (pairReserve0, pairReserve1);
        }
        if (pairToken0 == fewCurrency1 && pairToken1 == fewCurrency0) {
            return (pairReserve1, pairReserve0);
        }
        revert PairTokenMismatch(address(pair));
    }

    /// @notice Returns `sqrt(reserveCurrency1 / reserveCurrency0) * 2^96` for a FewV2 pair.
    function fromPair(ISwapV2Pair pair, address fewCurrency0, address fewCurrency1)
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        (uint112 reserveCurrency0, uint112 reserveCurrency1) = orderedReserves(pair, fewCurrency0, fewCurrency1);
        return fromReserves(reserveCurrency0, reserveCurrency1);
    }

    /// @notice Returns the exact floor of `sqrt(reserveCurrency1 / reserveCurrency0) * 2^96`.
    function fromReserves(uint112 reserveCurrency0, uint112 reserveCurrency1)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (reserveCurrency0 == 0 || reserveCurrency1 == 0) revert ZeroReserve();

        uint256 price;
        // For ratios below 2^64, ratio * 2^192 fits uint256. Taking the square root of
        // the floored quotient still gives the exact floored rational square root.
        if (uint256(reserveCurrency1) < (uint256(reserveCurrency0) << 64)) {
            price = Math.sqrt(Math.mulDiv(uint256(reserveCurrency1), Q192, uint256(reserveCurrency0)));
        } else {
            // A uint112 reserve ratio can make ratio * 2^192 overflow uint256. Scale by
            // 2^128 first, then recover the remaining 32 fractional bits with an exact
            // 512-bit comparison. This branch performs at most 32 binary-search steps.
            uint256 scaledRoot = Math.sqrt(Math.mulDiv(uint256(reserveCurrency1), Q128, uint256(reserveCurrency0)));
            uint256 low = scaledRoot << 32;
            uint256 high = ((scaledRoot + 1) << 32) - 1;

            while (low < high) {
                uint256 mid = low + ((high - low + 1) >> 1);
                if (_priceFits(mid, reserveCurrency0, reserveCurrency1)) {
                    low = mid;
                } else {
                    high = mid - 1;
                }
            }
            price = low;
        }

        return validate(price);
    }

    /// @notice Validates the PoolManager initialization range and safely narrows to uint160.
    function validate(uint256 sqrtPriceX96) internal pure returns (uint160) {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert SqrtPriceOutOfRange(sqrtPriceX96);
        }
        // The upper-bound check proves the value is below TickMath.MAX_SQRT_PRICE (< 2^160).
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPriceX96);
    }

    /// @dev Returns whether candidate^2 * reserveCurrency0 <= reserveCurrency1 * 2^192.
    ///      All inputs originate from uint112 reserves and the bounded candidate interval,
    ///      so the left-hand product fits in the two returned 256-bit limbs.
    function _priceFits(uint256 candidate, uint112 reserveCurrency0, uint112 reserveCurrency1)
        private
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

    /// @dev Full-width multiplication: product = high * 2^256 + low.
    function _fullMultiply(uint256 a, uint256 b) private pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }
}
