// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseLotteryManager} from "./BaseLotteryManager.sol";

/// @title ReferrerFeeLedger
/// @notice Shared ERC-20 referrer fee accounting for all lottery manager types.
/// @dev Inherits `BaseLotteryManager` to access `HUB_ROLE` / `hasRole` for the
///      Hub-proxy claim path. Both `ProtocolLotteryManager` and `UserLotteryManager`
///      inherit this mixin; C3 linearization merges the shared `BaseLotteryManager`
///      base correctly.
///
///      State layout (one storage slot per (referrer, token) pair):
///        `refFees[referrer][token]` — accrued ERC-20 referrer fees; claimed via
///        `claimReferrerFees`. CLT bonuses are tracked separately in `CltRewarder`.
abstract contract ReferrerFeeLedger is BaseLotteryManager {
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice Accrued referrer fees: `refFees[referrer][token] → amount`.
    mapping(address referrer => mapping(address token => uint256 amount)) public refFees;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Emitted when ERC-20 referrer fees are accrued on ticket purchase.
    event ReferrerFeeAdded(
        uint256 indexed lotteryId,
        address indexed referrer,
        address indexed token,
        uint256 amount,
        address buyer
    );

    /// @notice Emitted when referrer fees are claimed.
    event ReferrerFeeClaimed(address indexed referrer, address indexed token, uint256 amount);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when `claimReferrerFees` finds no accrued balance.
    error NoRefFees();

    /// @notice Thrown when a non-Hub caller tries to claim fees for another referrer.
    error InvalidReferrer();

    /* ─────────────────────────────────────── View ────────────────────────────── */

    /// @notice Returns accrued referrer fees for `referrer` in `token`.
    function getReferrerFee(address referrer, address token) external view returns (uint256) {
        return refFees[referrer][token];
    }

    /* ─────────────────────────────────────── Claim ───────────────────────────── */

    /// @notice Pays out all accrued ERC-20 referrer fees to `referrer`.
    /// @dev Hub calls with `referrer == msg.sender` (original caller forwarded).
    ///      Direct callers must match `referrer`.
    function claimReferrerFees(address referrer, address token) external {
        if (!hasRole(HUB_ROLE, msg.sender)) {
            if (referrer != msg.sender) revert InvalidReferrer();
        }

        uint256 amount = refFees[referrer][token];
        if (amount == 0) revert NoRefFees();
        refFees[referrer][token] = 0;
        IERC20(token).safeTransfer(referrer, amount);
        emit ReferrerFeeClaimed(referrer, token, amount);
    }
}
