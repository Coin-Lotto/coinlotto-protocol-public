// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ILotteryCore} from "./interfaces/ILotteryCore.sol";
import {IRegularMissionModule} from "./interfaces/IRegularMissionModule.sol";
import {ILotteryManager} from "./interfaces/ILotteryManager.sol";
import {ICltRewardPool} from "./interfaces/ICltRewardPool.sol";
import {LotteryKind, LotteryStatus} from "./structs/MetadataStruct.sol";

interface ILotteryHub {
    function getManager(uint256 lotteryId) external view returns (address);
}

/// @title CltMissions
/// @dev Flow:
///        • `hub.getManager(lotteryId)` → `ProtocolLotteryManager` (implements `IRegularMissionModule`).
///        • Eligibility reads ticket/kind/draw state from that manager; payouts via `rewardPool.withdrawClt`.
///        • USER lotteries do not implement `IRegularMissionModule` and cannot satisfy missions.
///
///      Missions (each claimable once per user):
///        • Golden Ticket — own any REGULAR ticket.
///        • Early Bird — buy within {EARLY_PURCHASE_WINDOW} after lottery start.
///        • Luck Insurance — exactly {MIN_TICKETS} losing REGULAR tickets across completed draws
///          (the mission floor and the submission cap are the same value; see
///          {MAX_LUCK_INSURANCE_ITEMS}).
///        • Stack The Odds — single purchase batch of ≥ {MIN_TICKETS} REGULAR tickets.
///
///      Referrer welcome CLT is handled by `CltRewarder` (Hub on first referral), not here.
///
///      Access control:
///        • `WORKER_ROLE` — bonus config, `rewardPool`, legacy `lottery` pointer.
///        • `DEFAULT_ADMIN_ROLE` — `setHub`, `setLegacyAdapter`.
contract CltMissions is AccessControl {
    /* ─────────────────────────────────────── Enums ──────────────────────────── */

    /// @notice Machine-readable reason a mission claim or view is blocked.
    enum ClaimBlockReason {
        NONE,
        READY_TO_CLAIM,
        MISSION_ALREADY_CLAIMED,
        NOT_TICKET_OWNER,
        LOTTERY_NOT_FINISHED,
        LOTTERY_KIND_NOT_REGULAR,
        EARLY_BIRD_WINDOW_EXPIRED,
        BATCH_SIZE_TOO_SMALL,
        TOTAL_WINNING_TICKETS_TOO_SMALL,
        NOT_LOSING_TICKETS,
        NOT_REFERER_FOR_USER,
        NOT_REGULAR_TICKET,
        LOTTERY_NOT_EXISTS,
        TICKET_NOT_EXISTS,
        TICKET_BATCH_SIZE_TOO_SMALL,
        TOO_MANY_BATCHES,
        TOO_MANY_TICKETS,
        UNSORTED_OR_DUPLICATE
    }

    /* ─────────────────────────────────────── Structs ──────────────────────────── */

    /// @notice Per-user flags for which one-time missions were claimed.
    struct MissionStatus {
        bool claimedGoldenTicket;
        bool claimedEarlyBird;
        bool claimedLuckInsurance;
        bool claimedStackTheOdds;
    }

    /// @notice CLT payout amounts for all four missions (updated atomically).
    struct MissionBonusConfig {
        uint128 goldenTicket;
        uint128 earlyBird;
        uint128 luckInsurance;
        uint128 stackTheOdds;
    }

    /* ─────────────────────────────────────── Roles ──────────────────────────── */

    /// @notice Role for operational configuration setters.
    bytes32 public constant WORKER_ROLE = keccak256("WORKER_ROLE");

    /* ─────────────────────────────────────── Constants ────────────────────────── */

    /// @notice Seconds after lottery `startTime` that qualify for Early Bird.
    uint64 internal constant EARLY_PURCHASE_WINDOW = 10 minutes;

    /// @notice Upper bound per mission bonus in `setMissionBonusConfig`.
    uint256 internal constant MAX_BONUS = 1000 ether;

    /// @notice Minimum tickets in one purchase for Stack The Odds.
    uint256 internal constant MIN_TICKETS = 10;

    /// @notice Upper bound on both the batch count and the total ticket count accepted by the
    ///         Luck Insurance paths.
    uint256 internal constant MAX_LUCK_INSURANCE_ITEMS = 10;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice Fallback mission data source when `hub.getCreator(lotteryId)` is zero.
    /// @dev Set to a contract exposing `ILotteryCore` views (e.g. legacy deployment). Optional.
    ILotteryCore public lottery;

    /// @notice `LotteryHub` used to resolve the creator for each `lotteryId`.
    ILotteryHub public hub;

    /// @notice Optional `ILotteryManager` used for `ticketOwner` when Hub has no route for an ID.
    ILotteryManager public legacyAdapter;

    /// @notice CLT storage; must grant this contract `WITHDRAW_ROLE`.
    ICltRewardPool public rewardPool;

    /// @notice Active mission bonus amounts.
    MissionBonusConfig public missionBonusConfig;

    /// @dev Per-user mission claim flags.
    mapping(address user => MissionStatus status) private _missionStatus;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    event LotterySet(address indexed newLottery);
    event HubSet(address indexed hub);
    event LegacyAdapterSet(address indexed legacyAdapter);
    event MissionClaimed(address indexed sender, MissionStatus status);
    event MissionBonusConfigSet(MissionBonusConfig config);
    event RewardPoolSet(address indexed addr);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when a required address is zero.
    error ZeroAddress();
    /// @notice Thrown when eligibility checks fail on claim (use views for detail).
    error MissionNotAvailable();
    /// @notice Thrown when any mission bonus in config exceeds {MAX_BONUS}.
    error ExceedsMaxCltMissionBonus();
    /// @notice Thrown when caller does not own the referenced ticket (legacy path).
    error NotTicketOwner();
    /// @notice Thrown when the early bird window has expired.
    error EarlyBirdWindowExpired();
    /// @notice Thrown when the managers are mixed.
    error MixedManagersNotAllowed();
    /// @notice Thrown when the mission has already been claimed.
    error MissionAlreadyClaimed();
    /// @notice Thrown when the lottery kind is not regular.
    error LotteryKindNotRegular();
    /// @notice Thrown when the batch size is too small.
    error BatchSizeTooSmall();
    /// @notice Thrown when the total winning tickets are too small.
    error TotalWinningTicketsTooSmall();
    /// @notice Thrown when the user is not the referrer for the user.
    error NotReferrerForUser();
    /// @notice Thrown when the ticket is not regular.
    error NotRegularTicket();
    /// @notice Thrown when the tickets are not losing.
    error NotLosingTickets();
    /// @notice Submitted batch count is invalid.
    error InvalidBatchCount();
    /// @notice Submitted total ticket count exceeds {MAX_LUCK_INSURANCE_ITEMS}.
    error TooManyTickets();
    /// @notice Lottery IDs are not strictly ascending across batches, or ticket IDs are not
    ///         strictly ascending within a batch (duplicates).
    error UnsortedTickets();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @param initialDefaultAdmin `DEFAULT_ADMIN_ROLE` and `WORKER_ROLE` holder.
    /// @param lottery_            Legacy core pointer for unmigrated IDs.
    /// @dev   `rewardPool` is set post-deploy via `setRewardPool()` during protocol setup.
    ///        `WORKER_ROLE` is granted to `initialDefaultAdmin` (not `msg.sender`) so the
    ///        deployer retains setter access when the contract is deployed via a CREATE2 factory.
    constructor(address initialDefaultAdmin, address lottery_) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
        _grantRole(WORKER_ROLE, msg.sender);

        _setLottery(lottery_);
    }

    /* ─────────────────────────── Configuration ──────────────────────────────── */

    function setLottery(address lottery_) external onlyRole(WORKER_ROLE) {
        _setLottery(lottery_);
    }

    /// @notice Sets the Hub used to resolve creators (required for new lottery IDs).
    function setHub(address hub_) external onlyRole(WORKER_ROLE) {
        _setHub(hub_);
    }

    /// @notice Sets optional legacy adapter for pre-Hub ticket lookups.
    function setLegacyAdapter(address legacyAdapter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLegacyAdapter(legacyAdapter_);
    }

    function setRewardPool(address rewardPool_) external onlyRole(WORKER_ROLE) {
        _setRewardPool(rewardPool_);
    }

    /// @notice Atomically updates all four mission bonus amounts.
    function setMissionBonusConfig(MissionBonusConfig calldata cfg) external onlyRole(WORKER_ROLE) {
        if (
            cfg.goldenTicket > MAX_BONUS ||
            cfg.earlyBird > MAX_BONUS ||
            cfg.luckInsurance > MAX_BONUS ||
            cfg.stackTheOdds > MAX_BONUS
        ) revert ExceedsMaxCltMissionBonus();

        missionBonusConfig = cfg;

        emit MissionBonusConfigSet(cfg);
    }

    /* ─────────────────────────── Mission claims ───────────────────────────────── */

    /// @notice Claims Early Bird CLT for a qualifying REGULAR ticket.
    function claimEarlyBirdMission(uint256 lotteryId, uint256 ticketId) external {
        if (!_canEarly(lotteryId, ticketId)) revert MissionNotAvailable();
        uint256 bonus = missionBonusConfig.earlyBird;
        if (bonus == 0) revert MissionNotAvailable();
        MissionStatus storage ms = _missionStatus[msg.sender];
        ms.claimedEarlyBird = true;
        rewardPool.withdrawClt(msg.sender, bonus);
        emit MissionClaimed(msg.sender, ms);
    }

    /// @notice Claims Golden Ticket CLT for owning a REGULAR ticket.
    function claimGoldenTicketMission(uint256 lotteryId, uint256 ticketId) external {
        if (!_canGold(lotteryId, ticketId)) revert MissionNotAvailable();
        uint256 bonus = missionBonusConfig.goldenTicket;
        if (bonus == 0) revert MissionNotAvailable();
        MissionStatus storage ms = _missionStatus[msg.sender];
        ms.claimedGoldenTicket = true;
        rewardPool.withdrawClt(msg.sender, bonus);
        emit MissionClaimed(msg.sender, ms);
    }

    /// @notice Claims Luck Insurance CLT for a batch of losing REGULAR tickets.
    /// @dev All batches must resolve to the same `ProtocolLotteryManager` via Hub.
    function claimLuckInsuranceMission(ILotteryCore.TicketBatch[] calldata losingTickets) external {
        if (_missionStatus[msg.sender].claimedLuckInsurance) revert MissionNotAvailable();
        uint256 batchLen = losingTickets.length;
        if (batchLen == 0 || batchLen > MAX_LUCK_INSURANCE_ITEMS) revert InvalidBatchCount();

        IRegularMissionModule manager = _resolveLotteryCore(losingTickets[0].lotteryId);

        uint256 lastLotteryId = losingTickets[0].lotteryId;
        uint256 total = losingTickets[0].ticketIds.length;

        for (uint256 i = 1; i < batchLen; ) {
            uint256 lotteryId = losingTickets[i].lotteryId;
            if (lotteryId <= lastLotteryId) revert UnsortedTickets();
            lastLotteryId = lotteryId;

            IRegularMissionModule c = _resolveLotteryCore(lotteryId);
            if (address(c) != address(manager)) revert MixedManagersNotAllowed();

            total += losingTickets[i].ticketIds.length;
            // prettier-ignore
            unchecked { ++i; }
        }
        if (total > MAX_LUCK_INSURANCE_ITEMS) revert TooManyTickets();

        (bool isLosing, address owner, uint256 allTicketCount) = manager.validateLosingTicketsForMission(losingTickets);
        if (owner != msg.sender) revert MissionNotAvailable();
        if (!isLosing) revert MissionNotAvailable();
        if (allTicketCount < MIN_TICKETS) revert MissionNotAvailable();

        uint256 luckBonus = missionBonusConfig.luckInsurance;
        if (luckBonus == 0) revert MissionNotAvailable();

        MissionStatus storage ms = _missionStatus[msg.sender];
        ms.claimedLuckInsurance = true;

        rewardPool.withdrawClt(msg.sender, luckBonus);
        emit MissionClaimed(msg.sender, ms);
    }

    /// @notice Claims Stack The Odds CLT for a qualifying bulk REGULAR purchase.
    /// @param ticketId First ticket ID of the purchase batch on `lotteryId`.
    function claimStackTheOddsMission(uint256 lotteryId, uint256 ticketId) external {
        if (!_canStackTheOdds(lotteryId, ticketId)) revert MissionNotAvailable();
        uint256 bonus = missionBonusConfig.stackTheOdds;
        if (bonus == 0) revert MissionNotAvailable();
        MissionStatus storage ms = _missionStatus[msg.sender];
        ms.claimedStackTheOdds = true;
        rewardPool.withdrawClt(msg.sender, bonus);
        emit MissionClaimed(msg.sender, ms);
    }

    /* ─────────────────────────── Eligibility views ──────────────────────────── */

    /// @notice Returns whether `user` may claim Golden Ticket for `ticketId`.
    function canClaimGoldenTicket(
        address user,
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (bool canClaim, ClaimBlockReason reason) {
        if (_missionStatus[user].claimedGoldenTicket) return (false, ClaimBlockReason.MISSION_ALREADY_CLAIMED);

        IRegularMissionModule manager = _resolveLotteryCore(lotteryId);
        if (address(manager).code.length == 0) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);
        ILotteryCore coreView = ILotteryCore(address(manager));
        LotteryStatus status = coreView.getLotteryStatus(lotteryId);
        if (status == LotteryStatus.NONE) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);
        uint256 maxTicketId = coreView.totalTicketsSold(lotteryId);
        if (ticketId > maxTicketId) return (false, ClaimBlockReason.TICKET_NOT_EXISTS);

        try manager.getMissionTicketInfo(lotteryId, ticketId) returns (
            LotteryKind kind,
            address owner,
            uint64,
            uint64
        ) {
            if (owner != user) return (false, ClaimBlockReason.NOT_TICKET_OWNER);
            if (!_isEligibleKind(kind)) return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
            return (true, ClaimBlockReason.READY_TO_CLAIM);
        } catch {
            return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
        }
    }

    /// @notice Returns whether `user` may claim Early Bird for `ticketId`.
    function canClaimEarlyBird(
        address user,
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (bool canClaim, ClaimBlockReason reason) {
        if (_missionStatus[user].claimedEarlyBird) return (false, ClaimBlockReason.MISSION_ALREADY_CLAIMED);

        IRegularMissionModule manager = _resolveLotteryCore(lotteryId);
        if (address(manager).code.length == 0) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);
        ILotteryCore coreView = ILotteryCore(address(manager));
        LotteryStatus status = coreView.getLotteryStatus(lotteryId);
        if (status == LotteryStatus.NONE) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);
        uint256 maxTicketId = coreView.totalTicketsSold(lotteryId);
        if (ticketId > maxTicketId) return (false, ClaimBlockReason.TICKET_NOT_EXISTS);

        try manager.getMissionTicketInfo(lotteryId, ticketId) returns (
            LotteryKind kind,
            address owner,
            uint64 purchaseTime,
            uint64 lotteryStart
        ) {
            if (owner != user) return (false, ClaimBlockReason.NOT_TICKET_OWNER);
            if (!_isEligibleKind(kind)) return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
            if (purchaseTime >= lotteryStart + EARLY_PURCHASE_WINDOW)
                return (false, ClaimBlockReason.EARLY_BIRD_WINDOW_EXPIRED);
            return (true, ClaimBlockReason.READY_TO_CLAIM);
        } catch {
            return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
        }
    }

    /// @notice Returns whether `user` may claim Stack The Odds for a batch starting at `ticketId`.
    function canClaimStackTheOdds(
        address user,
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (bool canClaim, ClaimBlockReason reason) {
        if (_missionStatus[user].claimedStackTheOdds) return (false, ClaimBlockReason.MISSION_ALREADY_CLAIMED);

        IRegularMissionModule manager = _resolveLotteryCore(lotteryId);
        if (address(manager).code.length == 0) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);
        ILotteryCore coreView = ILotteryCore(address(manager));
        LotteryStatus status = coreView.getLotteryStatus(lotteryId);
        if (status == LotteryStatus.NONE) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);
        uint256 maxTicketId = coreView.totalTicketsSold(lotteryId);
        if (ticketId > maxTicketId) return (false, ClaimBlockReason.TICKET_NOT_EXISTS);

        try manager.getMissionBatchData(lotteryId, ticketId) returns (
            LotteryKind kind,
            address owner,
            uint256 batchSize
        ) {
            if (owner != user) return (false, ClaimBlockReason.NOT_TICKET_OWNER);
            if (!_isEligibleKind(kind)) return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
            if (batchSize < MIN_TICKETS) return (false, ClaimBlockReason.BATCH_SIZE_TOO_SMALL);
            return (true, ClaimBlockReason.READY_TO_CLAIM);
        } catch {
            return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
        }
    }

    /// @notice Returns whether `user` may claim Luck Insurance for `losingTickets`.
    function canClaimLosingTickets(
        address user,
        ILotteryCore.TicketBatch[] calldata losingTickets
    ) external view returns (bool canClaim, ClaimBlockReason reason) {
        if (_missionStatus[user].claimedLuckInsurance) return (false, ClaimBlockReason.MISSION_ALREADY_CLAIMED);

        uint256 batchLen = losingTickets.length;
        if (batchLen == 0) return (false, ClaimBlockReason.BATCH_SIZE_TOO_SMALL);
        if (batchLen > MAX_LUCK_INSURANCE_ITEMS) return (false, ClaimBlockReason.TOO_MANY_BATCHES);

        IRegularMissionModule manager = _resolveLotteryCore(losingTickets[0].lotteryId);
        ILotteryCore coreView = ILotteryCore(address(manager));

        uint256 total;
        uint256 lastLotteryId;

        for (uint256 i = 0; i < batchLen; ++i) {
            uint256 lotteryId = losingTickets[i].lotteryId;
            if (lotteryId <= lastLotteryId) return (false, ClaimBlockReason.UNSORTED_OR_DUPLICATE);
            lastLotteryId = lotteryId;

            uint256[] calldata ticketIds = losingTickets[i].ticketIds;
            uint256 idsLen = ticketIds.length;
            if (idsLen == 0) return (false, ClaimBlockReason.TICKET_BATCH_SIZE_TOO_SMALL);

            total += idsLen;
            if (total > MAX_LUCK_INSURANCE_ITEMS) return (false, ClaimBlockReason.TOO_MANY_TICKETS);

            if (i > 0 && address(_resolveLotteryCore(lotteryId)) != address(manager))
                return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);

            LotteryStatus status = coreView.getLotteryStatus(lotteryId);
            if (status == LotteryStatus.NONE) return (false, ClaimBlockReason.LOTTERY_NOT_EXISTS);

            uint256 maxTicketId = coreView.totalTicketsSold(lotteryId);
            uint256 lastTicketId;
            for (uint256 j = 0; j < idsLen; ++j) {
                uint256 ticketId = ticketIds[j];
                if (ticketId <= lastTicketId) return (false, ClaimBlockReason.UNSORTED_OR_DUPLICATE);
                lastTicketId = ticketId;

                if (ticketId > maxTicketId) return (false, ClaimBlockReason.TICKET_NOT_EXISTS);
                try manager.getMissionTicketInfo(lotteryId, ticketId) returns (
                    LotteryKind kind,
                    address currentOwner,
                    uint64,
                    uint64
                ) {
                    if (currentOwner != user) return (false, ClaimBlockReason.NOT_TICKET_OWNER);
                    if (!_isEligibleKind(kind)) return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
                } catch {
                    return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
                }
            }
        }

        bool isLosing;
        address owner;
        uint256 allTicketCount;
        try manager.validateLosingTicketsForMission(losingTickets) returns (
            bool _isLosing,
            address _owner,
            uint256 _count
        ) {
            isLosing = _isLosing;
            owner = _owner;
            allTicketCount = _count;
        } catch {
            return (false, ClaimBlockReason.LOTTERY_KIND_NOT_REGULAR);
        }
        if (!isLosing) return (false, ClaimBlockReason.NOT_LOSING_TICKETS);
        if (owner != user) return (false, ClaimBlockReason.NOT_TICKET_OWNER);
        if (allTicketCount < MIN_TICKETS) return (false, ClaimBlockReason.TOTAL_WINNING_TICKETS_TOO_SMALL);

        return (true, ClaimBlockReason.READY_TO_CLAIM);
    }

    /// @notice Returns mission claim flags for `user`.
    function getMissionStatus(address user) external view returns (MissionStatus memory) {
        return _missionStatus[user];
    }

    /* ─────────────────────────── Kind eligibility ─────────────────────────────── */

    /// @dev Returns true for lottery kinds that qualify for mission rewards.
    ///      REGULAR: ProtocolLotteryManager lotteries.
    ///      BATTLE:  ProtocolDuelLotteryManager lotteries (implements IRegularMissionModule).
    function _isEligibleKind(LotteryKind _kind) private pure returns (bool) {
        return _kind == LotteryKind.REGULAR || _kind == LotteryKind.BATTLE;
    }

    /* ─────────────────────────── Creator resolution ───────────────────────────── */

    /// @dev Resolves `hub.getManager(lotteryId)` as `IRegularMissionModule`, else uses `lottery`.
    function _resolveLotteryCore(uint256 lotteryId) private view returns (IRegularMissionModule) {
        ILotteryHub h = hub;
        if (address(h) != address(0)) {
            address manager = h.getManager(lotteryId);
            if (manager != address(0)) return IRegularMissionModule(manager);
        }
        return IRegularMissionModule(address(lottery));
    }

    /* ─────────────────────────── Private eligibility ──────────────────────────── */

    function _canGold(uint256 _lId, uint256 _tId) private view returns (bool) {
        if (_missionStatus[msg.sender].claimedGoldenTicket) return false;
        IRegularMissionModule core = _resolveLotteryCore(_lId);
        (LotteryKind kind, address owner, , ) = core.getMissionTicketInfo(_lId, _tId);
        return owner == msg.sender && _isEligibleKind(kind);
    }

    function _canEarly(uint256 _lId, uint256 _tId) private view returns (bool) {
        if (_missionStatus[msg.sender].claimedEarlyBird) return false;
        IRegularMissionModule core = _resolveLotteryCore(_lId);
        (LotteryKind kind, address owner, uint64 purchaseTime, uint64 lotteryStart) = core.getMissionTicketInfo(
            _lId,
            _tId
        );
        if (owner != msg.sender || !_isEligibleKind(kind)) return false;
        return purchaseTime < lotteryStart + EARLY_PURCHASE_WINDOW;
    }

    function _canStackTheOdds(uint256 _lId, uint256 _tId) private view returns (bool) {
        if (_missionStatus[msg.sender].claimedStackTheOdds) return false;
        IRegularMissionModule core = _resolveLotteryCore(_lId);
        (LotteryKind kind, address owner, uint256 batchSize) = core.getMissionBatchData(_lId, _tId);
        if (owner != msg.sender || !_isEligibleKind(kind)) return false;
        return batchSize >= MIN_TICKETS;
    }

    /* ─────────────────────────── Internal setters ─────────────────────────────── */

    function _setLottery(address lottery_) internal {
        if (lottery_ == address(0)) revert ZeroAddress();
        lottery = ILotteryCore(lottery_);
        emit LotterySet(lottery_);
    }

    function _setHub(address hub_) internal {
        if (hub_ == address(0)) revert ZeroAddress();
        hub = ILotteryHub(hub_);
        emit HubSet(hub_);
    }

    function _setLegacyAdapter(address legacyAdapter_) internal {
        if (legacyAdapter_ == address(0)) revert ZeroAddress();
        legacyAdapter = ILotteryManager(legacyAdapter_);
        emit LegacyAdapterSet(legacyAdapter_);
    }

    function _setRewardPool(address rewardPool_) internal {
        if (rewardPool_ == address(0)) revert ZeroAddress();
        rewardPool = ICltRewardPool(rewardPool_);
        emit RewardPoolSet(rewardPool_);
    }
}
