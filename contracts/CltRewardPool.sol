// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICltRewardPool} from "./interfaces/ICltRewardPool.sol";

/// @title CltRewardPool
contract CltRewardPool is AccessControl, ICltRewardPool {
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── Roles ──────────────────────────── */

    /// @notice Role required to call `withdrawClt` and move CLT out of the bank.
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    /* ─────────────────────────────────────── State ──────────────────────────── */

    /// @notice CLT token used for every withdrawal from this contract.
    IERC20 public cltToken;

    /* ─────────────────────────────────────── Events ─────────────────────────── */

    /// @notice Emitted when the CLT token address is configured.
    event CltTokenSet(address indexed cltToken);

    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    /// @notice Thrown when a required address argument is `address(0)`.
    error ZeroAddress();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Deploys the bank.  CLT token is set post-deploy via `setCltToken`.
    /// @param initialDefaultAdmin Address receiving `DEFAULT_ADMIN_ROLE`.
    constructor(address initialDefaultAdmin) {
        if (initialDefaultAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
    }

    /* ─────────────────────────────────────── Configuration ──────────────────── */

    /// @notice Sets the CLT token address.  Can only be called by `DEFAULT_ADMIN_ROLE`.
    /// @param cltToken_ CLT (`CoinLotto`) token; must be non-zero.
    function setCltToken(address cltToken_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cltToken_ == address(0)) revert ZeroAddress();
        cltToken = IERC20(cltToken_);
        emit CltTokenSet(cltToken_);
    }

    /* ─────────────────────────────────────── External ───────────────────────── */

    /// @notice Transfers `amount` CLT from this contract to `to`.
    /// @dev Callable only by `WITHDRAW_ROLE` holders (`CltMissions`, `CltRewarder`).
    ///      Emits {CltWithdrawn}.
    /// @param to     Recipient of the CLT transfer.
    /// @param amount Wei amount of CLT to send.
    function withdrawClt(address to, uint256 amount) external onlyRole(WITHDRAW_ROLE) {
        cltToken.safeTransfer(to, amount);
        emit CltWithdrawn(to, amount);
    }
}
