// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MultiplierPayoutModel
/// @notice Pure math for MULTIPLIER payout lotteries (variable winner count from pool × multiplier).
/// @dev Stateless helper mixed into concrete creators. The multiplier (`payoutRateBp`) is stored
///      on the per-lottery `Lottery` record in `BaseLotteryManager._lotteries`.
///
///      Winner count: K = (prizePool × BP) / (ticketPrice × payoutRateBp), minimum 1 when pool > 0.
///      Prizes: equal split; winner index 0 absorbs integer rounding remainder.
abstract contract MultiplierPayoutModel {
    /// @dev Basis-points denominator (100.00%).
    uint256 private constant BP = 10_000;

    /// @notice Computes how many winning positions exist for a multiplier lottery.
    /// @param _prizePool     Net prize pool after fees (token smallest units).
    /// @param _payoutRateBp  Target payout multiplier in BP (e.g. 15_000 = 1.5× ticket price).
    /// @param _ticketPrice   Per-ticket price (must be > 0).
    /// @return count        Number of winners (≥ 1 when inputs allow a draw; `0` if pool is zero).
    function _calcMultiplierWinnerCount(
        uint256 _prizePool,
        uint256 _payoutRateBp,
        uint256 _ticketPrice
    ) internal pure returns (uint24 count) {
        if (_prizePool == 0 || _ticketPrice == 0 || _payoutRateBp == 0) return 0;
        uint256 denom = _ticketPrice * _payoutRateBp;
        // Saturation check: determine if floor(_prizePool * BP / denom) would exceed uint24.max
        // WITHOUT computing _prizePool * BP (which can overflow uint256 for large prizePool).
        //
        // Condition: floor(p * BP / d) >= 2^24  iff  p * BP >= (uint24.max + 1) * d
        //         => p >= ceil((uint24.max + 1) * d / BP)
        //
        // Safety: (uint24.max + 1) = 2^24 = 16_777_216; denom ≤ uint128.max * uint32.max ≈ 1.46e48
        //         product ≤ 16_777_216 * 1.46e48 ≈ 2.45e55  <<  uint256.max — always safe.
        uint256 satCap = uint256(type(uint24).max) + 1; // 16_777_216
        if (_prizePool >= (satCap * denom + BP - 1) / BP) return type(uint24).max;
        uint256 k = Math.mulDiv(_prizePool, BP, denom);
        count = k == 0 ? 1 : uint24(k);
    }

    /// @notice Computes prize amount and total winner count for one winner index.
    /// @param _prizePool     Net prize pool after fees.
    /// @param _payoutRateBp  Multiplier in BP.
    /// @param _ticketPrice   Per-ticket price.
    /// @param _winnerIndex   0-based winner ordinal.
    /// @return prizeForIndex Prize for `winnerIndex`.
    /// @return winnerCount   Total winning positions.
    function _calcMultiplierPrize(
        uint256 _prizePool,
        uint256 _payoutRateBp,
        uint256 _ticketPrice,
        uint24 _winnerIndex
    ) internal pure returns (uint256 prizeForIndex, uint256 winnerCount) {
        winnerCount = _calcMultiplierWinnerCount(_prizePool, _payoutRateBp, _ticketPrice);
        if (winnerCount == 0) return (0, 0);
        if (winnerCount == 1) return (_prizePool, 1);
        uint256 perWinner = _prizePool / winnerCount;
        prizeForIndex = (_winnerIndex == 0) ? perWinner + (_prizePool % winnerCount) : perWinner;
    }
}
