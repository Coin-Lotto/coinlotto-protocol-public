import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import {
  DAY,
  KIND,
  MODEL,
  STATUS,
  VRF_PRICE,
  buy,
  createProtocol,
  encodeRegular,
  encodeSuperWinRate,
  systemFixture,
} from "./helpers/protocol";

describe("ProtocolLotteryManager", function () {
  describe("constructor", function () {
    it("should emit HubSet with the hub", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.deploymentTransaction())
        .to.emit(f.protocolManager, "HubSet")
        .withArgs(await f.hub.getAddress());
    });

    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.DEFAULT_ADMIN_ROLE();
      await expect(f.protocolManager.deploymentTransaction())
        .to.emit(f.protocolManager, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("setHub", function () {
    it("should emit HubSet with the new hub", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setHub(f.stranger.address))
        .to.emit(f.protocolManager, "HubSet")
        .withArgs(f.stranger.address);
    });

    it("should emit RoleGranted for the new hub", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.HUB_ROLE();
      await expect(f.protocolManager.setHub(f.stranger.address))
        .to.emit(f.protocolManager, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });

    it("should emit RoleRevoked for the previous hub", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.HUB_ROLE();
      await expect(f.protocolManager.setHub(f.stranger.address))
        .to.emit(f.protocolManager, "RoleRevoked")
        .withArgs(role, await f.hub.getAddress(), f.deployer.address);
    });
  });

  describe("setRndConsumer", function () {
    it("should emit RndCoordinatorSet with the new coordinator", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setRndConsumer(f.stranger.address))
        .to.emit(f.protocolManager, "RndCoordinatorSet")
        .withArgs(f.stranger.address);
    });

    it("should emit RoleGranted for the new coordinator", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.RANDOMNESS_COORDINATOR_ROLE();
      await expect(f.protocolManager.setRndConsumer(f.stranger.address))
        .to.emit(f.protocolManager, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });

    it("should emit RoleRevoked for the previous coordinator when it has no pending request", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.RANDOMNESS_COORDINATOR_ROLE();
      await expect(f.protocolManager.setRndConsumer(f.stranger.address))
        .to.emit(f.protocolManager, "RoleRevoked")
        .withArgs(role, await f.rnd.getAddress(), f.deployer.address);
    });

    it("should emit ConsumerRevocationDeferred when the previous coordinator still has a pending request", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 2);
      await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      await expect(f.protocolManager.setRndConsumer(f.stranger.address))
        .to.emit(f.protocolManager, "ConsumerRevocationDeferred")
        .withArgs(await f.rnd.getAddress(), 1);
    });
  });

  describe("finalizeConsumerRevocation", function () {
    it("should emit RoleRevoked once the deferred coordinator has no pending request", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 2);
      const draw = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await draw.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.protocolManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      const old = await f.rnd.getAddress();
      await f.protocolManager.setRndConsumer(f.stranger.address);
      await f.vrf.fulfill(requestId, [50n]);
      const role = await f.protocolManager.RANDOMNESS_COORDINATOR_ROLE();
      await expect(f.protocolManager.finalizeConsumerRevocation(old))
        .to.emit(f.protocolManager, "RoleRevoked")
        .withArgs(role, old, f.deployer.address);
    });
  });

  describe("setMaximumTiers", function () {
    it("should emit MaximumTiersSet with the new cap", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMaximumTiers(8)).to.emit(f.protocolManager, "MaximumTiersSet").withArgs(8);
    });
  });

  describe("setMinimumWinRateBp", function () {
    it("should emit MinimumWinRateBpSet with the new minimum", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMinimumWinRateBp(20))
        .to.emit(f.protocolManager, "MinimumWinRateBpSet")
        .withArgs(20);
    });
  });

  describe("setMaximumWinRateBp", function () {
    it("should emit MaximumWinRateBpSet with the new maximum", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMaximumWinRateBp(7000))
        .to.emit(f.protocolManager, "MaximumWinRateBpSet")
        .withArgs(7000);
    });
  });

  describe("setMinimumMultiplierBp", function () {
    it("should emit MinimumMultiplierBpSet with the new minimum", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMinimumMultiplierBp(16_000))
        .to.emit(f.protocolManager, "MinimumMultiplierBpSet")
        .withArgs(16_000);
    });
  });

  describe("setMaximumMultiplierBp", function () {
    it("should emit MaximumMultiplierBpSet with the new maximum", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMaximumMultiplierBp(90_000))
        .to.emit(f.protocolManager, "MaximumMultiplierBpSet")
        .withArgs(90_000);
    });
  });

  describe("setProtocolFeeRevenueShareBp", function () {
    it("should emit ProtocolFeeRevenueShareBpSet with the new share", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setProtocolFeeRevenueShareBp(2500))
        .to.emit(f.protocolManager, "ProtocolFeeRevenueShareBpSet")
        .withArgs(2500);
    });
  });

  describe("setTicketLimit", function () {
    it("should emit TicketLimitSet with the new limit", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setTicketLimit(10)).to.emit(f.protocolManager, "TicketLimitSet").withArgs(10);
    });
  });

  describe("setSuperLotteryAllocationLimitBp", function () {
    it("should emit SuperLotteryAllocationLimitBpSet with the new cap", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setSuperLotteryAllocationLimitBp(1500))
        .to.emit(f.protocolManager, "SuperLotteryAllocationLimitBpSet")
        .withArgs(1500);
    });
  });

  describe("setProtocolFeeProtocolLotteriesLimitBp", function () {
    it("should emit ProtocolFeeLimitBpSet with the new cap", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setProtocolFeeProtocolLotteriesLimitBp(2500))
        .to.emit(f.protocolManager, "ProtocolFeeLimitBpSet")
        .withArgs(2500);
    });
  });

  describe("setCltTicketRewardLimit", function () {
    it("should emit CltTicketRewardLimitSet with the new limit", async function () {
      const f = await systemFixture();
      const limit = ethers.parseEther("2");
      await expect(f.protocolManager.setCltTicketRewardLimit(limit))
        .to.emit(f.protocolManager, "CltTicketRewardLimitSet")
        .withArgs(limit);
    });
  });

  describe("setMaxDurationRegular", function () {
    it("should emit MaxDurationRegularSet with the new duration", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMaxDurationRegular(20 * DAY))
        .to.emit(f.protocolManager, "MaxDurationRegularSet")
        .withArgs(20 * DAY);
    });
  });

  describe("setMaxDurationSuper", function () {
    it("should emit MaxDurationSuperSet with the new duration", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setMaxDurationSuper(40 * DAY))
        .to.emit(f.protocolManager, "MaxDurationSuperSet")
        .withArgs(40 * DAY);
    });
  });

  describe("setTreasury", function () {
    it("should emit TreasurySet with the treasury", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setTreasury(f.deployer.address))
        .to.emit(f.protocolManager, "TreasurySet")
        .withArgs(f.deployer.address);
    });
  });

  describe("setCltToken", function () {
    it("should emit CltTokenSet with the token", async function () {
      const f = await systemFixture();
      const clt = await f.coinLotto.getAddress();
      await expect(f.protocolManager.setCltToken(clt)).to.emit(f.protocolManager, "CltTokenSet").withArgs(clt);
    });
  });

  describe("setRewardPool", function () {
    it("should emit RewardPoolSet with the pool", async function () {
      const f = await systemFixture();
      const pool = await f.rewardPool.getAddress();
      await expect(f.protocolManager.setRewardPool(pool)).to.emit(f.protocolManager, "RewardPoolSet").withArgs(pool);
    });
  });

  describe("setCltTreasuryLimitBp", function () {
    it("should emit CltTreasuryLimitBpSet with the new cap", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setCltTreasuryLimitBp(400))
        .to.emit(f.protocolManager, "CltTreasuryLimitBpSet")
        .withArgs(400);
    });
  });

  describe("setCltProtocolFeeBp", function () {
    it("should emit CltProtocolFeeBpSet with the new fee", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setCltProtocolFeeBp(400))
        .to.emit(f.protocolManager, "CltProtocolFeeBpSet")
        .withArgs(400);
    });
  });

  describe("setCltReferrerBonusBp", function () {
    it("should emit CltReferrerBonusBpSet with the new bonus", async function () {
      const f = await systemFixture();
      await expect(f.protocolManager.setCltReferrerBonusBp(400))
        .to.emit(f.protocolManager, "CltReferrerBonusBpSet")
        .withArgs(400);
    });
  });

  describe("setRewarder", function () {
    it("should emit RewarderSet with the rewarder", async function () {
      const f = await systemFixture();
      const rewarder = await f.rewarder.getAddress();
      await expect(f.protocolManager.setRewarder(rewarder))
        .to.emit(f.protocolManager, "RewarderSet")
        .withArgs(rewarder);
    });
  });

  async function linked() {
    const f = await systemFixture();
    const asset = await f.token.getAddress();
    const clt = await f.coinLotto.getAddress();
    const superLot = await createProtocol(
      f,
      KIND.SUPER,
      MODEL.WIN_RATE,
      encodeSuperWinRate(1_000, asset),
      1,
      14 * DAY,
      0,
      clt,
    );
    const cltPerTicket = ethers.parseEther("1");
    const regular = await createProtocol(
      f,
      KIND.REGULAR,
      MODEL.MULTIPLIER,
      encodeRegular(15_000, superLot.id, 1_000, cltPerTicket),
      4,
      7 * DAY,
      500,
    );
    return { f, asset, clt, superLot, regular, cltPerTicket };
  }

  describe("createLotteryFromHub", function () {
    it("should emit LotteryCreated with the id, operator, kind, and model", async function () {
      const { f, regular } = await linked();
      await expect(regular.tx)
        .to.emit(f.protocolManager, "LotteryCreated")
        .withArgs(regular.id, f.operator.address, KIND.REGULAR, MODEL.MULTIPLIER);
    });

    it("should emit LotteryStatusUpdated with ACTIVE", async function () {
      const { f, regular } = await linked();
      await expect(regular.tx)
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(regular.id, STATUS.ACTIVE);
    });

    it("should emit FeederLinked with the regular, super, and allocation", async function () {
      const { f, regular, superLot } = await linked();
      await expect(regular.tx)
        .to.emit(f.protocolManager, "FeederLinked")
        .withArgs(regular.id, superLot.id, 1_000);
    });
  });

  describe("registerTicketPurchase", function () {
    async function purchased() {
      const ctx = await linked();
      const quote = await ctx.f.protocolManager.quoteTicketPurchase(ctx.regular.id, 1, ctx.f.referrer.address);
      const purchase = await buy(ctx.f, ctx.f.protocolManager, ctx.f.buyer, ctx.regular.id, 1, ctx.f.referrer.address);
      return { ...ctx, quote, purchase };
    }

    it("should emit TicketsMinted with the recipient, first ticket, and quantity", async function () {
      const { f, regular, purchase } = await purchased();
      await expect(purchase)
        .to.emit(f.protocolManager, "TicketsMinted")
        .withArgs(regular.id, f.buyer.address, 1, 1);
    });

    it("should emit ReferrerFeeAdded with the referrer, token, share, and buyer", async function () {
      const { f, asset, regular, quote, purchase } = await purchased();
      await expect(purchase)
        .to.emit(f.protocolManager, "ReferrerFeeAdded")
        .withArgs(regular.id, f.referrer.address, asset, quote.refShare, f.buyer.address);
    });

    it("should emit FeederFundsForwarded with the regular, super, and net amount", async function () {
      const { f, regular, superLot, quote, purchase } = await purchased();
      await expect(purchase)
        .to.emit(f.protocolManager, "FeederFundsForwarded")
        .withArgs(regular.id, superLot.id, quote.netFeeder);
    });

    it("should emit CltUserPerTicketRewardAdded with the buyer and per-ticket amount", async function () {
      const { f, regular, cltPerTicket, purchase } = await purchased();
      await expect(purchase)
        .to.emit(f.protocolManager, "CltUserPerTicketRewardAdded")
        .withArgs(regular.id, f.buyer.address, cltPerTicket);
    });

    it("should emit CltReferrerBonusAdded with the referrer, bonus, and buyer", async function () {
      const { f, regular, cltPerTicket, purchase } = await purchased();
      const bonus = (cltPerTicket * 500n) / 10_000n;
      await expect(purchase)
        .to.emit(f.protocolManager, "CltReferrerBonusAdded")
        .withArgs(regular.id, f.referrer.address, bonus, f.buyer.address);
    });

    it("should emit LotteryStatusUpdated with READY_TO_DRAW when the lottery sells out", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.WIN_RATE, encodeRegular(1_000), 1, 7 * DAY);
      const purchase = await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await expect(purchase)
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.READY_TO_DRAW);
    });

    it("should emit FeederFundsSkipped when the linked super no longer accepts funds", async function () {
      const { f, superLot, regular } = await linked();
      await buy(f, f.protocolManager, f.buyer, regular.id, 1, f.referrer.address);
      await buy(f, f.protocolManager, f.buyer, superLot.id, 1);
      await f.hub.connect(f.buyer).requestDraw(superLot.id);
      const purchase = await buy(f, f.protocolManager, f.stranger, regular.id, 1);
      await expect(purchase)
        .to.emit(f.protocolManager, "FeederFundsSkipped")
        .withArgs(regular.id, superLot.id, 100_000n);
    });
  });

  describe("claimReferrerFees", function () {
    it("should emit ReferrerFeeClaimed with the referrer, token, and amount", async function () {
      const f = await systemFixture();
      const asset = await f.token.getAddress();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY, 500);
      const quote = await f.protocolManager.quoteTicketPurchase(created.id, 1, f.referrer.address);
      await buy(f, f.protocolManager, f.buyer, created.id, 1, f.referrer.address);
      await expect(f.protocolManager.connect(f.referrer).claimReferrerFees(f.referrer.address, asset))
        .to.emit(f.protocolManager, "ReferrerFeeClaimed")
        .withArgs(f.referrer.address, asset, quote.refShare);
    });
  });

  describe("requestDraw", function () {
    it("should emit DrawRequested with the VRF request id", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 2);
      const tx = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await tx.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.protocolManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      await expect(tx).to.emit(f.protocolManager, "DrawRequested").withArgs(created.id, requestId);
    });

    it("should emit LotteryStatusUpdated with DRAW_REQUESTED", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 2);
      await expect(f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE }))
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.DRAW_REQUESTED);
    });

    it("should emit DrawCompleted with seed 1 for a single ticket", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.WIN_RATE, encodeRegular(1_000), 1, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await expect(f.hub.connect(f.buyer).requestDraw(created.id))
        .to.emit(f.protocolManager, "DrawCompleted")
        .withArgs(created.id, 1);
    });
  });

  describe("fulfillRandomness", function () {
    async function requested() {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 2);
      const tx = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await tx.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.protocolManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      return { f, created, requestId };
    }

    it("should emit DrawCompleted with the normalized seed", async function () {
      const { f, created, requestId } = await requested();
      await expect(f.vrf.fulfill(requestId, [50n])).to.emit(f.protocolManager, "DrawCompleted").withArgs(created.id, 51);
    });

    it("should emit LotteryStatusUpdated with DRAW_COMPLETED", async function () {
      const { f, created, requestId } = await requested();
      await expect(f.vrf.fulfill(requestId, [50n]))
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.DRAW_COMPLETED);
    });
  });

  describe("claimPrize", function () {
    async function drawn() {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.WIN_RATE, encodeRegular(1_000), 1, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await f.hub.connect(f.buyer).requestDraw(created.id);
      const state = await f.protocolManager.getLotteryStateView(created.id);
      return { f, created, prize: state.prizePool };
    }

    it("should emit PrizeClaimed with the winner index, winner, and amount", async function () {
      const { f, created, prize } = await drawn();
      await expect(f.hub.connect(f.buyer).claimPrize(created.id, 0))
        .to.emit(f.protocolManager, "PrizeClaimed")
        .withArgs(created.id, 0, f.buyer.address, prize);
    });

    it("should emit LotteryStatusUpdated with FULLY_CLAIMED", async function () {
      const { f, created } = await drawn();
      await expect(f.hub.connect(f.buyer).claimPrize(created.id, 0))
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.FULLY_CLAIMED);
    });
  });

  describe("claimPrizeBatch", function () {
    it("should emit PrizeClaimedBatch with the claimer, total, and winner indexes", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.WIN_RATE, encodeRegular(1_000), 1, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await f.hub.connect(f.buyer).requestDraw(created.id);
      const state = await f.protocolManager.getLotteryStateView(created.id);
      await expect(f.hub.connect(f.buyer).claimPrizeBatch(created.id, [0]))
        .to.emit(f.protocolManager, "PrizeClaimedBatch")
        .withArgs(created.id, f.buyer.address, state.prizePool, [0]);
    });

    it("should emit LotteryStatusUpdated with FULLY_CLAIMED", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.WIN_RATE, encodeRegular(1_000), 1, 7 * DAY);
      await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await f.hub.connect(f.buyer).requestDraw(created.id);
      await expect(f.hub.connect(f.buyer).claimPrizeBatch(created.id, [0]))
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.FULLY_CLAIMED);
    });
  });

  describe("recordDonationFor", function () {
    it("should emit Donated with the lottery, donor, and amount", async function () {
      const f = await systemFixture();
      const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
      const amount = 5_000n;
      await f.token.mint(f.buyer.address, amount);
      await f.token.connect(f.buyer).approve(await f.hub.getAddress(), amount);
      await expect(f.hub.connect(f.buyer).donate(created.id, amount))
        .to.emit(f.protocolManager, "Donated")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  async function donated() {
    const f = await systemFixture();
    const created = await createProtocol(f, KIND.REGULAR, MODEL.MULTIPLIER, encodeRegular(15_000), 2, 7 * DAY);
    const amount = 5_000n;
    await f.token.mint(f.buyer.address, amount);
    await f.token.connect(f.buyer).approve(await f.hub.getAddress(), amount);
    await f.hub.connect(f.buyer).donate(created.id, amount);
    const end = (await f.protocolManager.getLottery(created.id)).params.endTime;
    await time.increaseTo(Number(end) + 1);
    return { f, created, amount };
  }

  describe("withdrawDonation", function () {
    it("should emit DonationWithdrawn with the lottery, donor, and amount", async function () {
      const { f, created, amount } = await donated();
      await expect(f.protocolManager.connect(f.buyer).withdrawDonation(created.id))
        .to.emit(f.protocolManager, "DonationWithdrawn")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  describe("withdrawDonationFor", function () {
    it("should emit DonationWithdrawn with the lottery, donor, and amount", async function () {
      const { f, created, amount } = await donated();
      await expect(f.hub.connect(f.buyer).withdrawDonation(created.id))
        .to.emit(f.protocolManager, "DonationWithdrawn")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  describe("forwardExternalFeederFunds", function () {
    async function superLottery() {
      const f = await systemFixture();
      const asset = await f.token.getAddress();
      const clt = await f.coinLotto.getAddress();
      const created = await createProtocol(
        f,
        KIND.SUPER,
        MODEL.WIN_RATE,
        encodeSuperWinRate(1_000, asset),
        10,
        DAY,
        0,
        clt,
      );
      return { f, asset, created };
    }

    it("should emit FeederFundsForwarded when the super still accepts funds", async function () {
      const { f, asset, created } = await superLottery();
      const amount = 2_500n;
      await expect(f.protocolManager.forwardExternalFeederFunds(1, created.id, amount, asset))
        .to.emit(f.protocolManager, "FeederFundsForwarded")
        .withArgs(1, created.id, amount);
    });

    it("should emit FeederFundsSkipped when the super is no longer accepting funds", async function () {
      const { f, asset, created } = await superLottery();
      const end = (await f.protocolManager.getLottery(created.id)).params.endTime;
      await time.increaseTo(Number(end) + 1);
      const amount = 2_500n;
      await expect(f.protocolManager.forwardExternalFeederFunds(1, created.id, amount, asset))
        .to.emit(f.protocolManager, "FeederFundsSkipped")
        .withArgs(1, created.id, amount);
    });
  });

  describe("recoverStrandedFunds", function () {
    async function funded() {
      const f = await systemFixture();
      const asset = await f.token.getAddress();
      const clt = await f.coinLotto.getAddress();
      const created = await createProtocol(
        f,
        KIND.SUPER,
        MODEL.WIN_RATE,
        encodeSuperWinRate(1_000, asset),
        10,
        DAY,
        0,
        clt,
      );
      const amount = 2_500n;
      await f.protocolManager.forwardExternalFeederFunds(1, created.id, amount, asset);
      await f.token.mint(await f.protocolManager.getAddress(), amount);
      const end = (await f.protocolManager.getLottery(created.id)).params.endTime;
      await time.increaseTo(Number(end) + 1);
      return { f, created, amount };
    }

    it("should emit StrandedFundsRecovered with the super, recipient, and amount", async function () {
      const { f, created, amount } = await funded();
      await expect(f.protocolManager.recoverStrandedFunds(created.id, f.deployer.address))
        .to.emit(f.protocolManager, "StrandedFundsRecovered")
        .withArgs(created.id, f.deployer.address, amount);
    });

    it("should emit LotteryStatusUpdated with CANCELLED", async function () {
      const { f, created } = await funded();
      await expect(f.protocolManager.recoverStrandedFunds(created.id, f.deployer.address))
        .to.emit(f.protocolManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.CANCELLED);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.DEFAULT_ADMIN_ROLE();
      await expect(f.protocolManager.grantRole(role, f.stranger.address))
        .to.emit(f.protocolManager, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.DEFAULT_ADMIN_ROLE();
      await f.protocolManager.grantRole(role, f.stranger.address);
      await expect(f.protocolManager.revokeRole(role, f.stranger.address))
        .to.emit(f.protocolManager, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.protocolManager.DEFAULT_ADMIN_ROLE();
      await f.protocolManager.grantRole(role, f.stranger.address);
      await expect(f.protocolManager.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.protocolManager, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
