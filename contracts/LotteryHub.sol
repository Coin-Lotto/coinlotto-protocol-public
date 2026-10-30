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

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {LotteryKind, LotteryParams, PayoutModel, Lottery, LotteryStateView, LotteryStatus} from "./structs/MetadataStruct.sol";
import {TicketPurchaseQuote} from "./structs/TicketPurchaseQuote.sol";
import {ILotteryManager} from "./interfaces/ILotteryManager.sol";
import {IReferralRegistry} from "./interfaces/IReferralRegistry.sol";
import {ICltRewarder} from "./interfaces/ICltRewarder.sol";

/// @notice Winner slot summary returned by {getWinnerInfo} and {getWinnersInfo}.
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

/// @dev Minimal read interface for a previous Hub deployment used when `lotteryId < initialLotteryId`.
///      Exposes `getManager` (the transitive resolver) rather than the raw `lotteryIdToManager` mapping
///      so that resolution recurses through the full legacy-hub chain across N generations.
///      All deployed `LotteryHub` contracts already implement this function; no old-hub redeployment needed.
interface ILotteryHubLegacy {
    function getManager(uint256 lotteryId) external view returns (address);
}

/// @dev Extended manager views used by Hub batch read helpers.
interface ILotteryManagerDetail {
    function getLottery(uint256 lotteryId) external view returns (Lottery memory);

    function getLotteryStateView(uint256 lotteryId) external view returns (LotteryStateView memory);

    function totalTicketsSold(uint256 lotteryId) external view returns (uint256);

    function getLotteryTiers(uint256 lotteryId) external view returns (uint16[] memory);
}

/// @dev Off-manager winner-list reader. Winner views were moved off the managers to keep
///      `ProtocolLotteryManager` under the EIP-170 bytecode limit; see `w`.
///      Declared locally (rather than imported) so this file keeps its own `WinnerInfo`.
interface ILotteryWinnerReader {
    function getWinnersInfo(
        address manager,
        uint256 lotteryId,
        uint256 from,
        uint256 limit
    ) external view returns (WinnerInfo[] memory);
}

/// @notice Full lottery snapshot returned by {getLotteryBatch}.
struct LotteryFullInfo {
    uint256 lotteryId;
    address manager;
    Lottery lottery;
    LotteryStateView state;
    uint256 ticketsSold;
    uint16[] tiers;
}

/// @title LotteryHub
/// @notice Single entry point: lottery lifecycle routing, Hub-pull payments, and referrals.

