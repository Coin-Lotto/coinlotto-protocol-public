// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title CoinLotto Protocol
 * @notice Autonomous smart contract for creating and participating in user-created token-based lotteries.
 *
 * @dev This contract is decentralized software and executes according to its immutable
 * or governance-defined logic. Game parameters are defined by their creators.
 *
 * The protocol does not take custody of assets outside the contract logic,
 * does not make decisions on behalf of users, and does not guarantee
 * any outcome, availability, or financial return.
 *
 * Users are solely responsible for:
 * - evaluating lottery parameters;
 * - complying with applicable laws and regulations in their jurisdiction;
 * - verifying supported ERC-20 tokens before participating;
 * - understanding the risks associated with blockchain transactions.
 *
 * THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTIES OF ANY KIND,
 * EXPRESS OR IMPLIED.
 */

import {BaseLotteryManager} from "./abstract/BaseLotteryManager.sol";
import {RegularMissionModule} from "./abstract/RegularMissionModule.sol";
import {FeederAccounting} from "./abstract/FeederAccounting.sol";
import {ReferrerFeeLedger} from "./abstract/ReferrerFeeLedger.sol";
import {ProtocolManagerLib} from "./libraries/ProtocolManagerLib.sol";

import {LotteryStored, LotteryState, LotteryStatus, LotteryKind, LotteryParams, PayoutModel} from "./structs/MetadataStruct.sol";
import {TicketPurchaseQuote} from "./structs/TicketPurchaseQuote.sol";
import {ICltRewardPool} from "./interfaces/ICltRewardPool.sol";
import {ICltRewarder} from "./interfaces/ICltRewarder.sol";
import {IProtocolLotteryFeederSupport} from "./interfaces/IProtocolLotteryFeederSupport.sol";

