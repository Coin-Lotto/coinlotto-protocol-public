// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "../structs/MetadataStruct.sol";

/// @title ILotteryCore
/// @notice Shared types and read-only ticket/lottery queries for mission and reward integrations.
/// @dev In V2, live lotteries live on **creator contracts** routed by `LotteryHub`. REGULAR creators
///      expose the mission methods through `IRegularMissionModule` (same signatures as below).
///      `CltMissions` and `CltRewarder` call into the creator resolved for a `lotteryId`, not into
///      the Hub itself. This interface defines the cross-contract shape and `TicketBatch` helper type.
interface ILotteryCore {
    /// @notice A set of ticket IDs belonging to one lottery, used for batch mission validation.
    /// @param lotteryId  Global lottery ID (creator must own this ID).
    /// @param ticketIds  1-based ticket indices to check (may span multiple purchase batches).
    struct TicketBatch {
        uint256 lotteryId;
        uint256[] ticketIds;
    }

    /// @notice Returns ticket and lottery timing data for mission eligibility.
    /// @dev **Caller:** anyone (view). Implemented on REGULAR creators via `IRegularMissionModule`.
    ///      Uses ERC721A-style walk-back: `ticketId` may be any ID in a purchase batch; returned
    ///      `owner` and `purchaseTime` come from the batch-start record. Tickets are non-transferable.
    ///      **Reverts:** `TicketDoesNotExist` for ID `0` or IDs beyond sold range.
    /// @param lotteryId     Lottery on the creator.
    /// @param ticketId    Any valid 1-based ticket ID in the batch.
    /// @return kind         `LotteryKind` (expected `REGULAR` for mission modules).
    /// @return owner        Purchaser / current owner.
    /// @return purchaseTime Unix time of the batch purchase.
    /// @return lotteryStart `params.startTime` of the lottery.
    function getMissionTicketInfo(
        uint256 lotteryId,
        uint256 ticketId
    )
        external
        view
        returns (LotteryKind kind, address owner, uint64 purchaseTime, uint64 lotteryStart);

    /// @notice Returns kind, owner, and contiguous batch size for a batch-start ticket.
    /// @dev **Caller:** anyone (view).
    ///      **Validations:** `ticketId` must be the first ID of a `buyTickets` mint (batch start);
    ///      otherwise `TicketDoesNotExist`.
    ///      Used by Stack The Odds and similar missions needing purchase quantity in one call.
    /// @param lotteryId  Lottery on the creator.
    /// @param ticketId   Batch-start ticket ID.
    /// @return kind       Lottery kind.
    /// @return owner      Batch owner.
    /// @return batchSize  Count of tickets minted in that single Hub purchase.
    function getMissionBatchData(
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (LotteryKind kind, address owner, uint256 batchSize);

    /// @notice Checks whether all tickets in `batches` are non-winning REGULAR tickets owned by one address.
    /// @dev **Caller:** anyone (view). Typically `CltMissions` before paying a mission reward.
    ///      **Validations (returns `false` instead of revert):** empty input; wrong creator storage;
    ///      draw incomplete (`seed == 0`); non-REGULAR kind; mixed owners; any ticket is a winner.
    ///      **State:** none.
    /// @param batches  Groups of ticket IDs per lottery.
    /// @return isLosing       `true` only if every check passes.
    /// @return owner          Common owner when `isLosing`; otherwise `address(0)`.
    /// @return allTicketCount Total ticket count across all batches.
    function validateLosingTicketsForMission(
        TicketBatch[] calldata batches
    ) external view returns (bool isLosing, address owner, uint256 allTicketCount);

    /// @notice Returns the effective lifecycle status of `lotteryId`.
    /// @dev **Caller:** anyone (view). Mirrors `ILotteryManager.getLotteryStatus` on managers.
    /// @param lotteryId Lottery ID.
    /// @return status   `LotteryStatus` including virtual overlays.
    function getLotteryStatus(uint256 lotteryId) external view returns (LotteryStatus status);

    /// @notice Returns total tickets sold for `lotteryId`.
    /// @dev **Caller:** anyone (view). Equals next ticket index minus one (IDs start at `1`).
    /// @param lotteryId Lottery ID.
    /// @return Total sold ticket count.
    function totalTicketsSold(uint256 lotteryId) external view returns (uint256);
}
