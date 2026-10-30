// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title WinRatePayoutModel
/// @notice Pure math for WIN_RATE payout lotteries (fixed fraction of tickets win, equal split).
/// @dev Stateless helper mixed into concrete creators. `winRateBp` is stored on the
///      per-lottery `Lottery` record. Winner ticket indices use `LotteryPrizeLib` affine mapping.
abstract contract WinRatePayoutModel {
    /// @dev Basis-points denominator (100.00%).
    uint256 private constant BP_DENOMINATOR = 10_000;

    /// @notice Computes the number of winners from tickets sold and win rate.
    /// @param totalTickets Total tickets sold.
    /// @param winRateBp    Fraction of tickets that win (e.g. 1_000 = 10%).
    /// @return count        Winner count; at least 1 when `totalTickets > 0`.
    function _calcWinnerCount(
        uint256 totalTickets,
        uint256 winRateBp
    ) internal pure returns (uint256 count) {
        if (totalTickets == 0) return 0;
        count = (totalTickets * winRateBp) / BP_DENOMINATOR;
        if (count == 0) count = 1;
    }

    /// @notice Splits the prize pool equally across `winnerCount` winners.
    /// @param prizePool    Net prize pool.
    /// @param winnerCount  Number of winners (must be > 0).
    /// @return perWinner   Base share per winner.
    /// @return dust        Remainder assigned to winner index 0.
    function _calcWinRatePrizePerWinner(
        uint256 prizePool,
        uint256 winnerCount
    ) internal pure returns (uint256 perWinner, uint256 dust) {
        perWinner = prizePool / winnerCount;
        dust = prizePool - (perWinner * winnerCount);
    }
}
