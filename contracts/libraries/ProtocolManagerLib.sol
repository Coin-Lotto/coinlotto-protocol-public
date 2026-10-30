// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LotteryStored, LotteryState, LotteryStatus, LotteryKind, LotteryParams, PayoutModel} from "../structs/MetadataStruct.sol";
import {TicketPurchaseQuote} from "../structs/TicketPurchaseQuote.sol";
import {ICltRewarder} from "../interfaces/ICltRewarder.sol";

/// @title ProtocolManagerLib
/// @notice External linked library for `ProtocolLotteryManager`.
/// @dev Deployed once; called via DELEGATECALL so all storage reads/writes affect the
///      manager's own storage. The `public` visibility on every exported function is
///      required by the Solidity linker to generate a DELEGATECALL stub in the manager.
///
///      Extracted logic (heavy under viaIR — especially `abi.decode`):
///        • `quoteRegular` / `quoteSuper` — fee-split view helpers.
///        • `initRegular` / `initSuper`   — creation decode + validation + storage writes.
///
///      Events that must be emitted by the manager itself stay in the manager:
///        • `FeederLinked` — emitted by `_initRegular` after `initRegular` returns.
library ProtocolManagerLib {
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── Constants ──────────────────────── */

    uint256 private constant BP_DENOMINATOR = 10_000;
    uint256 private constant TIER_WEIGHTS_BP_DENOM = 10_000;
    /// @dev Mirrors `BaseLotteryManager.MIN_TICKET_PRICE`.
    uint256 private constant MIN_TICKET_PRICE = 100;

    /* ─────────────────────────────────────── Errors ──────────────────────────
       All selectors must match the errors declared in the manager and its base
       contracts. Identical signatures → identical 4-byte selectors.
    ─────────────────────────────────────────────────────────────────────────── */

    error ZeroAddress();
    error InvalidBp();
    error InvalidMinTicketCount();
    error InvalidPayoutMultiplier();
    error InvalidWinRateBp();
    error TooManyTiers(uint256 count);
    error InvalidAllocation();
    error ZeroSuperLotteryId();
    error InvalidCltTicketReward();
    error InvalidTierWeightsSum(uint256 sum);
    error ZeroLeadingTierWeight();
    error FeederAlreadyLinked();
    error InvalidFeederAllocBp();
    /// @notice ticketPrice * feederAllocBp < BP_DENOMINATOR; a 1-ticket purchase produces feederAmount == 0.
    ///         Required: ticketPrice * feederAllocBp >= 10_000.
    error FeederZeroPerTicket();
    /// @notice REGULAR `feeBp + feederAllocBp >= BP_DENOMINATOR`; the protocol fee and the feeder
    ///         allocation would consume the whole gross and underflow `prizeAmount`.
    error FeeAndAllocExceedGross();
    /// @notice ticketPrice * (BP_DENOMINATOR - feeBp - feederAllocBp) < BP_DENOMINATOR; a single
    ///         ticket would leave no raw unit of prize once the cumulative feeder floor rounds up.
    ///         Required: ticketPrice * (BP_DENOMINATOR - feeBp - feederAllocBp) >= 10_000.
    error PrizeFloorTooLow();
    /// @notice Linked SUPER feeBp == BP_DENOMINATOR; 100% SUPER fee consumes every feeder unit (netFeeder == 0).
    error SuperFeeConsumesFeeder();
    error UnsupportedPayoutModel();
    error InvalidSuperLotteryId();
    error SuperLotteryNotAcceptingFeeders();
    error MismatchEntryToken();
    error FeederShouldEndBeforeSuper();
    error SuperMultiplierNotSupported();
    error SuperPrizePoolEmpty(uint256 lotteryId);
    error OnlyRegularOrSuper();
    error SuperOnlyWithCltAsset();
    error InvalidCreatorCommission();
    error InvalidTicketPrice();
    error InvalidMaxTickets();
    error InvalidTimeRange();
    error ExceedsMaxDuration();
    error LotteryAlreadyExists();
    error NotRecoverable();
    error NothingToRecover();

    /* ─────────────────────────────────────── Events ──────────────────────────
       Declared here so the library bodies can emit them. Under DELEGATECALL
       `address(this)` is the manager, so logs are still emitted by the manager and
       the signatures match the manager's own declarations byte for byte.
    ─────────────────────────────────────────────────────────────────────────── */

    event LotteryStatusUpdated(uint256 indexed lotteryId, LotteryStatus indexed status);
    event StrandedFundsRecovered(uint256 indexed superId, address indexed recipient, uint256 amount);
    event FeederFundsForwarded(uint256 indexed regularId, uint256 indexed superId, uint256 amount);
    event FeederFundsSkipped(uint256 indexed regularId, uint256 indexed superId, uint256 skippedFeederAmount);
    event CltUserPerTicketRewardAdded(uint256 indexed lotteryId, address indexed user, uint256 amount);
    event CltReferrerBonusAdded(uint256 indexed lotteryId, address indexed referrer, uint256 amount, address buyer);
    event ReferrerFeeAdded(
        uint256 indexed lotteryId,
        address indexed referrer,
        address indexed token,
        uint256 amount,
        address buyer
    );

    /* ─────────────────────────────────────── Types ───────────────────────────── */

    /// @notice Manager configuration snapshot forwarded to {createLottery}.
    /// @dev Bundled into a struct purely to keep {createLottery} off the stack-too-deep limit.
    struct CreateCfg {
        uint64 durLimit;
        uint16 protocolFeeLimitBp;
        address cltToken;
        uint256 cltTicketRewardLimit;
        uint16 superAllocLimitBp;
        uint32 minMultBp;
        uint32 maxMultBp;
        uint16 minWinRateBp;
        uint16 maxWinRateBp;
        uint16 maxTiers;
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       QUOTE FUNCTIONS (view)
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Fee-split breakdown for a REGULAR ERC-20 ticket purchase.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager._quoteRegular`.
    ///      No events — safe to run in a view context.
    function quoteRegular(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        uint256 lotteryId,
        uint256 qty,
        address referrer,
        address treasury,
        uint16 protocolFeeRevenueShareBp
    ) private view returns (TicketPurchaseQuote memory q) {
        LotteryStored storage lot = lotteries[lotteryId];
        uint256 gross = qty * lot.ticketPrice;

        uint256 protFee = (gross * lot.feeBp) / BP_DENOMINATOR;
        uint256 refShare;
        if (referrer != address(0) && protFee > 0) {
            refShare = (protFee * protocolFeeRevenueShareBp) / BP_DENOMINATOR;
        }

        uint256 superProtocolFee;
        uint256 netFeeder;
        uint256 superId = lot.feederSuperLotteryId;
        if (superId != 0) {
            uint256 alloc = lot.feederAllocBp;

            uint256 price = lot.ticketPrice;
            uint256 soldBefore = _sold(lotteryIndex, lotteryId);
            uint256 allocBefore = (soldBefore * price * alloc) / BP_DENOMINATOR;
            uint256 allocAfter = ((soldBefore + qty) * price * alloc) / BP_DENOMINATOR;
            uint256 feederAmount = allocAfter - allocBefore;

            if (feederAmount > 0 && _liveAcceptsFeeding(lotteries, states, lotteryIndex, superId)) {
                uint256 superFeeBp = lotteries[superId].feeBp;
                // Cumulative on the same basis, so the SUPER fee is partition-independent too.
                superProtocolFee =
                    ((allocAfter * superFeeBp) / BP_DENOMINATOR) -
                    ((allocBefore * superFeeBp) / BP_DENOMINATOR);
                netFeeder = feederAmount - superProtocolFee;
            }
        }

        uint256 netTreasury = protFee - refShare + superProtocolFee;
        uint256 prizeAmount = gross - protFee - superProtocolFee - netFeeder;

        q.token = lot.asset;
        q.toTreasury = netTreasury;
        q.treasuryDest = treasury;
        q.prizeAmount = prizeAmount;
        q.refShare = refShare;
        q.netFeeder = netFeeder;
        q.cltLotteryReward = uint256(lot.cltAmountPerTicket) * qty;
    }

    /// @notice Fee-split breakdown for a SUPER CLT ticket purchase.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager._quoteSuper`.
    ///      Reverts if the SUPER prize pool has not been seeded by any feeder yet.
    function quoteSuper(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        uint256 lotteryId,
        uint256 qty,
        address cltToken_,
        address treasury_,
        uint16 cltTreasuryLimitBp_,
        uint16 cltProtocolFeeBp_,
        address rewardPool_
    ) private view returns (TicketPurchaseQuote memory q) {
        if (states[lotteryId].prizePool == 0) revert SuperPrizePoolEmpty(lotteryId);

        LotteryStored storage lot = lotteries[lotteryId];
        address clt = cltToken_;

        uint256 totalCLTCost = qty * lot.ticketPrice;
        uint256 totalSupply = clt != address(0) ? IERC20(clt).totalSupply() : 0;
        bool capReached;
        if (totalSupply > 0 && treasury_ != address(0)) {
            uint256 treasuryBal = IERC20(clt).balanceOf(treasury_);
            capReached = (treasuryBal * BP_DENOMINATOR) / totalSupply >= cltTreasuryLimitBp_;
        }

        uint256 cltToTreasury;
        uint256 cltToBank = totalCLTCost;
        if (!capReached && treasury_ != address(0)) {
            cltToTreasury = (totalCLTCost * cltProtocolFeeBp_) / BP_DENOMINATOR;
            cltToBank = totalCLTCost - cltToTreasury;
        }

        q.token = lot.asset;
        q.treasuryDest = treasury_;
        q.cltPayment = true;
        q.cltToken = clt;
        q.rewardPoolDest = rewardPool_;
        q.cltToTreasury = cltToTreasury;
        q.cltToBank = cltToBank;
    }

    /// @notice Kind-dispatching ticket-purchase quote for `lotteryId`.
    /// @dev Single exported entry point so the manager links one DELEGATECALL stub instead of two.
    ///      REGULAR routes to {quoteRegular}; every other kind routes to {quoteSuper}, matching
    ///      the manager's previous `kind == REGULAR ? _quoteRegular : _quoteSuper` branch exactly.
    function quote(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        uint256 lotteryId,
        uint256 qty,
        address referrer,
        address treasury_,
        uint16 protocolFeeRevenueShareBp,
        address cltToken_,
        uint16 cltTreasuryLimitBp_,
        uint16 cltProtocolFeeBp_,
        address rewardPool_
    ) public view returns (TicketPurchaseQuote memory) {
        if (lotteries[lotteryId].kind == LotteryKind.REGULAR) {
            return
                quoteRegular(
                    lotteries,
                    states,
                    lotteryIndex,
                    lotteryId,
                    qty,
                    referrer,
                    treasury_,
                    protocolFeeRevenueShareBp
                );
        }
        return
            quoteSuper(
                lotteries,
                states,
                lotteryId,
                qty,
                cltToken_,
                treasury_,
                cltTreasuryLimitBp_,
                cltProtocolFeeBp_,
                rewardPool_
            );
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       INIT FUNCTIONS (mutating)
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Decodes `extraData`, validates payout model params, and writes initial
    ///         REGULAR lottery config to storage.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager._initRegular`.
    ///      Returns feeder-link info so the manager can emit `FeederLinked`.
    /// @return feederLinked   True when this REGULAR was linked to a SUPER pool.
    /// @return linkedSuperId  SUPER lottery ID (0 when `feederLinked` is false).
    /// @return linkedAllocBp  Feeder allocation in BP (0 when `feederLinked` is false).
    function initRegular(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint16[]) storage lTiers,
        mapping(uint256 => address) storage superPrizeAssets,
        uint256 lotteryId,
        PayoutModel payoutModel,
        uint256 maxTickets,
        bytes calldata extraData,
        // validator config — read from manager state vars at call site
        uint256 cltTicketRewardLimit,
        uint16 superLotteryAllocationLimitBp,
        uint32 minimumMultiplierBp_,
        uint32 maximumMultiplierBp_,
        uint16 minimumWinRateBp_,
        uint16 maximumWinRateBp_,
        uint16 maximumTiers_
    ) public returns (bool feederLinked, uint64 linkedSuperId, uint16 linkedAllocBp) {
        if (payoutModel == PayoutModel.MULTIPLIER) {
            (uint256 multiplierBp, uint256 superLotteryId, uint256 allocBp, uint256 cltPerTicket) = abi.decode(
                extraData,
                (uint256, uint256, uint256, uint256)
            );

            _checkMultiplierBp(multiplierBp, minimumMultiplierBp_, maximumMultiplierBp_);
            if (maxTickets * BP_DENOMINATOR < multiplierBp) revert InvalidMinTicketCount();
            if (multiplierBp > type(uint32).max) revert InvalidBp();
            lotteries[lotteryId].payoutRateBp = uint32(multiplierBp);

            (feederLinked, linkedSuperId, linkedAllocBp) = _applyRegularExtras(
                lotteries,
                states,
                superPrizeAssets,
                lotteryId,
                superLotteryId,
                allocBp,
                cltPerTicket,
                cltTicketRewardLimit,
                superLotteryAllocationLimitBp
            );
        } else if (payoutModel == PayoutModel.TIER) {
            (uint16[] memory tiers, uint256 superLotteryId, uint256 allocBp, uint256 cltPerTicket) = abi.decode(
                extraData,
                (uint16[], uint256, uint256, uint256)
            );

            _checkTiersLength(tiers.length, maximumTiers_);
            if (maxTickets < tiers.length) revert InvalidMinTicketCount();
            _storeTiersInLib(lTiers, lotteryId, tiers);

            (feederLinked, linkedSuperId, linkedAllocBp) = _applyRegularExtras(
                lotteries,
                states,
                superPrizeAssets,
                lotteryId,
                superLotteryId,
                allocBp,
                cltPerTicket,
                cltTicketRewardLimit,
                superLotteryAllocationLimitBp
            );
        } else if (payoutModel == PayoutModel.WIN_RATE) {
            (uint256 winRateBp, uint256 superLotteryId, uint256 allocBp, uint256 cltPerTicket) = abi.decode(
                extraData,
                (uint256, uint256, uint256, uint256)
            );

            _checkWinRateBp(winRateBp, minimumWinRateBp_, maximumWinRateBp_);
            if (winRateBp > type(uint32).max) revert InvalidBp();
            lotteries[lotteryId].payoutRateBp = uint32(winRateBp);

            (feederLinked, linkedSuperId, linkedAllocBp) = _applyRegularExtras(
                lotteries,
                states,
                superPrizeAssets,
                lotteryId,
                superLotteryId,
                allocBp,
                cltPerTicket,
                cltTicketRewardLimit,
                superLotteryAllocationLimitBp
            );
        } else {
            revert UnsupportedPayoutModel();
        }
    }

    /// @notice Decodes `extraData` and writes initial SUPER lottery config to storage.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager._initSuper`.
    function initSuper(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => uint16[]) storage lTiers,
        mapping(uint256 => address) storage superPrizeAssets,
        uint256 lotteryId,
        PayoutModel payoutModel,
        uint256 maxTickets,
        bytes calldata extraData,
        uint16 minimumWinRateBp_,
        uint16 maximumWinRateBp_,
        uint16 maximumTiers_
    ) public {
        if (payoutModel == PayoutModel.MULTIPLIER) revert SuperMultiplierNotSupported();

        if (payoutModel == PayoutModel.WIN_RATE) {
            (uint256 winRateBp, address prizeAsset) = abi.decode(extraData, (uint256, address));
            _checkWinRateBp(winRateBp, minimumWinRateBp_, maximumWinRateBp_);
            if (prizeAsset == address(0)) revert ZeroAddress();
            if (winRateBp > type(uint32).max) revert InvalidBp();
            lotteries[lotteryId].payoutRateBp = uint32(winRateBp);
            superPrizeAssets[lotteryId] = prizeAsset;
        } else if (payoutModel == PayoutModel.TIER) {
            (uint16[] memory tiers, address prizeAsset) = abi.decode(extraData, (uint16[], address));
            _checkTiersLength(tiers.length, maximumTiers_);
            if (maxTickets < tiers.length) revert InvalidMinTicketCount();
            if (prizeAsset == address(0)) revert ZeroAddress();
            _storeTiersInLib(lTiers, lotteryId, tiers);
            superPrizeAssets[lotteryId] = prizeAsset;
        } else {
            revert UnsupportedPayoutModel();
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       CREATION (mutating)
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Validates base params, writes the initial lottery record, then applies
    ///         REGULAR or SUPER payout-model setup.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager.createLotteryFromHub`, which
    ///      retains the `REGULAR_OPERATOR_ROLE` check and the `LotteryCreated` emit.
    ///
    ///      The base-param validation and the initial storage write below are a deliberate
    ///      copy of `BaseLotteryManager._checkBase` and `BaseLotteryManager._initLottery`.
    ///      Holding the copy here lets the optimizer drop both from `ProtocolLotteryManager`'s
    ///      runtime bytecode (the manager no longer references them), which is the point of the
    ///      extraction. `UserLotteryManager` still uses the base versions.
    ///
    ///      INVARIANT: this copy must stay byte-for-byte equivalent to `_checkBase` +
    ///      `_initLottery`. `ProtocolManagerLibParity.t.sol` fails if they diverge.
    ///
    ///      `_checkBase`'s `maxTickets > type(uint24).max` check is intentionally absent:
    ///      `LotteryParams.maxTickets` is already `uint24`, so that branch is unreachable.
    ///
    /// @return feederLinked  True when a REGULAR was linked to a SUPER pool.
    /// @return linkedSuperId SUPER lottery ID (0 when `feederLinked` is false).
    /// @return linkedAllocBp Feeder allocation in BP (0 when `feederLinked` is false).
    function createLottery(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint16[]) storage lTiers,
        mapping(uint256 => address) storage superPrizeAssets,
        mapping(uint256 => uint256) storage lotteryIndex,
        uint256 lotteryId,
        address user,
        LotteryKind kind,
        PayoutModel payoutModel,
        LotteryParams calldata params,
        bytes calldata extraData,
        CreateCfg memory cfg
    ) public returns (bool feederLinked, uint64 linkedSuperId, uint16 linkedAllocBp) {
        if (kind != LotteryKind.REGULAR && kind != LotteryKind.SUPER) revert OnlyRegularOrSuper();

        // ── _checkBase ──────────────────────────────────────────────────────────
        if (params.asset == address(0)) revert ZeroAddress();
        if (params.ticketPrice < MIN_TICKET_PRICE) revert InvalidTicketPrice();
        if (params.ticketPrice > type(uint128).max) revert InvalidTicketPrice();
        if (params.feeBp > BP_DENOMINATOR) revert InvalidBp();
        if (params.maxTickets == 0) revert InvalidMaxTickets();
        uint64 nowTs = uint64(block.timestamp);
        uint64 effectiveStart = params.startTime < nowTs ? nowTs : params.startTime;
        if (effectiveStart >= params.endTime) revert InvalidTimeRange();
        if (params.endTime > type(uint40).max) revert InvalidTimeRange();
        if (cfg.durLimit > 0 && params.endTime - effectiveStart > cfg.durLimit) revert ExceedsMaxDuration();

        // Creator-commission cap; ordered after `_checkBase` exactly as in the manager.
        if (cfg.protocolFeeLimitBp > 0 && params.feeBp > cfg.protocolFeeLimitBp) revert InvalidCreatorCommission();

        // ── _initLottery ────────────────────────────────────────────────────────
        if (states[lotteryId].status != LotteryStatus.NONE) revert LotteryAlreadyExists();

        LotteryStored storage lot = lotteries[lotteryId];
        lot.creator = user;
        lot.kind = kind;
        lot.model = payoutModel;
        lot.feeBp = uint16(params.feeBp);
        lot.maxTickets = params.maxTickets;
        lot.asset = params.asset;
        lot.startTime = uint40(effectiveStart);
        lot.endTime = uint40(params.endTime);
        lot.ticketPrice = uint128(params.ticketPrice);

        LotteryStatus st = block.timestamp >= params.startTime ? LotteryStatus.ACTIVE : LotteryStatus.PENDING;
        states[lotteryId].status = st;
        lotteryIndex[lotteryId] = 1;
        emit LotteryStatusUpdated(lotteryId, st);

        // ── payout-model setup ──────────────────────────────────────────────────
        if (kind == LotteryKind.REGULAR) {
            (feederLinked, linkedSuperId, linkedAllocBp) = initRegular(
                lotteries,
                states,
                lTiers,
                superPrizeAssets,
                lotteryId,
                payoutModel,
                params.maxTickets,
                extraData,
                cfg.cltTicketRewardLimit,
                cfg.superAllocLimitBp,
                cfg.minMultBp,
                cfg.maxMultBp,
                cfg.minWinRateBp,
                cfg.maxWinRateBp,
                cfg.maxTiers
            );
        } else {
            if (params.asset != cfg.cltToken) revert SuperOnlyWithCltAsset();
            initSuper(
                lotteries,
                lTiers,
                superPrizeAssets,
                lotteryId,
                payoutModel,
                params.maxTickets,
                extraData,
                cfg.minWinRateBp,
                cfg.maxWinRateBp,
                cfg.maxTiers
            );
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       PURCHASE ACCOUNTING (mutating)
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Applies REGULAR post-purchase accounting: prize pool, CLT rewards,
    ///         referrer fee, and feeder forwarding.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager._registerRegularState`.
    ///      The feeder link is read from the manager's own storage (validated at creation).
    function registerRegularState(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        mapping(address => mapping(address => uint256)) storage refFees,
        uint256 lotteryId,
        uint256 qty,
        address buyer,
        address referrer,
        TicketPurchaseQuote calldata q,
        address recipient,
        uint16 cltReferrerBonusBp,
        address rewarder
    ) public {
        states[lotteryId].prizePool += q.prizeAmount;

        // Type-2a buyer CLT and type-2b referrer CLT in one `CltRewarder` call.
        uint256 cltLotteryReward = q.cltLotteryReward;
        if (cltLotteryReward != 0) {
            uint256 referrerBonus;
            if (referrer != address(0) && cltReferrerBonusBp != 0) {
                referrerBonus = (cltLotteryReward * cltReferrerBonusBp) / BP_DENOMINATOR;
            }

            ICltRewarder(rewarder).addCltPurchaseRewards(
                lotteryId,
                recipient,
                cltLotteryReward,
                referrer,
                referrerBonus
            );

            emit CltUserPerTicketRewardAdded(lotteryId, recipient, cltLotteryReward);
            if (referrerBonus > 0) emit CltReferrerBonusAdded(lotteryId, referrer, referrerBonus, buyer);
        }

        if (q.refShare != 0 && referrer != address(0)) {
            refFees[referrer][q.token] += q.refShare;
            emit ReferrerFeeAdded(lotteryId, referrer, q.token, q.refShare, buyer);
        }

        uint256 superId = lotteries[lotteryId].feederSuperLotteryId;
        if (q.netFeeder > 0) {
            if (!_liveAcceptsFeeding(lotteries, states, lotteryIndex, superId)) {
                revert SuperLotteryNotAcceptingFeeders();
            }
            states[superId].prizePool += q.netFeeder;
            emit FeederFundsForwarded(lotteryId, superId, q.netFeeder);
        } else if (superId != 0) {
            uint256 price = lotteries[lotteryId].ticketPrice;
            uint256 alloc = lotteries[lotteryId].feederAllocBp;
            uint256 soldAfter = _sold(lotteryIndex, lotteryId);
            uint256 feederAmount = ((soldAfter * price * alloc) / BP_DENOMINATOR) -
                (((soldAfter - qty) * price * alloc) / BP_DENOMINATOR);

            // Feeder slice already credited to REGULAR via `q.prizeAmount`;
            // only emit when SUPER rejects funding.
            if (feederAmount > 0 && !_liveAcceptsFeeding(lotteries, states, lotteryIndex, superId)) {
                emit FeederFundsSkipped(lotteryId, superId, feederAmount);
            }
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       EXTERNAL FEEDER SUPPORT
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Credits `amount` of `token` to a SUPER prize pool on behalf of an external feeder.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager.forwardExternalFeederFunds`,
    ///      which retains the `EXTERNAL_FEEDER_ROLE` gate.
    ///      Accounting only — the caller transfers the funds after a `true` return (push pattern).
    function forwardExternalFeeder(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        mapping(uint256 => address) storage superPrizeAssets,
        uint256 feederLotteryId,
        uint256 superLotteryId,
        uint256 amount,
        address token
    ) public returns (bool) {
        if (amount == 0) return false;
        if (lotteries[superLotteryId].kind != LotteryKind.SUPER) revert InvalidSuperLotteryId();
        if (superPrizeAssets[superLotteryId] != token) revert MismatchEntryToken();

        if (!_liveAcceptsFeeding(lotteries, states, lotteryIndex, superLotteryId)) {
            emit FeederFundsSkipped(feederLotteryId, superLotteryId, amount);
            return false;
        }

        states[superLotteryId].prizePool += amount;
        emit FeederFundsForwarded(feederLotteryId, superLotteryId, amount);
        return true;
    }

    /// @notice Feeder-relevant context for a SUPER lottery.
    /// @dev Called via DELEGATECALL from `ProtocolLotteryManager.getSuperFeederContext`.
    function superFeederContext(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        mapping(uint256 => address) storage superPrizeAssets,
        uint256 superLotteryId
    ) public view returns (uint16 superFeeBp, bool acceptsFeeding, address prizeAsset, uint64 superEndTime) {
        if (lotteries[superLotteryId].kind != LotteryKind.SUPER) revert InvalidSuperLotteryId();
        superFeeBp = lotteries[superLotteryId].feeBp;
        acceptsFeeding = _liveAcceptsFeeding(lotteries, states, lotteryIndex, superLotteryId);
        prizeAsset = superPrizeAssets[superLotteryId];
        superEndTime = lotteries[superLotteryId].endTime;
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       STRANDED FEEDER RECOVERY
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @notice Finalizes a zero-ticket expired SUPER lottery and recovers its feeder funds.
    function recoverStranded(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        mapping(uint256 => uint256) storage superDonationBalance,
        mapping(uint256 => address) storage superPrizeAssets,
        uint256 superId,
        address recipient
    ) public {
        if (lotteries[superId].kind != LotteryKind.SUPER) revert InvalidSuperLotteryId();
        if (block.timestamp <= lotteries[superId].endTime) revert NotRecoverable();
        if (_sold(lotteryIndex, superId) != 0) revert NotRecoverable();

        // Exclude lotteries that have entered the draw/claim lifecycle.
        LotteryStatus live = _liveStatus(lotteries, states, lotteryIndex, superId);
        if (
            live == LotteryStatus.DRAW_REQUESTED ||
            live == LotteryStatus.DRAW_COMPLETED ||
            live == LotteryStatus.FULLY_CLAIMED
        ) revert NotRecoverable();

        bool needsFinalization = states[superId].status != LotteryStatus.CANCELLED;
        uint256 recoverableAmount = states[superId].prizePool - superDonationBalance[superId];

        // Nothing to do: already finalized and no feeder funds remain.
        if (!needsFinalization && recoverableAmount == 0) revert NothingToRecover();

        if (needsFinalization) {
            states[superId].status = LotteryStatus.CANCELLED;
            emit LotteryStatusUpdated(superId, LotteryStatus.CANCELLED);
        }

        // Transfer feeder-funded portion only; outstanding donor liabilities remain in prizePool.
        if (recoverableAmount > 0) {
            states[superId].prizePool -= recoverableAmount;
            emit StrandedFundsRecovered(superId, recipient, recoverableAmount);
            IERC20(superPrizeAssets[superId]).safeTransfer(recipient, recoverableAmount);
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       PRIVATE HELPERS
    ═══════════════════════════════════════════════════════════════════════════ */

    /// @dev Tickets sold for `id`. Mirrors `BaseLotteryManager._sold`: the index is
    ///      1-based and pre-seeded to 1 at creation, so sold == index - 1.
    function _sold(mapping(uint256 => uint256) storage lotteryIndex, uint256 id) private view returns (uint256) {
        uint256 idx = lotteryIndex[id];
        return idx == 0 ? 0 : idx - 1;
    }

    /// @dev Time/claim-aware status overlay.
    ///      INVARIANT: must mirror `BaseLotteryManager._getLotteryStatus` exactly.
    ///      `ProtocolManagerLibParity.t.sol` fails if they diverge.
    function _liveStatus(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        uint256 id
    ) private view returns (LotteryStatus) {
        LotteryState storage s = states[id];
        LotteryStatus stored = s.status;
        if (stored == LotteryStatus.NONE) return LotteryStatus.NONE;

        LotteryStored storage lot = lotteries[id];

        if (stored == LotteryStatus.PENDING) {
            if (block.timestamp > lot.endTime) return LotteryStatus.CANCELLED;
            if (block.timestamp >= lot.startTime) return LotteryStatus.ACTIVE;
            return LotteryStatus.PENDING;
        }

        if (stored == LotteryStatus.ACTIVE && block.timestamp > lot.endTime) {
            return _sold(lotteryIndex, id) == 0 ? LotteryStatus.CANCELLED : LotteryStatus.READY_TO_DRAW;
        }

        if (stored == LotteryStatus.DRAW_COMPLETED) {
            if (s.prizePool > 0 && s.claimedPrizePool >= s.prizePool) return LotteryStatus.FULLY_CLAIMED;
        }

        return stored;
    }

    /// @dev Live-status feeder gate. Mirrors `ProtocolLotteryManager._superAcceptsFeeding`.
    function _liveAcceptsFeeding(
        mapping(uint256 => LotteryStored) storage lotteries,
        mapping(uint256 => LotteryState) storage states,
        mapping(uint256 => uint256) storage lotteryIndex,
        uint256 superLotteryId
    ) private view returns (bool) {
        LotteryStatus superStatus = _liveStatus(lotteries, states, lotteryIndex, superLotteryId);
        return
            superStatus != LotteryStatus.CANCELLED &&
            superStatus != LotteryStatus.DRAW_REQUESTED &&
            superStatus != LotteryStatus.DRAW_COMPLETED &&
            superStatus != LotteryStatus.FULLY_CLAIMED;
    }

    /// @dev Applies REGULAR-specific feeder/CLT extras after payout-model setup.
    ///      Mirrors `ProtocolLotteryManager._applyRegularExtras` minus the `FeederLinked` emit.
    function _applyRegularExtras(
        mapping(uint256 => LotteryStored) storage _lotteries,
        mapping(uint256 => LotteryState) storage _states,
        mapping(uint256 => address) storage _superPrizeAssets,
        uint256 _lotteryId,
        uint256 _superLotteryId,
        uint256 _allocBp,
        uint256 _cltPerTicket,
        uint256 _cltTicketRewardLimit,
        uint16 _superLotteryAllocationLimitBp
    ) private returns (bool feederLinked, uint64 linkedSuperId, uint16 linkedAllocBp) {
        if (_cltTicketRewardLimit > 0 && _cltPerTicket > _cltTicketRewardLimit) revert InvalidCltTicketReward();
        if (_allocBp != 0 && _superLotteryId == 0) revert ZeroSuperLotteryId();
        if (_superLotteryAllocationLimitBp > 0 && _allocBp > _superLotteryAllocationLimitBp) revert InvalidAllocation();

        if (_superLotteryId != 0) {
            if (_lotteries[_superLotteryId].kind != LotteryKind.SUPER) revert InvalidSuperLotteryId();
            if (!_superAcceptsFeeding(_states, _superLotteryId)) revert SuperLotteryNotAcceptingFeeders();

            // _registerFeeder + _writeFeederLink (inlined):
            if (_lotteries[_lotteryId].feederSuperLotteryId != 0) revert FeederAlreadyLinked();
            if (_allocBp == 0 || _allocBp > 10_000) revert InvalidFeederAllocBp();

            uint256 _price = _lotteries[_lotteryId].ticketPrice;
            uint256 _feeBp = _lotteries[_lotteryId].feeBp;

            // Enforce: floor(ticketPrice * feederAllocBp / BP_DENOMINATOR) >= 1 for qty = 1.
            // Guards against a feeder whose allocation is so small the SUPER is starved.
            if (_price * _allocBp < BP_DENOMINATOR) revert FeederZeroPerTicket();
            if (_feeBp + _allocBp >= BP_DENOMINATOR) revert FeeAndAllocExceedGross();
            if (_price * (BP_DENOMINATOR - _feeBp - _allocBp) < BP_DENOMINATOR) revert PrizeFloorTooLow();

            // 100% SUPER fee would leave netFeeder = feederAmount - feederAmount = 0.
            if (_lotteries[_superLotteryId].feeBp >= BP_DENOMINATOR) revert SuperFeeConsumesFeeder();
            if (_superLotteryId > type(uint64).max) revert InvalidSuperLotteryId();

            _lotteries[_lotteryId].feederSuperLotteryId = uint64(_superLotteryId);
            _lotteries[_lotteryId].feederAllocBp = uint16(_allocBp);

            address feederAsset = _lotteries[_lotteryId].asset;
            if (_superPrizeAssets[_superLotteryId] != feederAsset) revert MismatchEntryToken();

            if (_lotteries[_lotteryId].endTime > _lotteries[_superLotteryId].endTime)
                revert FeederShouldEndBeforeSuper();

            feederLinked = true;
            linkedSuperId = uint64(_superLotteryId);
            linkedAllocBp = uint16(_allocBp);
        }

        if (_cltPerTicket > 0) {
            if (_cltPerTicket > type(uint96).max) revert InvalidCltTicketReward();
            _lotteries[_lotteryId].cltAmountPerTicket = uint96(_cltPerTicket);
        }
    }

    /// @dev Checks whether a SUPER lottery still accepts feeder contributions.
    ///      Uses stored status only — virtual statuses (e.g. READY_TO_DRAW derived from ACTIVE+expired)
    ///      are irrelevant here; only the four terminal stored statuses reject feeding.
    ///      CANCELLED is included so that a SUPER finalized by `recoverStrandedFunds` (which writes
    ///      CANCELLED to storage) immediately stops receiving further feeder credits.
    function _superAcceptsFeeding(
        mapping(uint256 => LotteryState) storage _states,
        uint256 superLotteryId
    ) private view returns (bool) {
        LotteryStatus s = _states[superLotteryId].status;
        return
            s != LotteryStatus.CANCELLED &&
            s != LotteryStatus.DRAW_REQUESTED &&
            s != LotteryStatus.DRAW_COMPLETED &&
            s != LotteryStatus.FULLY_CLAIMED;
    }

    function _checkMultiplierBp(uint256 _bp, uint32 _minBp, uint32 _maxBp) private pure {
        if (_minBp > 0 && _bp < _minBp) revert InvalidPayoutMultiplier();
        if (_maxBp > 0 && _bp > _maxBp) revert InvalidPayoutMultiplier();
    }

    function _checkWinRateBp(uint256 _bp, uint16 _minBp, uint16 _maxBp) private pure {
        if (_minBp > 0 && _bp < _minBp) revert InvalidWinRateBp();
        if (_maxBp > 0 && _bp > _maxBp) revert InvalidWinRateBp();
    }

    function _checkTiersLength(uint256 tiersLength, uint16 maxTiers) private pure {
        if (tiersLength == 0) revert TooManyTiers(tiersLength);
        if (maxTiers > 0 && tiersLength > maxTiers) revert TooManyTiers(tiersLength);
    }

    function _storeTiersInLib(
        mapping(uint256 => uint16[]) storage _lTiers,
        uint256 _lotteryId,
        uint16[] memory _tiers
    ) private {
        if (_tiers[0] == 0) revert ZeroLeadingTierWeight();
        uint256 len = _tiers.length;
        uint256 sum;
        for (uint256 i; i < len; ) {
            sum += uint256(_tiers[i]);
            // prettier-ignore
            unchecked { ++i; }
        }
        if (sum != TIER_WEIGHTS_BP_DENOM) revert InvalidTierWeightsSum(sum);
        _lTiers[_lotteryId] = _tiers;
    }
}
