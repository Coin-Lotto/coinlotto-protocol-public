// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IReferralRegistry
/// @notice Permanent one-time referrer binding for lottery participants.
/// @dev Only addresses with `REFERRAL_LINKER_ROLE` (the deployed `LotteryHub`) may call
///      `linkReferrer`. The Hub invokes it at the start of `buyTickets` so every buyer is
///      registered before ticket proceeds are split.
interface IReferralRegistry {
    /// @notice Records `referrer` for `user` on first interaction; idempotent thereafter.
    /// @dev **Caller:** `REFERRAL_LINKER_ROLE` (Hub).
    ///      **Validations:** `user` must be non-zero (implementation); zero `referrer` or
    ///      `referrer == user` is stored as self-referral and exposed as `address(0)`.
    ///      **State:** Writes `_referrerOf[user]` once.
    ///      **Events:** `ReferrerLinked` on first link only.
    /// @param user     Buyer being registered.
    /// @param referrer Proposed referrer (`address(0)` → self-referral).
    /// @return effectiveReferrer  Stored referrer, or `address(0)` for self-referral.
    /// @return isNew                `true` when a new non-self referrer link was created.
    function linkReferrer(address user, address referrer) external returns (address, bool isNew);

    /// @notice Returns whether `user` has ever been linked (including self-referral).
    /// @dev **Caller:** anyone (view).
    /// @param user Address to query.
    /// @return `true` if `linkReferrer` has been called for `user`.
    function isRegistered(address user) external view returns (bool);

    /// @notice Returns the effective referrer for `user`.
    /// @dev **Caller:** anyone (view).
    ///      Returns `address(0)` when unregistered or self-referred.
    /// @param user Address to query.
    /// @return Referrer address or zero.
    function getReferrer(address user) external view returns (address);

    /// @notice Returns registration flag and effective referrer in one call.
    /// @dev **Caller:** anyone (view).
    ///      Self-referral returns `(true, address(0))`.
    /// @param user Address to query.
    /// @return isUserRegistered `true` after any `linkReferrer` call.
    /// @return referrer         Effective referrer; zero for none/self.
    function getReferrerInfo(address user) external view returns (bool isUserRegistered, address referrer);
}
