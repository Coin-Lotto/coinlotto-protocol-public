// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title TicketPurchaseQuote
/// @notice Payment breakdown for a ticket purchase in the Hub-pull flow.
/// @dev Produced by `ILotteryManager.quoteTicketPurchase` and consumed unchanged by
///      `registerTicketPurchase` after the Hub executes transfers.
///
///      **Hub flow**
///        1. Hub calls `quoteTicketPurchase` (view).
///        2. Hub `safeTransferFrom` buyer → `treasuryDest` / creator / CLT bank per quote.
///        3. Hub calls `registerTicketPurchase` with the same struct (no transfers inside creator).
///
///      **Accounting invariants** (enforced by creator implementations)
///        • Creator leg pulled by the Hub == `prizeAmount + refShare + netFeeder + creatorFee`.
///        • Total ERC-20 debited from the buyer == `toTreasury` + creator leg.
///        • CLT leg is orthogonal: `cltToBank` + `cltToTreasury` when `cltPayment == true`.
///
///      Derivable aggregates (`totalCost`, `toCreator`) and manager-local routing data
///      (`superLotteryId`, `superProtocolFee`) are intentionally not part of the struct:
///      the Hub recomputes the creator leg from the component fields and managers resolve
///      feeder links from their own storage, keeping the ABI payload minimal.
struct TicketPurchaseQuote {
    /* ── ERC-20 ticket payment (USER / REGULAR; SUPER prize pool asset) ─────── */

    /// @dev Ticket payment token (`Lottery.params.asset` or hub-configured treasury token).
    address token;
    /// @dev Protocol / revenue share sent to treasury.
    uint256 toTreasury;
    /// @dev Recipient of `toTreasury` (treasury or protocol address).
    address treasuryDest;

    /* ── Fields applied in registerTicketPurchase (no second pricing pass) ─── */

    /// @dev Portion of the creator leg added to `_state[lotteryId].prizePool`.
    uint256 prizeAmount;
    /// @dev Referrer share accrued in `refFees[referrer][token]` (post-draw claim via Hub).
    uint256 refShare;
    /// @dev Feeder share credited to the linked SUPER prize pool (REGULAR → SUPER).
    uint256 netFeeder;
    /// @dev USER only: slice added to `_state[lotteryId].creatorFees`; `0` for REGULAR/SUPER.
    uint256 creatorFee;

    /* ── CLT ticket path (SUPER lotteries) ─────────────────────────────────── */

    /// @dev `true` when ticket price is paid in CLT (`LotteryKind.SUPER`).
    bool cltPayment;
    /// @dev CLT token address when `cltPayment`.
    address cltToken;
    /// @dev CLT reward pool recipient when `cltPayment`.
    address rewardPoolDest;
    /// @dev CLT amount routed to the bank (mission / protocol sink).
    uint256 cltToBank;
    /// @dev CLT amount routed to treasury when under the configured cap.
    uint256 cltToTreasury;

    /* ── CLT buyer per-ticket reward (REGULAR) ─────────────────────────────── */

    /// @dev Total CLT credited to the buyer for this purchase (`cltAmountPerTicket × qty`).
    ///      NOT the flat referrer welcome bonus (type-1), which is a fixed per-new-referral
    ///      amount set on `CltRewarder` and independent of this value.
    uint256 cltLotteryReward;

    /// @dev `true` when the lottery is a USER lottery.
    bool isUserLottery;
}
