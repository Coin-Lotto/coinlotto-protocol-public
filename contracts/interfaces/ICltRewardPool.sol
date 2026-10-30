// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ICltRewardPool {
    /// @notice Emitted when CLT is transferred out of the bank.
    /// @param to     Recipient of the transfer.
    /// @param amount CLT amount sent.
    event CltWithdrawn(address indexed to, uint256 amount);

    /// @notice Transfers CLT from the bank to `to`.
    /// @dev **Caller:** `WITHDRAW_ROLE` (typically `CltRewarder`).
    ///      **Validations:** Implementation uses `SafeERC20`; insufficient balance reverts.
    ///      **State:** Reduces bank CLT balance.
    ///      **Events:** `CltWithdrawn`.
    /// @param to     Recipient address.
    /// @param amount CLT amount in token smallest units.
    function withdrawClt(address to, uint256 amount) external;
}
