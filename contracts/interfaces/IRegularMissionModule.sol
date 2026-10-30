// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LotteryKind} from "../structs/MetadataStruct.sol";
import {ILotteryCore} from "./ILotteryCore.sol";

/// @title IRegularMissionModule
/// @notice Mission-validation API implemented by managers that support CLT missions.
/// @dev Implemented by:
///      - `ProtocolLotteryManager` — for REGULAR and SUPER lotteries.
///      - `ProtocolDuelLotteryManager` — for BATTLE (protocol duel) lotteries.
///      USER-only managers (`UserLotteryManager`, `UserDuelLotteryManager`) intentionally omit
///      these functions so mission endpoints are absent from their ABI.
///
///      `CltMissions` resolves `lotteryId` → manager via `LotteryHub` and casts to this interface.
///      Signatures align with `ILotteryCore` mission views for a single integration surface.
interface IRegularMissionModule {
    /// @notice Ticket and schedule metadata for mission rules (walk-back ownership).
    /// @dev **Caller:** anyone (view).
    ///      **Reverts:** `TicketDoesNotExist` for invalid `ticketId`.
    /// @param lotteryId  Mission-eligible lottery on this manager.
    /// @param ticketId   Any valid ticket ID in a purchase batch.
    /// @return kind          Lottery kind (`REGULAR` or `BATTLE` depending on the manager).
    /// @return owner         Batch owner / original purchaser.
    /// @return purchaseTime  Purchase timestamp of the covering batch.
    /// @return lotteryStart  `params.startTime`.
    function getMissionTicketInfo(
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (LotteryKind kind, address owner, uint64 purchaseTime, uint64 lotteryStart);

    /// @notice Batch-start ticket metadata including purchase size.
    /// @dev **Caller:** anyone (view).
    ///      **Reverts:** `TicketDoesNotExist` when `ticketId` is not a batch-start record.
    /// @param lotteryId  Mission-eligible lottery on this manager.
    /// @param ticketId   First ticket ID of the purchase batch.
    /// @return kind       Lottery kind (`REGULAR` or `BATTLE`).
    /// @return owner      Batch owner.
    /// @return batchSize  Tickets minted in that Hub `buyTickets` call.
    function getMissionBatchData(
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (LotteryKind kind, address owner, uint256 batchSize);

    /// @notice Verifies losing tickets for Luck Insurance–style missions.
    /// @dev **Caller:** anyone (view); `CltMissions` consumes the boolean result.
    ///      **Returns `(false, address(0), 0)`** on any failed check (no revert).
    ///      Requires completed draw (`seed != 0`), single owner, no winning ticket IDs, and
    ///      a mission-eligible lottery kind (REGULAR or BATTLE per `_isMissionEligibleKind`).
    /// @param batches  Ticket groups per lottery ID.
    /// @return isLosing        `true` when all tickets are eligible losing tickets.
    /// @return batchOwner      Shared owner when `isLosing`.
    /// @return allTicketCount  Sum of `ticketIds.length` across batches.
    function validateLosingTicketsForMission(
        ILotteryCore.TicketBatch[] calldata batches
    ) external view returns (bool isLosing, address batchOwner, uint256 allTicketCount);
}
