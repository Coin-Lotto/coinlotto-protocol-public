// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LotteryStored, LotteryState, PayoutModel} from "../structs/MetadataStruct.sol";
import {LotteryPrizeLib} from "./LotteryPrizeLib.sol";

/// @title LotteryCoreLib
/// @notice Canonical winner-count and prize-amount math for every payout model.
/// @dev Linked into all managers and into `LotteryWinnerReader`, so on-chain claim amounts and
///      displayed amounts are computed by the same code and cannot diverge.
///
///      Structure:
///        • **Pure core** ({multiplierWinnerCount}, {winnerCountPure}, {calcPrizePure}) holds the
///          single implementation. Callers that already have the inputs in memory use it directly.
///        • **Storage wrappers** ({winnerCount}, {calcPrize}) exist only so managers can pass their
///          own storage pointers. Mappings are passed to libraries as slot numbers and
///          `DELEGATECALL` preserves `address(this)`, so there is no storage-layout impact.
///
///      The saturation cap in {multiplierWinnerCount} keeps the winner count inside `uint24`
///      without multiplying a large prize pool by the basis-point denominator, and must not be relaxed.
library LotteryCoreLib {
    /// @dev Basis-points denominator (100.00%).
    uint256 private constant BP = 10_000;

    /* ═══════════════════════════════════════════════════════════════════════════
       PURE CORE — single source of truth
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Winning positions for a MULTIPLIER lottery.
    /// @dev The saturation branch determines whether `floor(prizePool * BP / denom)`
    ///      would exceed `uint24.max` *without* computing `prizePool * BP`, which can overflow
    ///      `uint256` for a large pool.
    ///
    ///      Condition: `floor(p * BP / d) >= 2^24` iff `p * BP >= (uint24.max + 1) * d`
    ///              => `p >= ceil((uint24.max + 1) * d / BP)`
    ///
    ///      Safety: `(uint24.max + 1) = 2^24 = 16_777_216`; `denom <= uint128.max * uint32.max`
    ///              `≈ 1.46e48`, so the product `≈ 2.45e55 << uint256.max` — always safe.
    /// @param prizePool    Net prize pool after fees (token smallest units).
    /// @param payoutRateBp Target payout multiplier in BP (e.g. 15_000 = 1.5x ticket price).
    /// @param ticketPrice  Per-ticket price.
    /// @return count       Number of winners; `0` when any input is zero.
    function multiplierWinnerCount(
        uint256 prizePool,
        uint256 payoutRateBp,
        uint256 ticketPrice
    ) public pure returns (uint24 count) {
        if (prizePool == 0 || ticketPrice == 0 || payoutRateBp == 0) return 0;
        uint256 denom = ticketPrice * payoutRateBp;
        uint256 satCap = uint256(type(uint24).max) + 1; // 16_777_216
        if (prizePool >= (satCap * denom + BP - 1) / BP) return type(uint24).max;
        uint256 k = Math.mulDiv(prizePool, BP, denom);
        count = k == 0 ? 1 : uint24(k);
    }

    /// @notice Winner slot count for any payout model at a given tickets-sold snapshot.
    /// @dev When exactly one ticket is sold, every model yields a single winner who may claim
    ///      the entire pool (including pre-draw donations) in one claim.
    ///      MULTIPLIER uses `min(K, sold)` to prevent duplicate winner slots when `K > sold`;
    ///      WIN_RATE is at least 1 when `sold > 0` and the rate is non-zero;
    ///      TIER uses `min(tierCount, sold)`.
    /// @param model        Payout model, as the `PayoutModel` ordinal.
    /// @param payoutRateBp Multiplier (MULTIPLIER) or win rate (WIN_RATE) in BP.
    /// @param ticketPrice  Per-ticket price.
    /// @param prizePool    Net prize pool.
    /// @param tierCount    Configured tier count (TIER only).
    /// @param sold         Tickets sold snapshot.
    function winnerCountPure(
        uint8 model,
        uint256 payoutRateBp,
        uint256 ticketPrice,
        uint256 prizePool,
        uint256 tierCount,
        uint256 sold
    ) public pure returns (uint24) {
        if (sold == 0) return 0;
        if (sold == 1) return 1;

        if (model == uint8(PayoutModel.MULTIPLIER)) {
            uint24 k = multiplierWinnerCount(prizePool, payoutRateBp, ticketPrice);
            uint24 sold_ = uint24(sold);
            return k < sold_ ? k : sold_;
        }
        if (model == uint8(PayoutModel.WIN_RATE)) {
            if (payoutRateBp == 0) return 0;
            return uint24(_winRateWinnerCount(sold, payoutRateBp));
        }
        return uint24(tierCount < sold ? tierCount : sold);
    }

    /// @notice Prize amount for a 0-based winner index after the draw.
    /// @dev Mirrors `BaseLotteryManager._calcPrize` plus `_calcMultiplierPrizeForLottery`.
    ///      Winner index `0` absorbs integer rounding dust in every model.
    /// @param model        Payout model, as the `PayoutModel` ordinal.
    /// @param payoutRateBp Multiplier (MULTIPLIER) or win rate (WIN_RATE) in BP.
    /// @param ticketPrice  Per-ticket price.
    /// @param prizePool    Frozen `LotteryState.prizePool`.
    /// @param tiers        Tier weights in BP (TIER only; ignored otherwise).
    /// @param winnerIndex  0-based winner ordinal.
    /// @param sold         Tickets sold snapshot.
    function calcPrizePure(
        uint8 model,
        uint256 payoutRateBp,
        uint256 ticketPrice,
        uint256 prizePool,
        uint16[] memory tiers,
        uint24 winnerIndex,
        uint256 sold
    ) public pure returns (uint256) {
        if (model == uint8(PayoutModel.MULTIPLIER)) {
            // Single-ticket rule takes precedence: the sole winner claims the whole pool.
            if (sold == 1) return prizePool;

            uint24 k = multiplierWinnerCount(prizePool, payoutRateBp, ticketPrice);
            uint24 effectiveWinners = k < uint24(sold) ? k : uint24(sold);
            if (effectiveWinners == 0) return 0;
            if (effectiveWinners == 1) return prizePool;

            uint256 perWinner = prizePool / effectiveWinners;
            return winnerIndex == 0 ? perWinner + (prizePool % effectiveWinners) : perWinner;
        }

        if (model == uint8(PayoutModel.WIN_RATE)) {
            uint256 wCount = _winRateWinnerCount(sold, payoutRateBp);
            uint256 perWinner = prizePool / wCount;
            uint256 dust = prizePool - (perWinner * wCount);
            return winnerIndex == 0 ? perWinner + dust : perWinner;
        }

        uint24 tierWinners = uint24(tiers.length < sold ? tiers.length : sold);
        return LotteryPrizeLib.prizeForTierProportional(prizePool, tiers, tierWinners, winnerIndex);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       STORAGE WRAPPERS — manager side only
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice {winnerCountPure} fed from manager storage.
    /// @dev `lTiers` is only touched for TIER, so other models pay no extra SLOAD.
    function winnerCount(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint16[]) storage lTiers,
        uint256 lotteryId,
        uint256 sold
    ) public view returns (uint24) {
        LotteryStored storage lot = lotteries[lotteryId];
        PayoutModel model = lot.model;
        return
            winnerCountPure(
                uint8(model),
                lot.payoutRateBp,
                lot.ticketPrice,
                model == PayoutModel.MULTIPLIER ? states[lotteryId].prizePool : 0,
                model == PayoutModel.TIER ? lTiers[lotteryId].length : 0,
                sold
            );
    }

    /// @notice {calcPrizePure} fed from manager storage.
    /// @dev TIER routes to {LotteryPrizeLib.prizeForTierProportionalFromStorage} rather than
    ///      copying the weights into memory here, avoiding a redundant round trip on the claim
    ///      path. Both paths share the same canonical tier math.
    function calcPrize(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint16[]) storage lTiers,
        uint256 lotteryId,
        uint24 winnerIndex,
        uint256 sold
    ) public view returns (uint256) {
        LotteryStored storage lot = lotteries[lotteryId];
        uint256 prizePool = states[lotteryId].prizePool;
        PayoutModel model = lot.model;

        if (model == PayoutModel.TIER) {
            uint256 tierCount = lTiers[lotteryId].length;
            uint24 tierWinners = uint24(tierCount < sold ? tierCount : sold);
            return
                LotteryPrizeLib.prizeForTierProportionalFromStorage(
                    prizePool,
                    lTiers[lotteryId],
                    tierWinners,
                    winnerIndex
                );
        }

        uint16[] memory noTiers;
        return calcPrizePure(uint8(model), lot.payoutRateBp, lot.ticketPrice, prizePool, noTiers, winnerIndex, sold);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       PRIVATE HELPERS
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @dev At least one winner whenever any ticket was sold, so a low rate cannot strand the pool.
    function _winRateWinnerCount(uint256 totalTickets, uint256 winRateBp) private pure returns (uint256 count) {
        if (totalTickets == 0) return 0;
        count = (totalTickets * winRateBp) / BP;
        if (count == 0) count = 1;
    }
}
