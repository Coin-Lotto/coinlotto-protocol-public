// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IVRFV2PlusWrapperLike
/// @notice Minimal Chainlink VRF v2.5 wrapper surface used by `RndConsumer`.
/// @dev Wraps the direct-funding (native payment) model. `RndConsumer` inherits
///      `VRFV2PlusWrapperConsumerBase`, which also requires `link()` for construction even
///      when requests are paid in ETH (`nativePayment: true` in extra args).
interface IVRFV2PlusWrapperLike {
    /// @notice LINK token address configured on the wrapper.
    /// @dev **Caller:** anyone (view). May be `address(0)` on native-only deployments.
    /// @return LINK ERC-20 address used by the wrapper configuration.
    function link() external view returns (address);

    /// @notice Quotes the native-token cost of a VRF request using the live `tx.gasprice`.
    /// @dev **Caller:** anyone (view). Used by `RndConsumer.requestRandomness` at execution
    ///      time to enforce the minimum `msg.value` check. Reads `tx.gasprice` internally,
    ///      so results may be zero or misleading when called via off-chain `eth_call`.
    ///      For off-chain fee estimation use `estimateRequestPriceNative` instead.
    /// @param callbackGasLimit Gas supplied to the consuming contract callback.
    /// @param numWords         Number of random words (lottery uses `1`).
    /// @return Native-token price in wei.
    function calculateRequestPriceNative(
        uint32 callbackGasLimit,
        uint32 numWords
    ) external view returns (uint256);

    /// @notice Gas-price-aware fee estimate. Unlike `calculateRequestPriceNative`,
    ///         this function accepts an explicit gas price and is safe for off-chain use.
    /// @param callbackGasLimit Gas supplied to the consuming contract callback.
    /// @param numWords         Number of random words (lottery uses `1`).
    /// @param requestGasPriceWei The caller's gas-price assumption for this estimate (in wei).
    /// @return Estimated native-token price in wei.
    function estimateRequestPriceNative(
        uint32 callbackGasLimit,
        uint32 numWords,
        uint256 requestGasPriceWei
    ) external view returns (uint256);

    /// @notice Submits a VRF request paid with `msg.value` in the native token.
    /// @dev **Caller:** `RndConsumer` (or another funded consumer).
    ///      **Payment:** `msg.value` must meet the price from `calculateRequestPriceNative`.
    ///      **Returns:** Chainlink `requestId` used for fulfillment routing.
    /// @param callbackGasLimit     Callback gas for `fulfillRandomWords`.
    /// @param requestConfirmations Block confirmations before delivery.
    /// @param numWords             Random words to generate.
    /// @param extraArgs            VRF v2.5 extra args (e.g. native payment flag).
    /// @return requestId Assigned Chainlink request identifier.
    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256);
}
