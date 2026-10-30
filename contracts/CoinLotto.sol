// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title CoinLotto
/// @notice Native ERC-20 token (CLT) of the CoinLotto lottery protocol.
/// @dev Inherits from OFT only. `Ownable` is NOT listed in the `is` clause because OFT's
///      chain already includes it (OAppCore → Ownable), but OAppPreCrimeSimulator also
///      inherits Ownable without forwarding its constructor args. Solidity therefore
///      requires the leaf contract to supply `Ownable(initialOwner)` explicitly in the
///      constructor initializer list — exactly the pattern used by LayerZero's own OFTMock.
contract CoinLotto is OFT {
    /* ─────────────────────────────────────── Constants ──────────────────────────── */

    /// @notice Hard cap on total CLT supply (1 billion tokens, 18 decimals).
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Address that can mint CLT.
    address public minter;

    event MinterSet(address indexed minter);

    error OnlyMinter();
    error InvalidAddress();

    modifier onlyMinter() {
        if (minter != msg.sender) revert OnlyMinter();
        _;
    }

    /* ─────────────────────────────────────── Constructor ────────────────────── */

    /// @notice Mints `initialSupply_` CLT to `initialOwner` and wires LayerZero OFT.
    /// @param lzEndpoint_    LayerZero endpoint on this chain.
    /// @param initialOwner   Address receiving ownership and the initial supply.
    ///                       The sum across all chains should equal MAX_SUPPLY.
    constructor(
        address lzEndpoint_,
        address initialOwner,
        address minter_ /// @dev can be 0 address for one-time minter
    ) OFT("CoinLotto", "CLT", lzEndpoint_, initialOwner) Ownable(initialOwner) {
        minter = minter_;
        emit MinterSet(minter_);
    }

    /* ─────────────────────────────────────── External ───────────────────────── */
    function mint(address to) external onlyMinter {
        if (to == address(0)) revert InvalidAddress();
        _mint(to, MAX_SUPPLY);

        minter = address(0);
        emit MinterSet(address(0));
    }

    /// @notice Burns `amount` CLT from `msg.sender`.
    /// @param amount The amount of CLT to burn.
    function burn(uint256 amount) external onlyOwner {
        _burn(msg.sender, amount);
    }
}
