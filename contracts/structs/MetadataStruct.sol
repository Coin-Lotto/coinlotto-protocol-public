// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/* ─────────────────────────────────────────────────────────────────────────────
   Shared protocol types for the lottery system.
   Used by LotteryHub, creator contracts (USER / REGULAR / SUPER), and off-chain
   indexers. Lottery IDs are assigned globally by the Hub; per-lottery state lives
   on the creator contract that owns that ID.
   ───────────────────────────────────────────────────────────────────────────── */

/// @notice High-level lottery category. Determines fee splits, feeder behaviour, and
///         which creator contract (`LotteryHub` creator-type key) handles the lottery.
enum LotteryKind {
    /// @dev Sentinel — lottery slot unused or ID not yet created.
    NONE,
    /// @dev End-user-created lottery (`USER_LOTTERY`). Creator fee accrues in `creatorFees`.
    USER,
    /// @dev Protocol-operated lottery (`REGULAR_LOTTERY`). May link to a SUPER feeder target;
    ///         may credit per-ticket CLT mission rewards.
    REGULAR,
    /// @dev Protocol super-lottery (`REGULAR_LOTTERY` creator). Ticket payment is typically CLT;
    ///         prize pool may be funded in an ERC-20 by REGULAR feeders (`params.asset` of the feeder).
    SUPER,
    /// @dev Two-ticket duel (`BATTLE_LOTTERY` creator). Protocol vs user variants via `extraData`.
    BATTLE
}

/// @notice Defines how winners and payouts are calculated after the draw.
enum PayoutModel {
    /// @dev Sentinel value. Not used for active lotteries.
    NONE,

    /// @dev Multiplier-based payout model.
    /// The base payout is calculated from the ticket price:
    /// `ticketPrice * payoutRateBp / 10_000`.
    ///
    /// The multiplier defines how much one winning ticket is expected to receive
    /// relative to the ticket price.
    ///
    /// If the prize pool allows more payout slots than the number of sold tickets,
    /// the winner count must be limited by `soldTickets`.
    /// In this case, the prize pool should be distributed between real sold tickets,
    /// not between artificial repeated winner slots.
    ///
    /// The same ticket should not be duplicated in the winners list unless
    /// repeat-winning is explicitly supported by the lottery rules.
    MULTIPLIER,

    /// @dev Tier-based payout model.
    /// The prize pool is split between winners according to tier weights
    /// provided at lottery creation via `extraData`.
    ///
    /// Each tier represents a share of the prize pool.
    /// This model is usually used for classic lotteries with ranked prizes,
    /// such as first place, second place, third place, and so on.
    TIER,

    /// @dev Win-rate-based payout model.
    /// The number of winners is calculated as a percentage of sold tickets:
    /// `winnerCount = soldTickets * payoutRateBp / 10_000`.
    ///
    /// This model is usually used when the lottery defines what percentage
    /// of sold tickets should become winning tickets, for example SUPER lotteries.
    WIN_RATE
}

/// @notice On-chain lifecycle phase for a lottery.
/// @dev Stored in `LotteryState.status`. `getLotteryStatus` on creators may return
///      **virtual** values (ACTIVE, READY_TO_DRAW) derived from timestamps and sales
///      without rewriting storage.
///
/// Stored transitions (typical path):
///   NONE → PENDING → ACTIVE → READY_TO_DRAW → DRAW_REQUESTED → DRAW_COMPLETED → FULLY_CLAIMED
///
/// Short-circuit: if fewer than two tickets sold at draw time, randomness may be skipped
/// and status moves directly to DRAW_COMPLETED.
///
/// Virtual overlays (not always stored):
///   • PENDING + `startTime <= now <= endTime` → reported as ACTIVE.
///   • PENDING + `now > endTime` (no tickets sold) → reported as CANCELLED.
///   • ACTIVE + `now > endTime` + sold > 0 (not sold out) → reported as READY_TO_DRAW.
///   • ACTIVE + `now > endTime` + sold == 0 → reported as CANCELLED.
///   • DRAW_COMPLETED + all prizes claimed → reported as FULLY_CLAIMED.
// prettier-ignore
enum LotteryStatus {
    NONE,           // 0 — lottery does not exist
    PENDING,        // 1 — created; sale window not open yet
    ACTIVE,         // 2 — sales open (stored or virtual)
    DRAW_REQUESTED, // 3 — VRF request submitted; awaiting callback
    DRAW_COMPLETED, // 4 — seed set; prizes claimable
    FULLY_CLAIMED,  // 5 — all winner slots paid
    READY_TO_DRAW,  // 6 — sold out (stored) or ACTIVE past endTime with sold > 0 (virtual)
    CANCELLED       // 7 — PENDING past endTime, or ACTIVE past endTime with sold == 0 (virtual)
}

