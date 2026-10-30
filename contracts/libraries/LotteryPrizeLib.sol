// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LotteryPrizeLib
/// @notice Deterministic winner-index selection and tier prize allocation (pure/view library).
/// @dev Used by creator contracts and mission validation. Responsibilities:
///
///      **Winner selection** — For each 1-based winner ordinal `y`, derive a unique 0-based
///      ticket index via an 8-round alternating Feistel permutation over Z_a × Z_b:
///        a = ceil(sqrt(sold)), b = ceil(sold/a), D = a×b ≥ sold.
///        Forward: 1-based ordinal → 0-based ticketIndex (cycle-walking until in [0, sold-1]).
///        Inverse: 1-based ticketId → 0-based ordinal (used by mission validation).
///      A single-ticket lottery always maps to index 0.
///
///      **Prize allocation** — Tier and share-array helpers split `totalPrize` proportionally;
///      winner index `0` absorbs integer rounding remainder where applicable.
///
///      Payout models (MULTIPLIER, WIN_RATE, TIER) combine this library with model-specific
///      winner-count logic in their respective abstract payout contracts.
library LotteryPrizeLib {
    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Thrown when a Feistel input is outside the valid domain.
    ///      Requirements: sold > 0, ordinal ∈ [1, sold], ticketId ∈ [1, sold].
    error InvalidFeistelInput();

    // ─────────────────────────────────────────────────────────────────────────
    // Prize calculation (storage-backed)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tier-proportional prize for one winner using active tiers only.
    /// @dev Canonical implementation. Normalizes weights over the first `_actualWinners` tiers
    ///      (`min(tiers.length, ticketsSold)` at the call site). Winner index `0` absorbs
    ///      rounding dust when `_actualWinners >= 2`.
    ///
    ///      Reverts with an array out-of-bounds panic when `_actualWinners > _tiers.length`,
    ///      matching the storage variant.
    /// @param _totalPrize    Net prize pool at draw time.
    /// @param _tiers         Tier weight array in BP (memory).
    /// @param _actualWinners Active tier/winner count.
    /// @param _winnerIndex   0-based winner ordinal.
    /// @return amount        Prize in token smallest units.
    function prizeForTierProportional(
        uint256 _totalPrize,
        uint16[] memory _tiers,
        uint24 _actualWinners,
        uint24 _winnerIndex
    ) public pure returns (uint256 amount) {
        uint256 n = uint256(_actualWinners);
        if (n == 0) return 0;

        uint256 requested = uint256(_winnerIndex);
        uint256 activeTierSum;
        uint256 winnerTier;

        bool needDustPass = requested == 0 && n >= 2;
        uint256[] memory cached;
        if (needDustPass) cached = new uint256[](n);

        unchecked {
            for (uint256 i; i < n; ++i) {
                uint256 share = uint256(_tiers[i]);
                activeTierSum += share;
                if (i == requested) winnerTier = share;
                if (needDustPass) cached[i] = share;
            }
        }
        if (activeTierSum == 0) return 0;

        amount = Math.mulDiv(_totalPrize, winnerTier, activeTierSum);

        if (needDustPass) {
            uint256 totalAllocated;
            for (uint256 i; i < n; ) {
                totalAllocated += Math.mulDiv(_totalPrize, cached[i], activeTierSum);
                // prettier-ignore
                unchecked { ++i; } // counter only — n ≤ type(uint24).max = 16_777_215
            }
            if (_totalPrize > totalAllocated) {
                amount += _totalPrize - totalAllocated;
            }
        }
    }

    /// @notice Storage-pointer entry point for {prizeForTierProportional}.
    /// @dev Signature retained for existing callers. Copies the first `_actualWinners` weights
    ///      into memory and delegates, so tier math has exactly one implementation.
    ///
    ///      The copy loop reads the same slots the canonical loop would have read, so the SLOAD
    ///      count is unchanged and an out-of-range `_actualWinners` still panics on the same
    ///      index. The added cost is memory expansion plus loop overhead, bounded by
    ///      `MAX_TIER_LENGTH` (100).
    /// @param _totalPrize    Net prize pool at draw time.
    /// @param _tiers         Tier weight array in BP (storage pointer).
    /// @param _actualWinners Active tier/winner count.
    /// @param _winnerIndex   0-based winner ordinal.
    /// @return amount        Prize in token smallest units.
    function prizeForTierProportionalFromStorage(
        uint256 _totalPrize,
        uint16[] storage _tiers,
        uint24 _actualWinners,
        uint24 _winnerIndex
    ) public view returns (uint256 amount) {
        uint256 n = uint256(_actualWinners);
        if (n == 0) return 0;

        uint16[] memory tiers = new uint16[](n);
        for (uint256 i; i < n; ) {
            tiers[i] = _tiers[i];
            // prettier-ignore
            unchecked { ++i; } // counter only — n ≤ type(uint24).max = 16_777_215
        }

        return prizeForTierProportional(_totalPrize, tiers, _actualWinners, _winnerIndex);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Winner selection (pure)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Core 8-round Feistel forward cycle walk: 1-based ordinal → 0-based ticket index.
    /// @dev    Domain: a = ceil(sqrt(sold)), b = ceil(sold/a), D = a×b.
    ///         Starts from `ordinal − 1` (in-domain by guard). Applies one 8-round Feistel
    ///         eval per iteration; repeats until output < sold. Termination is guaranteed
    ///         because the cycle containing the start value always reaches an in-domain element.
    ///         Guards: sold > 0 and ordinal ∈ [1, sold] — enforced at library level.
    /// @param _seed          Draw seed (`LotteryState.seed`).
    /// @param _sold          Tickets sold at draw time.
    /// @param _ticketOrdinal 1-based winner ordinal.
    /// @return idx           Winning ticket index in `[0, _sold - 1]`.
    function winningTicketIndexInternal(
        uint256 _seed,
        uint24 _sold,
        uint24 _ticketOrdinal
    ) internal pure returns (uint24 idx) {
        uint256 n = uint256(_sold);
        if (n == 0 || _ticketOrdinal < 1 || _ticketOrdinal > _sold) revert InvalidFeistelInput();
        if (n == 1) return 0;
        uint256 a = _isqrtCeil(n);
        uint256 b = (n + a - 1) / a; // ceil(n / a)
        uint256 x = uint256(_ticketOrdinal - 1);
        while (true) {
            x = _feistelForward(x, a, b, _seed);
            if (x < n) return uint24(x);
        }
    }

    /// @notice Internal wrapper for winner ticket index derivation.
    /// @dev    Signature `(uint256, uint24, uint24) → uint24` is unchanged from the affine
    ///         implementation. Delegates directly to `winningTicketIndexInternal`.
    /// @param _seed          Draw seed.
    /// @param _sold          Tickets sold.
    /// @param _ticketOrdinal 1-based winner ordinal.
    /// @return idx           0-based winning ticket index.
    function winningTicketIndex(uint256 _seed, uint24 _sold, uint24 _ticketOrdinal) internal pure returns (uint24 idx) {
        return winningTicketIndexInternal(_seed, _sold, _ticketOrdinal);
    }

    /// @notice Inverse Feistel cycle walk: 1-based ticketId → 0-based ordinal.
    /// @dev    `ordinalForTicket(seed, sold, ticketId) < wCount` iff ticketId is a winner.
    ///         Equivalence with the exhaustive forward scan is guaranteed by Feistel bijectivity:
    ///         if forward maps ordinal `wi+1` to `ticketId−1`, then inverse maps `ticketId−1`
    ///         back to `wi`. Result 0-based so caller compares directly to wCount.
    ///         Guards: sold > 0 and ticketId ∈ [1, sold] — enforced at library level.
    /// @param _seed     Draw seed.
    /// @param _sold     Tickets sold at draw time.
    /// @param _ticketId 1-based ticket ID.
    /// @return ordinal0 0-based ordinal. ordinal0 < wCount → winner; ≥ wCount → loser.
    function ordinalForTicketInternal(
        uint256 _seed,
        uint24 _sold,
        uint256 _ticketId
    ) internal pure returns (uint24 ordinal0) {
        uint256 n = uint256(_sold);
        if (n == 0 || _ticketId < 1 || _ticketId > n) revert InvalidFeistelInput();
        if (n == 1) return 0;
        uint256 a = _isqrtCeil(n);
        uint256 b = (n + a - 1) / a;
        uint256 x = _ticketId - 1;
        while (true) {
            x = _feistelInverse(x, a, b, _seed);
            if (x < n) return uint24(x);
        }
    }

    /// @notice Thin internal wrapper for `ordinalForTicketInternal`.
    ///         Exposed externally only via PrizeLibHarness (test-only; not in production ABI).
    function ordinalForTicket(uint256 _seed, uint24 _sold, uint256 _ticketId) internal pure returns (uint24) {
        return ordinalForTicketInternal(_seed, _sold, _ticketId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers — Feistel
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Ceiling integer square root: smallest s such that s*s >= n.
    ///      Uses bit-scan initial estimate + Newton's method, then rounds up.
    // prettier-ignore
    function _isqrtCeil(uint256 n) internal pure returns (uint256 s) {
        if (n == 0) return 0;
        // Bit-length based initial over-estimate
        uint256 x = n;
        s = 1;
        unchecked {
            if (x >= 0x100000000000000000000000000000000) { x >>= 128; s <<= 64; }
            if (x >= 0x10000000000000000) { x >>= 64;  s <<= 32; }
            if (x >= 0x100000000)         { x >>= 32;  s <<= 16; }
            if (x >= 0x10000)             { x >>= 16;  s <<= 8;  }
            if (x >= 0x100)               { x >>= 8;   s <<= 4;  }
            if (x >= 0x10)                { x >>= 4;   s <<= 2;  }
            if (x >= 0x4)                 {             s <<= 1;  }
            // Newton's method — 7 iterations are sufficient for 256-bit n
            s = (s + n / s) >> 1;
            s = (s + n / s) >> 1;
            s = (s + n / s) >> 1;
            s = (s + n / s) >> 1;
            s = (s + n / s) >> 1;
            s = (s + n / s) >> 1;
            s = (s + n / s) >> 1;
            // s is now floor(sqrt(n)); clamp to true floor
            if (s > n / s) s = n / s;
        }
        // Round up to ceiling if not a perfect square
        if (s * s < n) {
            unchecked { ++s; }
        }
    }

    /// @dev Single 8-round forward Feistel eval over Z_a × Z_b.
    ///      A 96-byte keccak buffer [seed | round | half] is allocated once per call and
    ///      reused across all 8 rounds, preventing quadratic memory growth in cycle-walk loops.
    ///
    ///      Even rounds (i=0,2,4,6): f = keccak256(seed, i, R) % a;  L = (L + f) % a
    ///      Odd  rounds (i=1,3,5,7): f = keccak256(seed, i, L) % b;  R = (R + f) % b
    // prettier-ignore
    function _feistelForward(uint256 x, uint256 a, uint256 b, uint256 seed) internal pure returns (uint256) {
        uint256 L = x / b;
        uint256 R = x % b;
        uint256 f;
        uint256 hp;
        // Allocate 96-byte buffer once; advance free pointer by 0x60 only once per call.
        assembly {
            hp := mload(0x40)
            mstore(0x40, add(hp, 0x60))
            mstore(hp, seed)
        }
        for (uint256 i; i < 8; ++i) {
            if (i % 2 == 0) {
                // Even round: update L from R
                assembly {
                    mstore(add(hp, 0x20), i)
                    mstore(add(hp, 0x40), R)
                    f := mod(keccak256(hp, 0x60), a)
                }
                unchecked { L = (L + f) % a; }
            } else {
                // Odd round: update R from L
                assembly {
                    mstore(add(hp, 0x20), i)
                    mstore(add(hp, 0x40), L)
                    f := mod(keccak256(hp, 0x60), b)
                }
                unchecked { R = (R + f) % b; }
            }
        }
        return L * b + R;
    }

    /// @dev Single 8-round inverse Feistel eval over Z_a × Z_b (rounds 7→0, subtract modularly).
    ///      Correctly reverses the forward by undoing each round in reverse order:
    ///      Even rounds (i=6,4,2,0): f = keccak256(seed, i, R) % a;  L = (L + a − f) % a
    ///      Odd  rounds (i=7,5,3,1): f = keccak256(seed, i, L) % b;  R = (R + b − f) % b
    // prettier-ignore
    function _feistelInverse(uint256 x, uint256 a, uint256 b, uint256 seed) internal pure returns (uint256) {
        uint256 L = x / b;
        uint256 R = x % b;
        uint256 f;
        uint256 hp;
        assembly {
            hp := mload(0x40)
            mstore(0x40, add(hp, 0x60))
            mstore(hp, seed)
        }
        // Iterate from round 7 down to 0
        for (uint256 i = 8; i > 0; ) {
            unchecked { --i; }
            if (i % 2 == 0) {
                // Even round: undo L update (hash uses R, which is already the pre-round value)
                assembly {
                    mstore(add(hp, 0x20), i)
                    mstore(add(hp, 0x40), R)
                    f := mod(keccak256(hp, 0x60), a)
                }
                unchecked { L = (L + a - f) % a; }
            } else {
                // Odd round: undo R update (hash uses L, which is unchanged in this inverse step)
                assembly {
                    mstore(add(hp, 0x20), i)
                    mstore(add(hp, 0x40), L)
                    f := mod(keccak256(hp, 0x60), b)
                }
                unchecked { R = (R + b - f) % b; }
            }
        }
        return L * b + R;
    }
}
