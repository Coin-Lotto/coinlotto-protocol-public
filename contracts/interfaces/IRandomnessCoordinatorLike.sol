// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IVRFV2PlusWrapper} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusWrapper.sol";

/// @title IRandomnessCoordinatorLike
/// @notice Chainlink VRF v2.5 coordinator API implemented by `RndConsumer`.
/// @dev Lottery **creator** contracts register as consumers and call `requestRandomness` during
///      `requestDraw` (including its post-timeout retry). Fulfillment is delivered to the requesting consumer via
///      `ILotteryRandomnessConsumer.fulfillRandomness`. Uses native-token (ETH) direct funding.
interface IRandomnessCoordinatorLike {
    /// @notice Emitted when a consumer contract is registered or removed.
    /// @param consumer Creator or other protocol contract address.
    /// @param allowed  `true` when registered; `false` when deregistered.
    event ConsumerSet(address indexed consumer, bool allowed);

    /// @dev Declared for ABI stability. Not emitted: refunds are credited to `pendingRefunds`
    ///      instead of being sent.
    /// @param to     Intended refund recipient.
    /// @param amount Wei that could not be returned.
    event EtherRefundFailed(address indexed to, uint256 amount);

    /// @notice ETH credited to `recipient`'s withdrawable refund balance.
    /// @param recipient Address that may withdraw the refund.
    /// @param amount    Wei credited.
    event RefundCredited(address indexed recipient, uint256 amount);

    /// @notice `recipient` withdrew its refund balance to `to`.
    /// @param recipient Address whose balance was withdrawn.
    /// @param to        ETH destination.
    /// @param amount    Wei sent.
    event RefundWithdrawn(address indexed recipient, address indexed to, uint256 amount);

    /// @notice Zero address passed where forbidden.
    error ZeroAddress();

    /// @notice `msg.value` is below the current VRF request price.
    error InvalidEtherAmount();

    /// @notice `requestRandomness` / `cancelRequest` caller is not in `registeredConsumers`.
    /// @param sender Calling address.
    error NotRegisteredConsumer(address sender);

    /// @notice `cancelRequest` caller is not the consumer that created the request.
    error NotRequestConsumer();

    /// @notice Unknown request, already fulfilled, or cancelled mapping entry.
    error InvalidRequest();

    /// @notice Submits one VRF word for `lotteryId` using native ETH payment.
    /// @dev **Caller:** registered consumer (lottery creator).
    ///      **Payment:** `msg.value >= calculateRequestFee(currentGasPriceWei)`; excess credited to
    ///      `pendingRefunds[refundTo]` (no ETH sent to `refundTo`).
    ///      **State:** Stores `requestId → { consumer, lotteryId, drawGeneration }`;
    ///      increments `_pendingRequestCount[msg.sender]`.
    ///      **Returns:** Chainlink `requestId`.
    /// @param lotteryId     Lottery associated with the request (stored as `uint64`).
    /// @param drawGeneration Current draw generation from `LotteryState.drawGeneration`.
    ///                       Stored in the pending entry and checked on callback to detect
    ///                       stale responses from superseded requests or a rotated coordinator.
    /// @param refundTo      Address credited with excess ETH (`address(0)` forfeits it).
    /// @return requestId Chainlink VRF request identifier.
    function requestRandomness(
        uint256 lotteryId,
        uint32 drawGeneration,
        address refundTo
    ) external payable returns (uint256 requestId);

    /// @notice Credits `msg.value` to `recipient`'s withdrawable refund balance.
    /// @dev **Caller:** registered consumer. Used for single-ticket draw refunds. Sends no ETH.
    /// @param recipient Non-zero refund owner.
    function creditRefund(address recipient) external payable;

    /// @notice Withdraws the caller's full refund balance to `to`.
    /// @dev **Caller:** anyone with a non-zero `pendingRefunds` balance.
    /// @param to Non-zero ETH destination.
    function withdrawRefund(address to) external;

    /// @notice Withdrawable refund balance of `recipient`.
    function pendingRefunds(address recipient) external view returns (uint256 amount);

    /// @notice Sum of all withdrawable refund balances (reserved ETH).
    function totalPendingRefunds() external view returns (uint256 amount);

    /// @notice Removes a pending request so a late VRF callback reverts with `InvalidRequest`.
    /// @dev **Caller:** the consumer that created `requestId`.
    ///      **Validations:** `NotRequestConsumer` if caller mismatch; `InvalidRequest` if missing.
    ///      **State:** Deletes pending mapping entry; decrements `_pendingRequestCount[msg.sender]`.
    /// @param requestId Request to cancel before fulfillment.
    function cancelRequest(uint256 requestId) external;

