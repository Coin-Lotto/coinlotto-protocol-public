// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ICltRewarder
/// @notice CLT reward ledger wired from `LotteryHub` and creator contracts.
/// @dev Three independent flows:
///      1. **Referrer welcome bonus** — `addCltReferreWelcomeBonus` / `claimReferrerBonus`
///         (flat bonus when an invited user is linked for the first time).
///      2. **Per-lottery referrer CLT** — accrued via `addCltPurchaseRewards`, claimed with
///         `claimCltLotteryReferrerReward` / `claimCltLotteryReferrerRewardBatch`.
///      3. **Per-lottery buyer CLT** — accrued via `addCltPurchaseRewards`, claimed with
///         `claimCltPerTicketReward` / `claimCltPerTicketRewardBatch`.
///      Hub calls `addCltReferreWelcomeBonus` when `buyTickets` establishes a new referral (`isNew`).
interface ICltRewarder {
    /// @notice Credits the configured referrer welcome bonus to `referrer` for `user`'s first qualifying purchase.
    /// @dev **Caller:** `REWARD_OPERATOR_ROLE` (Hub).
    ///      **Return semantics (evaluated in order):**
    ///        - Global `_welcomeBonusCredited[user]` already `true` → no credit, returns `true` (Hub closes local gate).
    ///        - `referrerWelcomeBonus == 0` → no credit, returns `false` (Hub leaves local gate open; eligibility preserved).
    ///        - First real credit → marks global flag (CEI), increments `_pendingCltWelcomeBonus[referrer]`, returns `true`.
    ///      **Selector:** unchanged (`void → bool` does not affect the 4-byte selector).
    ///      **State:** Sets `_welcomeBonusCredited[user]` and increments `_pendingCltWelcomeBonus[referrer]` on first credit.
    ///      **Events:** `CltReferrerWelcomeBonusAdded` on first credit only.
    /// @param referrer Referrer receiving the welcome bonus.
    /// @param lotteryId Lottery in which the qualifying purchase occurred.
    /// @param user      Buyer whose eligibility is checked and marked.
    /// @return closeGate `true` when the Hub should close its local `_welcomeBonusCredited` cache for `user`;
    ///         `false` when the bonus is disabled and the Hub must leave the gate open.
    function addCltReferreWelcomeBonus(address referrer, uint256 lotteryId, address user) external returns (bool);

    /// @notice Returns whether `user` has ever had the referrer welcome bonus credited globally.
    /// @dev Persists across Hub migrations — stored in `CltRewarder`, not in Hub.
    ///      Not called in the `buyTickets` hot path; provided for off-chain queries and Hub getter delegation.
    function isWelcomeBonusCredited(address user) external view returns (bool);

    /// @notice Returns unclaimed referrer welcome bonus for `referrer`.
    function getCltWelcomeBonusAmount(address referrer) external view returns (uint256);

    /// @notice Claims all unclaimed referrer welcome bonus for `msg.sender`.
    /// @dev **Caller:** referrer with a balance.
    ///      **Validations:** Reverts `NoCltReward` when balance zero.
    ///      **State:** Clears pending balance; pulls CLT via `ICltRewardPool`.
    ///      **Events:** `ReferrerBonusClaimed`.
    function claimReferrerBonus() external;

    /// @notice Returns sum of pending per-lottery referrer CLT for `user` across `lotteryIds`.
    /// @param lotteryIds Lottery IDs to query.
    /// @param user       Account to query.
    /// @return totalAmount Sum of pending CLT across the given lotteries.
    function getCltLotteryReferrerRewardAmount(
        uint256[] calldata lotteryIds,
        address user
    ) external view returns (uint256 totalAmount);

    /// @notice Claims per-lottery referrer CLT accrued for `msg.sender` in one lottery.
    /// @param lotteryId Lottery whose pending balance is claimed.
    function claimCltLotteryReferrerReward(uint256 lotteryId) external;

    /// @notice Claims pending referrer CLT for `msg.sender` across multiple lotteries in one bank withdrawal.
    /// @param lotteryIds Lotteries to claim; zero-balance IDs are skipped.
    function claimCltLotteryReferrerRewardBatch(uint256[] calldata lotteryIds) external;

    /// @notice Credits buyer per-ticket CLT and referrer lottery CLT in a single call.
    /// @dev Gas optimisation for the REGULAR buy path: one external call instead of two.
    ///      The two accruals remain in **separate ledgers** (`_pendingCltPerTicketReward` for
    ///      `buyer`, `_pendingCltLotteryReferrerReward` for `referrer`); zero amounts and a
    ///      zero `referrer` skip the corresponding leg without reverting.
    /// @param lotteryId      Target lottery.
    /// @param buyer          Per-ticket reward beneficiary.
    /// @param buyerAmount    CLT credited to `buyer` (0 = skip).
    /// @param referrer       Referrer reward beneficiary (zero = skip).
    /// @param referrerAmount CLT credited to `referrer` (0 = skip).
    function addCltPurchaseRewards(
        uint256 lotteryId,
        address buyer,
        uint256 buyerAmount,
        address referrer,
        uint256 referrerAmount
    ) external;

    /// @notice Returns sum of pending per-ticket buyer CLT for `user` across `lotteryIds`.
    /// @param lotteryIds Lottery IDs to query.
    /// @param user       Account to query.
    /// @return totalAmount Sum of pending CLT across the given lotteries.
    function getCltPerTicketRewardAmount(
        uint256[] calldata lotteryIds,
        address user
    ) external view returns (uint256 totalAmount);

    /// @notice Claims per-ticket buyer CLT accrued for `msg.sender` in one lottery.
    /// @dev **Validations:** Reverts `LotteryNotDrawn` when `lotteryId` status is not
    ///      `DRAW_COMPLETED` or `FULLY_CLAIMED`. Reverts `LotteryHubNotSet` when the
    ///      hub has not been configured. Reverts `NoCltReward` when balance is zero.
    /// @param lotteryId Lottery whose ticket rewards are claimed.
    function claimCltPerTicketReward(uint256 lotteryId) external;

    /// @notice Claims pending per-ticket buyer CLT for `msg.sender` across multiple lotteries in one bank withdrawal.
    /// @dev **Validations:** Reverts `LotteryHubNotSet` when the hub has not been configured.
    ///      Input IDs whose status is not `DRAW_COMPLETED` or `FULLY_CLAIMED` are omitted from processing.
    ///      Reverts `NoCltReward` when aggregate claimable amount is zero.
    ///      **Events:** `CltPerTicketRewardClaimedBatch` lists only draw-completed IDs from the input.
    /// @param lotteryIds Lotteries to attempt; non-completed IDs are skipped without revert.
    function claimCltPerTicketRewardBatch(uint256[] calldata lotteryIds) external;
}
