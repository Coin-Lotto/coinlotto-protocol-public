// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IReferralRegistry} from "./interfaces/IReferralRegistry.sol";

/// @title ReferralRegistry
/// @notice Immutable first-referrer binding for protocol users.
/// @dev Flow: `LotteryHub.buyTickets` calls `linkReferrer` before quoting and pulling
///      payment. The returned effective referrer drives fee splits on creators.
///
///      Semantics:
///        • First successful link for a user is permanent.
///        • `referrer == address(0)` or `referrer == user` stores self-referral internally
///          as `user → user` but exposes `address(0)` (no referrer fee).
///        • Repeat calls return the stored referrer and `isNew == false`.
///
///      Access control:
///        • `DEFAULT_ADMIN_ROLE` — admin rotation.
///        • `REFERRAL_LINKER_ROLE` — granted to `LotteryHub` (primary linker in V2).
contract ReferralRegistry is AccessControl, IReferralRegistry {
    /* ─────────────────────────────────────── Roles ──────────────────────────── */

    /// @notice Role required to call `linkReferrer`.
    bytes32 public constant REFERRAL_LINKER_ROLE = keccak256("REFERRAL_LINKER_ROLE");

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @dev `user → referrer`. Zero means unregistered. `user → user` means self-referral.
    mapping(address user => address referrer) private _referrerOf;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Emitted once when a user's referrer is first recorded.
    /// @param user     Buyer being registered.
    /// @param referrer Stored referrer (`user` when self-referred).
    event ReferrerLinked(address indexed user, address indexed referrer);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when a required address argument is `address(0)`.
    error ZeroAddress();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Deploys the registry and optionally grants the linker role at birth.
    /// @param initialDefaultAdmin Address receiving `DEFAULT_ADMIN_ROLE`.
    /// @param linker_             Address granted `REFERRAL_LINKER_ROLE`; use `address(0)` to skip.
    constructor(address initialDefaultAdmin, address linker_) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
        if (linker_ != address(0)) {
            _grantRole(REFERRAL_LINKER_ROLE, linker_);
        }
    }

    /* ─────────────────────────────────────── External ───────────────────────── */

    /// @inheritdoc IReferralRegistry
    /// @notice Links `referrer` to `user` on first call; otherwise returns the stored binding.
    /// @dev Only `REFERRAL_LINKER_ROLE`. Self-referral is stored as `user` but returned as zero.
    /// @param user     Buyer whose referrer is being set or queried.
    /// @param referrer Proposed referrer; zero means self-referral.
    /// @return effectiveReferrer Referrer used for fee math, or zero when self-referred.
    /// @return isNew `true` only when a new external referrer was linked this call.
    function linkReferrer(
        address user,
        address referrer
    ) external onlyRole(REFERRAL_LINKER_ROLE) returns (address effectiveReferrer, bool isNew) {
        address existingReferrer = _referrerOf[user];

        if (existingReferrer != address(0)) {
            return (existingReferrer == user ? address(0) : existingReferrer, false);
        }

        if (referrer == address(0) || referrer == user) {
            _referrerOf[user] = user;
            emit ReferrerLinked(user, user);
            return (address(0), false);
        }

        _referrerOf[user] = referrer;
        emit ReferrerLinked(user, referrer);
        return (referrer, true);
    }

    /// @inheritdoc IReferralRegistry
    /// @notice Returns whether `user` has any referrer record (including self-referral).
    function isRegistered(address user) external view returns (bool) {
        return _referrerOf[user] != address(0);
    }

    /// @inheritdoc IReferralRegistry
    /// @notice Returns the effective referrer for `user`, or zero if none/self-referred.
    function getReferrer(address user) external view returns (address) {
        address existingReferrer = _referrerOf[user];
        if (existingReferrer == address(0) || existingReferrer == user) return address(0);
        return existingReferrer;
    }

    /// @inheritdoc IReferralRegistry
    /// @notice Returns registration flag and effective referrer in one call.
    /// @return isUserRegistered `true` if `user` was ever linked.
    /// @return referrer Effective referrer, or zero for unregistered/self-referred.
    function getReferrerInfo(address user) external view returns (bool isUserRegistered, address referrer) {
        address existingReferrer = _referrerOf[user];
        if (existingReferrer == address(0)) return (false, address(0));
        if (existingReferrer == user) return (true, address(0));
        return (true, existingReferrer);
    }
}
