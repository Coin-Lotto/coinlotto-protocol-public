// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LotteryKind, LotteryParams, LotteryStatus, PayoutModel} from "../structs/MetadataStruct.sol";
import {TicketPurchaseQuote} from "../structs/TicketPurchaseQuote.sol";

/// @title ILotteryManager
/// @notice API implemented by every lottery manager (`UserLotteryManager`,
///         `ProtocolLotteryManager`, and related modules) and routed through `LotteryHub`.
/// @dev **ID assignment** — The Hub increments `lotteryCount`, assigns `lotteryId`, then calls
///      `createLotteryFromHub`. Creators must never mint their own global IDs.
///
///      **Hub-pull ticket sales** — Buyers approve only the Hub. The Hub quotes, pulls ERC-20/CLT,
///      then registers the purchase on the owning creator with zero transfers in step 3.
///
///      **Access** — State-changing entry points (except draw/claim when called directly) expect
///      `msg.sender == hub` via `HUB_ROLE` / `onlyHub` on implementations.
interface ILotteryManager {
    /* ─────────────────────────── Lifecycle ──────────────────────────── */

    /// @notice Initialises lottery `lotteryId` on this creator.
    /// @dev **Caller:** `LotteryHub.createLottery` only (atomic with ID assignment).
    ///      **Validations:** Kind/model/params/extraData checks are implementation-specific;
    ///      reverts roll back the Hub counter increment.
    ///      **State:** Writes `Lottery`, initial `LotteryState`, ticket index; may emit
    ///      `LotteryStatusUpdated`, `LotteryCreated` (per creator).
    /// @param lotteryId       Hub-assigned global ID.
    /// @param originalCaller  `msg.sender` of the Hub create call (fee beneficiary for USER).
    /// @param kind            `USER`, `REGULAR`, or `SUPER`.
    /// @param payoutModel     `MULTIPLIER`, `TIER`, or `WIN_RATE`.
    /// @param params          Base economics and schedule (`LotteryParams`).
    /// @param extraData       ABI-encoded model data (multiplier bp, tier array, win-rate bp, …).
    function createLotteryFromHub(
        uint256 lotteryId,
        address originalCaller,
        LotteryKind kind,
        PayoutModel payoutModel,
        LotteryParams calldata params,
        bytes calldata extraData
    ) external;

    /* ─────────────────────────── Ticket purchase (Hub-pull) ───────────── */

