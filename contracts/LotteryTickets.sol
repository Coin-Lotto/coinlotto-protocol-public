// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title LotteryTickets
/// @notice Per-lottery ticket indexing and ERC721A-style lazy ownership tracking.
/// @dev Mixed into `BaseLotteryManager` (not deployed alone). Each `lotteryId` maintains its
///      own ticket namespace:
///
///      IMPORTANT — Tickets are NON-TRANSFERABLE. There is intentionally no transfer or
///      approval mechanism in this contract. This invariant is relied upon by
///      {ProtocolLotteryManager.claimCltReward}, which reads the live `balanceOf` at claim time
///      rather than a purchase-time snapshot. Any upgrade that adds ticket transfers MUST also
///      migrate the CLT reward logic to a per-ticket claim model.
///
///        - `_lotteryIndex[lotteryId]` — next ticket ID to mint (starts at `1` after init).
///        - `_ownerships[lotteryId][ticketId]` — sparse map: only the **first** ID of each
///          purchase batch stores `owner` and `purchaseTime`; later IDs in the batch resolve
///          by walking backward until a non-zero owner is found.
///        - `balanceOf[lotteryId][owner]` — per-owner ticket count.
///
///      Ticket IDs are **1-based**; ID `0` is unused. Tickets sold =
///      `_lotteryIndex[lotteryId] - 1` (or `0` before the lottery is initialised).
contract LotteryTickets {
    /* ------------------------------------- Types ------------------------------------- */

    /// @notice Ownership record for the first ticket in a purchased batch.
    struct TicketOwnership {
        /// @dev Owner of the batch (and all consecutive unmapped IDs after it).
        address owner;
        /// @dev `block.timestamp` when the batch was minted.
        uint64 purchaseTime;
    }

    /* ------------------------------------- State ------------------------------------- */

    /// @dev Next ticket ID to assign per lottery (equals `ticketsSold + 1` once initialised).
    mapping(uint256 lotteryId => uint256 currentIndex) internal _lotteryIndex;

    /// @dev Sparse ownership: first ticket of each batch only.
    mapping(uint256 lotteryId => mapping(uint256 ticketId => TicketOwnership))
        internal _ownerships;

    /// @notice Ticket balance per `(lotteryId, owner)`.
    mapping(uint256 lotteryId => mapping(address owner => uint256 balance)) public balanceOf;

    /* ------------------------------------- Events ------------------------------------- */

    /// @notice Emitted when a contiguous batch of tickets is minted.
    /// @param lotteryId      Lottery the tickets belong to.
    /// @param recipient      Owner of the batch.
    /// @param startTicketId  First ticket ID in the batch (1-based).
    /// @param quantity       Number of tickets minted.
    event TicketsMinted(
        uint256 indexed lotteryId,
        address indexed recipient,
        uint256 startTicketId,
        uint256 quantity
    );

    /* ------------------------------------- Errors ------------------------------------- */

    /// @notice Mint or purchase quantity is zero.
    error InvalidQuantity();

    /// @notice `ticketRecipient` or another required address is the zero address.
    error ZeroAddress();

    /// @notice Ticket ID is `0`, above the current index, or has no resolvable owner.
    error TicketDoesNotExist();

    /* ------------------------------------- External views ------------------------------------- */

    /// @notice Returns owner and purchase time for a ticket.
    /// @param lotteryId    Lottery ID.
    /// @param ticketId     1-based ticket ID.
    /// @return owner        Ticket owner.
    /// @return purchaseTime Batch purchase timestamp.
    function getTicketOwnership(
        uint256 lotteryId,
        uint256 ticketId
    ) external view returns (address owner, uint64 purchaseTime) {
        TicketOwnership memory o = _resolveOwnership(lotteryId, ticketId);
        return (o.owner, o.purchaseTime);
    }

    /* ------------------------------------- Public views ------------------------------------- */

    /// @notice Returns the owner of a ticket (ERC721-style).
    /// @param lotteryId Lottery ID.
    /// @param ticketId  1-based ticket ID.
    /// @return          Owner address.
    function ownerOf(uint256 lotteryId, uint256 ticketId) public view returns (address) {
        return _resolveOwnership(lotteryId, ticketId).owner;
    }

    /* ------------------------------------- Internal mint ------------------------------------- */

    /// @notice Mints a contiguous batch of tickets to `ticketRecipient`.
    /// @dev Writes one `TicketOwnership` at the current index and advances `_lotteryIndex`
    ///      by `quantity`. Caller must enforce `maxTickets` and lifecycle rules.
    /// @param _lotteryId       Target lottery.
    /// @param _quantity        Tickets to mint (must be > 0).
    /// @param _ticketRecipient Owner of the new batch.
    function _mintTix(uint256 _lotteryId, uint256 _quantity, address _ticketRecipient) internal {
        if (_ticketRecipient == address(0)) revert ZeroAddress();
        uint256 startTicketId = _lotteryIndex[_lotteryId];

        unchecked {
            _lotteryIndex[_lotteryId] += _quantity;
        }

        _ownerships[_lotteryId][startTicketId] = TicketOwnership({
            owner: _ticketRecipient,
            purchaseTime: uint64(block.timestamp)
        });

        emit TicketsMinted(_lotteryId, _ticketRecipient, startTicketId, _quantity);

        unchecked {
            balanceOf[_lotteryId][_ticketRecipient] += _quantity;
        }
    }

    /* ------------------------------------- Internal helpers ------------------------------------- */

    /// @dev Returns tickets sold: `_lotteryIndex - 1`, or `0` if index is still `0`.
    function _sold(uint256 _lotteryId) internal view returns (uint256) {
        uint256 idx = _lotteryIndex[_lotteryId];
        return idx > 0 ? idx - 1 : 0;
    }

    /// @dev Resolves ownership by walking backward from `ticketId` to the batch head record.
    /// @param _lotteryId Lottery ID.
    /// @param _ticketId  1-based ticket ID.
    /// @return ownership Owner and purchase time for the batch containing `ticketId`.
    function _resolveOwnership(
        uint256 _lotteryId,
        uint256 _ticketId
    ) internal view returns (TicketOwnership memory ownership) {
        if (_ticketId == 0 || _ticketId >= _lotteryIndex[_lotteryId]) {
            revert TicketDoesNotExist();
        }

        unchecked {
            for (uint256 curr = _ticketId; ; curr--) {
                ownership = _ownerships[_lotteryId][curr];
                if (ownership.owner != address(0)) return ownership;
                if (curr == 1) break;
            }
        }

        revert TicketDoesNotExist();
    }
}
