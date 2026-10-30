// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILotteryRandomnessConsumer} from "./interfaces/IRandomnessCoordinatorLike.sol";

/// @title RndConsumer
/// @notice Shared Chainlink VRF v2.5 coordinator for lottery managers.
/// @dev Managers (`BaseLotteryManager` descendants) request randomness here; fulfillment
///      routes back to the requesting manager via `ILotteryRandomnessConsumer.fulfillRandomness`.
///
///      Request lifecycle:
///        1. Registered consumer calls `requestRandomness{value: fee}(lotteryId, refundTo)`.
///        2. `_pendingRequests[requestId]` stores `{consumer, lotteryId}`.
///        3. Wrapper calls `fulfillRandomWords`; seed is normalized to [1, type(uint256).max].
///        4. Pending entry is deleted (CEI) then consumer callback runs.
///
///      Access control:
///        • `owner` — `setConsumer`, `setVrfConfig`, `withdraw`, `recover` (unreserved ETH only).
///        • `registeredConsumers` — `requestRandomness`, `cancelRequest`, `creditRefund`.
///        • anyone — `withdrawRefund` (own `pendingRefunds`).
contract RndConsumer is VRFV2PlusWrapperConsumerBase, Ownable, ReentrancyGuard {
    /* ─────────────────────────────────────── Structs ──────────────────────────── */

    /// @notice Routing record for an in-flight VRF request.
    /// @dev Storage layout — 2 slots (36 bytes used, 28 wasted in slot 1):
    ///        Slot 0: consumer (20) + drawGeneration (4) + lotteryId (8)  = 32 bytes
    ///        Slot 1: createdAt (4)                                        =  4 bytes used
    ///      `lotteryId` is kept as uint64 (no truncation risk, full range safety).
    ///      `createdAt` uses a dedicated slot; 28 bytes of slot 1 remain unused.
    ///      Zero `consumer` means no pending request (fulfilled, cancelled, or force-closed).
    struct PendingRequest {
        address consumer;
        uint32 drawGeneration; // snapshot of LotteryState.drawGeneration at request time
        uint64 lotteryId;      // cast from uint256 at request time; uint64 preserves full range
        uint32 createdAt;      // Unix timestamp at request creation (slot 1)
    }

    /* ─────────────────────────────────────── Constants ─────────────────────── */

    /// @notice Minimum time that must elapse after request creation before the owner
    ///         may force-close it via `forceCloseRequests`. Protects against premature
    ///         cleanup of requests that are still within normal Chainlink fulfillment latency.
    uint256 private constant FORCE_CLOSE_DELAY = 1 days;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice Gas limit passed to the VRF callback on each fulfillment.
    uint32 public callbackGasLimit;

    /// @notice Block confirmations Chainlink waits before fulfilling.
    uint16 public requestConfirmations;

    /// @notice Whether an address may request or cancel randomness.
    mapping(address consumer => bool) public registeredConsumers;

    /// @dev VRF `requestId` → originating consumer and lottery.
    mapping(uint256 requestId => PendingRequest) private _pendingRequests;

    /// @dev Outstanding VRF request count per requesting manager (consumer address).
    ///      Incremented on `requestRandomness`, decremented on `fulfillRandomWords` or
    ///      `cancelRequest`. Used by managers to decide when it is safe to revoke an
    ///      old coordinator's `RANDOMNESS_COORDINATOR_ROLE`.
    mapping(address manager => uint16) private _pendingRequestCount;

    /// @notice Withdrawable ETH refunds per recipient (excess VRF fees, single-ticket draw refunds).
    /// @dev Credited rather than sent, so no draw calls a user address.
    mapping(address recipient => uint256) public pendingRefunds;

    /// @notice Sum of all `pendingRefunds`; reserved and excluded from owner `withdraw` / `recover`.
    uint256 public totalPendingRefunds;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Emitted when a consumer is added or removed from the allowlist.
    /// @param consumer Creator or coordinator address.
    /// @param allowed  `true` when registered, `false` when removed.
    event ConsumerSet(address indexed consumer, bool allowed);

    /// @notice Emitted when VRF callback parameters change.
    /// @param callbackGasLimit     New callback gas limit.
    /// @param requestConfirmations New confirmation depth.
    event VrfConfigSet(uint32 callbackGasLimit, uint16 requestConfirmations);

    /// @notice Excess ETH refund failed.
    /// @dev Declared for ABI stability. Not emitted: excess is credited to {pendingRefunds}
    ///      instead of being sent.
    /// @param to     Intended refund recipient.
    /// @param amount Wei that could not be sent.
    event EtherRefundFailed(address indexed to, uint256 amount);

    /// @notice Emitted when a VRF callback arrives for a superseded request.
    /// @dev Fired when `PendingRequest.drawGeneration` differs from the manager's current
    ///      `drawGeneration(lotteryId)`. The pending entry is cleaned up and `_pendingRequestCount`
    ///      is decremented, but `fulfillRandomness` is not called. Covers a newer request on the
    ///      same manager and a request left behind after coordinator rotation.
    /// @param requestId      The stale Chainlink request ID.
    /// @param consumer       Manager that originated the request.
    /// @param lotteryId      Associated lottery.
    /// @param staleGen       Generation stored in the pending entry (now superseded).
    /// @param currentGen     Generation currently active on the manager.
    event StaleVrfResponseIgnored(
        uint256 indexed requestId,
        address indexed consumer,
        uint256 indexed lotteryId,
        uint32 staleGen,
        uint32 currentGen
    );

    /// @notice Emitted when the owner force-closes a permanently stuck VRF request.
    /// @dev Fired once per entry in `forceCloseRequests`. After this event, the pending
    ///      entry is deleted and the originating manager's `pendingRequestCount` is decremented.
    ///      A subsequent Chainlink callback for the same `requestId` reverts with {InvalidRequest}.
    /// @param requestId Closed Chainlink request ID.
    /// @param consumer  Manager that submitted the request.
    /// @param lotteryId Associated lottery.
    event RequestForceClosed(
        uint256 indexed requestId,
        address indexed consumer,
        uint256 indexed lotteryId
    );

    /// @notice Emitted when ETH is credited to `recipient`'s withdrawable refund balance.
    /// @param recipient Address that may withdraw the refund.
    /// @param amount    Wei credited.
    event RefundCredited(address indexed recipient, uint256 amount);

    /// @notice Emitted when `recipient` withdraws its refund balance to `to`.
    /// @param recipient Address whose balance was withdrawn.
    /// @param to        ETH destination.
    /// @param amount    Wei sent.
    event RefundWithdrawn(address indexed recipient, address indexed to, uint256 amount);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when a required address is zero.
    error ZeroAddress();

    /// @notice Thrown when a numeric parameter must be non-zero.
    error InvalidAmount();

    /// @notice Thrown when `msg.value` is below the quoted native VRF fee.
    error InvalidEtherAmount();

    /// @notice Thrown when an owner ETH sweep or `recover` transfer fails.
    error EtherTransferFailed();

    /// @notice Thrown when fulfilling or cancelling an unknown/already-cleared request.
    error InvalidRequest();

    /// @notice Thrown when `requestRandomness` or `cancelRequest` is called by a non-consumer.
    /// @param sender Caller that failed the allowlist check.
    error NotRegisteredConsumer(address sender);

    /// @notice Thrown when `cancelRequest` is invoked by a consumer other than the request owner.
    error NotRequestConsumer();

    /// @notice Thrown when `forceCloseRequests` is called before `FORCE_CLOSE_DELAY` has elapsed
    ///         since the request was created.
    error RequestTooEarly();

    /// @notice Thrown when `withdrawRefund` is called with no pending refund.
    error NoPendingRefund();

    /* ─────────────────────────────────────── Modifiers ────────────────────────── */

    /// @dev Restricts to addresses with `registeredConsumers[msg.sender] == true`.
    modifier onlyRegisteredConsumer() {
        if (!registeredConsumers[msg.sender]) revert NotRegisteredConsumer(msg.sender);
        _;
    }

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Initializes VRF wrapper wiring and default callback parameters.
    /// @param owner_                Initial `owner` (also validated non-zero).
    /// @param wrapper_              Chainlink VRF v2.5 wrapper contract.
    /// @param callbackGasLimit_     Callback gas limit; must be > 0.
    /// @param requestConfirmations_ Confirmations; must be > 0.
    constructor(
        address owner_,
        address wrapper_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_
    ) Ownable(owner_) VRFV2PlusWrapperConsumerBase(wrapper_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (wrapper_ == address(0)) revert ZeroAddress();
        if (callbackGasLimit_ == 0) revert InvalidAmount();
        if (requestConfirmations_ == 0) revert InvalidAmount();

        callbackGasLimit = callbackGasLimit_;
        requestConfirmations = requestConfirmations_;
    }

    /* ─────────────────────────── Randomness requests ────────────────────────── */

    /// @notice Requests one VRF word for `lotteryId` and records the calling consumer.
    /// @dev Caller must send at least `calculateRequestFee(currentGasPriceWei)` in native ETH. Excess is
    ///      credited to `pendingRefunds[refundTo]` when `refundTo` is non-zero (withdraw via
    ///      `withdrawRefund`); no ETH is sent to `refundTo`.
    ///      Increments `_pendingRequestCount[msg.sender]` so coordinator rotation can be
    ///      deferred until all in-flight requests for this manager are resolved.
    /// @param lotteryId      Lottery associated with this request (stored as `uint64`).
    /// @param drawGeneration Current draw generation from `LotteryState.drawGeneration`.
    ///                       Stored in the pending entry; compared on callback to detect stale
    ///                       responses.
    /// @param refundTo       Address credited with ETH above the VRF fee; may be zero to forfeit excess.
    /// @return requestId Chainlink VRF request identifier.
    function requestRandomness(
        uint256 lotteryId,
        uint32 drawGeneration,
        address refundTo
    ) external payable onlyRegisteredConsumer nonReentrant returns (uint256 requestId) {
        uint32 gasLimit = callbackGasLimit;
        uint16 confirmations = requestConfirmations;

        uint256 reqPrice = i_vrfV2PlusWrapper.calculateRequestPriceNative(gasLimit, 1);
        if (msg.value < reqPrice) revert InvalidEtherAmount();

        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}));

        requestId = i_vrfV2PlusWrapper.requestRandomWordsInNative{value: reqPrice}(
            gasLimit,
            confirmations,
            1,
            extraArgs
        );

        _pendingRequests[requestId] = PendingRequest({
            consumer: msg.sender,
            drawGeneration: drawGeneration,
            lotteryId: uint64(lotteryId),
            createdAt: uint32(block.timestamp)
        });
        _pendingRequestCount[msg.sender]++;

        uint256 excess = msg.value - reqPrice;
        if (excess > 0 && refundTo != address(0)) _creditRefund(refundTo, excess);
    }

    /// @notice Credits `msg.value` to `recipient`'s refund balance (single-ticket draw refund).
    /// @dev **Caller:** registered consumer (manager). Sends no ETH.
    /// @param recipient Non-zero address that may later `withdrawRefund`.
    function creditRefund(address recipient) external payable onlyRegisteredConsumer {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidAmount();
        _creditRefund(recipient, msg.value);
    }

    /// @notice Withdraws the caller's full refund balance to `to`.
    /// @dev Not consumer-gated: works after coordinator rotation or consumer deregistration.
    ///      `to` lets contracts that reject ETH redirect the payout.
    /// @param to Non-zero ETH destination.
    function withdrawRefund(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NoPendingRefund();
        pendingRefunds[msg.sender] = 0;
        totalPendingRefunds -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EtherTransferFailed();
        emit RefundWithdrawn(msg.sender, to, amount);
    }

    function _creditRefund(address recipient, uint256 amount) private {
        pendingRefunds[recipient] += amount;
        totalPendingRefunds += amount;
        emit RefundCredited(recipient, amount);
    }

    /// @notice Removes a pending request so a late VRF callback reverts with {InvalidRequest}.
    /// @dev Only the consumer that created `requestId` may cancel.
    ///      Decrements `_pendingRequestCount[msg.sender]` to reflect that this request is resolved.
    /// @param requestId VRF request to drop from the routing table.
    function cancelRequest(uint256 requestId) external onlyRegisteredConsumer {
        PendingRequest storage req = _pendingRequests[requestId];
        if (req.consumer == address(0)) revert InvalidRequest();
        if (req.consumer != msg.sender) revert NotRequestConsumer();
        delete _pendingRequests[requestId];
        if (_pendingRequestCount[msg.sender] > 0) _pendingRequestCount[msg.sender]--;
    }

    /* ─────────────────────────── Admin (onlyOwner) ──────────────────────────── */

    /// @notice Registers or deregisters a creator (or other consumer) address.
    /// @param consumer Non-zero consumer contract.
    /// @param allowed  Registration flag.
    function setConsumer(address consumer, bool allowed) external onlyOwner {
        if (consumer == address(0)) revert ZeroAddress();
        registeredConsumers[consumer] = allowed;
        emit ConsumerSet(consumer, allowed);
    }

    /// @notice Updates VRF callback gas and confirmation settings.
    /// @param newCallbackGasLimit     Must be > 0.
    /// @param newRequestConfirmations Must be > 0.
    function setVrfConfig(uint32 newCallbackGasLimit, uint16 newRequestConfirmations) external onlyOwner {
        if (newCallbackGasLimit == 0 || newRequestConfirmations == 0) revert InvalidAmount();
        callbackGasLimit = newCallbackGasLimit;
        requestConfirmations = newRequestConfirmations;
        emit VrfConfigSet(newCallbackGasLimit, newRequestConfirmations);
    }

    /// @notice Sweeps the native balance not reserved for `totalPendingRefunds` to `owner`.
    function withdraw() external onlyOwner {
        (bool ok, ) = owner().call{value: address(this).balance - totalPendingRefunds}("");
        if (!ok) revert EtherTransferFailed();
    }

    /// @notice Sends a fixed wei amount of unreserved balance to `to`.
    /// @param to     Non-zero recipient.
    /// @param amount Positive amount not exceeding `balance - totalPendingRefunds`.
    function recover(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > address(this).balance - totalPendingRefunds) revert InvalidAmount();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EtherTransferFailed();
    }

    /// @notice Emergency batch-cleanup for permanently stuck VRF requests.
    /// @dev Owner-only. Designed for requests that have been pending longer than reasonable
    ///      Chainlink fulfillment latency (e.g., dead coordinator node, dropped request).
    ///
    ///      A request may be force-closed only when **both** conditions hold:
    ///        (a) The entry still exists (`consumer != address(0)`).
    ///        (b) At least `FORCE_CLOSE_DELAY` (1 day) has elapsed since `createdAt`.
    ///
    ///      The batch is **atomic**: any entry failing either condition reverts the entire call.
    ///      Duplicate `requestId` values also revert: after the first iteration the entry is
    ///      deleted, so the second occurrence fails condition (a) with {InvalidRequest}.
    ///
    ///      Effects per closed request:
    ///        - `_pendingRequests[requestId]` deleted.
    ///        - `_pendingRequestCount[consumer]` decremented.
    ///        - {RequestForceClosed} emitted.
    ///
    ///      A subsequent Chainlink callback for a force-closed request reverts with {InvalidRequest}
    ///      (CEI guard in `fulfillRandomWords` catches the zeroed `consumer`). The lottery is unaffected.
    ///
    ///      After cleanup, if `pendingRequestCount(oldConsumer) == 0` for a given manager, the
    ///      manager can call `finalizeConsumerRevocation(oldConsumer)` normally.
    ///
    /// @param requestIds Non-empty list of request IDs to close.
    function forceCloseRequests(uint256[] calldata requestIds) external onlyOwner {
        uint256 len = requestIds.length;
        if (len == 0) revert InvalidAmount();

        for (uint256 i; i < len; ) {
            uint256 reqId = requestIds[i];
            PendingRequest memory req = _pendingRequests[reqId];

            // (a) must still exist
            if (req.consumer == address(0)) revert InvalidRequest();

            // (b) must be old enough
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp < uint256(req.createdAt) + FORCE_CLOSE_DELAY) revert RequestTooEarly();

            delete _pendingRequests[reqId];
            if (_pendingRequestCount[req.consumer] > 0) _pendingRequestCount[req.consumer]--;

            emit RequestForceClosed(reqId, req.consumer, req.lotteryId);

            unchecked { ++i; }
        }
    }

    /* ─────────────────────────── Views ────────────────────────────────────────── */

    /// @notice Returns the configured VRF wrapper address.
    function vrfWrapper() external view returns (address) {
        return address(i_vrfV2PlusWrapper);
    }

    /// @notice Returns whether `consumer` may request randomness.
    function isRegisteredConsumer(address consumer) external view returns (bool) {
        return registeredConsumers[consumer];
    }

    /// @notice Returns the lottery ID for a pending `requestId`, or 0 if none.
    function requestToLottery(uint256 requestId) external view returns (uint256) {
        return _pendingRequests[requestId].lotteryId;
    }

    /// @notice Returns the consumer address for a pending `requestId`, or zero if none.
    function requestConsumer(uint256 requestId) external view returns (address) {
        return _pendingRequests[requestId].consumer;
    }

    /// @notice Returns the creation timestamp of a pending request, or 0 if not found.
    /// @dev Useful for off-chain monitoring tools to identify force-close candidates.
    ///      Returns 0 once the request is fulfilled, cancelled, or force-closed.
    function requestCreatedAt(uint256 requestId) external view returns (uint32 timestamp) {
        return _pendingRequests[requestId].createdAt;
    }

    /// @notice Returns the number of unresolved VRF requests submitted by `manager`.
    /// @dev Used by `BaseLotteryManager.setRndConsumer` and `finalizeConsumerRevocation` to
    ///      determine whether the old coordinator's `RANDOMNESS_COORDINATOR_ROLE` can be revoked
    ///      without stranding in-flight callbacks. Per-manager so multiple managers sharing one
    ///      coordinator are counted independently.
    /// @param manager The consumer (manager) contract address to query.
    /// @return count  Number of outstanding (unfulfilled, uncancelled) requests from `manager`.
    function pendingRequestCount(address manager) external view returns (uint16 count) {
        return _pendingRequestCount[manager];
    }

    /// @notice Gas-price-aware estimate of the native fee for one VRF word.
    /// @dev Delegates to `IVRFV2PlusWrapper.estimateRequestPriceNative` with the
    ///      caller-supplied gas price, so the estimate is deterministic with respect to
    ///      `gasPriceWei` and safe to use in off-chain contexts where `tx.gasprice`
    ///      may be zero or differ from the eventual execution gas price.
    ///
    ///      This is still an **estimate**: the actual fee charged by `requestRandomness`
    ///      is recalculated at execution time using the live `tx.gasprice`. Pass the
    ///      expected submission gas price and apply an off-chain buffer for safety.
    ///
    ///      Buffering and retry policy remain the caller's responsibility.
    /// @param gasPriceWei The caller's gas-price assumption for this estimate (in wei).
    ///                    Typically set to the current network `maxFeePerGas` or `gasPrice`.
    /// @return fee Estimated native-token fee in wei.
    function calculateRequestFee(uint256 gasPriceWei) external view returns (uint256) {
        return i_vrfV2PlusWrapper.estimateRequestPriceNative(callbackGasLimit, 1, gasPriceWei);
    }

    /* ─────────────────────────── VRF fulfillment ────────────────────────────── */

    /// @dev Chainlink entry point (via `VRFV2PlusWrapperConsumerBase`). Deletes the routing
    ///      entry (CEI), decrements the per-manager pending count, then checks whether the
    ///      callback belongs to the current draw generation before forwarding to the manager.
    ///
    ///      Stale callbacks:
    ///      If `PendingRequest.drawGeneration` differs from `manager.drawGeneration(lotteryId)`,
    ///      the request has been superseded by a newer VRF request (retry) or by coordinator
    ///      rotation followed by a retry. In that case the callback is consumed cleanly:
    ///      the pending entry is already deleted, the count is decremented, {StaleVrfResponseIgnored}
    ///      is emitted, and the function returns without calling `fulfillRandomness`.
    ///
    /// @param _requestId   Fulfilled request ID.
    /// @param _randomWords VRF output; length 1 for this deployment.
    // solhint-disable-next-line private-vars-leading-underscore
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        PendingRequest memory req = _pendingRequests[_requestId];
        delete _pendingRequests[_requestId]; // CEI: clear before any external calls
        if (req.consumer == address(0)) revert InvalidRequest();

        // Decrement per-manager count for every resolved request (including stale ones).
        if (_pendingRequestCount[req.consumer] > 0) _pendingRequestCount[req.consumer]--;

        // Stale generation check: query the manager's current draw generation.
        // This is a cross-contract STATICCALL; generation is a packed uint32 in LotteryState.
        uint32 currentGen = ILotteryRandomnessConsumer(req.consumer).drawGeneration(req.lotteryId);
        if (req.drawGeneration != currentGen) {
            emit StaleVrfResponseIgnored(_requestId, req.consumer, req.lotteryId, req.drawGeneration, currentGen);
            return; // clean return — no revert, Chainlink marks tx as successful
        }

        uint256 seed = _randomWords[0];
        uint256 normalizedSeed = seed == type(uint256).max ? seed : seed + 1;

        ILotteryRandomnessConsumer(req.consumer).fulfillRandomness(req.lotteryId, normalizedSeed);
    }
}