/// @dev Architecture:
///        • Global `lotteryCount` assigns IDs; `lotteryIdToManager` is write-once per ID.
///        • `managerRegistry` maps type keys → manager; only affects new creations.
///        • All user-facing actions resolve a manager then delegate to `ILotteryManager`.
///
///      Hub-pull ticket flow (`buyTickets`):
///        1. `refRegistry.linkReferrer(buyer, referrer)` → effective referrer.
///        2. `creator.quoteTicketPurchase(lotteryId, qty, effectiveReferrer)` (view).
///        3. Hub `safeTransferFrom` buyer → `treasuryDest` / creator / `rewardPoolDest` per quote.
///        4. `creator.registerTicketPurchase(...)` — mints tickets, no transfers inside.
///        5. If REGULAR lottery (not USER, not SUPER/`cltPayment`) and first such purchase by this
///           buyer (`_welcomeBonusCredited[buyer] == false`), `rewarder.addCltReferrerBonus(referrer)`
///           (flat welcome bonus).
///
///      Buyers approve only this Hub for ERC-20 pulls (payment token and CLT paths).
///
///      Access control:
///        • `DEFAULT_ADMIN_ROLE` — admin rotation (24h delay).
///        • `WORKER_ROLE` — registry wiring, manager registration, legacy hub pointer.
///
///      Legacy routing: IDs below `initialLotteryId` may resolve via `legacyHub` when set.
contract LotteryHub is AccessControl, ReentrancyGuard, Nonces {
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── Roles ──────────────────────────── */

    /// @notice Role for protocol configuration and creator registry management.
    bytes32 public constant WORKER_ROLE = keccak256("WORKER_ROLE");

    /* ─────────────────────────────────────── Manager type keys ────────────────── */

    /// @notice `managerType` key for `UserLotteryManager` (USER kind only).
    bytes32 public constant USER_LOTTERY = keccak256("USER_LOTTERY");

    /// @notice `managerType` key for `ProtocolLotteryManager` (REGULAR and SUPER kinds).
    bytes32 public constant REGULAR_LOTTERY = keccak256("REGULAR_LOTTERY");

    /* ─────────────────────────────────────── Enums ──────────────────────────── */

    /// @notice Whether a registered manager may receive new lotteries via `createLottery`.
    /// @dev Existing lotteries keep routing via `lotteryIdToManager` regardless of status.
    enum ManagerStatus {
        NONE,
        ACTIVE,
        CREATION_PAUSED,
        DEPRECATED
    }

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice Optional previous Hub for `lotteryId < initialLotteryId` lookups.
    ILotteryHubLegacy public legacyHub;

    /// @notice Referral registry; Hub holds `REFERRAL_LINKER_ROLE` and links on each buy.
    IReferralRegistry public refRegistry;

    /// @notice Referrer welcome CLT; Hub calls `addCltRewards` on first referral + CLT quote.
    ICltRewarder public rewarder;

    /// @dev Off-manager winner-list reader backing {getWinnersInfo} and {getWinnerInfo}.
    ///      Both getters degrade to empty/zero results while unset, so the Hub stays usable
    ///      between deployment and {setWinnerReader}.
    ILotteryWinnerReader public winnerReader;

    /// @notice Global lottery ID counter; next ID is `lotteryCount + 1` after increment.
    uint256 public lotteryCount;

    /// @notice First lottery ID owned by this Hub; lower IDs may use `legacyHub`.
    uint256 public immutable initialLotteryId;

    /// @notice Permanent manager routing table (set once at creation, never updated).
    mapping(uint256 lotteryId => address manager) public lotteryIdToManager;

    /// @notice Mutable map from manager type key to current manager implementation.
    mapping(bytes32 managerType => address manager) public managerRegistry;

    /// @notice Creation gate per manager address (see {ManagerStatus}).
    mapping(address manager => ManagerStatus) public managerStatus;

    /// @dev Tracks whether a buyer has already triggered the referrer welcome bonus on a protocol lottery.
    mapping(address buyer => bool) private _welcomeBonusCredited;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Emitted when `refRegistry` is set or replaced.
    event RefRegistrySet(address indexed newRefRegistry);

    /// @notice Emitted when `rewarder` is set or replaced.
    event RewarderSet(address indexed newRewarder);

    /// @notice Emitted after a lottery is created and routed in this Hub.
    /// @param lotteryId   Assigned global ID.
    /// @param manager     Manager contract that initialized storage.
    /// @param managerType Type key used in `createLottery`.
    /// @param nonce       Hub creation nonce (event ordering aid).
    /// @param kind        Lottery kind stored on the manager.
    /// @param sender      `msg.sender` of `createLottery` (lottery owner / operator).
    event LotteryRegistered(
        uint256 indexed lotteryId,
        address indexed manager,
        bytes32 indexed managerType,
        uint256 nonce,
        LotteryKind kind,
        address sender
    );

    /// @notice Emitted when a manager address is bound to a type key.
    event ManagerRegistered(bytes32 indexed managerType, address indexed manager);

    /// @notice Emitted when a manager's {ManagerStatus} changes.
    event ManagerStatusChanged(address indexed manager, ManagerStatus indexed status);

    /// @notice Emitted when `legacyHub` is set or cleared.
    event LegacyHubSet(address indexed legacyHub);
    event WinnerReaderSet(address indexed winnerReader);

    /// @notice Emitted after a successful `buyTickets` (indexer / analytics hook).
    /// @param lotteryId  Lottery purchased.
    /// @param buyer      `msg.sender` of `buyTickets` (payer).
    /// @param qty        Ticket count.
    /// @param referrer   Effective referrer from registry (zero if none).
    event TicketsBought(uint256 indexed lotteryId, address indexed buyer, uint256 qty, address referrer);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when a configured address must be non-zero.
    error ZeroAddress();

    /// @notice Thrown when `managerRegistry[managerType]` is unset.
    /// @param managerType Unknown type key passed to `createLottery`.
    error UnknownManagerType(bytes32 managerType);

    /// @notice Thrown when no creator resolves for `lotteryId` on this Hub or legacy Hub.
    /// @param lotteryId Unrouted or non-existent ID.
    error UnknownLotteryId(uint256 lotteryId);

    /// @notice Thrown when the target manager is not {ManagerStatus.ACTIVE} for new lotteries.
    /// @param manager Manager that rejected creation.
    error ManagerPaused(address manager);

    /// @notice Thrown when `setManagerStatus` is called with {ManagerStatus.NONE}.
    error InvalidStatus();

    /// @notice Thrown when `claimReferrerFees` is called with an empty managers array.
    error EmptyManagersArray();

    /// @notice Thrown when the actual tokens received by the manager after a transfer are less
    ///         than the nominal amount requested.  Indicates a fee-on-transfer or otherwise
    ///         non-standard token that the protocol does not support.
    error TransferAmountMismatch();

    /// @notice Thrown when a donation is not allowed for the given lottery.
    error ProhibitedDonation();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Deploys the Hub and seeds the lottery ID space.
    /// @param initialDefaultAdmin `DEFAULT_ADMIN_ROLE` holder.
    /// @param initialLotteryId_   First ID this Hub assigns (use `legacyCount + 1` when migrating).
    constructor(address initialDefaultAdmin, uint256 initialLotteryId_) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
        _grantRole(WORKER_ROLE, msg.sender);

        initialLotteryId = initialLotteryId_;
        lotteryCount = initialLotteryId_ - 1;
    }

    /* ─────────────────────────── Configuration (WORKER_ROLE) ────────────────── */

    /// @notice Sets the referral registry used during `buyTickets`.
    /// @param refRegistry_ Non-zero `ReferralRegistry` address.
    function setRefRegistry(address refRegistry_) external onlyRole(WORKER_ROLE) {
        if (refRegistry_ == address(0)) revert ZeroAddress();
        refRegistry = IReferralRegistry(refRegistry_);
        emit RefRegistrySet(refRegistry_);
    }

    /// @notice Sets the CLT rewarder invoked on first-time referrer links with CLT missions.
    /// @param rewarder_ Non-zero `CltRewarder` address.
    function setRewarder(address rewarder_) external onlyRole(WORKER_ROLE) {
        if (rewarder_ == address(0)) revert ZeroAddress();
        rewarder = ICltRewarder(rewarder_);
        emit RewarderSet(rewarder_);
    }

    /// @notice Sets the reader that serves {getWinnersInfo} and {getWinnerInfo}.
    /// @param winnerReader_ Non-zero `LotteryWinnerReader` address.
    function setWinnerReader(address winnerReader_) external onlyRole(WORKER_ROLE) {
        if (winnerReader_ == address(0)) revert ZeroAddress();
        winnerReader = ILotteryWinnerReader(winnerReader_);
        emit WinnerReaderSet(winnerReader_);
    }

    /// @notice Points sub-threshold lottery IDs at a previous Hub deployment.
    /// @dev Pass `address(0)` when legacy lotteries are fully settled.
    /// @param legacyHub_ Previous Hub implementing {ILotteryHubLegacy}, or zero.
    function setLegacyHub(address legacyHub_) external onlyRole(WORKER_ROLE) {
        legacyHub = ILotteryHubLegacy(legacyHub_);
        emit LegacyHubSet(legacyHub_);
    }

    /* ─────────────────────────── Manager registry (WORKER_ROLE) ─────────────── */

    /// @notice Registers or updates the manager for `managerType` (future creations only).
    /// @dev First registration sets {ManagerStatus.ACTIVE}. Does not alter `lotteryIdToManager`.
    /// @param managerType Key such as {USER_LOTTERY} or {REGULAR_LOTTERY}.
    /// @param manager     `ILotteryManager` implementation; must be non-zero.
    function registerManager(bytes32 managerType, address manager) external onlyRole(WORKER_ROLE) {
        if (manager == address(0)) revert ZeroAddress();
        managerRegistry[managerType] = manager;
        if (managerStatus[manager] == ManagerStatus.NONE) {
            managerStatus[manager] = ManagerStatus.ACTIVE;
            emit ManagerStatusChanged(manager, ManagerStatus.ACTIVE);
        }
        emit ManagerRegistered(managerType, manager);
    }

    /// @notice Pauses or resumes new lottery creation on a manager without affecting existing IDs.
    /// @param manager Manager contract address.
    /// @param status  must not be {NONE} (reserved for unregistered state).
    function setManagerStatus(address manager, ManagerStatus status) external onlyRole(WORKER_ROLE) {
        if (manager == address(0)) revert ZeroAddress();
        if (status == ManagerStatus.NONE) revert InvalidStatus();
        managerStatus[manager] = status;
        emit ManagerStatusChanged(manager, status);
    }

    /* ─────────────────────────── Lottery creation ─────────────────────────────── */

    /// @notice Creates a lottery: assigns ID, delegates to manager, then records routing.
    /// @dev Atomic: counter increment reverts if `createLotteryFromHub` reverts.
    ///      `extraData` encoding is manager-specific (see `UserLotteryManager` / `ProtocolLotteryManager`).
    /// @param managerType  Registry key selecting the manager module.
    /// @param kind         USER, REGULAR, or SUPER (validated on manager).
    /// @param payoutModel  MULTIPLIER, TIER, or WIN_RATE.
    /// @param params       Shared {LotteryParams} struct.
    /// @param extraData    ABI-encoded manager extension fields.
    /// @return lotteryId   New global lottery identifier.
    function createLottery(
        bytes32 managerType,
        LotteryKind kind,
        PayoutModel payoutModel,
        LotteryParams calldata params,
        bytes calldata extraData
    ) external nonReentrant returns (uint256 lotteryId) {
        address manager = managerRegistry[managerType];
        if (manager == address(0)) revert UnknownManagerType(managerType);
        if (managerStatus[manager] != ManagerStatus.ACTIVE) revert ManagerPaused(manager);

        lotteryId = ++lotteryCount;

        uint256 nonce = _useNonce(msg.sender);

        // Emitted after the manager call so reverted creations never pay for this log.
        emit LotteryRegistered(lotteryId, manager, managerType, nonce, kind, msg.sender);

        ILotteryManager(manager).createLotteryFromHub(lotteryId, msg.sender, kind, payoutModel, params, extraData);

        lotteryIdToManager[lotteryId] = manager;
    }

    /* ─────────────────────────── Hub-pull ticket purchase ───────────────────── */

    /// @notice Purchases tickets using the Hub-pull payment model.
    /// @dev Buyer must approve this Hub for `quote.token` (and CLT when `quote.cltPayment`).
    /// @param lotteryId        Target lottery.
    /// @param qty              Number of tickets.
    /// @param referrer         Proposed referrer (registry may override with stored binding).
    /// @param ticketRecipient  Ticket owner (may differ from payer `msg.sender`).
    function buyTickets(
        uint256 lotteryId,
        uint256 qty,
        address referrer,
        address ticketRecipient
    ) external nonReentrant {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);

        address sender = _msgSender();
        (address effectiveReferrer, ) = refRegistry.linkReferrer(sender, referrer);

        TicketPurchaseQuote memory q = ILotteryManager(manager).quoteTicketPurchase(lotteryId, qty, effectiveReferrer);

        // Creator leg recomputed from quote components (struct carries no aggregate fields).
        uint256 toCreator = q.prizeAmount + q.refShare + q.netFeeder + q.creatorFee;
        ILotteryManager(manager).openHubSettlement();
        _pullExact(IERC20(q.token), sender, q.treasuryDest, q.toTreasury, manager, toCreator);
        if (q.cltPayment) {
            _pullExact(IERC20(q.cltToken), sender, q.treasuryDest, q.cltToTreasury, q.rewardPoolDest, q.cltToBank);
        }

        emit TicketsBought(lotteryId, sender, qty, effectiveReferrer);

        ILotteryManager(manager).registerTicketPurchase(lotteryId, qty, ticketRecipient, sender, effectiveReferrer, q);

        if (!_welcomeBonusCredited[sender]) {
            if (!q.isUserLottery && !q.cltPayment && effectiveReferrer != address(0)) {
                ICltRewarder _rewarder = rewarder;
                // Rewarder performs atomic global dedup and returns true when the hub should close its local gate.
                // Returns false only when referrerWelcomeBonus == 0 (bonus disabled) — gate stays open so eligibility
                // is preserved and the bonus fires once the bonus amount is re-enabled.
                bool closeGate = _rewarder.addCltReferreWelcomeBonus(effectiveReferrer, lotteryId, sender);
                if (closeGate) {
                    _welcomeBonusCredited[sender] = true;
                }
            }
        }
    }

    /* ─────────────────────────── Referrer fees ──────────────────────────────── */

    function claimReferrerFees(address[] memory managers, address token) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        uint256 len = managers.length;
        if (len == 0) revert EmptyManagersArray();

        for (uint256 i = 0; i < len; ++i) {
            ILotteryManager(managers[i]).claimReferrerFees(msg.sender, token);
        }
    }

    /* ─────────────────────────── Draw and prize claims ──────────────────────── */

    /// @notice Requests a VRF draw via the resolved manager. Calling again after the draw deadline
    ///         expired without fulfillment re-issues the VRF request.
    /// @dev Passes `msg.sender` as `payer` so excess ETH and single-ticket instant refunds are
    ///      credited to the caller in `RndConsumer` (`withdrawRefund`) — the Hub never holds them.
    /// @param lotteryId Lottery to draw.
    function requestDraw(uint256 lotteryId) external payable nonReentrant {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);
        ILotteryManager(manager).requestDraw{value: msg.value}(lotteryId, msg.sender);
    }

    /* ─────────────────────────── Donations ──────────────────────────────────── */

    /// @notice Boosts the prize pool of `lotteryId` by `amount` of its prize / donation asset.
    /// @dev Hub-pull model: caller approves this Hub for the donation asset (ticket asset for
    ///      USER/REGULAR; feeder prize ERC-20 for SUPER).
    ///
    ///      The flow is split so the asset address is known before the transfer (needed to
    ///      approve and snapshot balances) while accounting is only written after the transfer
    ///      succeeds.  A before/after `balanceOf` snapshot guards against fee-on-transfer tokens:
    ///      if the manager receives less than `amount` the transaction reverts — such tokens
    ///      are not supported by the protocol.
    ///        1. `getDonationAsset` — validates the lottery accepts donations,
    ///           returns the asset address (no accounting written).
    ///        2. `openHubSettlement` — locks the manager against nested Hub credits (any Hub).
    ///        3. Hub pulls tokens donor → manager; snapshot asserts no fee was deducted.
    ///        4. `recordDonationFor` — writes `amount` into `prizePool` and closes the settlement.
    /// @param lotteryId Target lottery.
    /// @param amount    Token amount to donate.
    function donate(uint256 lotteryId, uint256 amount) external nonReentrant {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);

        (address asset, bool allowed) = ILotteryManager(manager).getDonationAsset(lotteryId, amount);
        if (!allowed) revert ProhibitedDonation();

        ILotteryManager(manager).openHubSettlement();
        _pullExact(IERC20(asset), msg.sender, manager, amount, address(0), 0);

        ILotteryManager(manager).recordDonationFor(lotteryId, msg.sender, amount);
    }

    /// @notice Withdraws the caller's pre-draw donation; asset transferred directly to caller.
    /// @param lotteryId Lottery from which to withdraw.
    function withdrawDonation(uint256 lotteryId) external nonReentrant {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);
        ILotteryManager(manager).withdrawDonationFor(lotteryId, msg.sender);
    }

    /* ─────────────────────────── Prize claims ───────────────────────────────── */

    /// @notice Claims one winner slot; `msg.sender` must own the winning ticket.
    /// @dev No Hub-level reentrancy guard: pure proxy; the manager's `claimPrize` is guarded.
    /// @param lotteryId    Lottery to claim from.
    /// @param winnerIndex  Zero-based winner index from the draw (uint24 — ABI enforces upper bound).
    function claimPrize(uint256 lotteryId, uint24 winnerIndex) external {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);
        ILotteryManager(manager).claimPrize(lotteryId, winnerIndex, msg.sender);
    }

    /// @notice Claims multiple winner slots in one transaction.
    /// @dev No Hub-level reentrancy guard: pure proxy; the manager's `claimPrizeBatch` is guarded.
    /// @param lotteryId      Lottery to claim from.
    /// @param winnerIndices  Winner indices to claim.
    function claimPrizeBatch(uint256 lotteryId, uint24[] calldata winnerIndices) external {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);
        ILotteryManager(manager).claimPrizeBatch(lotteryId, winnerIndices, msg.sender);
    }

    /* ─────────────────────────── Views ────────────────────────────────────────── */

    /// @notice Batch read of full lottery config, runtime state, ticket count, and tiers.
    /// @dev Unmapped IDs leave the corresponding entry zeroed. Prize pool figures live in
    ///      `results[i].state` (`prizePool`, `claimedPrizePool`, `currentPrizePool`).
    ///      `tiers` is non-empty only for `PayoutModel.TIER` lotteries.
    /// @param lotteryIds Lottery IDs to query.
    /// @return results   Per-ID snapshot, aligned with `lotteryIds`.
    function getLotteryBatch(uint256[] calldata lotteryIds) external view returns (LotteryFullInfo[] memory results) {
        uint256 len = lotteryIds.length;
        results = new LotteryFullInfo[](len);

        for (uint256 i = 0; i < len; ) {
            uint256 lotteryId = lotteryIds[i];
            address manager = _resolveManager(lotteryId);

            if (manager != address(0)) {
                ILotteryManagerDetail detail = ILotteryManagerDetail(manager);
                Lottery memory lottery = detail.getLottery(lotteryId);

                results[i] = LotteryFullInfo({
                    lotteryId: lotteryId,
                    manager: manager,
                    lottery: lottery,
                    state: detail.getLotteryStateView(lotteryId),
                    ticketsSold: detail.totalTicketsSold(lotteryId),
                    tiers: lottery.model == PayoutModel.TIER ? detail.getLotteryTiers(lotteryId) : new uint16[](0)
                });
            }
            // prettier-ignore
            unchecked { ++i; }
        }
    }

    /// @notice Returns the number of winner slots for `lotteryId` on the resolved manager.
    /// @param lotteryId Lottery to query.
    function countWinners(uint256 lotteryId) external view returns (uint256) {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) revert UnknownLotteryId(lotteryId);
        return ILotteryManager(manager).countWinners(lotteryId);
    }

    /// @notice Paginated winner list; returns an empty array when `startIndex` is out of range.
    /// @dev Slot indices align with `claimPrize(lotteryId, winnerIndex)`.
    ///      Served by {winnerReader}; returns an empty array for an unknown `lotteryId` or while
    ///      the reader is unset.
    /// @param lotteryId  Lottery to query.
    /// @param startIndex 0-based index of the first winner slot to return.
    /// @param count      Maximum number of slots to include.
    function getWinnersInfo(
        uint256 lotteryId,
        uint256 startIndex,
        uint256 count
    ) external view returns (WinnerInfo[] memory) {
        address manager = _resolveManager(lotteryId);
        ILotteryWinnerReader reader = winnerReader;
        if (manager == address(0) || address(reader) == address(0)) return new WinnerInfo[](0);
        return reader.getWinnersInfo(manager, lotteryId, startIndex, count);
    }

    /// @notice Returns full information for a single winner slot.
    /// @dev Returns a zero-value struct when `winnerIndex` is out of range, the draw has not
    ///      completed yet, or `lotteryId` is unknown.  Safe to call at any lifecycle stage.
    ///
    ///      Implemented as a single-element {getWinnersInfo} request: the reader already clamps
    ///      `winnerIndex` to the winner count and returns an empty array when out of range, so
    ///      the previous explicit `countWinners` bounds staticcall is no longer needed.
    /// @param lotteryId   Lottery to query.
    /// @param winnerIndex 0-based winner slot in [0, countWinners - 1].
    function getWinnerInfo(uint256 lotteryId, uint256 winnerIndex) external view returns (WinnerInfo memory) {
        address manager = _resolveManager(lotteryId);
        ILotteryWinnerReader reader = winnerReader;
        if (manager == address(0) || address(reader) == address(0)) return WinnerInfo(0, 0, address(0), false);

        WinnerInfo[] memory infos = reader.getWinnersInfo(manager, lotteryId, winnerIndex, 1);
        if (infos.length == 0) return WinnerInfo(0, 0, address(0), false);
        return infos[0];
    }

    /// @notice Returns prize pool breakdown from the resolved creator.
    /// @return claimedPrizePool   Already paid out.
    /// @return unclaimedPrizePool Remaining claimable.
    /// @return totalPrizePool     Sum of claimed and unclaimed.
    function getPrizePool(
        uint256 lotteryId
    ) external view returns (uint256 claimedPrizePool, uint256 unclaimedPrizePool, uint256 totalPrizePool) {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) return (0, 0, 0);
        return ILotteryManager(manager).getPrizePool(lotteryId);
    }

    /// @notice Returns accrued referrer fees for `referrer` in `token` on `manager`.
    function getReferrerFee(address manager, address referrer, address token) external view returns (uint256) {
        if (manager == address(0)) return 0;
        try ILotteryManager(manager).getReferrerFee(referrer, token) returns (uint256 fee) {
            return fee;
        } catch {
            return 0;
        }
    }

    /// @notice Returns the effective lifecycle status of `lotteryId`.
    /// @dev Routes through `_resolveManager`; returns `LotteryStatus.NONE` when no manager is registered.
    function getLotteryStatus(uint256 lotteryId) external view returns (LotteryStatus) {
        address manager = _resolveManager(lotteryId);
        if (manager == address(0)) return LotteryStatus.NONE;
        return ILotteryManager(manager).getLotteryStatus(lotteryId);
    }

    /// @notice Returns the manager responsible for `lotteryId` (local table or legacy Hub).
    function getManager(uint256 lotteryId) external view returns (address) {
        return _resolveManager(lotteryId);
    }

    /// @notice Batch-resolves manager address per lottery ID (local table + optional legacy Hub).
    function getManagerBatch(uint256[] calldata lotteryIds) external view returns (address[] memory managers) {
        uint256 len = lotteryIds.length;
        managers = new address[](len);
        for (uint256 i = 0; i < len; ) {
            managers[i] = _resolveManager(lotteryIds[i]);
            // prettier-ignore
            unchecked { ++i; }
        }
        return managers;
    }

    /// @notice Returns whether `buyer` has ever had the referrer welcome bonus credited globally.
    /// @dev Delegates to `CltRewarder.isWelcomeBonusCredited` — returns global truth, not the local Hub cache.
    ///      The hub-local `_welcomeBonusCredited` mapping is a gas-saving cache and may be stale for users
    ///      credited on a prior Hub who have not yet made their first purchase on the current Hub.
    function getWelcomeBonusCredited(address buyer) external view returns (bool) {
        return rewarder.isWelcomeBonusCredited(buyer);
    }

    function _pullExact(IERC20 t, address from, address toA, uint256 amtA, address toB, uint256 amtB) private {
        // Degenerate shapes first: there is nothing to batch, so avoid the overlap analysis below.
        if (amtA == 0) {
            if (amtB != 0) _pullLeg(t, from, toB, amtB);
            return;
        }
        if (amtB == 0) {
            _pullLeg(t, from, toA, amtA);
            return;
        }

        // A self-directed leg moves no balance, so it gets no recipient bracket and is excluded
        // from the expected debit; the aggregate payer assertion then proves it was a no-op.
        bool selfA = toA == from;
        bool selfB = toB == from;
        // Both legs sharing a destination (`treasuryDest == manager`, or
        // `treasuryDest == rewardPoolDest`) is measured with one bracket against the summed amount.
        bool merged = !selfA && !selfB && toA == toB;

        uint256 expectedDebit = (selfA ? 0 : amtA) + (selfB ? 0 : amtB);

        uint256 fromBefore = t.balanceOf(from);
        uint256 aBefore = selfA ? 0 : t.balanceOf(toA);
        uint256 bBefore = (selfB || merged) ? 0 : t.balanceOf(toB);

        t.safeTransferFrom(from, toA, amtA);
        t.safeTransferFrom(from, toB, amtB);

        if (!selfA && t.balanceOf(toA) != aBefore + (merged ? amtA + amtB : amtA)) {
            revert TransferAmountMismatch();
        }
        if (!selfB && !merged && t.balanceOf(toB) != bBefore + amtB) revert TransferAmountMismatch();
        if (t.balanceOf(from) + expectedDebit != fromBefore) revert TransferAmountMismatch();
    }

    /// @dev Single-leg form of {_pullExact}: 4 balance reads, which is the floor for asserting both
    ///      sides of one transfer. `amount` must be non-zero.
    ///
    ///      Comparisons are written as `after != before + amount` rather than
    ///      `after - before != amount` so that an unexpected balance *decrease* on either side
    ///      surfaces as TransferAmountMismatch instead of an arithmetic panic.
    function _pullLeg(IERC20 t, address from, address to, uint256 amount) private {
        if (from == to) {
            t.safeTransferFrom(from, to, amount);
            return;
        }

        uint256 fromBefore = t.balanceOf(from);
        uint256 toBefore = t.balanceOf(to);

        t.safeTransferFrom(from, to, amount);

        if (t.balanceOf(to) != toBefore + amount) revert TransferAmountMismatch();
        if (t.balanceOf(from) + amount != fromBefore) revert TransferAmountMismatch();
    }

    /// @dev Resolves manager: local `lotteryIdToManager`, then `legacyHub` for old IDs.
    function _resolveManager(uint256 _lotteryId) private view returns (address manager) {
        manager = lotteryIdToManager[_lotteryId];
        if (manager == address(0) && _lotteryId < initialLotteryId) {
            ILotteryHubLegacy legacy = legacyHub;
            if (address(legacy) != address(0)) {
                manager = legacy.getManager(_lotteryId);
            }
        }
    }
}
