// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICltRewarder} from "./interfaces/ICltRewarder.sol";
import {ICltRewardPool} from "./interfaces/ICltRewardPool.sol";
import {LotteryStatus} from "./structs/MetadataStruct.sol";

/// @dev Minimal Hub surface used to query lottery status for draw-completion checks.
interface ILotteryHubForRewarder {
    function getLotteryStatus(uint256 lotteryId) external view returns (LotteryStatus);
}

/// @title CltRewarder
/// @notice Standalone CLT reward ledger for referrer welcome bonuses.
/// @dev Wired to `LotteryHub`: on `buyTickets`, when `ReferralRegistry.linkReferrer`
///      returns `isNew == true`, the Hub calls `addCltReferrerBonus(referrer)` to credit
///      `referrerWelcomeBonus` (independent of `quote.cltLotteryReward`). Referrers claim
///      via `claimReferrerBonus()`.
///
///      Per-ticket buyer CLT is claimed via `claimCltPerTicketReward` / `claimCltPerTicketRewardBatch` (after draw)
///      (reads ticket balances and pulls from `CltRewardPool` directly). This contract also
///      exposes lottery referrer and per-ticket reward paths for optional integrations.
///
///      Access control:
///        • `DEFAULT_ADMIN_ROLE` — role administration.
///        • `WORKER_ROLE` — `setRewardPool`, `setCltReferrerWelcomeBonusAmount`, `setLotteryHub`.
///        • `REWARD_OPERATOR_ROLE` — accrual functions (Hub / managers at setup).
contract CltRewarder is AccessControl, ReentrancyGuard, ICltRewarder {
    /* ─────────────────────────────────────── Roles ──────────────────────────── */

    /// @notice Role for protocol worker configuration setters.
    bytes32 public constant WORKER_ROLE = keccak256("WORKER_ROLE");

    /// @notice Role for contracts that credit referrer / lottery CLT (typically `LotteryHub`).
    bytes32 public constant REWARD_OPERATOR_ROLE = keccak256("REWARD_OPERATOR_ROLE");

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice Bank that executes CLT transfers on claim.
    ICltRewardPool public rewardPool;

    /// @notice Hub used to resolve manager per lottery for draw-completion checks on per-ticket reward claims.
    ILotteryHubForRewarder public lotteryHub;

    /// @notice CLT credited per successful `addCltReferrerBonus` call.
    uint256 public referrerWelcomeBonus;

    /// @dev Unclaimed referrer welcome bonus per referrer (first invited-user link).
    mapping(address referrer => uint256 clt) private _pendingCltWelcomeBonus;

    /// @dev Per-lottery pending referrer CLT per user.
    mapping(uint256 lotteryId => mapping(address user => uint256 clt)) private _pendingCltLotteryReferrerReward;

    /// @dev Per-lottery pending buyer CLT per user.
    mapping(uint256 lotteryId => mapping(address user => uint256 clt)) private _pendingCltPerTicketReward;

    /// @dev Global per-buyer credited flag — persists across Hub migrations.
    ///      `CltRewarder` is the protocol-wide source of truth for welcome-bonus eligibility.
    ///      If `CltRewarder` itself is ever replaced, these flags must be migrated/backfilled
    ///      into the new Rewarder before activation.
    mapping(address user => bool) private _welcomeBonusCredited;

    /* ─────────────────────────────────────── Events ─────────────────────────── */
    /// @notice Emitted when the CLT bank address is updated.
    /// @param rewardPool New `ICltRewardPool` implementation.
    event RewardPoolSet(address indexed rewardPool);

    /// @notice Emitted when the lottery hub address is updated.
    /// @param lotteryHub New hub address.
    event LotteryHubSet(address indexed lotteryHub);

    /// @notice Emitted when `referrerWelcomeBonus` is updated.
    /// @param amount New flat bonus per new referral.
    event ReferrerWelcomeBonusSet(uint256 amount);

    /// @notice Emitted when `referrerWelcomeBonus` is added to `referrer`.
    /// @param referrer Referrer who received the bonus.
    /// @param amount   Amount of CLT added.
    event CltReferrerWelcomeBonusAdded(
        uint256 indexed lotteryId,
        address indexed referrer,
        uint256 amount,
        address user
    );

    /// @notice Emitted when referrer welcome bonus is claimed via `claimReferrerBonus`.
    /// @param referrer Referrer who claimed.
    /// @param amount   CLT withdrawn from `rewardPool`.
    event CltReferrerBonusClaimed(address indexed referrer, uint256 amount);

    /// @notice Emitted when lottery referrer CLT is added to `user` in `lotteryId`.
    /// @param lotteryId Lottery the reward is tied to.
    /// @param user      Buyer or beneficiary of the accrual.
    /// @param amount    CLT amount added to pending balance.
    event CltLotteryRewardAdded(uint256 indexed lotteryId, address indexed user, uint256 amount);

    /// @notice Emitted when lottery referrer CLT is claimed for `user` in `lotteryId`.
    /// @param lotteryId Lottery the reward is tied to.
    /// @param user      Buyer or beneficiary of the accrual.
    /// @param amount    CLT amount withdrawn from `rewardPool`.
    event CltLotteryRewardClaimed(uint256 indexed lotteryId, address indexed user, uint256 amount);

    /// @notice Emitted when `claimCltLotteryReferrerRewardBatch` withdraws CLT for `user`.
    /// @param user        Claimant.
    /// @param totalAmount CLT withdrawn from `rewardPool`.
    /// @param lotteryIds  IDs passed to the batch claim (includes zero-balance entries).
    event CltLotteryRewardClaimedBatch(address indexed user, uint256 totalAmount, uint256[] lotteryIds);

    /// @notice Emitted when per-ticket buyer CLT is added to `user` in `lotteryId`.
    /// @param lotteryId Lottery the reward is tied to.
    /// @param user      Buyer or beneficiary of the accrual.
    /// @param amount    CLT amount added to pending balance.
    event CltPerTicketRewardAdded(uint256 indexed lotteryId, address indexed user, uint256 amount);

    /// @notice Emitted when per-ticket buyer CLT is claimed for `user` in `lotteryId`.
    /// @param lotteryId Lottery the reward is tied to.
    /// @param user      Buyer or beneficiary of the accrual.
    /// @param amount    CLT amount withdrawn from `rewardPool`.
    event CltPerTicketRewardClaimed(uint256 indexed lotteryId, address indexed user, uint256 amount);

    /// @notice Emitted when `claimCltPerTicketRewardBatch` withdraws CLT for `user`.
    /// @param user        Claimant.
    /// @param totalAmount CLT withdrawn from `rewardPool`.
    /// @param lotteryIds  Draw-completed IDs from the input list (non-drawn IDs omitted).
    event CltPerTicketRewardClaimedBatch(address indexed user, uint256 totalAmount, uint256[] lotteryIds);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when a claim is attempted with zero pending CLT.
    error NoCltReward();

    /// @notice Thrown when a required address argument is `address(0)`.
    error ZeroAddress();

    /// @notice Thrown when an accrual function is called with zero `amount`.
    error ZeroAmount();

    /// @notice Thrown when per-ticket reward is claimed before the lottery draw is completed.
    error LotteryNotDrawn();

    /// @notice Thrown when `lotteryHub` has not been configured yet.
    error LotteryHubNotSet();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Deploys the rewarder; deployer receives `WORKER_ROLE` and `REWARD_OPERATOR_ROLE` until reassigned.
    /// @param initialDefaultAdmin Address receiving `DEFAULT_ADMIN_ROLE`.
    constructor(address initialDefaultAdmin) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
        _grantRole(WORKER_ROLE, msg.sender);
    }

    /* ─────────────────────────── Configuration (WORKER_ROLE) ───────────────── */

    /// @notice Points payouts at a new `CltRewardPool` and grants it `WITHDRAW_ROLE` separately at setup.
    /// @param rewardPool_ Non-zero `CltRewardPool` address.
    function setRewardPool(address rewardPool_) external onlyRole(WORKER_ROLE) {
        if (rewardPool_ == address(0)) revert ZeroAddress();
        rewardPool = ICltRewardPool(rewardPool_);
        emit RewardPoolSet(rewardPool_);
    }

    /// @notice Sets the Hub used to resolve lottery manager for draw-status checks on per-ticket reward claims.
    /// @param lotteryHub_ Non-zero `LotteryHub` address.
    function setLotteryHub(address lotteryHub_) external onlyRole(WORKER_ROLE) {
        if (lotteryHub_ == address(0)) revert ZeroAddress();
        lotteryHub = ILotteryHubForRewarder(lotteryHub_);
        emit LotteryHubSet(lotteryHub_);
    }

    /// @notice Sets the flat CLT amount credited on each new referral via `addCltReferrerBonus`.
    /// @param amount Wei amount; zero disables accrual (calls become no-ops).
    function setCltReferrerWelcomeBonusAmount(uint256 amount) external onlyRole(WORKER_ROLE) {
        referrerWelcomeBonus = amount;
        emit ReferrerWelcomeBonusSet(amount);
    }

    /* ─────────────────────────── Welcome bonus ──────────────────────────────── */

    /// @inheritdoc ICltRewarder
    function addCltReferreWelcomeBonus(
        address referrer,
        uint256 lotteryId,
        address user
    ) external onlyRole(REWARD_OPERATOR_ROLE) returns (bool) {
        if (_welcomeBonusCredited[user]) return true;

        uint256 amount = referrerWelcomeBonus;
        if (amount == 0) return false;
        _welcomeBonusCredited[user] = true;
        _pendingCltWelcomeBonus[referrer] += amount;
        
        emit CltReferrerWelcomeBonusAdded(lotteryId, referrer, amount, user);
        return true;
    }

    /// @inheritdoc ICltRewarder
    function isWelcomeBonusCredited(address user) external view returns (bool) {
        return _welcomeBonusCredited[user];
    }

    /// @inheritdoc ICltRewarder
    function getCltWelcomeBonusAmount(address referrer) external view returns (uint256) {
        return _pendingCltWelcomeBonus[referrer];
    }

    /// @inheritdoc ICltRewarder
    function claimReferrerBonus() external nonReentrant {
        address user = msg.sender;
        uint256 amount = _pendingCltWelcomeBonus[user];
        if (amount == 0) revert NoCltReward();
        _pendingCltWelcomeBonus[user] = 0;
        rewardPool.withdrawClt(user, amount);
        emit CltReferrerBonusClaimed(user, amount);
    }

    /* ─────────────────────────── Lottery referrer rewards ─────────────────── */
    /// @inheritdoc ICltRewarder
    function getCltLotteryReferrerRewardAmount(
        uint256[] calldata lotteryIds,
        address user
    ) external view returns (uint256 totalAmount) {
        uint256 length = lotteryIds.length;
        for (uint256 i = 0; i < length; i++) {
            totalAmount += _pendingCltLotteryReferrerReward[lotteryIds[i]][user];
        }
        return totalAmount;
    }

    /// @inheritdoc ICltRewarder
    function claimCltLotteryReferrerReward(uint256 lotteryId) external nonReentrant {
        address user = msg.sender;
        uint256 amount = _pendingCltLotteryReferrerReward[lotteryId][user];
        if (amount == 0) revert NoCltReward();
        _pendingCltLotteryReferrerReward[lotteryId][user] = 0;
        rewardPool.withdrawClt(user, amount);
        emit CltLotteryRewardClaimed(lotteryId, user, amount);
    }

    /// @inheritdoc ICltRewarder
    function claimCltLotteryReferrerRewardBatch(uint256[] calldata lotteryIds) external nonReentrant {
        address user = msg.sender;
        uint256 length = lotteryIds.length;
        uint256 totalAmount;
        for (uint256 i = 0; i < length; ++i) {
            uint256 lotteryId = lotteryIds[i];
            uint256 amount = _pendingCltLotteryReferrerReward[lotteryId][user];
            if (amount > 0) {
                totalAmount += amount;
                _pendingCltLotteryReferrerReward[lotteryId][user] = 0;
            }
        }

        if (totalAmount == 0) revert NoCltReward();
        rewardPool.withdrawClt(user, totalAmount);
        emit CltLotteryRewardClaimedBatch(user, totalAmount, lotteryIds);
    }

    /* ─────────────────────────── Internal helpers ──────────────────────────── */

    /// @dev Reverts if `lotteryHub` is unset or the lottery has not yet completed its draw.
    ///      Accepted statuses: `DRAW_COMPLETED` and `FULLY_CLAIMED`.
    function _assertLotteryPlayed(uint256 _lotteryId) private view {
        ILotteryHubForRewarder hub = lotteryHub;
        if (address(hub) == address(0)) revert LotteryHubNotSet();
        LotteryStatus status = hub.getLotteryStatus(_lotteryId);
        if (status != LotteryStatus.DRAW_COMPLETED && status != LotteryStatus.FULLY_CLAIMED) revert LotteryNotDrawn();
    }

    /* ─────────────────────────── Per-ticket buyer rewards ─────────────────── */
    /// @inheritdoc ICltRewarder
    function addCltPurchaseRewards(
        uint256 lotteryId,
        address buyer,
        uint256 buyerAmount,
        address referrer,
        uint256 referrerAmount
    ) external onlyRole(REWARD_OPERATOR_ROLE) {
        if (buyerAmount > 0) {
            _pendingCltPerTicketReward[lotteryId][buyer] += buyerAmount;
            emit CltPerTicketRewardAdded(lotteryId, buyer, buyerAmount);
        }
        if (referrerAmount > 0 && referrer != address(0)) {
            _pendingCltLotteryReferrerReward[lotteryId][referrer] += referrerAmount;
            emit CltLotteryRewardAdded(lotteryId, referrer, referrerAmount);
        }
    }

    function getCltPerTicketRewardAmount(
        uint256[] calldata lotteryIds,
        address user
    ) external view returns (uint256 totalAmount) {
        uint256 length = lotteryIds.length;
        ILotteryHubForRewarder hub = lotteryHub;

        for (uint256 i = 0; i < length; ++i) {
            uint256 lotteryId = lotteryIds[i];
            LotteryStatus status = hub.getLotteryStatus(lotteryId);
            if (status != LotteryStatus.DRAW_COMPLETED && status != LotteryStatus.FULLY_CLAIMED) continue;
            uint256 amount = _pendingCltPerTicketReward[lotteryId][user];
            if (amount > 0) {
                totalAmount += amount;
            }
        }
        return totalAmount;
    }

    function claimCltPerTicketReward(uint256 lotteryId) external nonReentrant {
        _assertLotteryPlayed(lotteryId);
        address user = msg.sender;
        uint256 amount = _pendingCltPerTicketReward[lotteryId][user];
        if (amount == 0) revert NoCltReward();
        _pendingCltPerTicketReward[lotteryId][user] = 0;
        rewardPool.withdrawClt(user, amount);
        emit CltPerTicketRewardClaimed(lotteryId, user, amount);
    }

    /// @inheritdoc ICltRewarder
    function claimCltPerTicketRewardBatch(uint256[] calldata lotteryIds) external nonReentrant {
        ILotteryHubForRewarder hub = lotteryHub;
        if (address(hub) == address(0)) revert LotteryHubNotSet();
        address user = msg.sender;
        uint256 length = lotteryIds.length;
        uint256 totalAmount;
        uint256 completedCount;

        uint256[] memory completedLotteryIds = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            uint256 lotteryId = lotteryIds[i];
            LotteryStatus status = hub.getLotteryStatus(lotteryId);
            if (status != LotteryStatus.DRAW_COMPLETED && status != LotteryStatus.FULLY_CLAIMED) {
                continue;
            }

            uint256 amount = _pendingCltPerTicketReward[lotteryId][user];
            if (amount > 0) {
                totalAmount += amount;
                _pendingCltPerTicketReward[lotteryId][user] = 0;
                completedLotteryIds[completedCount++] = lotteryId;
            }
        }

        if (totalAmount == 0) revert NoCltReward();

        // Shrink the over-allocated array to the draw-completed entries recorded above.
        // Safe: `completedCount <= length`, so this only reduces the array length.
        assembly {
            mstore(completedLotteryIds, completedCount)
        }

        rewardPool.withdrawClt(user, totalAmount);
        emit CltPerTicketRewardClaimedBatch(user, totalAmount, completedLotteryIds);
    }
}