    /// @notice Computes the full payment breakdown for buying `qty` tickets.
    /// @dev **Caller:** anyone (view). Hub calls before transfers.
    ///      **Validations:** Reverts if lottery inactive, sold out, bad `qty`, or timing invalid
    ///      (`InvalidQuantity`, `LotteryNotActive`, `ExceedsMaxTickets`, …).
    ///      **State:** none.
    /// @param lotteryId Target lottery.
    /// @param qty       Ticket count (`> 0`).
    /// @param referrer  Effective referrer from `ReferralRegistry` (`address(0)` allowed).
    /// @return quote    Struct used for Hub transfers and `registerTicketPurchase`.
    function quoteTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address referrer
    ) external view returns (TicketPurchaseQuote memory quote);

    /// @notice Mints tickets and updates accounting after Hub transfers.
    /// @dev **Caller:** Hub only (`HUB_ROLE`).
    ///      **Validations:** Same purchase rules as quote; quote fields must match what Hub paid.
    ///      **State:** Increments sold count, updates `prizePool` / `creatorFees` / `refFees` /
    ///      feeder SUPER pool, may transition status to ACTIVE or READY_TO_DRAW; mints tickets.
    ///      **Events:** Ticket mint / status events per creator (Hub emits `TicketsBought`).
    /// @param lotteryId        Target lottery.
    /// @param qty              Ticket count.
    /// @param ticketRecipient  Owner of minted ticket IDs.
    /// @param originalCaller   Hub buyer (`msg.sender` on `buyTickets`).
    /// @param referrer         Resolved referrer.
    /// @param quote            Prior `quoteTicketPurchase` result.
    function registerTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address ticketRecipient,
        address originalCaller,
        address referrer,
        TicketPurchaseQuote calldata quote
    ) external;

    /* ─────────────────────────── Draw & prizes ────────────────────────── */

    /// @notice Requests randomness for `lotteryId` when the lottery is ready to draw.
    /// @dev **Caller:** Hub (sets `payer = msg.sender`) or direct call (must have `payer == msg.sender`).
    ///      **Payment:** `msg.value` must cover the VRF fee. Excess ETH and single-ticket instant
    ///      refunds are credited to `payer` in `RndConsumer` (`pendingRefunds`, pulled via
    ///      `withdrawRefund`) — never sent during the draw and never bounced through the Hub.
    ///      **State:** Sets `DRAW_REQUESTED`, `drawDeadline`; may short-circuit to
    ///      `DRAW_COMPLETED` when `< 2` tickets sold.
    ///      **Retry:** if a prior request timed out without a seed, calling again after the
    ///      `drawDeadline` re-issues the VRF request (reverts before the deadline or once fulfilled).
    /// @param lotteryId Lottery to draw.
    /// @param payer     Originating user; credited with any ETH refund in `RndConsumer`.
    function requestDraw(uint256 lotteryId, address payer) external payable;

    /// @notice Validates that a donation is allowed and returns the donation asset, without
    ///         writing any accounting. The Hub calls this before the token transfer so that the
    ///         actual received amount (after any fee-on-transfer deduction) can be measured
    ///         with a before/after `balanceOf` snapshot and then recorded via `recordDonationFor`.
    /// @dev **Caller:** Hub only (`HUB_ROLE`). Reverts with `ZeroAmount` when `amount == 0`.
    ///      Returns `allowed == false` when the lottery no longer accepts donations; the Hub
    ///      reverts with `ProhibitedDonation` in that case.
    /// @param lotteryId Lottery to boost.
    /// @param amount    Intended donation amount (used only for the zero-check; not stored).
    /// @return asset    ERC-20 the Hub must pull from the donor.
    function getDonationAsset(uint256 lotteryId, uint256 amount) external view returns (address asset, bool allowed);

    /// @notice Records the accounting for a Hub-routed donation after the token transfer.
    /// @dev **Caller:** Hub only (`HUB_ROLE`). `actualReceived` is the balance delta measured by
    ///      the Hub around the `safeTransferFrom`, reflecting actual tokens received (which may be
    ///      less than the original `amount` for fee-on-transfer tokens). Emits `Donated`.
    /// @param lotteryId     Lottery to boost.
    /// @param donor         Donor address tracked for potential pre-draw withdrawal.
    /// @param actualReceived Tokens actually received by this contract (Hub-measured delta).
    function recordDonationFor(uint256 lotteryId, address donor, uint256 actualReceived) external;

    /// @notice Opens the manager-wide Hub settlement before a Hub transfers tokens to it.
    /// @dev **Caller:** Hub only (`HUB_ROLE`). Reverts while another Hub settlement is in flight on
    ///      this manager. `recordDonationFor` / `registerTicketPurchase` close it and revert when
    ///      it is not open.
    function openHubSettlement() external;

    /// @notice Withdraws a pre-draw donation on behalf of `donor`; transfers asset to `donor`.
    /// @dev **Caller:** Hub only (`HUB_ROLE`). Reverts with `NoDonation` when balance is zero.
    ///      Emits `DonationWithdrawn`.
    /// @param lotteryId Lottery from which to withdraw.
    /// @param donor     Address whose donation is cleared and refunded.
    function withdrawDonationFor(uint256 lotteryId, address donor) external;

    /// @notice Pays the prize for winner slot `winnerIndex` to `claimer`.
    /// @dev **Caller:** Hub sets `claimer` to the end user; direct calls must pass the real winner.
    ///      **Validations:** `DRAW_COMPLETED` or `FULLY_CLAIMED`; `claimer` owns winning ticket;
    ///      slot not already claimed (`AlreadyClaimed`, `NotWinner`, `DrawNotCompleted`).
    ///      **State:** Sets claim bit, increases `claimedPrizePool`, may set `FULLY_CLAIMED`.
    ///      **Events:** `PrizeClaimed` (creator / Hub).
    /// @param lotteryId    Lottery ID.
    /// @param winnerIndex  0-based winner rank from VRF mapping.
    /// @param claimer      Recipient of the ERC-20 prize transfer.
    function claimPrize(uint256 lotteryId, uint24 winnerIndex, address claimer) external;

    /// @notice Batch variant of `claimPrize` for multiple winner indices.
    /// @dev **Caller / validations:** Same as `claimPrize` per index; empty array reverts.
    ///      **Events:** `PrizeClaimedBatch` on implementations that support it.
    /// @param lotteryId       Lottery ID.
    /// @param winnerIndices   0-based winner slots.
    /// @param claimer         Prize recipient; must own each winning ticket.
    /// @return totalAmount    Sum of prizes transferred in this batch.
    function claimPrizeBatch(
        uint256 lotteryId,
        uint24[] calldata winnerIndices,
        address claimer
    ) external returns (uint256 totalAmount);

    /* ─────────────────────────── Referrer fees ────────────────────────── */

    /// @notice Returns accrued referrer fees for `referrer` in `token` on this creator.
    /// @dev **Caller:** anyone (view). Hub `getReferrerFee(lotteryId, …)` resolves the creator first.
    /// @param referrer Referrer address.
    /// @param token    Fee denomination (ticket asset).
    /// @return Accrued balance not yet claimed.
    function getReferrerFee(address referrer, address token) external view returns (uint256);

    /// @notice Transfers accrued referrer fees to `referrer`.
    /// @dev **Caller:** Hub only; Hub passes `msg.sender` as `referrer`.
    ///      **Validations:** `amount > 0` or reverts `NoRefFees`.
    ///      **State:** Clears `refFees[referrer][token]`.
    ///      **Events:** `ReferrerFeeClaimed`.
    /// @param referrer Recipient (must match Hub caller when routed via Hub).
    /// @param token    ERC-20 to transfer.
    function claimReferrerFees(address referrer, address token) external;

    /* ─────────────────────────── Views ────────────────────────────────── */

    /// @notice Effective lifecycle status including virtual overlays.
    /// @dev **Caller:** anyone (view).
    /// @param lotteryId Lottery ID on this creator.
    /// @return Status per `LotteryStatus` (may differ from raw `LotteryState.status`).
    function getLotteryStatus(uint256 lotteryId) external view returns (LotteryStatus);

    /// @notice Owner of ticket `ticketId` (1-based IDs).
    /// @dev **Caller:** anyone (view). Used by Hub prize checks and `CltMissions`.
    /// @param lotteryId Lottery ID.
    /// @param ticketId  Ticket index.
    /// @return Owner address or revert `TicketDoesNotExist`.
    function ticketOwner(uint256 lotteryId, uint256 ticketId) external view returns (address);

    /// @notice Prize pool balances for winner payouts.
    /// @dev **Caller:** anyone (view).
    /// @param lotteryId Lottery ID.
    /// @return claimedPrizePool   Paid out so far.
    /// @return unclaimedPrizePool `prizePool - claimedPrizePool`.
    /// @return totalPrizePool     Frozen `prizePool` snapshot.
    function getPrizePool(
        uint256 lotteryId
    )
        external
        view
        returns (uint256 claimedPrizePool, uint256 unclaimedPrizePool, uint256 totalPrizePool);

    /// @notice Returns the number of claimable winner slots for `lotteryId`.
    /// @dev Uses current tickets sold and prize pool; MULTIPLIER count grows with donations.
    /// @param lotteryId Lottery ID on this creator.
    /// @return Winner slot count under the lottery payout model.
    function countWinners(uint256 lotteryId) external view returns (uint256);
}
