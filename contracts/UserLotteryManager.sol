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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLotteryManager} from "./abstract/BaseLotteryManager.sol";
import {ReferrerFeeLedger} from "./abstract/ReferrerFeeLedger.sol";

import {LotteryStored, LotteryState, LotteryStatus, LotteryKind, LotteryParams, PayoutModel} from "./structs/MetadataStruct.sol";
import {TicketPurchaseQuote} from "./structs/TicketPurchaseQuote.sol";

/// @title UserLotteryManager
/// @notice Manager module for `LotteryKind.USER` lotteries (all payout models).
/// @dev Hub integration:
///        • Creation: `createLotteryFromHub` — `onlyHub`, decodes `extraData`, emits {LotteryCreated}.
///        • Purchase: `quoteTicketPurchase` (view) + `registerTicketPurchase` (`onlyHub`, no transfers).
///        • Draw/claim: inherited `BaseLotteryManager` paths via Hub proxies.
///
///      Hub-pull payment (ERC-20 `params.asset` only; no CLT ticket path):
///        gross = qty × ticketPrice
///        treasuryFee = gross × protocolFeeUserLotteriesBp / BP
///        refShare = (referrer ≠ 0) ? treasuryFee × protocolFeeRevenueShareBp / BP : 0
///        netTreasury = treasuryFee − refShare
///        creatorFee = gross × params.feeBp / BP
///        prizeAmount = gross − treasuryFee − creatorFee
///        Hub pulls: netTreasury → treasury; (creatorFee + refShare + prizeAmount) → this contract
///
///      `extraData` encoding (pass to `LotteryHub.createLottery` with `USER_LOTTERY`):
///        • MULTIPLIER: `abi.encode(uint256 multiplierBp)`
///        • TIER:       `abi.encode(uint16[] tiers)`
///        • WIN_RATE:   `abi.encode(uint256 winRateBp)`
///
///      Access control:
///        • `HUB_ROLE` — Hub-only create/register/draw entry points (from `BaseLotteryCreator`).
///        • `WORKER_ROLE` — fee and treasury configuration.
///        • `DEFAULT_ADMIN_ROLE` — role admin (24h delay).
///
///      Does not implement `IRegularMissionModule` (no `CltMissions` eligibility on USER IDs).
contract UserLotteryManager is ReferrerFeeLedger {
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice Protocol fee on USER ticket gross, in basis points.
    uint16 public protocolFeeUserLotteriesBp;

    /// @notice Maximum `params.feeBp` allowed at USER lottery creation; 0 = no cap.
    uint16 public creatorFeeUserLotteriesLimitBp;

    /// @notice Treasury receiving net protocol fees after referrer share.
    address public treasury;

    /// @notice Maximum `params.duration` for USER lotteries (seconds).
    uint64 public maxDurationUsers;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Emitted when `treasury` is updated.
    event TreasurySet(address indexed treasury);

    /// @notice Emitted when `protocolFeeUserLotteriesBp` is updated.
    event ProtocolFeeUserLotteriesBpSet(uint16 indexed value);

    /// @notice Emitted when `creatorFeeUserLotteriesLimitBp` is updated.
    event CreatorFeeUserLotteriesLimitBpSet(uint16 indexed value);

    /// @notice Emitted when `maxDurationUsers` is updated.
    event MaxDurationUsersSet(uint64 indexed value);

    /// @notice Emitted when creator fees are accrued on ticket purchase.
    event CreatorFeeAdded(uint256 indexed lotteryId, address indexed creator, address token, uint256 amount);

    /// @notice Emitted when the lottery creator withdraws accumulated creator fees post-draw.
    event CreatorFeeClaimed(uint256 indexed lotteryId, address indexed creator, address token, uint256 amount);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when `createLotteryFromHub` receives a non-USER `kind`.
    error OnlyUserLotteries();

    /// @notice Thrown when `payoutModel` is not MULTIPLIER, TIER, or WIN_RATE.
    error UnsupportedPayoutModel();

    /// @notice Thrown when `claimCreatorFee` is called by an address other than `lot.creator`.
    error NotLotteryCreator();

    /// @notice Thrown when `claimCreatorFee` is called with zero accrued creator fees.
    error NoCreatorFees();

    /// @notice Thrown when draw is not finished (status not DRAW_COMPLETED / FULLY_CLAIMED).
    error NotReadyToClaim();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Deploys the USER creator and grants `HUB_ROLE` to `hub_`.
    ///         RndConsumer is wired post-deploy via `setRndConsumer`.
    /// @param initialDefaultAdmin `DEFAULT_ADMIN_ROLE` holder.
    /// @param hub_                `LotteryHub` address.
    constructor(address initialDefaultAdmin, address hub_) BaseLotteryManager(initialDefaultAdmin, hub_) {
        _grantRole(WORKER_ROLE, msg.sender);
    }

    /* ─────────────────────────── Configuration (WORKER_ROLE) ────────────────── */

    /// @notice Sets the maximum creator fee BP allowed on new USER lotteries.
    /// @param creatorFeeUserLotteriesLimitBp_ Cap; must be ≤ {MAX_CREATOR_FEE_BP}.
    function setCreatorFeeUserLotteriesLimitBp(uint16 creatorFeeUserLotteriesLimitBp_) external onlyRole(WORKER_ROLE) {
        if (creatorFeeUserLotteriesLimitBp_ > MAX_FEE_LIMIT_BP) revert InvalidCreatorCommission();
        creatorFeeUserLotteriesLimitBp = creatorFeeUserLotteriesLimitBp_;
        emit CreatorFeeUserLotteriesLimitBpSet(creatorFeeUserLotteriesLimitBp_);
    }

    /// @notice Sets the maximum allowed USER lottery duration.
    /// @param newDuration Seconds; must be non-zero.
    function setMaxDurationUsers(uint64 newDuration) external onlyRole(WORKER_ROLE) {
        if (newDuration == 0) revert InvalidAmount();
        maxDurationUsers = newDuration;
        emit MaxDurationUsersSet(newDuration);
    }

    /// @notice Updates the treasury address used in purchase quotes.
    function setTreasury(address treasury_) external onlyRole(WORKER_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Sets the USER lottery protocol fee rate.
    /// @param protocolFeeUserLotteriesBp_ Basis points; must be ≤ `MAX_CREATOR_FEE_BP` (20%).
    function setProtocolFeeUserLotteriesBp(uint16 protocolFeeUserLotteriesBp_) external onlyRole(WORKER_ROLE) {
        if (protocolFeeUserLotteriesBp_ > MAX_CREATOR_FEE_BP) revert InvalidCreatorCommission();
        protocolFeeUserLotteriesBp = protocolFeeUserLotteriesBp_;
        emit ProtocolFeeUserLotteriesBpSet(protocolFeeUserLotteriesBp_);
    }

    /* ─────────────────────────── Creator fee claim ──────────────────────────── */

    /// @notice Withdraws accumulated creator fees for `lotteryId` after the draw completes.
    /// @dev Callable only by `lot.creator` (the `originalCaller` at Hub creation).
    function claimCreatorFee(uint256 lotteryId) external {
        LotteryStatus liveStatus = _getLotteryStatus(lotteryId);
        if (liveStatus != LotteryStatus.DRAW_COMPLETED && liveStatus != LotteryStatus.FULLY_CLAIMED)
            revert NotReadyToClaim();

        LotteryStored storage lot = _lotteries[lotteryId];
        if (lot.creator != msg.sender) revert NotLotteryCreator();

        LotteryState storage s = _state[lotteryId];
        uint256 amount = s.creatorFees;
        if (amount == 0) revert NoCreatorFees();

        s.creatorFees = 0;
        address asset = lot.asset;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit CreatorFeeClaimed(lotteryId, msg.sender, asset, amount);
    }

    /* ─────────────────────────── ILotteryCreator — creation ───────────────────── */

    /// @inheritdoc BaseLotteryManager
    /// @notice Initializes a USER lottery; decodes `extraData` per `payoutModel`.
    function createLotteryFromHub(
        uint256 lotteryId,
        address originalCaller,
        LotteryKind kind,
        PayoutModel payoutModel,
        LotteryParams calldata params,
        bytes calldata extraData
    ) external override onlyHub {
        if (kind != LotteryKind.USER) revert OnlyUserLotteries();

        _checkBase(params, maxDurationUsers);
        uint256 feeCap = creatorFeeUserLotteriesLimitBp;
        if (feeCap > 0 && params.feeBp > feeCap) revert InvalidCreatorCommission();

        _initLottery(lotteryId, kind, payoutModel, originalCaller, params);

        if (payoutModel == PayoutModel.MULTIPLIER) {
            uint256 multiplierBp = abi.decode(extraData, (uint256));
            _checkMultiplierBp(multiplierBp);
            if (params.maxTickets * BP_DENOMINATOR < multiplierBp) revert InvalidMinTicketCount();
            _setPayoutRateBp(lotteryId, multiplierBp);
        } else if (payoutModel == PayoutModel.TIER) {
            uint16[] memory tiers = abi.decode(extraData, (uint16[]));
            _checkTiersLength(tiers.length);
            if (params.maxTickets < tiers.length) revert InvalidMinTicketCount();
            _storeTiers(lotteryId, tiers);
        } else if (payoutModel == PayoutModel.WIN_RATE) {
            uint256 winRateBp = abi.decode(extraData, (uint256));
            _checkWinRateBp(winRateBp);
            _setPayoutRateBp(lotteryId, winRateBp);
        } else {
            revert UnsupportedPayoutModel();
        }

        emit LotteryCreated(lotteryId, originalCaller, kind, payoutModel);
    }

    /* ─────────────────────────── ILotteryCreator — Hub-pull purchase ─────────── */

    /// @inheritdoc BaseLotteryManager
    /// @notice Returns the ERC-20 payment breakdown for a USER ticket purchase.
    function quoteTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address referrer
    ) external view override returns (TicketPurchaseQuote memory q) {
        LotteryStored storage lot = _lotteries[lotteryId];
        uint256 gross = qty * lot.ticketPrice;
        uint256 creatorFee = (gross * lot.feeBp) / BP_DENOMINATOR;
        uint256 treasuryFee = (gross * protocolFeeUserLotteriesBp) / BP_DENOMINATOR;

        uint256 refShare = 0;
        if (referrer != address(0) && treasuryFee > 0) {
            refShare = (treasuryFee * protocolFeeRevenueShareBp) / BP_DENOMINATOR;
        }

        uint256 netTreasury = treasuryFee - refShare;
        uint256 prizeAmount = gross - treasuryFee - creatorFee;

        q.token = lot.asset;
        q.toTreasury = netTreasury;
        q.treasuryDest = treasury;
        q.prizeAmount = prizeAmount;
        q.refShare = refShare;
        q.creatorFee = creatorFee;
        q.isUserLottery = true;
    }

    /// @inheritdoc BaseLotteryManager
    /// @notice Mints tickets and updates pools after Hub has pulled ERC-20 (no transfers here).
    /// @dev No local reentrancy guard: Hub-only entrypoint and the Hub's `buyTickets` is guarded.
    ///      Requires an open Hub settlement (`openHubSettlement`) and closes it as its last step.
    function registerTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address ticketRecipient,
        address buyer,
        address referrer,
        TicketPurchaseQuote calldata quote
    ) external override onlyHub {
        _executeTicketPurchase(lotteryId, qty, ticketRecipient);

        address token = quote.token;
        LotteryState storage s = _state[lotteryId];
        s.creatorFees += quote.creatorFee;
        s.prizePool += quote.prizeAmount;

        if (quote.creatorFee > 0) {
            emit CreatorFeeAdded(lotteryId, _lotteries[lotteryId].creator, token, quote.creatorFee);
        }

        if (quote.refShare > 0) {
            refFees[referrer][token] += quote.refShare;
            emit ReferrerFeeAdded(lotteryId, referrer, token, quote.refShare, buyer);
        }

        _closeHubSettlement();
    }

    /* ─────────────────────────── Ticket views ───────────────────────────────── */

    /// @notice Batch metadata starting at `ticketId` (ERC721A-style contiguous run).
    /// @dev `ProtocolLotteryManager` exposes the same data through
    ///      `RegularMissionModule.getMissionBatchData`. This entry point serves USER lotteries.
    /// @param lotteryId Lottery ID.
    /// @param ticketId  1-based start of batch (must be a batch head with stored ownership).
    /// @return kind      Lottery kind.
    /// @return owner     Batch owner.
    /// @return batchSize Contiguous tickets in the batch from `ticketId`.
    function ticketBatchData(
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (LotteryKind kind, address owner, uint256 batchSize) {
        uint256 total = _lotteryIndex[lotteryId];
        if (ticketId == 0 || ticketId >= total) revert TicketDoesNotExist();
        TicketOwnership storage o = _ownerships[lotteryId][ticketId];
        if (o.owner == address(0)) revert TicketDoesNotExist();

        uint256 batchEnd = ticketId + 1;
        while (batchEnd < total && _ownerships[lotteryId][batchEnd].owner == address(0)) {
            // prettier-ignore
            unchecked { ++batchEnd; }
        }

        return (_lotteries[lotteryId].kind, o.owner, batchEnd - ticketId);
    }
}
