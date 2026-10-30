// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IProtocolLotteryFeederSupport
/// @notice Cross-manager REGULAR/SUPER feeder hooks exposed by `ProtocolLotteryManager`
///         for external feeders such as `ProtocolDuelLotteryManager`.
interface IProtocolLotteryFeederSupport {
    /// @notice Credits the SUPER prize pool for an incoming feeder contribution.
    ///         Returns `true` when the SUPER accepts the contribution; the caller MUST then
    ///         transfer `amount` of `token` to this contract via `safeTransfer`.
    ///         Returns `false` when the SUPER is not accepting feeds (caller keeps the funds).
    ///         Reverts with `MismatchEntryToken` when `token` differs from the SUPER's declared prize asset.
    /// @param feederLotteryId Source lottery ID (for events / accounting).
    /// @param superLotteryId  Target SUPER lottery ID.
    /// @param amount          Net feeder amount after SUPER protocol fee.
    /// @param token           ERC-20 asset that the caller will transfer on `true` return.
    function forwardExternalFeederFunds(
        uint256 feederLotteryId,
        uint256 superLotteryId,
        uint256 amount,
        address token
    ) external returns (bool forwarded);

    /// @notice Returns context needed by an external feeder before linking or forwarding funds.
    /// @return superFeeBp      Protocol fee bps that the SUPER charges on feeder proceeds.
    /// @return acceptsFeeding  True when the SUPER is still in a state that accepts feeder funds.
    /// @return prizeAsset      The ERC-20 asset declared as the SUPER prize; feeders must match this.
    /// @return superEndTime    End timestamp of the SUPER lottery; feeders must end before this.
    function getSuperFeederContext(
        uint256 superLotteryId
    ) external view returns (uint16 superFeeBp, bool acceptsFeeding, address prizeAsset, uint64 superEndTime);
}
