// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LotteryCoreLib} from "../libraries/LotteryCoreLib.sol";
import {LotteryPrizeLib} from "../libraries/LotteryPrizeLib.sol";
import {MultiplierPayoutModel} from "./MultiplierPayoutModel.sol";
import {TierPayoutModel} from "./TierPayoutModel.sol";
import {WinRatePayoutModel} from "./WinRatePayoutModel.sol";
import {LotteryTickets} from "../LotteryTickets.sol";
import {IRandomnessCoordinatorLike, ILotteryRandomnessConsumer} from "../interfaces/IRandomnessCoordinatorLike.sol";
import {Lottery, LotteryStored, LotteryState, LotteryStateView, LotteryStatus, LotteryKind, LotteryParams, PayoutModel} from "../structs/MetadataStruct.sol";
import {TicketPurchaseQuote} from "../structs/TicketPurchaseQuote.sol";

/// @title BaseLotteryManager
/// @notice Abstract base for lottery manager contracts (USER, REGULAR, SUPER, BATTLE variants).
/// @dev Architecture:
///
///      **LotteryHub** — Users interact through the Hub. The Hub holds `HUB_ROLE` on each creator,
///      assigns monotonic `lotteryId` values, forwards `originalCaller` (the end user), executes
///      ERC-20 transfers for ticket purchases, then calls `registerTicketPurchase`. Creation and
///      purchase entry points on creators must be Hub-gated; never use `msg.sender` for ownership
///      or fee attribution when the Hub is the caller.
///
///      **RndConsumer (VRF)** — `rndCoordinator` is the shared randomness coordinator. Draw
///      requests call `requestRandomness`; fulfillment arrives on `fulfillRandomness` from an
///      account with `RANDOMNESS_COORDINATOR_ROLE`. Single-ticket lotteries skip VRF and use
///      seed `1` instantly.
///
///      **Creator storage model** (per `lotteryId`, all on this contract):
///        - `_lotteries[lotteryId]` → static `Lottery` (kind, model, creator, `LotteryParams`).
///        - `_state[lotteryId]` → runtime `LotteryState` (status, seed, prize pool, claims bitmap).
///        - `_donations[lotteryId][donor]` → optional prize-pool top-ups before draw.
///        - Inherited ticket layer: `_lotteryIndex`, `_ownerships`, `balanceOf` (`LotteryTickets`).
///
///      **Prizes** — Paid by direct ERC-20 transfer from the creator balance. Winner slots are
///      0-based ordinals; winning ticket IDs are derived from `seed` via `LotteryPrizeLib`.
///      Claim state uses a per-winner bitmap in `LotteryState.claimedWords`.
///
///      Concrete creators implement payout math (`_calcPrize`), Hub creation
///      (`createLotteryFromHub`), quoting/payment (`quoteTicketPurchase`, `registerTicketPurchase`),
///      and may override `_prizeAsset` when the prize token differs from the ticket token.
abstract contract BaseLotteryManager is
    AccessControl,
    ReentrancyGuard,
    LotteryTickets,
    ILotteryRandomnessConsumer,
    MultiplierPayoutModel,
    TierPayoutModel,
    WinRatePayoutModel
{
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── Constants ─────────────────────── */

    /// @notice Role for Hub-only creation and ticket registration paths.
    bytes32 public constant HUB_ROLE = keccak256("HUB_ROLE");

    /// @notice Role for protocol worker configuration setters.
    bytes32 public constant WORKER_ROLE = keccak256("WORKER_ROLE");

    /// @notice Role allowed to call `fulfillRandomness` (RndConsumer).
    bytes32 public constant RANDOMNESS_COORDINATOR_ROLE = keccak256("RANDOMNESS_COORDINATOR_ROLE");

    /// @dev Seconds after a VRF request during which a retry is blocked; once elapsed, calling
    ///      `requestDraw` again re-issues the VRF request.
    uint256 private constant VRF_TIMEOUT = 15 minutes;

    /// @notice Basis-points denominator (100.00%).
    uint256 public constant BP_DENOMINATOR = 10_000;

    /// @dev Minimum allowed ticket price (smallest units of `params.asset`).
    uint256 internal constant MIN_TICKET_PRICE = 100;

    /// @dev Maximum protocol fee on User Lottery ticket sales (20%).
    uint256 internal constant MAX_CREATOR_FEE_BP = 2_000;

    /// @dev Maximum creator fee cap and protocol lottery fee limit (30%).
    uint256 internal constant MAX_FEE_LIMIT_BP = 3_000;

    /// @dev Maximum REGULAR→SUPER feeder allocation (20%).
    uint256 internal constant MAX_ALLOCATION_BP = 2_000;

    /// @dev Maximum CLT reward per ticket (1_000 CLT, 18 decimals).
    uint256 internal constant MAX_CLT_PER_TICKET = 1_000 * 10 ** 18;

    /// @notice Public cap reference for tier count configuration.
    uint256 internal constant MAX_TIER_LENGTH = 100;

    /// @notice Protocol-wide minimum win rate (BP) for configuration bounds.
    uint256 internal constant MIN_WIN_RATE_BP = 10;

    /// @notice Protocol-wide maximum win rate (BP) for configuration bounds.
    uint256 internal constant MAX_WIN_RATE_BP = 7_500;

    /// @notice Protocol-wide minimum payout multiplier (BP) for configuration bounds.
    uint256 internal constant MIN_PAYOUT_MULTIPLIER_BP = 15_000;

    /// @dev Absolute ceiling on tickets purchasable in a single `buyTickets` call.
    ///      Immutable after compile — no role or governance mechanism can raise
    ///      `ticketLimit` above this value.
    uint256 internal constant HARD_MAX_TICKETS_PER_TX = 100;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice LotteryHub that routes creation and ticket purchases to this manager.
    address public hub;

    /// @notice Shared VRF coordinator (`RndConsumer`).
    IRandomnessCoordinatorLike public rndCoordinator;

    /// @notice Configured minimum multiplier (BP) for MULTIPLIER lotteries; `0` disables lower bound check.
    uint32 public minimumMultiplierBp;

    /// @notice Configured maximum multiplier (BP) for MULTIPLIER lotteries; `0` disables upper bound check.
    uint32 public maximumMultiplierBp;

    /// @notice Configured minimum win rate (BP) for WIN_RATE lotteries.
    uint16 public minimumWinRateBp;

    /// @notice Configured maximum win rate (BP) for WIN_RATE lotteries.
    uint16 public maximumWinRateBp;

    /// @notice Maximum tier count for TIER lotteries.
    uint16 public maximumTiers;

    /// @notice Share of protocol fee revenue paid to referrers (BP, 0–10_000).
    uint16 public protocolFeeRevenueShareBp;

    /// @notice Configurable per-tx ticket cap for this manager (1–HARD_MAX_TICKETS_PER_TX).
    ///         Each deployed manager instance holds its own independent value.
    ///         Initialized to HARD_MAX_TICKETS_PER_TX (100) in the constructor.
    uint8 public ticketLimit;

    /// @dev Immutable lottery configuration set at creation (packed, 4 slots; see `LotteryStored`).
    ///      External views unpack into the ABI-facing `Lottery` struct via `getLottery`.
    mapping(uint256 lotteryId => LotteryStored) internal _lotteries;

    /// @dev Mutable lifecycle, draw, and prize accounting.
    mapping(uint256 lotteryId => LotteryState) internal _state;

    /// @dev Per-donor amounts credited to the prize pool (withdrawable before draw).
    mapping(uint256 lotteryId => mapping(address donor => uint256 amount)) internal _donations;

    /// @dev Hub settlement lock: `1` = idle, `2` = a Hub is between its balance snapshots on this
    ///      manager. Shared by every `HUB_ROLE` holder so a nested credit through another Hub cannot
    ///      pollute an outer balance-delta check. Plain storage because the EVM target is `paris`.
    uint256 private _hubSettlement;

    /// @notice Winner slot summary for paginated views.
    struct WinnerInfo {
        /// @dev 1-based winning ticket ID.
        uint256 ticketIdx;
        /// @dev Prize amount for this winner ordinal.
        uint256 prizeAmount;
        /// @dev Owner of the winning ticket.
        address winner;
        /// @dev True when this slot's prize has already been claimed.
        bool claimed;
    }

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Manager submitted a Chainlink VRF draw request.
    /// @param lotteryId  Lottery being drawn.
    /// @param requestId  Coordinator request ID.
    event DrawRequested(uint256 indexed lotteryId, uint256 indexed requestId);

    /// @notice Draw seed stored and lottery marked draw-complete (alias for integrators).
    /// @param lotteryId Lottery ID.
    /// @param seed      Final randomness seed.
    event DrawCompleted(uint256 indexed lotteryId, uint256 seed);

    /// @notice `hub` address updated.
    event HubSet(address indexed hub);

    /// @notice `rndCoordinator` address updated.
    event RndCoordinatorSet(address indexed rndCoordinator);

    /// @notice Old coordinator role revocation deferred because it still has pending VRF requests.
    /// @dev Emitted by `setRndConsumer` when the old consumer's `pendingRequestCount(address(this))`
    ///      is non-zero. The worker must call `finalizeConsumerRevocation(oldConsumer)` after the count
    ///      reaches zero.
    /// @param oldConsumer  Previous coordinator contract.
    /// @param pendingCount Outstanding requests from this manager on the old consumer.
    event ConsumerRevocationDeferred(address indexed oldConsumer, uint16 pendingCount);

    /// @notice Stored or virtual lifecycle status transition.
    event LotteryStatusUpdated(uint256 indexed lotteryId, LotteryStatus indexed status);

    /// @notice Donor credited `amount` of `params.asset` to the prize pool.
    event Donated(uint256 indexed lotteryId, address indexed donor, uint256 amount);

    /// @notice Worker set minimum win rate bound.
    event MinimumWinRateBpSet(uint16 indexed minimumWinRateBp);

    /// @notice Worker set maximum win rate bound.
    event MaximumWinRateBpSet(uint16 indexed maximumWinRateBp);

    /// @notice Worker set maximum tier count.
    event MaximumTiersSet(uint16 indexed value);

    /// @notice Worker set minimum multiplier bound.
    event MinimumMultiplierBpSet(uint32 indexed value);

    /// @notice Worker set maximum multiplier bound.
    event MaximumMultiplierBpSet(uint32 indexed value);

    /// @notice Worker set referrer revenue share on protocol fees.
    event ProtocolFeeRevenueShareBpSet(uint16 indexed value);

    /// @notice Worker updated the per-tx ticket cap for this manager.
    event TicketLimitSet(uint8 indexed value);

    /// @notice Donor withdrew a pre-draw donation.
    event DonationWithdrawn(uint256 indexed lotteryId, address indexed donor, uint256 amount);

    /// @notice Single winner slot claimed on the manager (includes payout amount).
    event PrizeClaimed(uint256 indexed lotteryId, uint256 indexed winnerIndex, address indexed winner, uint256 amount);

    /// @notice New lottery initialised by the Hub on this creator.
    event LotteryCreated(
        uint256 indexed lotteryId,
        address indexed originalCaller,
        LotteryKind kind,
        PayoutModel model
    );

    /// @notice Multiple winner slots claimed in one transaction.
    event PrizeClaimedBatch(
        uint256 indexed lotteryId,
        address indexed claimer,
        uint256 totalAmount,
        uint24[] winnerIndices
    );

    /* ─────────────────────────────────────── Errors ─────────────────────────── */
    /// @notice Lottery `startTime` not reached (stored status still PENDING).
    error LotteryNotStartedYet();

    /// @notice Current time is past `params.endTime`.
    error LotteryEnded();

    /// @notice Lottery is not in an open purchase state.
    error LotteryNotActive();

    /// @notice Purchase quantity exceeds remaining ticket capacity.
    /// @param ticketsLeft Tickets still available.
    error ExceedsMaxTickets(uint256 ticketsLeft);

    /// @notice Single `buyTickets` call qty exceeds the per-tx ticket cap.
    /// @param limit Active `ticketLimit` at the time of the call.
    error ExceedsBatchLimit(uint256 limit);

    /// @notice Proposed `ticketLimit` is zero or exceeds `HARD_MAX_TICKETS_PER_TX`.
    error InvalidTicketLimit();

    /// @notice Draw cannot start until sold out or past `endTime` (READY_TO_DRAW).
    error NotReadyToDraw();

    /// @notice Draw requested but no tickets were sold.
    error NoTicketsSold();

    /// @notice `LotteryState.seed` already set; duplicate fulfillment blocked.
    error SeedAlreadyAdded();

    /// @notice Draw was not requested (wrong status for fulfill/re-request).
    error DrawNotRequested();

    /// @notice `finalizeConsumerRevocation` was called with the currently active coordinator.
    ///         Revoking the active coordinator would break all ongoing and future VRF requests.
    error CannotRevokeActiveConsumer();

    /// @notice `finalizeConsumerRevocation` was called while the old consumer still has
    ///         unresolved VRF requests for this manager.
    /// @param count Outstanding pending request count on the old consumer.
    error ConsumerStillPending(uint16 count);

    /// @notice Prizes cannot be claimed until draw completes.
    error DrawNotCompleted();

    /// @notice `winnerIndex` is out of range for this lottery's winner count.
    error InvalidWinnerIndex();

    /// @notice This winner slot was already claimed.
    error PrizeAlreadyClaimed();

    /// @notice `claimer` does not own the winning ticket for this slot.
    error NotWinner();

    /// @notice ETH refund to draw requester failed.
    /// @dev Declared for ABI stability. Not thrown: draw refunds are credited in `RndConsumer`.
    error EtherRefundFailed();

    /// @notice Basis-point value is invalid for the field.
    error InvalidBp();

    /// @notice VRF re-request attempted before `drawDeadline` elapsed.
    error DrawDeadlineNotReached();

    /// @notice Caller has no donation balance to withdraw.
    error NoDonation();

    /// @notice Donations or purchases blocked after draw started or completed.
    error LotteryAlreadyDrawn();

    /// @notice Donation withdrawal is only allowed when the lottery is CANCELLED
    ///         (expired with zero ticket sales). Attempting to withdraw while the
    ///         lottery is in any other state (ACTIVE, READY_TO_DRAW, DRAW_REQUESTED,
    ///         DRAW_COMPLETED, FULLY_CLAIMED, or PENDING) reverts with this error.
    error DonationWithdrawalNotAllowed();

    /// @notice Thrown when donation is prohibited.
    error ProhibitedDonation();

    /// @notice Attempted to initialize a lottery ID that is already in use.
    ///         `_initLottery` enforces a write-once invariant: once a lottery ID has been
    ///         initialized its `_state[id].status` moves from `NONE` to `ACTIVE` or `PENDING`
    ///         and can never return to `NONE`. Any subsequent initialization of the same ID
    ///         is unconditionally rejected.
    error LotteryAlreadyExists();

    /// @notice Donation or claim amount is zero.
    error ZeroAmount();

    /// @notice Actual tokens received after a direct `donate` transfer are less than `amount`.
    ///         Indicates a fee-on-transfer or otherwise non-standard token; not supported.
    error TransferAmountMismatch();

    /// @notice Direct claim caller is not Hub and `claimer != msg.sender`.
    error InvalidClaimer();

    /// @notice Amount parameter is zero where non-zero is required.
    error InvalidAmount();

    /// @notice `params.ticketPrice` below minimum.
    error InvalidTicketPrice();

    /// @notice `params.maxTickets` is zero.
    error InvalidMaxTickets();

    /// @notice `startTime` / `endTime` ordering or window is invalid.
    error InvalidTimeRange();

    /// @notice Lottery duration exceeds creator-type `maxDuration`.
    error ExceedsMaxDuration();

    /// @notice Multiplier BP outside configured bounds.
    error InvalidPayoutMultiplier();

    /// @notice Win rate BP outside configured bounds.
    error InvalidWinRateBp();

    /// @notice Tier array empty or longer than `maximumTiers`.
    /// @param count Rejected tier count.
    error TooManyTiers(uint256 count);

    /// @notice Minimum ticket count constraint violated.
    error InvalidMinTicketCount();

    /// @notice Creator commission BP too high.
    error InvalidCreatorCommission();

    /// @notice Feeder allocation BP too high.
    error InvalidAllocation();

    /// @notice SUPER feeder link requires non-zero super lottery ID.
    error ZeroSuperLotteryId();

    /// @notice Per-ticket CLT reward exceeds cap.
    error InvalidCltTicketReward();

    /// @notice Referrer protocol-fee share exceeds 100%.
    error InvalidProtocolFeeRevenueShare();

    /// @notice Thrown when `payer` does not match `msg.sender` on a direct (non-Hub) draw call.
    error InvalidPayer();

    /* ─────────────────────────────────────── Modifiers ──────────────────────── */

    /// @dev Restricts to accounts with `HUB_ROLE` (the deployed LotteryHub).
    modifier onlyHub() {
        _checkRole(HUB_ROLE);
        _;
    }

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Deploys the creator and wires the Hub.  RndConsumer is set post-deploy via `setRndConsumer`.
    /// @param initialDefaultAdmin Account receiving `DEFAULT_ADMIN_ROLE`.
    /// @param hub_                LotteryHub address (`HUB_ROLE`).
    constructor(address initialDefaultAdmin, address hub_) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
        _grantRole(WORKER_ROLE, initialDefaultAdmin);

        _setHub(hub_);
        _grantRole(HUB_ROLE, hub_);

        ticketLimit = uint8(HARD_MAX_TICKETS_PER_TX);
        _hubSettlement = 1;
    }

    /* ─────────────────────────── Configuration (WORKER_ROLE) ──────────── */

    /// @notice Migrates to a new LotteryHub: revokes `HUB_ROLE` from the old address, grants it to the new one.
    function setHub(address hub_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setHub(hub_);
    }

    /// @notice Sets (or migrates) the VRF randomness coordinator.
    /// @param rndConsumer_ New RndConsumer address; must be non-zero and differ from current.
    function setRndConsumer(address rndConsumer_) external onlyRole(WORKER_ROLE) {
        if (rndConsumer_ == address(0)) revert ZeroAddress();
        address prev = address(rndCoordinator);

        if (rndConsumer_ == prev) return;

        rndCoordinator = IRandomnessCoordinatorLike(rndConsumer_);
        _grantRole(RANDOMNESS_COORDINATOR_ROLE, rndConsumer_);

        if (prev != address(0)) {
            uint16 pending = IRandomnessCoordinatorLike(prev).pendingRequestCount(address(this));
            if (pending == 0) {
                _revokeRole(RANDOMNESS_COORDINATOR_ROLE, prev);
            } else {
                // Old coordinator keeps its role until its pending requests drain.
                emit ConsumerRevocationDeferred(prev, pending);
            }
        }
        emit RndCoordinatorSet(rndConsumer_);
    }

    /// @notice Revokes `RANDOMNESS_COORDINATOR_ROLE` from a previously superseded coordinator
    ///         once all its in-flight VRF requests for this manager have been resolved.
    /// @dev Called by `WORKER_ROLE` after {ConsumerRevocationDeferred} confirms that
    ///      `oldConsumer.pendingRequestCount(address(this)) == 0`.
    ///      Reverts if `oldConsumer` is still the active coordinator (would break live draws)
    ///      or if it still has pending requests.
    /// @param oldConsumer Previous coordinator contract to revoke.
    function finalizeConsumerRevocation(address oldConsumer) external onlyRole(WORKER_ROLE) {
        if (oldConsumer == address(0)) revert ZeroAddress();
        if (oldConsumer == address(rndCoordinator)) revert CannotRevokeActiveConsumer();
        uint16 pending = IRandomnessCoordinatorLike(oldConsumer).pendingRequestCount(address(this));
        if (pending != 0) revert ConsumerStillPending(pending);
        _revokeRole(RANDOMNESS_COORDINATOR_ROLE, oldConsumer);
    }

    function _setHub(address hub_) private {
        if (hub_ == address(0)) revert ZeroAddress();
        address prev = hub;
        // Revoke the old Hub only when there is a previous Hub and it differs from the new one.
        // Skipping when prev == hub_ prevents a spurious RoleRevoked event on same-address re-sets.
        if (prev != address(0) && prev != hub_) {
            _revokeRole(HUB_ROLE, prev);
        }
        hub = hub_;
        _grantRole(HUB_ROLE, hub_);
        emit HubSet(hub_);
    }

    /// @notice Sets maximum tier count for TIER lotteries.
    /// @param newMaximumTiers New cap; must be ≤ `MAX_TIER_LENGTH`.
    function setMaximumTiers(uint16 newMaximumTiers) external onlyRole(WORKER_ROLE) {
        if (newMaximumTiers > MAX_TIER_LENGTH) revert TooManyTiers(newMaximumTiers);
        maximumTiers = newMaximumTiers;
        emit MaximumTiersSet(newMaximumTiers);
    }

    /// @notice Sets minimum win rate bound (BP).
    /// @param minimumWinRateBp_ Must be ≥ `MIN_WIN_RATE_BP` and ≤ `maximumWinRateBp` when set.
    function setMinimumWinRateBp(uint16 minimumWinRateBp_) external onlyRole(WORKER_ROLE) {
        if (minimumWinRateBp_ < MIN_WIN_RATE_BP) revert InvalidWinRateBp();
        if (maximumWinRateBp > 0 && minimumWinRateBp_ > maximumWinRateBp) revert InvalidWinRateBp();
        minimumWinRateBp = minimumWinRateBp_;
        emit MinimumWinRateBpSet(minimumWinRateBp_);
    }

    /// @notice Sets maximum win rate bound (BP).
    /// @param maximumWinRateBp_ Must be ≤ `MAX_WIN_RATE_BP` and ≥ `minimumWinRateBp` when set.
    function setMaximumWinRateBp(uint16 maximumWinRateBp_) external onlyRole(WORKER_ROLE) {
        if (maximumWinRateBp_ > MAX_WIN_RATE_BP) revert InvalidWinRateBp();
        if (minimumWinRateBp > 0 && maximumWinRateBp_ < minimumWinRateBp) revert InvalidWinRateBp();
        maximumWinRateBp = maximumWinRateBp_;
        emit MaximumWinRateBpSet(maximumWinRateBp_);
    }

    /// @notice Sets minimum payout multiplier bound (BP).
    /// @param minimumMultiplierBp_ Must be ≥ `MIN_PAYOUT_MULTIPLIER_BP` and ≤ `maximumMultiplierBp` when set.
    function setMinimumMultiplierBp(uint32 minimumMultiplierBp_) external onlyRole(WORKER_ROLE) {
        if (minimumMultiplierBp_ < MIN_PAYOUT_MULTIPLIER_BP) revert InvalidPayoutMultiplier();
        if (maximumMultiplierBp > 0 && minimumMultiplierBp_ > maximumMultiplierBp) revert InvalidPayoutMultiplier();
        minimumMultiplierBp = minimumMultiplierBp_;
        emit MinimumMultiplierBpSet(minimumMultiplierBp_);
    }

    /// @notice Sets maximum payout multiplier bound (BP).
    /// @param newMaximumMultiplierBp Must be ≥ `minimumMultiplierBp` when that is non-zero.
    function setMaximumMultiplierBp(uint32 newMaximumMultiplierBp) external onlyRole(WORKER_ROLE) {
        if (minimumMultiplierBp > 0 && newMaximumMultiplierBp < minimumMultiplierBp) {
            revert InvalidPayoutMultiplier();
        }
        maximumMultiplierBp = newMaximumMultiplierBp;
        emit MaximumMultiplierBpSet(newMaximumMultiplierBp);
    }

    /// @notice Sets referrer share of protocol fee revenue (BP).
    /// @param newProtocolFeeRevenueShareBp Value in `[0, BP_DENOMINATOR]`.
    function setProtocolFeeRevenueShareBp(uint16 newProtocolFeeRevenueShareBp) external onlyRole(WORKER_ROLE) {
        if (newProtocolFeeRevenueShareBp > BP_DENOMINATOR) revert InvalidProtocolFeeRevenueShare();
        protocolFeeRevenueShareBp = newProtocolFeeRevenueShareBp;
        emit ProtocolFeeRevenueShareBpSet(newProtocolFeeRevenueShareBp);
    }

    /// @notice Sets the per-tx ticket cap for this manager.
    /// @dev Accepts values in `[1, HARD_MAX_TICKETS_PER_TX]`.  Zero is rejected to prevent
    ///      accidentally disabling all purchases; values above the compile-time ceiling
    ///      are rejected unconditionally — no role can bypass the constant.
    /// @param newTicketLimit New cap (1–100 inclusive).
    function setTicketLimit(uint8 newTicketLimit) external onlyRole(WORKER_ROLE) {
        if (newTicketLimit == 0 || newTicketLimit > HARD_MAX_TICKETS_PER_TX) revert InvalidTicketLimit();
        ticketLimit = newTicketLimit;
        emit TicketLimitSet(newTicketLimit);
    }

    /* ─────────────────────────── Payout hooks ───────────────────────────── */

    /// @notice Computes winner slot count for `lotteryId` at a given tickets-sold snapshot.
    /// @dev When exactly one ticket is sold, all payout models yield a single winner who may
    ///      claim the entire `prizePool` (including pre-draw donations) in one claim.
    ///      MULTIPLIER uses `min(K, sold)` to prevent duplicate winner slots when K > soldTickets;
    ///      WIN_RATE min 1 when sold > 0 and rate > 0; TIER uses `min(tiers.length, sold)`.
    ///      Body lives in `LotteryCoreLib.winnerCount`, shared with `LotteryWinnerReader`.
    function _winnerCount(uint256 _lotteryId, uint256 _sold) private view returns (uint24) {
        return LotteryCoreLib.winnerCount(_lotteries, _state, _lTiers, _lotteryId, _sold);
    }

    /// @notice Number of claimable winner slots for `lotteryId` at current ticket sales.
    function _countWinners(uint256 _lotteryId) internal view virtual returns (uint24) {
        return _winnerCount(_lotteryId, _sold(_lotteryId));
    }

    /// @notice MULTIPLIER prize for one winner slot; respects the single-ticket full-pool rule.
    /// @dev Uses `min(K, soldTickets)` as the effective winner count so that prize distribution
    ///      is consistent with `_winnerCount` — prevents unclaimed funds when K > soldTickets.
    ///
    ///      Retained for duel mocks that override `_calcPrize` and call this directly. The
    ///      production managers reach the same math through `LotteryCoreLib.calcPrize`, so the
    ///      optimizer drops this from their runtime bytecode.
    function _calcMultiplierPrizeForLottery(
        uint256 _lotteryId,
        uint24 _winnerIndex,
        uint256 _sold
    ) internal view returns (uint256) {
        if (_sold == 1) return _state[_lotteryId].prizePool;
        LotteryStored storage lot = _lotteries[_lotteryId];
        uint256 pool = _state[_lotteryId].prizePool;
        uint24 k = _calcMultiplierWinnerCount(pool, lot.payoutRateBp, lot.ticketPrice);
        uint24 effectiveWinners = (k < uint24(_sold)) ? k : uint24(_sold);
        if (effectiveWinners == 0) return 0;
        if (effectiveWinners == 1) return pool;
        uint256 perWinner = pool / effectiveWinners;
        return (_winnerIndex == 0) ? perWinner + (pool % effectiveWinners) : perWinner;
    }

    /// @notice Prize amount for a 0-based winner index after the draw.
    /// @dev Uses frozen `LotteryState.prizePool` and model-specific rules.
    ///      `sold` is the caller-cached tickets-sold count, avoiding repeated `_sold` reads
    ///      when claiming multiple winner slots in one transaction.
    ///      Body lives in `LotteryCoreLib.calcPrize`, shared with `LotteryWinnerReader`, so
    ///      claimed and displayed amounts cannot diverge.
    function _calcPrize(
        uint256 _lotteryId,
        uint24 _winnerIndex,
        uint256 _sold
    ) internal view virtual returns (uint256) {
        return LotteryCoreLib.calcPrize(_lotteries, _state, _lTiers, _lotteryId, _winnerIndex, _sold);
    }

    /* ─────────────────────────── Hub entry points (virtual) ─────────────── */

    /// @notice Initialises lottery-type-specific state after the Hub assigns `lotteryId`.
    /// @dev Concrete implementations must apply `onlyHub`. Typically calls `_initLottery` then
    ///      stores model-specific fields (tiers, feeder link, etc.).
    function createLotteryFromHub(
        uint256 lotteryId,
        address originalCaller,
        LotteryKind kind,
        PayoutModel payoutModel,
        LotteryParams calldata params,
        bytes calldata extraData
    ) external virtual;

    /// @notice Off-chain quote for a ticket purchase (no state change).
    /// @dev Hub calls this before transferring tokens; concrete creators split fees/pool.
    function quoteTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address referrer
    ) external view virtual returns (TicketPurchaseQuote memory);

    /// @notice Records a purchase after the Hub transferred tokens (no transfers here).
    /// @param lotteryId        Target lottery.
    /// @param qty              Ticket count.
    /// @param ticketRecipient  Ticket owner (may differ from payer).
    /// @param originalCaller   End user forwarded by the Hub.
    /// @param referrer         Referrer for fee sharing, if any.
    /// @param quote            Prior `quoteTicketPurchase` result.
    function registerTicketPurchase(
        uint256 lotteryId,
        uint256 qty,
        address ticketRecipient,
        address originalCaller,
        address referrer,
        TicketPurchaseQuote calldata quote
    ) external virtual;

    /* ─────────────────────────── Draw (public) ──────────────────────────── */

    /// @notice Requests a VRF draw when the lottery is ready and more than one ticket was sold.
    /// @dev **Hub path:** Hub passes `msg.sender` as `payer`. **Direct path:** caller must pass
    ///      `payer == msg.sender`. ETH refunds (overpay or single-ticket instant draw) are credited
    ///      to `payer` in `RndConsumer` (`pendingRefunds`, pulled via `withdrawRefund`); no ETH is
    ///      sent to `payer` during the draw.
    /// @dev **Retry:** if a prior request timed out without a seed, calling this again after the
    ///      `drawDeadline` re-issues the VRF request. It reverts before the deadline
    ///      (`DrawDeadlineNotReached`) or once a seed was delivered (`SeedAlreadyAdded`).
    /// @param lotteryId Target lottery.
    /// @param payer     Originating user; credited with any ETH refund in `RndConsumer`.
    function requestDraw(uint256 lotteryId, address payer) external payable nonReentrant {
        if (!hasRole(HUB_ROLE, msg.sender) && payer != msg.sender) revert InvalidPayer();
        _requestDrawBase(lotteryId, payer);
    }

    /* ─────────────────────────── Donations ───────────────────────────────── */

    /// @notice Validates that a donation is allowed and returns the asset, without writing
    ///         accounting.  The Hub calls this before the token transfer so it can measure the
    ///         actual received amount via a before/after `balanceOf` snapshot and then record it
    ///         via `recordDonationFor`.
    /// @dev **Caller:** Hub only (`HUB_ROLE`).
    ///      No local reentrancy guard: Hub-only entrypoint and the Hub's `donate` is guarded.
    /// @param lotteryId Target lottery.
    /// @param amount    Intended donation amount (used only for the zero-check; not stored here).
    /// @return asset    ERC-20 accepted for donations to `lotteryId`.
    function getDonationAsset(uint256 lotteryId, uint256 amount) external view returns (address asset, bool allowed) {
        if (amount == 0) revert ZeroAmount();
        return (_donationAsset(lotteryId), _checkDonateAllowed(lotteryId));
    }

    /// @notice Records the accounting for a Hub-routed donation after the Hub has measured the
    ///         actual received amount via a before/after `balanceOf` snapshot.
    /// @dev **Caller:** Hub only (`HUB_ROLE`), after `openHubSettlement`. Emits `Donated`.
    ///      Closes the Hub settlement as its last step.
    /// @param lotteryId     Target lottery.
    /// @param donor         Address credited as donor.
    /// @param actualReceived Tokens actually received (Hub-measured balance delta).
    function recordDonationFor(
        uint256 lotteryId,
        address donor,
        uint256 actualReceived
    ) external onlyHub nonReentrant {
        if (!_checkDonateAllowed(lotteryId)) revert ProhibitedDonation();
        _recordDonation(lotteryId, donor, actualReceived);
        _closeHubSettlement();
    }

    /// @notice Opens the Hub settlement before a Hub transfers tokens to this manager.
    /// @dev **Caller:** Hub only (`HUB_ROLE`). Reverts `ReentrancyGuardReentrantCall` while any
    ///      Hub's settlement is in flight on this manager. Closed by `recordDonationFor` /
    ///      `registerTicketPurchase` once all accounting is written.
    function openHubSettlement() external onlyHub {
        if (_hubSettlement == 2) revert ReentrancyGuardReentrantCall();
        _hubSettlement = 2;
    }

    /// @dev Must be the last statement of every Hub-routed accounting path.
    function _closeHubSettlement() internal {
        if (_hubSettlement != 2) revert ReentrancyGuardReentrantCall();
        _hubSettlement = 1;
    }

    /// @notice Withdraws the caller's pre-draw donation (direct path).
    /// @param lotteryId Target lottery.
    function withdrawDonation(uint256 lotteryId) external nonReentrant {
        _checkWithdrawDonationAllowed(lotteryId);
        _executeDonationWithdrawal(lotteryId, msg.sender);
    }

    /// @notice Hub-routed donation withdrawal; transfers asset directly to `donor`.
    /// @dev **Caller:** Hub only (`HUB_ROLE`). Hub passes original `msg.sender` as `donor`.
    ///      No local reentrancy guard: Hub-only entrypoint and the Hub's `withdrawDonation` is guarded.
    /// @param lotteryId Target lottery.
    /// @param donor     Address whose donation is cleared and refunded.
    function withdrawDonationFor(uint256 lotteryId, address donor) external onlyHub {
        _checkWithdrawDonationAllowed(lotteryId);
        _executeDonationWithdrawal(lotteryId, donor);
    }

    /// @notice Returns a donor's outstanding credited donation for `lotteryId`.
    /// @param lotteryId Lottery ID.
    /// @param donor     Donor address.
    /// @return          Amount still credited (before withdraw or draw).
    function donationOf(uint256 lotteryId, address donor) external view returns (uint256) {
        return _donations[lotteryId][donor];
    }

    /* ─────────────────────────── Donation internals ─────────────────────── */

    function _checkDonateAllowed(uint256 _lotteryId) private view returns (bool allowed) {
        LotteryStatus live = _getLotteryStatus(_lotteryId);
        return
            live != LotteryStatus.NONE &&
            live != LotteryStatus.CANCELLED &&
            live != LotteryStatus.DRAW_REQUESTED &&
            live != LotteryStatus.DRAW_COMPLETED &&
            live != LotteryStatus.FULLY_CLAIMED;
    }

    function _checkWithdrawDonationAllowed(uint256 _lotteryId) private view {
        if (_getLotteryStatus(_lotteryId) != LotteryStatus.CANCELLED)
            revert DonationWithdrawalNotAllowed();
    }

    function _recordDonation(uint256 _lotteryId, address _donor, uint256 _amount) internal virtual {
        _donations[_lotteryId][_donor] += _amount;
        _state[_lotteryId].prizePool += _amount;
        emit Donated(_lotteryId, _donor, _amount);
    }

    function _executeDonationWithdrawal(uint256 _lotteryId, address _donor) internal virtual {
        uint256 amount = _donations[_lotteryId][_donor];
        if (amount == 0) revert NoDonation();
        _donations[_lotteryId][_donor] = 0;
        _state[_lotteryId].prizePool -= amount;
        IERC20(_donationAsset(_lotteryId)).safeTransfer(_donor, amount);
        emit DonationWithdrawn(_lotteryId, _donor, amount);
    }

    /* ─────────────────────────── Prize claims ───────────────────────────── */

    /// @notice Claims one winner slot for `claimer`.
    /// @dev Hub proxy sets `claimer` to the end user; direct calls require `claimer == msg.sender`
    ///      unless caller has `HUB_ROLE`.
    /// @param lotteryId   Lottery ID.
    /// @param winnerIndex 0-based winner ordinal.
    /// @param claimer     Recipient of the prize transfer.
    function claimPrize(uint256 lotteryId, uint24 winnerIndex, address claimer) external nonReentrant {
        _assertClaimer(claimer);
        _claimPrizeBase(lotteryId, winnerIndex, claimer);
    }

    /// @notice Claims multiple winner slots in one transaction.
    /// @param lotteryId      Lottery ID.
    /// @param winnerIndices  0-based winner ordinals (non-empty).
    /// @param claimer        Prize recipient.
    /// @return totalAmount   Sum of prizes transferred in this batch.
    function claimPrizeBatch(
        uint256 lotteryId,
        uint24[] calldata winnerIndices,
        address claimer
    ) external nonReentrant returns (uint256 totalAmount) {
        _assertClaimer(claimer);

        uint256 len = winnerIndices.length;
        if (len == 0) revert InvalidWinnerIndex();

        LotteryState storage s = _state[lotteryId];
        if (s.status != LotteryStatus.DRAW_COMPLETED && s.status != LotteryStatus.FULLY_CLAIMED)
            revert DrawNotCompleted();

        uint24 winnerCount = _countWinners(lotteryId);
        uint24 sold = uint24(_sold(lotteryId));

        for (uint256 i = 0; i < len; ) {
            totalAmount += _processWinnerSlot(s, lotteryId, winnerIndices[i], winnerCount, sold, claimer);
            // prettier-ignore
            unchecked { ++i; }
        }

        _finalizeClaim(lotteryId, s, claimer, totalAmount);
        emit PrizeClaimedBatch(lotteryId, claimer, totalAmount, winnerIndices);
        return totalAmount;
    }

    /* ─────────────────────────── Views ───────────────────────────────────── */

    /// @notice Effective lifecycle status including time-based and claim exhaustion rules.
    /// @param lotteryId Lottery ID.
    /// @return          Current `LotteryStatus` (may differ from stored status near boundaries).
    function getLotteryStatus(uint256 lotteryId) external view returns (LotteryStatus) {
        return _getLotteryStatus(lotteryId);
    }

    /// @notice Owner of a 1-based ticket ID.
    /// @param lotteryId Lottery ID.
    /// @param ticketId  1-based ticket ID.
    /// @return          Owner address.
    function ticketOwner(uint256 lotteryId, uint256 ticketId) external view returns (address) {
        return ownerOf(lotteryId, ticketId);
    }

    /// @notice Returns the current draw generation for `lotteryId`.
    /// @dev Called by `RndConsumer.fulfillRandomWords` to detect stale VRF callbacks. The generation
    ///      is incremented on every new VRF request (first draw or retry),
    ///      so any pending callback whose stored generation differs from this value is stale and
    ///      must not be forwarded. Implements `ILotteryRandomnessConsumer.drawGeneration`.
    ///      Returns `0` when no draw has ever been requested for this lottery.
    /// @param lotteryId Lottery to query.
    /// @return generation Current `LotteryState.drawGeneration`.
    function drawGeneration(uint256 lotteryId) external view returns (uint32 generation) {
        return _state[lotteryId].drawGeneration;
    }

    /// @notice Static lottery configuration.
    /// @dev Unpacks the internal `LotteryStored` layout into the ABI-facing `Lottery` shape,
    ///      so external integrations see the same return type as before packing.
    /// @param lotteryId Lottery ID.
    /// @return          `Lottery` struct copy.
    function getLottery(uint256 lotteryId) external view returns (Lottery memory) {
        LotteryStored storage lot = _lotteries[lotteryId];
        return
            Lottery({
                creator: lot.creator,
                kind: lot.kind,
                model: lot.model,
                params: LotteryParams({
                    ticketPrice: lot.ticketPrice,
                    asset: lot.asset,
                    feeBp: lot.feeBp,
                    maxTickets: lot.maxTickets,
                    startTime: lot.startTime,
                    endTime: lot.endTime
                }),
                payoutRateBp: lot.payoutRateBp,
                cltAmountPerTicket: lot.cltAmountPerTicket,
                feederSuperLotteryId: lot.feederSuperLotteryId,
                feederAllocBp: lot.feederAllocBp
            });
    }

    /// @notice Runtime lottery state snapshot for off-chain reads.
    /// @param lotteryId Lottery ID.
    /// @return view_    Effective status, draw fields, and prize pool accounting.
    function getLotteryStateView(uint256 lotteryId) external view returns (LotteryStateView memory view_) {
        LotteryState storage s = _state[lotteryId];
        view_.status = _getLotteryStatus(lotteryId);
        view_.drawDeadline = s.drawDeadline;
        view_.drawGeneration = s.drawGeneration;
        view_.seed = s.seed;
        view_.creatorFees = s.creatorFees;
        view_.prizePool = s.prizePool;
        view_.claimedPrizePool = s.claimedPrizePool;
        view_.currentPrizePool = s.prizePool - s.claimedPrizePool;
    }

    /// @notice Total tickets sold for `lotteryId`.
    /// @param lotteryId Lottery ID.
    /// @return          Ticket count.
    function totalTicketsSold(uint256 lotteryId) external view returns (uint256) {
        return _sold(lotteryId);
    }

    /// @notice Returns the number of winner slots for `lotteryId` under its payout model.
    /// @dev Uses current tickets sold and prize pool; MULTIPLIER count grows with donations.
    function countWinners(uint256 lotteryId) external view returns (uint256) {
        return _winnerCount(lotteryId, _sold(lotteryId));
    }

    /// @notice Prize pool accounting snapshot.
    /// @dev `totalPrizePool` is the frozen pool at draw; claims increment `claimedPrizePool` only.
    /// @param lotteryId Lottery ID.
    /// @return claimedPrizePool   Sum paid to winners so far.
    /// @return unclaimedPrizePool `totalPrizePool - claimedPrizePool`.
    /// @return totalPrizePool     Full pool used for winner math.
    function getPrizePool(
        uint256 lotteryId
    ) external view returns (uint256 claimedPrizePool, uint256 unclaimedPrizePool, uint256 totalPrizePool) {
        LotteryState storage s = _state[lotteryId];
        totalPrizePool = s.prizePool;
        claimedPrizePool = s.claimedPrizePool;
        unclaimedPrizePool = totalPrizePool - claimedPrizePool;
    }

    /// @notice Raw claim-bitmap word covering winner slots `[wordIndex * 256, wordIndex * 256 + 255]`.
    /// @dev The one claim-bitmap primitive that cannot be synthesised from the other public
    ///      getters, so `LotteryWinnerReader` depends on it. Winner lists themselves are served
    ///      by that reader via `LotteryHub`, not from the manager.
    ///
    ///      Returns a whole word rather than a single flag so that paginating a winner list
    ///      costs one call per 256 slots instead of one per slot. Bit `n` of the result is the
    ///      claim flag for winner slot `wordIndex * 256 + n`. Unwritten words read as zero, so
    ///      an out-of-range `wordIndex` reports every slot as unclaimed.
    /// @param lotteryId Lottery to query.
    /// @param wordIndex 0-based bitmap word index (`winnerIndex >> 8`).
    function claimedWord(uint256 lotteryId, uint256 wordIndex) external view returns (uint256) {
        return _state[lotteryId].claimedWords[wordIndex];
    }

    /* ─────────────────────────── VRF callback ───────────────────────────── */

    /// @inheritdoc ILotteryRandomnessConsumer
    /// @notice Called by RndConsumer with the VRF seed; transitions to `DRAW_COMPLETED`.
    /// @dev Not `nonReentrant`: a valid fulfillment relayed from a callback that runs under the
    ///      manager lock (token transfer hooks in claims or donation withdrawal) must still land.
    ///      Safe only while `_fulfillRandomnessBase` and its full call chain make no external call;
    ///      adding one requires restoring a guard.
    function fulfillRandomness(
        uint256 lotteryId,
        uint256 seed
    ) external override onlyRole(RANDOMNESS_COORDINATOR_ROLE) {
        _fulfillRandomnessBase(lotteryId, seed);
    }

    /* ─────────────────────────── Internal — lifecycle ─────────────────────── */

    /// @dev Writes the packed `LotteryStored` + initial `LotteryState` and sets ticket index to `1`.
    ///      Stores `effectiveStart` (= max(params.startTime, block.timestamp)) as the lottery's
    ///      `startTime` so that storage is consistent with the duration validated in `_checkBase`.
    ///      Narrowing casts are safe: `_checkBase` (always executed before this) bounds
    ///      `ticketPrice` to uint128, `feeBp` to `BP_DENOMINATOR`, timestamps to uint40,
    ///      and `maxTickets` to uint24.
    function _initLottery(
        uint256 _lotteryId,
        LotteryKind _kind,
        PayoutModel _model,
        address _creator,
        LotteryParams calldata _params
    ) internal {
        // Write-once invariant: a lottery ID may be initialized exactly once.
        // `_state[id].status` is NONE (0) by default for any slot never written by this function.
        // The same slot is written below, so this read costs no additional cold SLOAD.
        if (_state[_lotteryId].status != LotteryStatus.NONE) revert LotteryAlreadyExists();

        uint64 nowTs = uint64(block.timestamp);
        uint64 effectiveStart = _params.startTime < nowTs ? nowTs : _params.startTime;

        LotteryStored storage lot = _lotteries[_lotteryId];
        lot.creator = _creator;
        lot.kind = _kind;
        lot.model = _model;
        lot.feeBp = uint16(_params.feeBp);
        lot.maxTickets = _params.maxTickets;
        lot.asset = _params.asset;
        lot.startTime = uint40(effectiveStart);
        lot.endTime = uint40(_params.endTime);
        lot.ticketPrice = uint128(_params.ticketPrice);

        LotteryState storage s = _state[_lotteryId];
        s.status = block.timestamp >= _params.startTime ? LotteryStatus.ACTIVE : LotteryStatus.PENDING;

        _lotteryIndex[_lotteryId] = 1;

        emit LotteryStatusUpdated(_lotteryId, s.status);
    }

    /// @dev Reverts unless quantity, timing, status, and capacity allow a purchase.
    /// @return sold       Tickets already sold (reused by the caller to avoid a second SLOAD).
    /// @return maxTickets Sale cap (reused by the caller to avoid a second SLOAD).
    function _validatePurchase(
        uint256 _lotteryId,
        uint256 _qty
    ) internal view returns (uint256 sold, uint256 maxTickets) {
        if (_qty == 0) revert InvalidQuantity();

        LotteryStatus status = _getLotteryStatus(_lotteryId);
        if (status == LotteryStatus.PENDING) revert LotteryNotStartedYet();
        if (status != LotteryStatus.ACTIVE && status != LotteryStatus.READY_TO_DRAW) revert LotteryNotActive();
        LotteryStored storage lot = _lotteries[_lotteryId];
        if (block.timestamp > lot.endTime) revert LotteryEnded();
        sold = _sold(_lotteryId);
        maxTickets = lot.maxTickets;
        uint256 remaining = maxTickets - sold;
        if (_qty > ticketLimit) revert ExceedsBatchLimit(ticketLimit);
        if (_qty > remaining) revert ExceedsMaxTickets(remaining);
    }

    /// @dev Validates core `LotteryParams` shared by all creator types.
    ///      Also enforces the packed-storage bounds required by `LotteryStored`
    ///      (uint128 price, uint40 timestamps, uint16 feeBp) so `_initLottery` casts are safe.
    function _checkBase(LotteryParams calldata _params, uint64 _maxDuration) internal view {
        if (_params.asset == address(0)) revert ZeroAddress();
        if (_params.ticketPrice < MIN_TICKET_PRICE) revert InvalidTicketPrice();
        if (_params.ticketPrice > type(uint128).max) revert InvalidTicketPrice();
        if (_params.feeBp > BP_DENOMINATOR) revert InvalidBp();
        if (_params.maxTickets == 0) revert InvalidMaxTickets();
        if (_params.maxTickets > type(uint24).max) revert InvalidMaxTickets();
        uint64 nowTs = uint64(block.timestamp);
        uint64 effectiveStart = _params.startTime < nowTs ? nowTs : _params.startTime;
        if (effectiveStart >= _params.endTime) revert InvalidTimeRange();
        if (_params.endTime > type(uint40).max) revert InvalidTimeRange();
        if (_maxDuration > 0 && _params.endTime - effectiveStart > _maxDuration) revert ExceedsMaxDuration();
    }

    /// @dev Validates multiplier BP against `minimumMultiplierBp` / `maximumMultiplierBp` when set.
    function _checkMultiplierBp(uint256 _bp) internal view {
        uint256 lo = minimumMultiplierBp;
        uint256 hi = maximumMultiplierBp;
        if (lo > 0 && _bp < lo) revert InvalidPayoutMultiplier();
        if (hi > 0 && _bp > hi) revert InvalidPayoutMultiplier();
    }

    /// @dev Validates win rate BP against configured bounds when non-zero.
    function _checkWinRateBp(uint256 _bp) internal view {
        uint256 lo = minimumWinRateBp;
        uint256 hi = maximumWinRateBp;
        if (lo > 0 && _bp < lo) revert InvalidWinRateBp();
        if (hi > 0 && _bp > hi) revert InvalidWinRateBp();
    }

    /// @dev Requires non-empty tier list within `maximumTiers` when configured.
    function _checkTiersLength(uint256 _tiersLength) internal view {
        if (_tiersLength == 0) revert TooManyTiers(_tiersLength);
        uint256 cap = maximumTiers;
        if (cap > 0 && _tiersLength > cap) revert TooManyTiers(_tiersLength);
    }

    /// @dev Sets READY_TO_DRAW when sold out; promotes PENDING → ACTIVE on first purchase after start.
    function _updateStatusAfterPurchase(
        uint256 _lotteryId,
        uint256 _soldBefore,
        uint256 _qty,
        uint256 _maxTickets
    ) internal {
        LotteryState storage s = _state[_lotteryId];
        if (_soldBefore + _qty == _maxTickets) {
            s.status = LotteryStatus.READY_TO_DRAW;
            emit LotteryStatusUpdated(_lotteryId, LotteryStatus.READY_TO_DRAW);
        } else if (s.status == LotteryStatus.PENDING) {
            s.status = LotteryStatus.ACTIVE;
            emit LotteryStatusUpdated(_lotteryId, LotteryStatus.ACTIVE);
        }
    }

    /// @dev ERC-20 token used for prize payouts; default is ticket payment asset.
    function _prizeAsset(uint256 _lotteryId) internal view virtual returns (address) {
        return _lotteries[_lotteryId].asset;
    }

    /// @dev Writes the packed `payoutRateBp`; bounds-checks the uint32 narrowing.
    function _setPayoutRateBp(uint256 _lotteryId, uint256 _bp) internal {
        if (_bp > type(uint32).max) revert InvalidBp();
        _lotteries[_lotteryId].payoutRateBp = uint32(_bp);
    }

    /// @dev Writes the packed `cltAmountPerTicket`; bounds-checks the uint96 narrowing.
    function _setCltAmountPerTicket(uint256 _lotteryId, uint256 _amount) internal {
        if (_amount > type(uint96).max) revert InvalidCltTicketReward();
        _lotteries[_lotteryId].cltAmountPerTicket = uint96(_amount);
    }

    /// @dev ERC-20 token accepted for prize-pool donations; default matches `_prizeAsset`.
    function _donationAsset(uint256 _lotteryId) internal view virtual returns (address) {
        return _prizeAsset(_lotteryId);
    }

    /// @notice Returns the ERC-20 token that must be used to donate to `lotteryId`.
    function getDonationAsset(uint256 lotteryId) external view returns (address) {
        return _donationAsset(lotteryId);
    }

    /// @dev Mints tickets and updates status; caller must have completed payment accounting.
    function _executeTicketPurchase(uint256 _lotteryId, uint256 _qty, address _ticketRecipient) internal {
        (uint256 sold, uint256 maxTix) = _validatePurchase(_lotteryId, _qty);
        _mintTix(_lotteryId, _qty, _ticketRecipient);
        _updateStatusAfterPurchase(_lotteryId, sold, _qty, maxTix);
    }

    /* ─────────────────────────── Internal — draw ──────────────────────────── */

    /// @dev Starts draw: instant fulfill if one ticket sold; else VRF request + deadline.
    /// @dev Re-entry after a timed-out VRF request (status still `DRAW_REQUESTED`, no seed,
    ///      deadline passed) issues a fresh request and extends the deadline.
    /// @dev `payer` is credited in `RndConsumer` with excess ETH and the full refund on single-ticket draws.
    function _requestDrawBase(uint256 _lotteryId, address _payer) internal {
        LotteryState storage s = _state[_lotteryId];

        if (s.status == LotteryStatus.DRAW_REQUESTED) {
            // Retry path: a prior VRF request timed out without delivering a seed.
            if (s.seed != 0) revert SeedAlreadyAdded();
            if (block.timestamp <= s.drawDeadline) revert DrawDeadlineNotReached();

            s.drawDeadline = uint64(block.timestamp + VRF_TIMEOUT);
            // Increment generation so any pending callback for the old generation is stale.
            s.drawGeneration++;
            uint256 retryRequestId = rndCoordinator.requestRandomness{value: msg.value}(
                _lotteryId, s.drawGeneration, _payer
            );
            emit DrawRequested(_lotteryId, retryRequestId);
            return;
        }

        LotteryStatus live = _getLotteryStatus(_lotteryId);

        if (live != LotteryStatus.READY_TO_DRAW) revert NotReadyToDraw();

        uint256 sold = _sold(_lotteryId);
        if (sold == 0) revert NoTicketsSold();

        if (sold == 1) {
            // Single-ticket lotteries skip VRF: the sole ticket holder is the guaranteed winner.
            // Seed 1 is a deterministic sentinel; see LotteryPrizeLib.winningTicketIndexInternal
            // which returns index 0 immediately when sold == 1, making the seed irrelevant.
            s.status = LotteryStatus.DRAW_REQUESTED;
            emit LotteryStatusUpdated(_lotteryId, LotteryStatus.DRAW_REQUESTED);
            _fulfillRandomnessBase(_lotteryId, 1);
            if (msg.value > 0) rndCoordinator.creditRefund{value: msg.value}(_payer);
            return;
        }

        s.status = LotteryStatus.DRAW_REQUESTED;
        s.drawDeadline = uint64(block.timestamp + VRF_TIMEOUT);
        // Increment generation on every new VRF request so callbacks from superseded
        // requests, including those left on a rotated-away coordinator, are detected as stale.
        s.drawGeneration++;
        emit LotteryStatusUpdated(_lotteryId, LotteryStatus.DRAW_REQUESTED);

        uint256 requestId = rndCoordinator.requestRandomness{value: msg.value}(
            _lotteryId, s.drawGeneration, _payer
        );

        emit DrawRequested(_lotteryId, requestId);
    }

    /// @dev Persists seed and moves to `DRAW_COMPLETED`.
    ///      This function and its full call chain must make no external call
    ///      (no token transfer, rewarder, feeder, coordinator or Hub call, no hook). It is reachable
    ///      from the unguarded `fulfillRandomness` while another function holds the manager lock.
    function _fulfillRandomnessBase(uint256 lotteryId, uint256 seed) internal {
        LotteryState storage s = _state[lotteryId];
        if (s.status != LotteryStatus.DRAW_REQUESTED) revert DrawNotRequested();
        if (s.seed != 0) revert SeedAlreadyAdded();

        s.seed = seed;
        s.status = LotteryStatus.DRAW_COMPLETED;

        emit LotteryStatusUpdated(lotteryId, LotteryStatus.DRAW_COMPLETED);
        emit DrawCompleted(lotteryId, seed);
    }

    /* ─────────────────────────── Internal — claims ────────────────────────── */

    /// @dev Single-slot claim: validate, mark bitmap, transfer prize.
    function _claimPrizeBase(uint256 _lotteryId, uint24 _winnerIndex, address _claimer) internal {
        LotteryState storage s = _state[_lotteryId];
        if (s.status != LotteryStatus.DRAW_COMPLETED && s.status != LotteryStatus.FULLY_CLAIMED)
            revert DrawNotCompleted();

        uint24 winnerCount = _countWinners(_lotteryId);
        uint24 sold = uint24(_sold(_lotteryId));

        uint256 prize = _processWinnerSlot(s, _lotteryId, _winnerIndex, winnerCount, sold, _claimer);
        _finalizeClaim(_lotteryId, s, _claimer, prize);

        emit PrizeClaimed(_lotteryId, _winnerIndex, _claimer, prize);
    }

    /// @dev Hub may claim on behalf of `claimer`; otherwise `claimer` must be `msg.sender`.
    function _assertClaimer(address _claimer) internal view {
        if (!hasRole(HUB_ROLE, msg.sender)) {
            if (_claimer != msg.sender) revert InvalidClaimer();
        }
    }

    /// @dev Marks winner slot claimed, verifies ticket ownership, returns prize amount.
    function _processWinnerSlot(
        LotteryState storage _s,
        uint256 _lotteryId,
        uint24 _wi,
        uint24 _winnerSlotCount,
        uint24 _sold,
        address _claimer
    ) internal returns (uint256) {
        if (_wi >= _winnerSlotCount) revert InvalidWinnerIndex();

        uint256 _wordIndex = uint256(_wi) >> 8;
        uint256 _bitIndex = uint256(_wi) & 255;
        uint256 word = _s.claimedWords[_wordIndex];
        if ((word >> _bitIndex) & 1 != 0) revert PrizeAlreadyClaimed();
        _s.claimedWords[_wordIndex] = word | (1 << _bitIndex);

        uint24 ticketIdx = LotteryPrizeLib.winningTicketIndex(_s.seed, _sold, _wi + 1);
        address owner = ownerOf(_lotteryId, uint256(ticketIdx) + 1);
        if (owner != _claimer) revert NotWinner();

        return _calcPrize(_lotteryId, _wi, _sold);
    }

    /// @dev Updates claimed pool, may set FULLY_CLAIMED, transfers ERC-20 prize.
    function _finalizeClaim(uint256 _lotteryId, LotteryState storage _s, address _claimer, uint256 _amount) internal {
        _s.claimedPrizePool += _amount;
        if (_s.claimedPrizePool >= _s.prizePool) {
            _s.status = LotteryStatus.FULLY_CLAIMED;
            emit LotteryStatusUpdated(_lotteryId, LotteryStatus.FULLY_CLAIMED);
        }
        if (_amount > 0) {
            IERC20(_prizeAsset(_lotteryId)).safeTransfer(_claimer, _amount);
        }
    }

    /// @dev Resolves effective status: time gates, sold-out, and full claim exhaustion.
    function _getLotteryStatus(uint256 _lotteryId) internal view returns (LotteryStatus) {
        LotteryState storage s = _state[_lotteryId];
        LotteryStatus stored = s.status;

        if (stored == LotteryStatus.NONE) return LotteryStatus.NONE;

        LotteryStored storage lot = _lotteries[_lotteryId];

        if (stored == LotteryStatus.PENDING) {
            // Expiry check first: a PENDING lottery past endTime has zero tickets sold
            // (any purchase would have stored ACTIVE), so it is permanently void.
            if (block.timestamp > lot.endTime) return LotteryStatus.CANCELLED;
            if (block.timestamp >= lot.startTime) return LotteryStatus.ACTIVE;
            return LotteryStatus.PENDING;
        }

        if (stored == LotteryStatus.ACTIVE && block.timestamp > lot.endTime) {
            // Enforce the intended lifecycle invariant: a lottery that expired with zero
            // tickets sold is CANCELLED, not READY_TO_DRAW.  The _sold() read is cold
            // any subsequent _sold() call in the same transaction (e.g. requestDraw).
            return _sold(_lotteryId) == 0 ? LotteryStatus.CANCELLED : LotteryStatus.READY_TO_DRAW;
        }

        if (stored == LotteryStatus.DRAW_COMPLETED) {
            if (s.prizePool > 0 && s.claimedPrizePool >= s.prizePool) {
                return LotteryStatus.FULLY_CLAIMED;
            }
        }

        return stored;
    }
}