    /// @notice Returns the number of outstanding VRF requests for `manager` that have not
    ///         yet been fulfilled or cancelled.
    /// @dev Used by `BaseLotteryManager.setRndConsumer` and `finalizeConsumerRevocation` to
    ///      decide whether revocation of an old coordinator is safe. Per-manager so multiple
    ///      managers sharing one `RndConsumer` have independent counts.
    /// @param manager The manager (consumer) contract address to query.
    /// @return count  Number of unresolved VRF requests from `manager`.
    function pendingRequestCount(address manager) external view returns (uint16 count);

    /// @notice Returns the configured Chainlink VRF v2.5 wrapper.
    /// @dev **Caller:** anyone (view).
    function vrfWrapper() external view returns (IVRFV2PlusWrapper wrapper);

    /// @notice Whether `consumer` may call `requestRandomness`.
    /// @dev **Caller:** anyone (view).
    /// @param consumer Contract address to check.
    /// @return allowed Registration flag.
    function isRegisteredConsumer(address consumer) external view returns (bool allowed);

    /// @notice Gas limit forwarded to the VRF callback on consumers.
    /// @dev **Caller:** anyone (view).
    function callbackGasLimit() external view returns (uint32 gasLimit);

    /// @notice Block confirmations required before VRF fulfillment.
    /// @dev **Caller:** anyone (view).
    function requestConfirmations() external view returns (uint16 confirmations);

    /// @notice Looks up the lottery ID for a pending VRF request.
    /// @dev **Caller:** anyone (view). Returns `0` after fulfillment or if unknown.
    /// @param requestId Chainlink request ID.
    /// @return lotteryId Associated lottery, or `0`.
    function requestToLottery(uint256 requestId) external view returns (uint256 lotteryId);

    /// @notice Returns the consumer that submitted `requestId`.
    /// @dev **Caller:** anyone (view). Zero address if not pending.
    /// @param requestId Chainlink request ID.
    /// @return consumer Originating consumer contract.
    function requestConsumer(uint256 requestId) external view returns (address consumer);

    /// @notice Gas-price-aware estimate of the native fee for one VRF word.
    /// @dev **Caller:** anyone (view). Delegates to `estimateRequestPriceNative` on the
    ///      underlying Chainlink wrapper using the supplied gas price. Off-chain safe.
    ///      Apply a buffer to the result; actual fee is recalculated at execution time.
    /// @param gasPriceWei The caller's gas-price assumption for this estimate (in wei).
    /// @return fee Estimated Wei required as `msg.value` for `requestRandomness`.
    function calculateRequestFee(uint256 gasPriceWei) external view returns (uint256 fee);
}

/// @title ILotteryRandomnessConsumer
/// @notice Callback surface implemented by lottery creators receiving VRF results.
/// @dev `RndConsumer` calls `fulfillRandomness` after normalising the raw word to `[1, type(uint256).max]`
///      so `seed == 0` remains the “draw incomplete” sentinel. Implementations must restrict
///      callers to the coordinator (`RANDOMNESS_COORDINATOR_ROLE` / router address).
interface ILotteryRandomnessConsumer {
    /// @notice Applies the verified draw seed to `lotteryId`.
    /// @dev **Caller:** `RndConsumer` (coordinator) only.
    ///      **State:** Sets `LotteryState.seed`, transitions to `DRAW_COMPLETED`, emits draw events.
    ///      **Reverts:** If lottery ID unknown or draw not expected (implementation-specific).
    /// @param lotteryId Target lottery on the consumer contract.
    /// @param seed      Normalised VRF output (`> 0`).
    function fulfillRandomness(uint256 lotteryId, uint256 seed) external;

    /// @notice Returns the current draw generation for `lotteryId`.
    /// @dev Called by `RndConsumer.fulfillRandomWords` to verify that an incoming VRF callback
    ///      belongs to the most recent pending request. If the generation stored in the
    ///      `PendingRequest` differs from the value returned here, the callback is stale and
    ///      must be discarded without forwarding randomness to the manager.
    ///      `0` means no draw has ever been requested for this lottery.
    /// @param lotteryId Target lottery.
    /// @return generation Current `LotteryState.drawGeneration`.
    function drawGeneration(uint256 lotteryId) external view returns (uint32 generation);
}
