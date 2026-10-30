// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LotteryPrizeLib} from "../libraries/LotteryPrizeLib.sol";

/// @title TierPayoutModel
/// @notice Tier-weight storage and prize math for TIER payout lotteries.
/// @dev Maintains `_lTiers[lotteryId]`, an ordered array of tier weights in basis points.
///      Active winner count = `min(tiers.length, ticketsSold)`. Prizes are proportional to
///      the active tier weights; index 0 absorbs rounding dust when multiple tiers apply.
abstract contract TierPayoutModel {
    /// @dev Tier weights must not exceed 100% in aggregate at creation time.
    uint256 private constant TIER_WEIGHTS_BP_DENOM = 10_000;

    /// @dev Per-lottery tier weight array (BP). Written at creation by the concrete creator.
    mapping(uint256 lotteryId => uint16[] tiers) internal _lTiers;

    /// @notice Thrown when tier weights sum to more than 100% (`10_000` BP).
    /// @param sum Aggregate tier weight in BP.
    error InvalidTierWeightsSum(uint256 sum);

    /// @notice Thrown when the first tier weight is zero, which would allow the
    ///         active-tier sum to be zero and permanently strand the prize pool.
    error ZeroLeadingTierWeight();

    /// @notice Returns the number of tier weights configured for `lotteryId`.
    /// @dev Empty for non-TIER lotteries or unknown IDs.
    function countTiers(uint256 lotteryId) external view returns (uint256) {
        return _lTiers[lotteryId].length;
    }

    /// @notice Returns all tier weights (basis points) for `lotteryId`.
    /// @dev Bounded by `MAX_TIER_LENGTH` (100) at creation. Empty array if not a TIER lottery.
    function getLotteryTiers(uint256 lotteryId) external view returns (uint16[] memory) {
        return _lTiers[lotteryId];
    }

    /// @notice Persists tier weights for a lottery at creation time.
    /// @dev Sum of all tier weights must be `<= 10_000` BP. Among active tiers at draw time,
    ///      prizes are proportional to each weight relative to the active subset.
    /// @param _lotteryId Target lottery.
    /// @param _tiers     Non-empty tier weight array in BP.
    function _storeTiers(uint256 _lotteryId, uint16[] memory _tiers) internal {
        if (_tiers[0] == 0) revert ZeroLeadingTierWeight();
        uint256 len = _tiers.length;
        uint256 sum;
        for (uint256 i; i < len; ) {
            sum += uint256(_tiers[i]);
            // prettier-ignore
            unchecked { ++i; }
        }
        if (sum != TIER_WEIGHTS_BP_DENOM) revert InvalidTierWeightsSum(sum);
        _lTiers[_lotteryId] = _tiers;
    }

    /// @notice Returns the prize for one winner index under tier-proportional distribution.
    /// @param _lotteryId      Lottery ID.
    /// @param _winnerIndex    0-based winner ordinal.
    /// @param _prizePool      Net prize pool at draw time.
    /// @param _actualWinners  Active winners: `min(tiers.length, ticketsSold)`.
    /// @return amount        Prize in token smallest units.
    function _calcTierPrize(
        uint256 _lotteryId,
        uint24 _winnerIndex,
        uint256 _prizePool,
        uint24 _actualWinners
    ) internal view returns (uint256 amount) {
        amount = LotteryPrizeLib.prizeForTierProportionalFromStorage(
            _prizePool,
            _lTiers[_lotteryId],
            _actualWinners,
            _winnerIndex
        );
    }

    /// @notice Returns the number of winning positions for a tier lottery.
    /// @param lotteryId   Lottery ID.
    /// @param ticketsSold Total tickets sold.
    /// @return count      `min(tiers.length, ticketsSold)`.
    function _tierWinnerCount(uint256 lotteryId, uint256 ticketsSold) internal view returns (uint24 count) {
        uint256 tierCount = _lTiers[lotteryId].length;
        count = uint24(tierCount < ticketsSold ? tierCount : ticketsSold);
    }
}
