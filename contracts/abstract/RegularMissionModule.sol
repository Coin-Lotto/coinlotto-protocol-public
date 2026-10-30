// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LotteryPrizeLib} from "../libraries/LotteryPrizeLib.sol";
import {BaseLotteryManager} from "./BaseLotteryManager.sol";
import {IRegularMissionModule} from "../interfaces/IRegularMissionModule.sol";
import {ILotteryCore} from "../interfaces/ILotteryCore.sol";
import {LotteryStored, LotteryState, LotteryKind, LotteryStatus} from "../structs/MetadataStruct.sol";

/// @title RegularMissionModule
/// @notice Mission views and validation required by `CltMissions`.
/// @dev Inherit this mixin on managers that host mission-eligible lotteries
///      (e.g. `ProtocolLotteryManager` for REGULAR, `ProtocolDuelLotteryManager` for BATTLE).
///      USER-only managers should inherit `BaseLotteryManager` directly so mission endpoints
///      are absent from their ABI.
///
///      All functions read the same manager-local storage as the base:
///      `_lotteries`, `_state`, `_ownerships`, and draw `seed` on `LotteryState`.
///      `validateLosingTicketsForMission` recomputes winning ticket IDs from `seed` and
///      rejects batches that include a winner, span multiple owners, or exceed
///      {MAX_LUCK_INSURANCE_ITEMS} batches or tickets.
abstract contract RegularMissionModule is BaseLotteryManager, IRegularMissionModule {
    /* ─────────────────────────── Constants ────────────────────────── */

    /// @dev Maximum batch count and total ticket count for Luck Insurance.
    uint256 internal constant MAX_LUCK_INSURANCE_ITEMS = 10;

    /* ─────────────────────────── Mission views ────────────────────── */

    /// @inheritdoc IRegularMissionModule
    function getMissionTicketInfo(
        uint256 lotteryId,
        uint256 ticketId
    ) external view override returns (LotteryKind kind, address owner, uint64 purchaseTime, uint64 lotteryStart) {
        TicketOwnership memory o = _resolveOwnership(lotteryId, ticketId);
        LotteryStored storage lot = _lotteries[lotteryId];
        return (lot.kind, o.owner, o.purchaseTime, uint64(lot.startTime));
    }

    /// @inheritdoc IRegularMissionModule
    function getMissionBatchData(
        uint256 lotteryId,
        uint256 ticketId
    ) external view override returns (LotteryKind kind, address owner, uint256 batchSize) {
        TicketOwnership storage record = _ownerships[lotteryId][ticketId];
        if (record.owner == address(0)) revert TicketDoesNotExist();

        uint256 totalSold = _sold(lotteryId);
        uint256 end = ticketId + 1;
        while (end <= totalSold && _ownerships[lotteryId][end].owner == address(0)) {
            // prettier-ignore
            unchecked { ++end; }
        }
        return (_lotteries[lotteryId].kind, record.owner, end - ticketId);
    }

    /// @inheritdoc IRegularMissionModule
    /// @dev Returns `(true, batchOwner, totalTicketCount)` only when every ticket in every batch:
    ///      - belongs to a mission-eligible lottery kind (REGULAR or BATTLE, per `_isMissionEligibleKind`),
    ///      - has a completed draw (`seed != 0`),
    ///      - is not a winning ticket,
    ///      - shares the same owner across all batches.
    function validateLosingTicketsForMission(
        ILotteryCore.TicketBatch[] calldata batches
    ) external view override returns (bool isLosing, address batchOwner, uint256 allTicketCount) {
        uint256 batchLen = batches.length;
        if (batchLen == 0 || batchLen > MAX_LUCK_INSURANCE_ITEMS) return (false, address(0), 0);

        address firstOwner;
        uint256 total;
        uint256 lastLotteryId;

        for (uint256 i; i < batchLen; ) {
            uint256 lotteryId = batches[i].lotteryId;
            if (lotteryId <= lastLotteryId) return (false, address(0), 0);
            lastLotteryId = lotteryId;

            LotteryState storage s = _state[lotteryId];

            if (s.status == LotteryStatus.NONE) return (false, address(0), 0);
            if (s.seed == 0) return (false, address(0), 0);

            if (!_isMissionEligibleKind(_lotteries[lotteryId].kind)) return (false, address(0), 0);

            uint24 sold = uint24(_sold(lotteryId));
            uint24 wCount = _countWinners(lotteryId);
            uint256[] calldata ids = batches[i].ticketIds;
            uint256 idsLen = ids.length;

            total += idsLen;
            if (total > MAX_LUCK_INSURANCE_ITEMS) return (false, address(0), 0);

            uint256 lastTicketId;

            for (uint256 j; j < idsLen; ) {
                uint256 ticketId = ids[j];
                if (ticketId <= lastTicketId) return (false, address(0), 0);
                lastTicketId = ticketId;

                address tOwner = ownerOf(lotteryId, ticketId);

                if (firstOwner == address(0)) firstOwner = tOwner;
                else if (tOwner != firstOwner) return (false, address(0), 0);

                uint24 ordinal0 = LotteryPrizeLib.ordinalForTicket(s.seed, sold, ticketId);
                if (ordinal0 < wCount) return (false, address(0), 0);
                // prettier-ignore
                unchecked { ++j; }
            }
            // prettier-ignore
            unchecked { ++i; }
        }
        return (true, firstOwner, total);
    }

    /* ─────────────────────────── Kind gate (overridable) ──────────── */

    /// @dev Returns true when `kind` qualifies for mission rewards.
    ///      Default: REGULAR only. Override in subclasses to extend eligibility
    ///      (e.g. ProtocolDuelLotteryManager overrides to accept BATTLE).
    function _isMissionEligibleKind(LotteryKind _kind) internal pure virtual returns (bool) {
        return _kind == LotteryKind.REGULAR;
    }
}
