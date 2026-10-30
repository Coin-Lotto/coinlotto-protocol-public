// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title FeederAccounting
/// @notice Tracks REGULAR → SUPER lottery feeder links and allocation math.
/// @dev REGULAR and SUPER lotteries must be created by the same concrete creator contract
///      so feeder state can be read and updated without cross-contract calls.
///
///      Feeder model:
///        - A REGULAR lottery may link to at most one SUPER lottery (`superId`).
///        - The link is write-once per REGULAR lottery.
///        - `allocBp` is the share of each REGULAR ticket's gross revenue forwarded to the
///          SUPER lottery's prize pool (basis points, 1–10 000).
///
///      Storage is not duplicated in this abstract contract. Feeder fields live on the
///      per-lottery `Lottery` struct; concrete creators override `_getFeederSuperId`,
///      `_getFeederAllocBp`, and `_writeFeederLink` to read/write `_lotteries[regularId]`.
abstract contract FeederAccounting {
    /* ─────────────────────────────── Errors ──────────────────────────────── */

    /// @notice A feeder link was already recorded for this REGULAR lottery.
    error FeederAlreadyLinked();

    /// @notice Feeder allocation is zero or exceeds 100% (10 000 BP).
    error InvalidFeederAllocBp();

    /* ─────────────────────────────── Virtual storage hooks ───────────────── */

    /// @dev Returns the SUPER lottery ID linked to `regularId`, or `0` if unlinked.
    function _getFeederSuperId(uint256 regularId) internal view virtual returns (uint256);

    /// @dev Returns the feeder allocation in BP for `regularId`, or `0` if unlinked.
    function _getFeederAllocBp(uint256 regularId) internal view virtual returns (uint256);

    /// @dev Persists `superId` and `allocBp` on the REGULAR lottery record.
    function _writeFeederLink(uint256 regularId, uint256 superId, uint256 allocBp) internal virtual;

    /* ─────────────────────────────── Internal helpers ────────────────────── */

    /// @notice Registers a REGULAR lottery as a feeder for a SUPER lottery.
    /// @dev Reverts if a link already exists or `allocBp` is outside `(0, 10_000]`.
    /// @param _regularId REGULAR lottery ID (feeder source).
    /// @param _superId   SUPER lottery ID that receives the allocation.
    /// @param _allocBp   Portion of gross ticket revenue sent to SUPER (basis points).
    function _registerFeeder(uint256 _regularId, uint256 _superId, uint256 _allocBp) internal {
        if (_getFeederSuperId(_regularId) != 0) revert FeederAlreadyLinked();
        if (_allocBp == 0 || _allocBp > 10_000) revert InvalidFeederAllocBp();
        _writeFeederLink(_regularId, _superId, _allocBp);
    }

    /// @dev Returns the linked SUPER lottery ID, or `0`.
    function _linkedSuperLottery(uint256 _regularId) internal view returns (uint256) {
        return _getFeederSuperId(_regularId);
    }

    /// @notice Computes the SUPER prize-pool contribution from REGULAR ticket revenue.
    /// @dev Returns `0` when `regularId` has no feeder link.
    /// @param _regularId REGULAR lottery ID.
    /// @param _revenue   Gross ticket revenue before protocol/creator fees.
    /// @return _amount   Token amount to credit to the SUPER prize pool.
    function _calcFeederAmount(uint256 _regularId, uint256 _revenue) internal view returns (uint256 _amount) {
        uint256 alloc = _getFeederAllocBp(_regularId);
        if (alloc == 0) return 0;
        _amount = (_revenue * alloc) / 10_000;
    }
}
