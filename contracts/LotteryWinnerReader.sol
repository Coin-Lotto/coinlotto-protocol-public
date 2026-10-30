// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Lottery, LotteryStateView, PayoutModel} from "./structs/MetadataStruct.sol";
import {LotteryCoreLib} from "./libraries/LotteryCoreLib.sol";
import {LotteryPrizeLib} from "./libraries/LotteryPrizeLib.sol";

/// @notice Winner slot summary returned by {LotteryWinnerReader.getWinnersInfo}.
/// @dev Field-for-field identical to `LotteryHub.WinnerInfo`, so the ABI tuple
///      `(uint256,uint256,address,bool)` matches and the Hub can decode it directly.
struct WinnerInfo {
    /// @dev 1-based winning ticket ID.
    uint256 ticketIdx;
    /// @dev Prize amount for this winner ordinal.
    uint256 prizeAmount;
    /// @dev Owner of the winning ticket.
    address winner;
    /// @dev True when this slot's prize has already been claimed.
    bool claimed;
}

/// @dev Manager views the reader composes. Every function is part of the managers' retained
///      public surface; see `BaseLotteryManager` and `TierPayoutModel`.
interface ILotteryManagerWinnerViews {
    function getLottery(uint256 lotteryId) external view returns (Lottery memory);

    function getLotteryStateView(uint256 lotteryId) external view returns (LotteryStateView memory);

    function totalTicketsSold(uint256 lotteryId) external view returns (uint256);

    function getLotteryTiers(uint256 lotteryId) external view returns (uint16[] memory);

    function ownerOf(uint256 lotteryId, uint256 ticketId) external view returns (address);

    function claimedWord(uint256 lotteryId, uint256 wordIndex) external view returns (uint256);
}

/// @title LotteryWinnerReader
/// @notice Off-manager reader that assembles paginated winner lists for any lottery manager.
/// @dev Exists purely to keep the winner-list view out of the managers' runtime bytecode, which
///      is what brings `ProtocolLotteryManager` back under the EIP-170 limit. It is:
///        • **stateless** — no storage, so nothing to migrate and nothing to corrupt;
///        • **permissionless** — view-only, no roles, safe for anyone to call;
///        • **manager-agnostic** — the manager address is a parameter, so one deployment serves
///          every current and future manager, including legacy ones.
///
///      Prize amounts come from `LotteryCoreLib.calcPrizePure` and winning ticket indices from
///      `LotteryPrizeLib.winningTicketIndex` — the same code the managers use on the claim path,
///      so a displayed prize can never disagree with what `claimPrize` pays out.
///
///      Reached through `LotteryHub.getWinnersInfo` / `LotteryHub.getWinnerInfo`; callers
///      normally have no reason to address it directly.
contract LotteryWinnerReader {
    /// @dev Per-request snapshot of everything the payout math needs. Held in memory rather than
    ///      in locals to keep the paging loop off the edge of the EVM stack.
    struct Ctx {
        uint256 seed;
        uint256 prizePool;
        uint256 sold;
        uint256 payoutRateBp;
        uint256 ticketPrice;
        PayoutModel model;
    }

    /// @notice Paginated winner list for `lotteryId` on `manager`, after the draw (`seed != 0`).
    /// @dev Reproduces the semantics of the winner list that previously lived on the managers:
    ///      an empty array before the draw, and an empty array once `from` is at or past the
    ///      winner count after `from + limit` is clamped to it.
    ///
    ///      The lottery record, state view, and tier weights are fetched once up front. The loop
    ///      then costs one `ownerOf` staticcall per slot plus one `claimedWord` staticcall per
    ///      256 slots, since the claim bitmap is read a word at a time and cached.
    /// @param manager   Lottery manager holding `lotteryId`.
    /// @param lotteryId Lottery to query.
    /// @param from      Start winner index (0-based).
    /// @param limit     Maximum entries to return.
    /// @return infos    Slice of winner ticket ID, prize, owner, and claim status.
    function getWinnersInfo(
        address manager,
        uint256 lotteryId,
        uint256 from,
        uint256 limit
    ) external view returns (WinnerInfo[] memory infos) {
        ILotteryManagerWinnerViews m = ILotteryManagerWinnerViews(manager);

        LotteryStateView memory state = m.getLotteryStateView(lotteryId);
        if (state.seed == 0) return new WinnerInfo[](0);

        Lottery memory lot = m.getLottery(lotteryId);

        Ctx memory ctx = Ctx({
            seed: state.seed,
            prizePool: state.prizePool,
            sold: m.totalTicketsSold(lotteryId),
            payoutRateBp: lot.payoutRateBp,
            ticketPrice: lot.params.ticketPrice,
            model: lot.model
        });

        // Tier weights are only consulted for TIER, matching the managers' own behaviour.
        uint16[] memory tiers;
        if (lot.model == PayoutModel.TIER) tiers = m.getLotteryTiers(lotteryId);

        uint256 total = uint256(
            LotteryCoreLib.winnerCountPure(
                uint8(ctx.model),
                ctx.payoutRateBp,
                ctx.ticketPrice,
                ctx.prizePool,
                tiers.length,
                ctx.sold
            )
        );

        uint256 end = from + limit > total ? total : from + limit;
        if (from >= end) return new WinnerInfo[](0);

        infos = new WinnerInfo[](end - from);
        _fill(m, lotteryId, ctx, tiers, from, end, infos);
    }

    /// @dev Populates `infos` for winner slots `[from, end)`.
    /// @dev Split out of {getWinnersInfo} so that the bitmap cache and the per-slot temporaries
    ///      get their own stack frame.
    function _fill(
        ILotteryManagerWinnerViews m,
        uint256 lotteryId,
        Ctx memory ctx,
        uint16[] memory tiers,
        uint256 from,
        uint256 end,
        WinnerInfo[] memory infos
    ) private view {
        // Slots are visited in ascending order, so holding only the most recent bitmap word is
        // enough to read each word at most once.
        uint256 cachedIndex = type(uint256).max;
        uint256 cachedWord;

        for (uint256 i = from; i < end; ) {
            uint24 wi = uint24(i);

            uint256 wordIndex = i >> 8;
            if (wordIndex != cachedIndex) {
                cachedWord = m.claimedWord(lotteryId, wordIndex);
                cachedIndex = wordIndex;
            }

            uint256 ticketId = uint256(LotteryPrizeLib.winningTicketIndex(ctx.seed, uint24(ctx.sold), wi + 1)) + 1;

            infos[i - from] = WinnerInfo({
                ticketIdx: ticketId,
                prizeAmount: LotteryCoreLib.calcPrizePure(
                    uint8(ctx.model),
                    ctx.payoutRateBp,
                    ctx.ticketPrice,
                    ctx.prizePool,
                    tiers,
                    wi,
                    ctx.sold
                ),
                winner: m.ownerOf(lotteryId, ticketId),
                claimed: (cachedWord >> (i & 255)) & 1 != 0
            });

            // prettier-ignore
            unchecked { ++i; }
        }
    }
}