/// @title ProtocolLotteryManager
/// @notice Manager for `LotteryKind.REGULAR` and `LotteryKind.SUPER` (shared storage).
/// @dev REGULAR and SUPER must live in one contract so `FeederAccounting` and SUPER prize
///      pools stay in a single storage domain. Hub routes both kinds via `REGULAR_LOTTERY`.
///
///      Hub-pull purchase:
///        REGULAR — ERC-20 payment: treasury, prize pool, referrer share, optional SUPER feeder.
///        SUPER   — CLT only: `cltToTreasury` / `cltToBank` (prize pool fed by REGULAR feeders).
///
///      `extraData` encoding for `LotteryHub.createLottery` (`REGULAR_LOTTERY`):
///
///        REGULAR + MULTIPLIER:
///          `abi.encode(uint256 multiplierBp, uint256 superLotteryId, uint256 allocBp, uint256 cltPerTicket)`
///        REGULAR + TIER:
///          `abi.encode(uint16[] tiers, uint256 superLotteryId, uint256 allocBp, uint256 cltPerTicket)`
///        REGULAR + WIN_RATE:
///          `abi.encode(uint256 winRateBp, uint256 superLotteryId, uint256 allocBp, uint256 cltPerTicket)`
///        SUPER + TIER:       `abi.encode(uint16[] tiers)`
///        SUPER + WIN_RATE:   `abi.encode(uint256 winRateBp)`
///        SUPER + MULTIPLIER: not supported (`SuperMultiplierNotSupported`)
///
///      Feeder fields: `superLotteryId == 0` means no SUPER link; `allocBp` and `cltPerTicket`
///      apply only when linking. Hub enforces same creator for REGULAR and linked SUPER IDs.
///
///      Access control:
///        • `HUB_ROLE` — Hub-only create/register/draw (from `BaseLotteryCreator`).
///        • `REGULAR_OPERATOR_ROLE` — required on `user` at creation.
///        • `WORKER_ROLE` — protocol fee, CLT, treasury, duration limits.
///
///      Implements `IRegularMissionModule` for `CltMissions` eligibility on REGULAR tickets.
contract ProtocolLotteryManager is
    RegularMissionModule,
    FeederAccounting,
    ReferrerFeeLedger,
    IProtocolLotteryFeederSupport
{
    /* ─────────────────────────────────────── Roles ──────────────────────────── */

    /// @notice Role required on `user` in `createLotteryFromHub`.
    bytes32 public constant REGULAR_OPERATOR_ROLE = keccak256("REGULAR_OPERATOR_ROLE");

    /// @notice Role granted to external feeder managers (e.g. `ProtocolDuelLotteryManager`).
    bytes32 public constant EXTERNAL_FEEDER_ROLE = keccak256("EXTERNAL_FEEDER_ROLE");

    /* ─────────────────────────────────────── Limits ─────────────────────────── */

    /// @notice Maximum `cltTreasuryLimitBp` admin setting.
    uint256 internal constant MAX_TREASURY_LIMIT_BP = 1000;

    /// @notice Maximum `cltProtocolFeeBp` admin setting.
    uint256 internal constant MAX_PROTOCOL_FEE_BP = 1000;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    ICltRewarder public rewarder;

    /// @notice Treasury for protocol and CLT fee slices.
    address public treasury;

    /// @notice `CltRewardPool` receiving SUPER ticket CLT proceeds.
    address public rewardPool;

    /// @notice CLT token for cap checks and referrer bonus denomination.
    address public cltToken;

    /// @notice Cap on `cltPerTicket` at REGULAR creation; 0 = unlimited.
    uint256 public cltTicketRewardLimit;

    /// @notice Max `params.duration` for REGULAR lotteries.
    uint64 public maxDurationRegular;

    /// @notice Max `params.duration` for SUPER lotteries.
    uint64 public maxDurationSuper;

    /// @notice CLT supply share above which SUPER sales skip treasury CLT fee.
    uint16 public cltTreasuryLimitBp;

    /// @notice CLT protocol fee BP on SUPER tickets when under treasury cap.
    uint16 public cltProtocolFeeBp;

    /// @notice CLT bonus to buyer (stored as referrer fee on buyer) when referred on REGULAR buy.
    uint16 public cltReferrerBonusBp;

    /// @notice Cap on `params.feeBp` at lottery creation; 0 = unlimited.
    uint16 public protocolFeeLimitBp;

    /// @notice Cap on feeder `allocBp`; 0 = unlimited.
    uint16 public superLotteryAllocationLimitBp;

    /// @dev SUPER lottery ID → ERC-20 prize asset set by first feeder (`params.asset` of that REGULAR).
    mapping(uint256 superId => address prizeAsset) private _superPrizeAsset;

    /// @dev Aggregate outstanding (not-yet-withdrawn) user donations credited to each SUPER lottery.
    ///      Mirrors the sum of all `_donations[superId][donor]` entries that have not yet been withdrawn.
    ///      Invariant: `_state[superId].prizePool >= _superDonationBalance[superId]` at all times.
    ///      The gap `prizePool - _superDonationBalance` equals the total feeder funds currently in the pool.
    mapping(uint256 superId => uint256 donationBalance) private _superDonationBalance;

    /* ─────────────────────────────────────── Events ─────────────────────────── */
    event TreasurySet(address indexed addr);
    event CltTokenSet(address indexed addr);
    event RewardPoolSet(address indexed addr);
    event CltTreasuryLimitBpSet(uint256 value);
    event CltProtocolFeeBpSet(uint256 value);
    event CltReferrerBonusBpSet(uint256 value);
    event SuperLotteryAllocationLimitBpSet(uint16 indexed value);
    event ProtocolFeeLimitBpSet(uint16 indexed value);
    event CltTicketRewardLimitSet(uint256 indexed value);
    event MaxDurationRegularSet(uint64 indexed value);
    event MaxDurationSuperSet(uint64 indexed value);

    /// @notice Emitted when a REGULAR lottery is linked as a SUPER feeder.
    event FeederLinked(uint256 indexed regularId, uint256 indexed superId, uint256 allocBp);

    /// @notice Emitted when feeder proceeds increase a SUPER prize pool.
    event FeederFundsForwarded(uint256 indexed regularId, uint256 indexed superId, uint256 amount);

    /// @notice Emitted when a REGULAR purchase would have fed a SUPER pool but the SUPER no longer accepts funding.
    event FeederFundsSkipped(uint256 indexed regularId, uint256 indexed superId, uint256 skippedFeederAmount);

    /// @notice Emitted when an admin recovers stranded feeder funds from a zero-ticket expired SUPER lottery.
    event StrandedFundsRecovered(uint256 indexed superId, address indexed recipient, uint256 amount);

    event CltReferrerBonusAdded(uint256 indexed lotteryId, address indexed referrer, uint256 amount, address buyer);

    event CltUserPerTicketRewardAdded(uint256 indexed lotteryId, address indexed user, uint256 amount);

    event RewarderSet(address indexed rewarder);
    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when `kind` is not REGULAR or SUPER.
    error OnlyRegularOrSuper();

    /// @notice Thrown when `payoutModel` is not supported for the given `kind`.
    error UnsupportedPayoutModel();

    /// @notice Thrown when a feeder SUPER ID is zero, wrong kind, or missing.
    error InvalidSuperLotteryId();

    /// @notice Thrown when `claimCltReward` has zero computed CLT for the caller.
    error NoCltReward();

    /// @notice Thrown when per-ticket CLT was already claimed for this user/lottery.
    error CltRewardAlreadyClaimed();

    /// @notice Thrown when `user` lacks {REGULAR_OPERATOR_ROLE}.
    error NotAuthorizedToCreateRegularLottery();

    /// @notice Thrown when a feeder ERC-20 does not match the SUPER prize asset.
    error MismatchEntryToken();

    /// @notice Thrown when donating to a SUPER lottery before a feeder defines its prize asset.
    error SuperPrizeAssetNotSet();

    /// @notice Thrown when a SUPER ticket is purchased while the feeder-funded prize pool is still zero.
    error SuperPrizePoolEmpty(uint256 lotteryId);

    /// @notice Thrown when SUPER lottery creation uses MULTIPLIER payout model.
    error SuperMultiplierNotSupported();

    /// @notice Thrown when a REGULAR lottery ends after its linked SUPER lottery.
    error FeederShouldEndBeforeSuper();

    /// @notice Thrown when ticketPrice * feederAllocBp < BP_DENOMINATOR so a 1-ticket purchase
    ///         would produce feederAmount == 0 and never fund the linked SUPER prize pool.
    error FeederZeroPerTicket();

    /// @notice Thrown when fee and alloc exceed gross.
    error FeeAndAllocExceedGross();

    /// @notice Thrown when prize floor is too low.
    error PrizeFloorTooLow();

    /// @notice Thrown when the linked SUPER has feeBp == BP_DENOMINATOR; 100% fee would consume
    ///         every feeder unit leaving netFeeder == 0.
    error SuperFeeConsumesFeeder();

    /// @notice Thrown when `cltTicketRewardLimit` admin cap is exceeded.
    error ExceedsCltTicketRewardLimit();

    /// @notice Thrown when `cltTreasuryLimitBp` exceeds {MAX_TREASURY_LIMIT_BP}.
    error InvalidCltTreasuryLimitBp();

    /// @notice Thrown when `cltProtocolFeeBp` exceeds {MAX_PROTOCOL_FEE_BP}.
    error InvalidProtocolFee();

    /// @notice Thrown when `cltReferrerBonusBp` exceeds `BP_DENOMINATOR`.
    error InvalidCltReferrerBonus();

    /// @notice Thrown when a SUPER lottery is created with a non-CLT asset.
    error SuperOnlyWithCltAsset();

    /// @dev Thrown when a feeder lottery is created linked to a SUPER that is no longer accepting feeders
    ///      (i.e. DRAW_REQUESTED, DRAW_COMPLETED, or FULLY_CLAIMED).
    error SuperLotteryNotAcceptingFeeders();

    /// @notice Thrown by `recoverStrandedFunds` when the SUPER is not in a recoverable state
    ///         (must be expired with zero CLT tickets sold).
    error NotRecoverable();

    /// @notice Thrown by `recoverStrandedFunds` when there are no stranded feeder funds to recover
    ///         (the entire prizePool is accounted for by outstanding donor liabilities).
    error NothingToRecover();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @param initialDefaultAdmin `DEFAULT_ADMIN_ROLE` holder.
    /// @param hub_                `LotteryHub` (`HUB_ROLE`).
    ///                            RndConsumer is wired post-deploy via `setRndConsumer`.
    constructor(address initialDefaultAdmin, address hub_) BaseLotteryManager(initialDefaultAdmin, hub_) {
        _grantRole(WORKER_ROLE, msg.sender);
    }

    /* ─────────────────────────── Configuration (WORKER_ROLE) ────────────────── */

    function setSuperLotteryAllocationLimitBp(uint16 newAllocationLimitBp) external onlyRole(WORKER_ROLE) {
        if (newAllocationLimitBp > MAX_ALLOCATION_BP) revert InvalidAllocation();
        superLotteryAllocationLimitBp = newAllocationLimitBp;
        emit SuperLotteryAllocationLimitBpSet(newAllocationLimitBp);
    }

    /// @notice Sets max `params.feeBp` for new REGULAR/SUPER lotteries.
    function setProtocolFeeProtocolLotteriesLimitBp(uint16 newProtocolFeeLimitBp) external onlyRole(WORKER_ROLE) {
        if (newProtocolFeeLimitBp > MAX_FEE_LIMIT_BP) revert InvalidCreatorCommission();
        protocolFeeLimitBp = newProtocolFeeLimitBp;
        emit ProtocolFeeLimitBpSet(newProtocolFeeLimitBp);
    }

    /// @notice Sets max `cltPerTicket` for new REGULAR lotteries.
    function setCltTicketRewardLimit(uint256 newCltTicketRewardLimit) external onlyRole(WORKER_ROLE) {
        if (newCltTicketRewardLimit > MAX_CLT_PER_TICKET) revert ExceedsCltTicketRewardLimit();
        cltTicketRewardLimit = newCltTicketRewardLimit;
        emit CltTicketRewardLimitSet(newCltTicketRewardLimit);
    }

    function setMaxDurationRegular(uint64 newDuration) external onlyRole(WORKER_ROLE) {
        if (newDuration == 0) revert InvalidAmount();
        maxDurationRegular = newDuration;
        emit MaxDurationRegularSet(newDuration);
    }

    function setMaxDurationSuper(uint64 newDuration) external onlyRole(WORKER_ROLE) {
        if (newDuration == 0) revert InvalidAmount();
        maxDurationSuper = newDuration;
        emit MaxDurationSuperSet(newDuration);
    }

    function setTreasury(address treasury_) external onlyRole(WORKER_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setCltToken(address cltToken_) external onlyRole(WORKER_ROLE) {
        if (cltToken_ == address(0)) revert ZeroAddress();
        cltToken = cltToken_;
        emit CltTokenSet(cltToken_);
    }

    function setRewardPool(address rewardPool_) external onlyRole(WORKER_ROLE) {
        if (rewardPool_ == address(0)) revert ZeroAddress();
        rewardPool = rewardPool_;
        emit RewardPoolSet(rewardPool_);
    }

    function setCltTreasuryLimitBp(uint16 cltTreasuryLimitBp_) external onlyRole(WORKER_ROLE) {
        if (cltTreasuryLimitBp_ > MAX_TREASURY_LIMIT_BP) revert InvalidCltTreasuryLimitBp();
        cltTreasuryLimitBp = cltTreasuryLimitBp_;
        emit CltTreasuryLimitBpSet(cltTreasuryLimitBp_);
    }

    function setCltProtocolFeeBp(uint16 cltProtocolFeeBp_) external onlyRole(WORKER_ROLE) {
        if (cltProtocolFeeBp_ > MAX_PROTOCOL_FEE_BP) revert InvalidProtocolFee();
        cltProtocolFeeBp = cltProtocolFeeBp_;
        emit CltProtocolFeeBpSet(cltProtocolFeeBp_);
    }

    function setCltReferrerBonusBp(uint16 cltReferrerBonusBp_) external onlyRole(WORKER_ROLE) {
        if (cltReferrerBonusBp_ > BP_DENOMINATOR) revert InvalidCltReferrerBonus();
        cltReferrerBonusBp = cltReferrerBonusBp_;
        emit CltReferrerBonusBpSet(cltReferrerBonusBp_);
    }

    function setRewarder(address rewarder_) external onlyRole(WORKER_ROLE) {
        if (rewarder_ == address(0)) revert ZeroAddress();
        rewarder = ICltRewarder(rewarder_);
        emit RewarderSet(rewarder_);
    }

    /* ─────────────────────────── FeederAccounting hooks ─────────────────────── */

    function _getFeederSuperId(uint256 _regularId) internal view override returns (uint256) {
        return _lotteries[_regularId].feederSuperLotteryId;
    }

    function _getFeederAllocBp(uint256 _regularId) internal view override returns (uint256) {
        return _lotteries[_regularId].feederAllocBp;
    }

    /// @dev `allocBp` ≤ 10_000 is enforced by `_registerFeeder`, so the uint16 cast is safe.
    function _writeFeederLink(uint256 _regularId, uint256 _superId, uint256 _allocBp) internal override {
        if (_superId > type(uint64).max) revert InvalidSuperLotteryId();
        _lotteries[_regularId].feederSuperLotteryId = uint64(_superId);
        _lotteries[_regularId].feederAllocBp = uint16(_allocBp);
    }

    /* ─────────────────────────── ILotteryCreator — creation ───────────────────── */

    /// @inheritdoc BaseLotteryManager
    function createLotteryFromHub(
        uint256 lotteryId,
        address user,
        LotteryKind kind,
        PayoutModel payoutModel,
        LotteryParams calldata params,
        bytes calldata extraData
    ) external override onlyHub {
        if (!hasRole(REGULAR_OPERATOR_ROLE, user)) revert NotAuthorizedToCreateRegularLottery();

        (bool feederLinked, uint64 linkedSuperId, uint16 linkedAllocBp) = ProtocolManagerLib.createLottery(
            _lotteries,
            _state,
            _lTiers,
            _superPrizeAsset,
            _lotteryIndex,
            lotteryId,
            user,
            kind,
            payoutModel,
            params,
            extraData,
            ProtocolManagerLib.CreateCfg({
                durLimit: kind == LotteryKind.REGULAR ? maxDurationRegular : maxDurationSuper,
                protocolFeeLimitBp: protocolFeeLimitBp,
                cltToken: cltToken,
                cltTicketRewardLimit: cltTicketRewardLimit,
                superAllocLimitBp: superLotteryAllocationLimitBp,
                minMultBp: minimumMultiplierBp,
                maxMultBp: maximumMultiplierBp,
                minWinRateBp: minimumWinRateBp,
                maxWinRateBp: maximumWinRateBp,
                maxTiers: maximumTiers
            })
        );

        if (feederLinked) emit FeederLinked(lotteryId, linkedSuperId, linkedAllocBp);
        emit LotteryCreated(lotteryId, user, kind, payoutModel);
    }

    /* ─────────────────────────── ILotteryCreator — Hub-pull purchase ─────────── */

    /// @inheritdoc BaseLotteryManager
    function quoteTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address referrer
    ) external view override returns (TicketPurchaseQuote memory quote) {
        return
            ProtocolManagerLib.quote(
                _lotteries,
                _state,
                _lotteryIndex,
                lotteryId,
                qty,
                referrer,
                treasury,
                protocolFeeRevenueShareBp,
                cltToken,
                cltTreasuryLimitBp,
                cltProtocolFeeBp,
                rewardPool
            );
    }

    /// @inheritdoc BaseLotteryManager
    /// @dev No local reentrancy guard: Hub-only entrypoint and the Hub's `buyTickets` is guarded.
    ///      Requires an open Hub settlement (`openHubSettlement`) and closes it as its last step,
    ///      so the settlement spans the external `rewarder` call in REGULAR accounting.
    function registerTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address ticketRecipient,
        address buyer,
        address referrer,
        TicketPurchaseQuote calldata quote
    ) external override onlyHub {
        LotteryKind kind = _lotteries[lotteryId].kind;
        if (kind == LotteryKind.SUPER) {
            // Draw-phase statuses are already rejected by `_validatePurchase` inside
            // `_executeTicketPurchase` (same `LotteryNotActive` error), so only the
            // prize-pool funding invariant needs an explicit check here.
            _requireSuperPrizePoolFunded(lotteryId);
        }

        _executeTicketPurchase(lotteryId, qty, ticketRecipient);

        if (kind == LotteryKind.REGULAR) {
            _registerRegularState(lotteryId, qty, buyer, referrer, quote, ticketRecipient);
        }

        _closeHubSettlement();
    }

    /* ─────────────────────────── Feeder guards ────────────────────────────────── */

    /// @dev SUPER CLT ticket sales require a feeder-funded USDT prize pool.
    function _requireSuperPrizePoolFunded(uint256 _lotteryId) private view {
        if (_state[_lotteryId].prizePool == 0) revert SuperPrizePoolEmpty(_lotteryId);
    }

    /* ─────────────────────────── Register state ───────────────────────────────── */

    /// @dev Updates REGULAR pools, CLT rewards, referrer fee, and SUPER feeder prize after
    ///      Hub transfers. The feeder link is resolved from this manager's own storage
    ///      (validated at creation), so the quote does not carry `superLotteryId` across the
    ///      Hub boundary. Body lives in `ProtocolManagerLib.registerRegularState`.
    function _registerRegularState(
        uint256 _lotteryId,
        uint256 _qty,
        address _buyer,
        address _referrer,
        TicketPurchaseQuote calldata _quote,
        address _recipient
    ) private {
        ProtocolManagerLib.registerRegularState(
            _lotteries,
            _state,
            _lotteryIndex,
            refFees,
            _lotteryId,
            _qty,
            _buyer,
            _referrer,
            _quote,
            _recipient,
            cltReferrerBonusBp,
            address(rewarder)
        );
    }

    /* ─────────────────────────── Prize asset ──────────────────────────────────── */

    /// @dev SUPER prizes pay in feeder ERC-20, not ticket CLT.
    function _prizeAsset(uint256 _lotteryId) internal view override returns (address) {
        if (_lotteries[_lotteryId].kind == LotteryKind.SUPER) {
            address pa = _superPrizeAsset[_lotteryId];
            if (pa != address(0)) return pa;
        }
        return super._prizeAsset(_lotteryId);
    }

    /// @dev SUPER donations accept only the feeder-defined prize ERC-20, not CLT ticket payments.
    function _donationAsset(uint256 _lotteryId) internal view override returns (address) {
        if (_lotteries[_lotteryId].kind == LotteryKind.SUPER) {
            address pa = _superPrizeAsset[_lotteryId];
            if (pa == address(0)) revert SuperPrizeAssetNotSet();
            return pa;
        }
        return super._donationAsset(_lotteryId);
    }

    /* ─────────────────────────── External feeder support ────────────────────── */

    /// @inheritdoc IProtocolLotteryFeederSupport
    function forwardExternalFeederFunds(
        uint256 feederLotteryId,
        uint256 superLotteryId,
        uint256 amount,
        address token
    ) external onlyRole(EXTERNAL_FEEDER_ROLE) returns (bool forwarded) {
        // Accounting only — caller is responsible for transferring `amount` of `token` to this
        // contract after this call returns true (push pattern; no transferFrom needed).
        return
            ProtocolManagerLib.forwardExternalFeeder(
                _lotteries,
                _state,
                _lotteryIndex,
                _superPrizeAsset,
                feederLotteryId,
                superLotteryId,
                amount,
                token
            );
    }

    /// @inheritdoc IProtocolLotteryFeederSupport
    function getSuperFeederContext(
        uint256 superLotteryId
    ) external view returns (uint16 superFeeBp, bool acceptsFeeding, address prizeAsset, uint64 superEndTime) {
        return
            ProtocolManagerLib.superFeederContext(_lotteries, _state, _lotteryIndex, _superPrizeAsset, superLotteryId);
    }

    /* ─────────────────────────── SUPER donation accounting ─────────────────── */

    /// @dev Maintains `_superDonationBalance` for SUPER lotteries so that `recoverStrandedFunds`
    ///      can compute the feeder-only portion of the prizePool without a hot-path SSTORE.
    ///      USER and REGULAR lotteries take the base path with zero extra cost.
    function _recordDonation(uint256 _lotteryId, address _donor, uint256 _amount) internal override {
        if (_lotteries[_lotteryId].kind == LotteryKind.SUPER) _superDonationBalance[_lotteryId] += _amount;
        super._recordDonation(_lotteryId, _donor, _amount);
    }

    /// @dev Mirrors `_recordDonation`: decrements `_superDonationBalance` before the base
    ///      implementation zeroes `_donations[lotteryId][donor]`.
    ///      `_donations` is `internal` in `BaseLotteryManager` and accessible here.
    function _executeDonationWithdrawal(uint256 _lotteryId, address _donor) internal override {
        if (_lotteries[_lotteryId].kind == LotteryKind.SUPER) {
            uint256 amount = _donations[_lotteryId][_donor]; // read before base zeroes it
            if (amount > 0) _superDonationBalance[_lotteryId] -= amount;
        }
        super._executeDonationWithdrawal(_lotteryId, _donor);
    }

    /* ─────────────────────────── Stranded feeder recovery ───────────────────── */

    /// @notice Finalizes a zero-ticket expired SUPER lottery and recovers any feeder funds it holds.
    ///
    /// @dev **Background:** Feeder funds from REGULAR ticket purchases are credited directly to
    ///      `_state[superId].prizePool`, bypassing `_donations`. When a SUPER expires with zero
    ///      CLT tickets sold those funds have no recovery path:
    ///        - Stored PENDING + expired → dynamic CANCELLED: `requestDraw` reverts `NotReadyToDraw`.
    ///        - Stored ACTIVE + expired + 0 CLT sold → dynamic CANCELLED: `requestDraw` reverts `NotReadyToDraw`.
    ///        - `withdrawDonation` always reverts `NoDonation` for feeder amounts.
    ///
    /// @dev **Eligibility:** Both conditions are checked directly and explicitly:
    ///      (a) `block.timestamp > endTime`  — sale period has expired.
    ///      (b) `_sold(superId) == 0`        — no CLT tickets were ever sold.
    ///      Lotteries that entered a draw/claim lifecycle are excluded regardless.
    ///
    /// @dev **Accounting model:**
    ///      `prizePool = feederFunds + outstandingDonations`
    ///      `recoverableAmount = prizePool - _superDonationBalance[superId]`
    ///      After recovery: `prizePool == _superDonationBalance[superId]`
    ///      → every outstanding donor is fully backed and can still call `withdrawDonation`.
    ///
    /// @dev **Finalization:** Stored CANCELLED is written unconditionally (when not already stored)
    ///      so that both feeder-acceptance gates immediately reject further credits even when
    ///      there are no feeder funds to transfer (all-donations SUPER).
    ///      `_checkDonateAllowed` also blocks new donations once stored CANCELLED.
    ///      `_checkWithdrawDonationAllowed` still allows outstanding donor withdrawals.
    ///
    ///      `NothingToRecover` is only thrown when the SUPER is already stored CANCELLED
    ///      (finalized in a prior call) **and** `recoverableAmount == 0`.
    ///
    /// @param superId   SUPER lottery to finalize and recover feeder funds from.
    /// @param recipient Address to receive the recovered feeder amount (if any).
    function recoverStrandedFunds(uint256 superId, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ProtocolManagerLib.recoverStranded(
            _lotteries,
            _state,
            _lotteryIndex,
            _superDonationBalance,
            _superPrizeAsset,
            superId,
            recipient
        );
    }
}
