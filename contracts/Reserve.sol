// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Reserve is TimelockController {
    using SafeERC20 for IERC20;

    /* ─────────────────────────────────────── Constants ──────────────────────── */

    uint256 public constant MIN_DELAY = 3 days;

    /* ─────────────────────────────────────── Types ──────────────────────────── */

    struct TransferRequest {
        address recipient;
        uint256 amount;
        bytes32 salt;
        uint64 createdAt;
        uint64 executableAt;
        bool executed;
        bool cancelled;
        bool exists;
    }

    /* ─────────────────────────────────────── Immutables ─────────────────────── */

    IERC20 public immutable token;

    /* ─────────────────────────────────────── State ──────────────────────────── */

    mapping(bytes32 requestId => TransferRequest request) private _requests;

    /* ─────────────────────────────────────── Events ─────────────────────────── */
    event TransferScheduled(
        bytes32 indexed requestId,
        address indexed recipient,
        uint256 amount,
        uint256 createdAt,
        uint256 executableAt
    );
    event TransferExecuted(bytes32 indexed requestId, address indexed recipient, uint256 amount);
    event TransferCancelled(bytes32 indexed requestId);
    /* ─────────────────────────────────────── Errors ─────────────────────────── */

    error ZeroAddress();
    error ZeroAmount();
    error RequestNotFound();
    error AlreadyExecuted();
    error AlreadyCancelled();
    error NotExecutable();
    error OnlyReserve();
    error DelayImmutable();

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @param token_    ERC-20 token to custody.
    /// @param proposers Accounts granted PROPOSER_ROLE + CANCELLER_ROLE (e.g. the Safe).
    /// @param executors Accounts granted EXECUTOR_ROLE (`[address(0)]` = open execution).
    /// @param admin     Optional admin address; use `address(0)` for self-administration.
    constructor(
        address token_,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(MIN_DELAY, proposers, executors, admin) {
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        _grantRole(PROPOSER_ROLE, address(this));
        _grantRole(EXECUTOR_ROLE, address(this));
    }

    /// @notice Disabled. The execution delay is permanently fixed at {MIN_DELAY}.
    function updateDelay(uint256) external pure override {
        revert DelayImmutable();
    }

    /// @notice Executes a ready timelock operation.
    function execute(
        address target,
        uint256 value,
        bytes calldata payload,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        super.execute(target, value, payload, predecessor, salt);
        if (_msgSender() != address(this)) {
            TransferRequest storage r = _requests[id];
            if (r.exists) emit TransferExecuted(id, r.recipient, r.amount);
        }
    }

    /// @notice Cancels a pending timelock operation.
    function cancel(bytes32 id) public override {
        super.cancel(id);
        if (_msgSender() != address(this)) {
            if (_requests[id].exists) emit TransferCancelled(id);
        }
    }

    /* ─────────────────────────────────────── External ───────────────────────── */

    /// @notice Schedules a timelocked token transfer. Callable only by the Safe.
    /// @param recipient Token recipient; must be non-zero.
    /// @param amount    Token amount; must be greater than zero.
    /// @param salt      Caller-supplied uniqueness salt.
    /// @return requestId The timelock operation id for this request.
    function scheduleTransfer(
        address recipient,
        uint256 amount,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 requestId) {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        bytes memory data = abi.encodeCall(this.release, (recipient, amount));

        // Mirrors TimelockController.hashOperation locally to avoid the
        // `bytes calldata` constraint of the base function.
        requestId = keccak256(abi.encode(address(this), uint256(0), data, bytes32(0), salt));

        uint64 executableAt = uint64(block.timestamp + MIN_DELAY);
        _requests[requestId] = TransferRequest({
            recipient: recipient,
            amount: amount,
            salt: salt,
            createdAt: uint64(block.timestamp),
            executableAt: executableAt,
            executed: false,
            cancelled: false,
            exists: true
        });

        // External self-call converts `data` (memory) to the required `bytes calldata`.
        this.schedule(address(this), 0, data, bytes32(0), salt, MIN_DELAY);

        emit TransferScheduled(requestId, recipient, amount, block.timestamp, executableAt);
    }

    /// @notice Executes a matured transfer request.
    /// @dev    Lifecycle guards use TimelockController operation state — the single source of truth.
    ///         `request.executed` / `request.cancelled` are never written; they are placeholders
    ///         for ABI compatibility only (see `getRequest`).
    function executeTransfer(bytes32 requestId) external {
        if (!hasRole(EXECUTOR_ROLE, address(0))) {
            _checkRole(EXECUTOR_ROLE, _msgSender());
        }

        TransferRequest storage request = _requests[requestId];
        if (!request.exists) revert RequestNotFound();

        // Single read — TimelockController is the authoritative lifecycle source.
        OperationState state = getOperationState(requestId);
        if (state == OperationState.Done) revert AlreadyExecuted();
        if (state == OperationState.Unset) revert AlreadyCancelled();
        if (state == OperationState.Waiting) revert NotExecutable();
        // state == OperationState.Ready — proceed

        bytes memory data = abi.encodeCall(this.release, (request.recipient, request.amount));
        // External self-call: preserves calldata type requirement and permission semantics
        // (`address(this)` holds EXECUTOR_ROLE so the timelock accept this call).
        this.execute(address(this), 0, data, bytes32(0), request.salt);

        emit TransferExecuted(requestId, request.recipient, request.amount);
    }

    /// @notice Cancels a pending request. Callable only by the Safe.
    /// @dev    Lifecycle guards use TimelockController operation state.
    function cancelTransfer(bytes32 requestId) external onlyRole(CANCELLER_ROLE) {
        TransferRequest storage request = _requests[requestId];
        if (!request.exists) revert RequestNotFound();

        // Single read — TimelockController is the authoritative lifecycle source.
        OperationState state = getOperationState(requestId);
        if (state == OperationState.Done) revert AlreadyExecuted();
        if (state == OperationState.Unset) revert AlreadyCancelled(); // already cancelled via any path
        // state == Waiting or Ready — proceed
        // Call super.cancel directly to bypass the generic-API override and avoid double-emission
        // of TransferCancelled (the override emits it for external callers; we emit it below).
        super.cancel(requestId);
        emit TransferCancelled(requestId);
    }

    function release(address recipient, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlyReserve();
        token.safeTransfer(recipient, amount);
    }

    /* ─────────────────────────────────────── Views ──────────────────────────── */
    /// @notice Returns the enforced minimum delay. Always returns {MIN_DELAY}.
    function getMinDelay() public pure override returns (uint256) {
        return MIN_DELAY;
    }

    /// @notice Returns the transfer request metadata with lifecycle fields derived from
    ///         TimelockController — the single source of truth.
    ///
    ///         `executed`, `cancelled`, and `executableAt` in the returned struct are
    ///         computed from Timelock state and are always accurate regardless of which
    ///         API path (wrapper or generic) was used to schedule, execute, or cancel.
    function getRequest(bytes32 requestId) external view returns (TransferRequest memory) {
        TransferRequest memory r = _requests[requestId];
        if (!r.exists) revert RequestNotFound();

        // Derive all lifecycle fields from TimelockController.
        OperationState state = getOperationState(requestId);
        r.executed = (state == OperationState.Done);
        r.cancelled = (state == OperationState.Unset); // exists + Unset → was cancelled via any path

        // executableAt: authoritative timestamp from timelock for active ops;
        // 0 for Done (_DONE_TIMESTAMP == 1) and Unset (timestamp == 0).
        uint256 ts = getTimestamp(requestId);
        r.executableAt = ts > 1 ? uint64(ts) : 0;

        return r;
    }

    function reserveBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function withdrawEth(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount > address(this).balance) revert ZeroAmount();
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}