/// @notice Immutable economic and scheduling inputs set at lottery creation.
/// @dev Written once into `Lottery.params`. Validated by the creator (`_checkBase` and
///      kind-specific rules) before state is committed.
struct LotteryParams {
    /// @dev Price per ticket in `asset` smallest units.
    uint256 ticketPrice;
    /// @dev ERC-20 accepted for ticket payment (e.g. USDC, USDT). SUPER may use CLT via
    ///      a separate quote path while `asset` still describes the prize denomination.
    address asset;
    /// @dev Creator fee in basis points (10_000 = 100%). Interpretation depends on `LotteryKind`.
    uint256 feeBp;
    /// @dev Maximum tickets that may be sold (`maxTickets` cap).
    uint24 maxTickets;
    /// @dev Unix timestamp when sales may begin.
    uint64 startTime;
    /// @dev Unix timestamp when the sale window ends (unless sold out earlier).
    uint64 endTime;
}

/// @notice Static configuration for one lottery ID on a creator contract.
/// @dev Stored in `_lotteries[lotteryId]`. Never mutated after `createLotteryFromHub`.
struct Lottery {
    /// @dev Address that may claim the creator fee after draw completion (USER) or the
    ///      protocol fee recipient configured for REGULAR/SUPER.
    address creator;
    /// @dev USER, REGULAR, SUPER, or BATTLE.
    LotteryKind kind;
    /// @dev MULTIPLIER, TIER, WIN_RATE, or WINNER_TAKES_ALL (BATTLE).
    PayoutModel model;
    /// @dev Ticket token, price, fee, capacity, and timing.
    LotteryParams params;
    /// @dev Model-specific parameter encoded at creation:
    ///      • WIN_RATE (SUPER): `payoutRateBp` = win-rate in basis points.
    ///      • MULTIPLIER (USER / REGULAR): `payoutRateBp` = minimum payout multiplier in bp.
    ///      • TIER: typically `0`; tier table stored separately on the creator.
    uint256 payoutRateBp;
    /// @dev CLT credited per ticket for mission rewards (REGULAR only; `0` otherwise).
    uint256 cltAmountPerTicket;
    /// @dev Target SUPER lottery ID when this REGULAR lottery feeds a super pool (`0` if none).
    uint256 feederSuperLotteryId;
    /// @dev Share of each ticket payment forwarded to the SUPER pool, in basis points (REGULAR feeders).
    uint256 feederAllocBp;
}

/// @notice Packed storage layout for lottery configuration — 4 slots instead of the 9 used
///         by the ABI-facing `Lottery` struct.
/// @dev Used only for `_lotteries[lotteryId]` storage on manager contracts; all external
///      views (`getLottery`, `getLotteryBatch`) unpack into `Lottery` / `LotteryParams`,
///      so the public ABI is unchanged.
///
///      Field bounds (validated at creation in `_checkBase` / write helpers):
///        • `feeBp`, `feederAllocBp` ≤ 10_000 → uint16.
///        • `payoutRateBp` ≤ type(uint32).max (multipliers up to ~429,496x).
///        • `startTime` / `endTime` as uint40 (valid past year 36_000).
///        • `ticketPrice` as uint128, `cltAmountPerTicket` as uint96.
///        • `feederSuperLotteryId` as uint64.
///
///      Slot layout:
///        slot 0: creator (160) | kind (8) | model (8) | feeBp (16) | feederAllocBp (16) | maxTickets (24)
///        slot 1: asset (160) | startTime (40) | endTime (40)
///        slot 2: ticketPrice (128) | cltAmountPerTicket (96) | payoutRateBp (32)
///        slot 3: feederSuperLotteryId (64)
struct LotteryStored {
    /// @dev Address that may claim the creator fee (USER) or protocol fee recipient.
    address creator;
    /// @dev USER, REGULAR, SUPER, or BATTLE.
    LotteryKind kind;
    /// @dev MULTIPLIER, TIER, or WIN_RATE.
    PayoutModel model;
    /// @dev Creator / protocol fee in basis points (≤ 10_000).
    uint16 feeBp;
    /// @dev REGULAR feeders: share of gross forwarded to the SUPER pool (≤ 10_000).
    uint16 feederAllocBp;
    /// @dev Maximum tickets that may be sold.
    uint24 maxTickets;
    /// @dev ERC-20 accepted for ticket payment.
    address asset;
    /// @dev Unix timestamp when sales may begin.
    uint40 startTime;
    /// @dev Unix timestamp when the sale window ends (unless sold out earlier).
    uint40 endTime;
    /// @dev Price per ticket in `asset` smallest units.
    uint128 ticketPrice;
    /// @dev CLT credited per ticket for mission rewards (REGULAR only; `0` otherwise).
    uint96 cltAmountPerTicket;
    /// @dev Model-specific rate: multiplier BP, win-rate BP, or `0` for TIER.
    uint32 payoutRateBp;
    /// @dev Target SUPER lottery ID when this REGULAR lottery feeds a super pool (`0` if none).
    uint64 feederSuperLotteryId;
}

