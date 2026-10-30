import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { DAY, MODEL, STATUS, VRF_PRICE, buy, createUser, systemFixture } from "./helpers/protocol";

describe("UserLotteryManager", function () {
  describe("constructor", function () {
    it("should emit HubSet with the hub", async function () {
      const f = await systemFixture();
      await expect(f.userManager.deploymentTransaction())
        .to.emit(f.userManager, "HubSet")
        .withArgs(await f.hub.getAddress());
    });

    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.userManager.DEFAULT_ADMIN_ROLE();
      await expect(f.userManager.deploymentTransaction())
        .to.emit(f.userManager, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("setHub", function () {
    it("should emit HubSet with the new hub", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setHub(f.stranger.address))
        .to.emit(f.userManager, "HubSet")
        .withArgs(f.stranger.address);
    });

    it("should emit RoleGranted for the new hub", async function () {
      const f = await systemFixture();
      const role = await f.userManager.HUB_ROLE();
      await expect(f.userManager.setHub(f.stranger.address))
        .to.emit(f.userManager, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });

    it("should emit RoleRevoked for the previous hub", async function () {
      const f = await systemFixture();
      const role = await f.userManager.HUB_ROLE();
      await expect(f.userManager.setHub(f.stranger.address))
        .to.emit(f.userManager, "RoleRevoked")
        .withArgs(role, await f.hub.getAddress(), f.deployer.address);
    });
  });

  describe("setRndConsumer", function () {
    it("should emit RndCoordinatorSet with the new coordinator", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setRndConsumer(f.stranger.address))
        .to.emit(f.userManager, "RndCoordinatorSet")
        .withArgs(f.stranger.address);
    });

    it("should emit RoleGranted for the new coordinator", async function () {
      const f = await systemFixture();
      const role = await f.userManager.RANDOMNESS_COORDINATOR_ROLE();
      await expect(f.userManager.setRndConsumer(f.stranger.address))
        .to.emit(f.userManager, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });

    it("should emit RoleRevoked for the previous coordinator when it has no pending request", async function () {
      const f = await systemFixture();
      const role = await f.userManager.RANDOMNESS_COORDINATOR_ROLE();
      await expect(f.userManager.setRndConsumer(f.stranger.address))
        .to.emit(f.userManager, "RoleRevoked")
        .withArgs(role, await f.rnd.getAddress(), f.deployer.address);
    });

    it("should emit ConsumerRevocationDeferred when the previous coordinator still has a pending request", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      await expect(f.userManager.setRndConsumer(f.stranger.address))
        .to.emit(f.userManager, "ConsumerRevocationDeferred")
        .withArgs(await f.rnd.getAddress(), 1);
    });
  });

  describe("finalizeConsumerRevocation", function () {
    it("should emit RoleRevoked once the deferred coordinator has no pending request", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      const draw = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await draw.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.userManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      const old = await f.rnd.getAddress();
      await f.userManager.setRndConsumer(f.stranger.address);
      await f.vrf.fulfill(requestId, [100n]);
      const role = await f.userManager.RANDOMNESS_COORDINATOR_ROLE();
      await expect(f.userManager.finalizeConsumerRevocation(old))
        .to.emit(f.userManager, "RoleRevoked")
        .withArgs(role, old, f.deployer.address);
    });
  });

  describe("setMaximumTiers", function () {
    it("should emit MaximumTiersSet with the new cap", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setMaximumTiers(8)).to.emit(f.userManager, "MaximumTiersSet").withArgs(8);
    });
  });

  describe("setMinimumWinRateBp", function () {
    it("should emit MinimumWinRateBpSet with the new minimum", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setMinimumWinRateBp(20)).to.emit(f.userManager, "MinimumWinRateBpSet").withArgs(20);
    });
  });

  describe("setMaximumWinRateBp", function () {
    it("should emit MaximumWinRateBpSet with the new maximum", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setMaximumWinRateBp(7000)).to.emit(f.userManager, "MaximumWinRateBpSet").withArgs(7000);
    });
  });

  describe("setMinimumMultiplierBp", function () {
    it("should emit MinimumMultiplierBpSet with the new minimum", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setMinimumMultiplierBp(16_000))
        .to.emit(f.userManager, "MinimumMultiplierBpSet")
        .withArgs(16_000);
    });
  });

  describe("setMaximumMultiplierBp", function () {
    it("should emit MaximumMultiplierBpSet with the new maximum", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setMaximumMultiplierBp(90_000))
        .to.emit(f.userManager, "MaximumMultiplierBpSet")
        .withArgs(90_000);
    });
  });

  describe("setProtocolFeeRevenueShareBp", function () {
    it("should emit ProtocolFeeRevenueShareBpSet with the new share", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setProtocolFeeRevenueShareBp(4000))
        .to.emit(f.userManager, "ProtocolFeeRevenueShareBpSet")
        .withArgs(4000);
    });
  });

  describe("setTicketLimit", function () {
    it("should emit TicketLimitSet with the new limit", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setTicketLimit(20)).to.emit(f.userManager, "TicketLimitSet").withArgs(20);
    });
  });

  describe("setCreatorFeeUserLotteriesLimitBp", function () {
    it("should emit CreatorFeeUserLotteriesLimitBpSet with the new cap", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setCreatorFeeUserLotteriesLimitBp(200))
        .to.emit(f.userManager, "CreatorFeeUserLotteriesLimitBpSet")
        .withArgs(200);
    });
  });

  describe("setMaxDurationUsers", function () {
    it("should emit MaxDurationUsersSet with the new duration", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setMaxDurationUsers(10 * DAY))
        .to.emit(f.userManager, "MaxDurationUsersSet")
        .withArgs(10 * DAY);
    });
  });

  describe("setTreasury", function () {
    it("should emit TreasurySet with the treasury", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setTreasury(f.deployer.address))
        .to.emit(f.userManager, "TreasurySet")
        .withArgs(f.deployer.address);
    });
  });

  describe("setProtocolFeeUserLotteriesBp", function () {
    it("should emit ProtocolFeeUserLotteriesBpSet with the new fee", async function () {
      const f = await systemFixture();
      await expect(f.userManager.setProtocolFeeUserLotteriesBp(400))
        .to.emit(f.userManager, "ProtocolFeeUserLotteriesBpSet")
        .withArgs(400);
    });
  });

  describe("createLotteryFromHub", function () {
    it("should emit LotteryCreated with the id, creator, kind, and model", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
      await expect(created.tx)
        .to.emit(f.userManager, "LotteryCreated")
        .withArgs(created.id, f.buyer.address, 1, MODEL.WIN_RATE);
    });

    it("should emit LotteryStatusUpdated with ACTIVE", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
      await expect(created.tx).to.emit(f.userManager, "LotteryStatusUpdated").withArgs(created.id, STATUS.ACTIVE);
    });
  });

  async function paidLottery() {
    const f = await systemFixture();
    const created = await createUser(f, f.buyer, 1, 100, MODEL.WIN_RATE);
    const quote = await f.userManager.quoteTicketPurchase(created.id, 1, f.buyer.address);
    const purchase = await buy(f, f.userManager, f.referrer, created.id, 1, f.buyer.address);
    return { f, created, quote, purchase };
  }

  describe("registerTicketPurchase", function () {
    it("should emit TicketsMinted with the recipient, first ticket, and quantity", async function () {
      const { f, created, purchase } = await paidLottery();
      await expect(purchase).to.emit(f.userManager, "TicketsMinted").withArgs(created.id, f.referrer.address, 1, 1);
    });

    it("should emit CreatorFeeAdded with the creator, token, and fee", async function () {
      const { f, created, quote, purchase } = await paidLottery();
      await expect(purchase)
        .to.emit(f.userManager, "CreatorFeeAdded")
        .withArgs(created.id, f.buyer.address, await f.token.getAddress(), quote.creatorFee);
    });

    it("should emit ReferrerFeeAdded with the referrer, token, share, and buyer", async function () {
      const { f, created, quote, purchase } = await paidLottery();
      await expect(purchase)
        .to.emit(f.userManager, "ReferrerFeeAdded")
        .withArgs(created.id, f.buyer.address, await f.token.getAddress(), quote.refShare, f.referrer.address);
    });

    it("should emit LotteryStatusUpdated with READY_TO_DRAW when the lottery sells out", async function () {
      const { f, created, purchase } = await paidLottery();
      await expect(purchase).to.emit(f.userManager, "LotteryStatusUpdated").withArgs(created.id, STATUS.READY_TO_DRAW);
    });
  });

  describe("claimReferrerFees", function () {
    it("should emit ReferrerFeeClaimed with the referrer, token, and amount", async function () {
      const { f, quote } = await paidLottery();
      await expect(f.userManager.connect(f.buyer).claimReferrerFees(f.buyer.address, await f.token.getAddress()))
        .to.emit(f.userManager, "ReferrerFeeClaimed")
        .withArgs(f.buyer.address, await f.token.getAddress(), quote.refShare);
    });
  });

  describe("requestDraw", function () {
    it("should emit LotteryStatusUpdated with DRAW_REQUESTED for a single ticket", async function () {
      const { f, created } = await paidLottery();
      await expect(f.hub.connect(f.referrer).requestDraw(created.id))
        .to.emit(f.userManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.DRAW_REQUESTED);
    });

    it("should emit DrawCompleted with seed 1 for a single ticket", async function () {
      const { f, created } = await paidLottery();
      await expect(f.hub.connect(f.referrer).requestDraw(created.id))
        .to.emit(f.userManager, "DrawCompleted")
        .withArgs(created.id, 1);
    });

    it("should emit DrawRequested with the VRF request id when more than one ticket was sold", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      const tx = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await tx.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.userManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      await expect(tx).to.emit(f.userManager, "DrawRequested").withArgs(created.id, requestId);
    });

    it("should emit LotteryStatusUpdated with DRAW_REQUESTED before a VRF request", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      await expect(f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE }))
        .to.emit(f.userManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.DRAW_REQUESTED);
    });

    it("should emit DrawRequested again when retrying after the VRF deadline", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      await time.increase(15 * 60 + 1);
      const tx = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await tx.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.userManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      await expect(tx).to.emit(f.userManager, "DrawRequested").withArgs(created.id, requestId);
    });
  });

  describe("fulfillRandomness", function () {
    async function requested() {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      const tx = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const receipt = await tx.wait();
      const requestId = receipt!.logs
        .map((log) => {
          try {
            return f.userManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      return { f, created, requestId };
    }

    it("should emit DrawCompleted with the normalized seed", async function () {
      const { f, created, requestId } = await requested();
      await expect(f.vrf.fulfill(requestId, [100n]))
        .to.emit(f.userManager, "DrawCompleted")
        .withArgs(created.id, 101);
    });

    it("should emit LotteryStatusUpdated with DRAW_COMPLETED", async function () {
      const { f, created, requestId } = await requested();
      await expect(f.vrf.fulfill(requestId, [100n]))
        .to.emit(f.userManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.DRAW_COMPLETED);
    });
  });

  describe("claimPrize", function () {
    async function drawn() {
      const paid = await paidLottery();
      await paid.f.hub.connect(paid.f.referrer).requestDraw(paid.created.id);
      const state = await paid.f.userManager.getLotteryStateView(paid.created.id);
      return { ...paid, prize: state.prizePool };
    }

    it("should emit PrizeClaimed with the winner index, winner, and amount", async function () {
      const { f, created, prize } = await drawn();
      await expect(f.hub.connect(f.referrer).claimPrize(created.id, 0))
        .to.emit(f.userManager, "PrizeClaimed")
        .withArgs(created.id, 0, f.referrer.address, prize);
    });

    it("should emit LotteryStatusUpdated with FULLY_CLAIMED", async function () {
      const { f, created } = await drawn();
      await expect(f.hub.connect(f.referrer).claimPrize(created.id, 0))
        .to.emit(f.userManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.FULLY_CLAIMED);
    });
  });

  describe("claimPrizeBatch", function () {
    it("should emit PrizeClaimedBatch with the claimer, total, and winner indexes", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
      await buy(f, f.userManager, f.buyer, created.id, 1);
      await f.hub.connect(f.buyer).requestDraw(created.id);
      const state = await f.userManager.getLotteryStateView(created.id);
      await expect(f.hub.connect(f.buyer).claimPrizeBatch(created.id, [0]))
        .to.emit(f.userManager, "PrizeClaimedBatch")
        .withArgs(created.id, f.buyer.address, state.prizePool, [0]);
    });

    it("should emit LotteryStatusUpdated with FULLY_CLAIMED", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
      await buy(f, f.userManager, f.buyer, created.id, 1);
      await f.hub.connect(f.buyer).requestDraw(created.id);
      await expect(f.hub.connect(f.buyer).claimPrizeBatch(created.id, [0]))
        .to.emit(f.userManager, "LotteryStatusUpdated")
        .withArgs(created.id, STATUS.FULLY_CLAIMED);
    });
  });

  describe("claimCreatorFee", function () {
    it("should emit CreatorFeeClaimed with the creator, token, and amount", async function () {
      const { f, created, quote } = await paidLottery();
      await f.hub.connect(f.referrer).requestDraw(created.id);
      await expect(f.userManager.connect(f.buyer).claimCreatorFee(created.id))
        .to.emit(f.userManager, "CreatorFeeClaimed")
        .withArgs(created.id, f.buyer.address, await f.token.getAddress(), quote.creatorFee);
    });
  });

  describe("recordDonationFor", function () {
    it("should emit Donated with the lottery, donor, and amount", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      const amount = 5_000n;
      await f.token.mint(f.buyer.address, amount);
      await f.token.connect(f.buyer).approve(await f.hub.getAddress(), amount);
      await expect(f.hub.connect(f.buyer).donate(created.id, amount))
        .to.emit(f.userManager, "Donated")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  async function donated() {
    const f = await systemFixture();
    const created = await createUser(f, f.buyer, 2);
    const amount = 5_000n;
    await f.token.mint(f.buyer.address, amount);
    await f.token.connect(f.buyer).approve(await f.hub.getAddress(), amount);
    await f.hub.connect(f.buyer).donate(created.id, amount);
    const end = (await f.userManager.getLottery(created.id)).params.endTime;
    await time.increaseTo(Number(end) + 1);
    return { f, created, amount };
  }

  describe("withdrawDonation", function () {
    it("should emit DonationWithdrawn with the lottery, donor, and amount", async function () {
      const { f, created, amount } = await donated();
      await expect(f.userManager.connect(f.buyer).withdrawDonation(created.id))
        .to.emit(f.userManager, "DonationWithdrawn")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  describe("withdrawDonationFor", function () {
    it("should emit DonationWithdrawn with the lottery, donor, and amount", async function () {
      const { f, created, amount } = await donated();
      await expect(f.hub.connect(f.buyer).withdrawDonation(created.id))
        .to.emit(f.userManager, "DonationWithdrawn")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.userManager.DEFAULT_ADMIN_ROLE();
      await expect(f.userManager.grantRole(role, f.stranger.address))
        .to.emit(f.userManager, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.userManager.DEFAULT_ADMIN_ROLE();
      await f.userManager.grantRole(role, f.stranger.address);
      await expect(f.userManager.revokeRole(role, f.stranger.address))
        .to.emit(f.userManager, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.userManager.DEFAULT_ADMIN_ROLE();
      await f.userManager.grantRole(role, f.stranger.address);
      await expect(f.userManager.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.userManager, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