/// @notice ABI-safe snapshot of runtime lottery state (no nested mappings).
/// @dev Used for external reads and indexing. Referrer balances are **not** stored in
///      `LotteryState`; `referrerFees` here is a convenience field when a view helper
///      aggregates `refFees` for display. Claim progress uses `claimedPrizePool` vs `prizePool`.
///      Per-winner claim bits live in `LotteryState.claimedWords` — query via winner views.
struct LotteryStateView {
    /// @dev Effective status; may match virtual `getLotteryStatus` output.
    LotteryStatus status;
    /// @dev Deadline for VRF fulfillment after `requestDraw`; once passed, `requestDraw` may retry.
    uint64 drawDeadline;
    /// @dev Current draw generation; incremented on every new VRF request. Exposed for monitoring.
    uint32 drawGeneration;
    /// @dev Normalised VRF seed; `0` until the draw completes.
    uint256 seed;
    /// @dev Optional aggregate of referrer fee liability for this lottery (not in base storage).
    uint256 referrerFees;
    /// @dev Accrued creator fee balance (USER lotteries); claimable post-draw.
    uint256 creatorFees;
    /// @dev Frozen distributable prize pool snapshot (excludes fee slices taken at purchase).
    uint256 prizePool;
    /// @dev Cumulative amount already paid to winners.
    uint256 claimedPrizePool;
    /// @dev Remaining winner liability: `prizePool - claimedPrizePool`.
    uint256 currentPrizePool;
}

/// @notice Per-lottery mutable state on the creator contract.
/// @dev Contains `claimedWords` mapping — must be read via storage, not copied to memory.
///      `prizePool` is frozen at draw time for winner math; claims increment `claimedPrizePool`
///      without shrinking `prizePool`.
///
/// Storage packing (slot 0): `status` (1 byte) + `drawDeadline` (8 bytes) + `drawGeneration` (4 bytes) = 13 bytes.
struct LotteryState {
    /// @dev Stored lifecycle phase (may differ from virtual status returned by views).
    LotteryStatus status;
    /// @dev VRF callback deadline; `0` until a draw is requested.
    uint64 drawDeadline;
    /// @dev Monotonic counter incremented on every new VRF request (first draw or retry).
    ///      Stored in each PendingRequest; RndConsumer compares on callback to detect stale
    ///      responses from superseded or rotated-away requests. `0` until first requestDraw.
    uint32 drawGeneration;
    /// @dev Draw seed; `0` means draw not completed.
    uint256 seed;
    /// @dev USER lottery creator fee pot; cleared on `claimCreatorFee`.
    uint256 creatorFees;
    /// @dev Net prize pool base for `_calcPrize` / `_countWinners`; increased on ticket sales and donations.
    uint256 prizePool;
    /// @dev Running total of prizes transferred to winners.
    uint256 claimedPrizePool;
    /// @dev Bitmap of claimed winner slots: `wordIndex = winnerIndex >> 8`, bit `winnerIndex & 255`.
    mapping(uint256 wordIndex => uint256 bits) claimedWords;
}
