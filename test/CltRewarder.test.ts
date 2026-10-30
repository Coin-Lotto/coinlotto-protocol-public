import { expect } from "chai";
import { ethers } from "hardhat";
import { MODEL, buy, createUser, systemFixture } from "./helpers/protocol";

describe("CltRewarder", function () {
  describe("constructor", function () {
    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.rewarder.DEFAULT_ADMIN_ROLE();
      await expect(f.rewarder.deploymentTransaction())
        .to.emit(f.rewarder, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("setRewardPool", function () {
    it("should emit RewardPoolSet with the pool", async function () {
      const f = await systemFixture();
      const pool = await f.rewardPool.getAddress();
      await expect(f.rewarder.setRewardPool(pool)).to.emit(f.rewarder, "RewardPoolSet").withArgs(pool);
    });
  });

  describe("setLotteryHub", function () {
    it("should emit LotteryHubSet with the hub", async function () {
      const f = await systemFixture();
      const hub = await f.hub.getAddress();
      await expect(f.rewarder.setLotteryHub(hub)).to.emit(f.rewarder, "LotteryHubSet").withArgs(hub);
    });
  });

  describe("setCltReferrerWelcomeBonusAmount", function () {
    it("should emit ReferrerWelcomeBonusSet with the amount", async function () {
      const f = await systemFixture();
      const bonus = ethers.parseEther("3");
      await expect(f.rewarder.setCltReferrerWelcomeBonusAmount(bonus))
        .to.emit(f.rewarder, "ReferrerWelcomeBonusSet")
        .withArgs(bonus);
    });
  });

  describe("addCltReferreWelcomeBonus", function () {
    it("should emit CltReferrerWelcomeBonusAdded with the lottery, referrer, amount, and user", async function () {
      const f = await systemFixture();
      const bonus = ethers.parseEther("3");
      await f.rewarder.setCltReferrerWelcomeBonusAmount(bonus);
      await expect(f.rewarder.addCltReferreWelcomeBonus(f.referrer.address, 1, f.buyer.address))
        .to.emit(f.rewarder, "CltReferrerWelcomeBonusAdded")
        .withArgs(1, f.referrer.address, bonus, f.buyer.address);
    });
  });

  describe("claimReferrerBonus", function () {
    it("should emit CltReferrerBonusClaimed with the referrer and amount", async function () {
      const f = await systemFixture();
      const bonus = ethers.parseEther("3");
      await f.rewarder.setCltReferrerWelcomeBonusAmount(bonus);
      await f.rewarder.addCltReferreWelcomeBonus(f.referrer.address, 1, f.buyer.address);
      await expect(f.rewarder.connect(f.referrer).claimReferrerBonus())
        .to.emit(f.rewarder, "CltReferrerBonusClaimed")
        .withArgs(f.referrer.address, bonus);
    });
  });

  async function drawnUserLottery(f: Awaited<ReturnType<typeof systemFixture>>) {
    const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
    await buy(f, f.userManager, f.buyer, created.id, 1);
    await f.hub.connect(f.buyer).requestDraw(created.id);
    return created;
  }

  describe("addCltPurchaseRewards", function () {
    it("should emit CltPerTicketRewardAdded with the lottery, buyer, and amount", async function () {
      const f = await systemFixture();
      const created = await drawnUserLottery(f);
      const amount = ethers.parseEther("2");
      await expect(f.rewarder.addCltPurchaseRewards(created.id, f.buyer.address, amount, ethers.ZeroAddress, 0))
        .to.emit(f.rewarder, "CltPerTicketRewardAdded")
        .withArgs(created.id, f.buyer.address, amount);
    });

    it("should emit CltLotteryRewardAdded with the lottery, referrer, and amount", async function () {
      const f = await systemFixture();
      const created = await drawnUserLottery(f);
      const amount = ethers.parseEther("1");
      await expect(f.rewarder.addCltPurchaseRewards(created.id, f.buyer.address, 0, f.referrer.address, amount))
        .to.emit(f.rewarder, "CltLotteryRewardAdded")
        .withArgs(created.id, f.referrer.address, amount);
    });
  });

  describe("claimCltLotteryReferrerReward", function () {
    it("should emit CltLotteryRewardClaimed with the lottery, referrer, and amount", async function () {
      const f = await systemFixture();
      const created = await drawnUserLottery(f);
      const amount = ethers.parseEther("1");
      await f.rewarder.addCltPurchaseRewards(created.id, f.buyer.address, 0, f.referrer.address, amount);
      await expect(f.rewarder.connect(f.referrer).claimCltLotteryReferrerReward(created.id))
        .to.emit(f.rewarder, "CltLotteryRewardClaimed")
        .withArgs(created.id, f.referrer.address, amount);
    });
  });

  describe("claimCltLotteryReferrerRewardBatch", function () {
    it("should emit CltLotteryRewardClaimedBatch with the total and lottery ids", async function () {
      const f = await systemFixture();
      const created = await drawnUserLottery(f);
      const amount = ethers.parseEther("1");
      await f.rewarder.addCltPurchaseRewards(created.id, f.buyer.address, 0, f.stranger.address, amount);
      await expect(f.rewarder.connect(f.stranger).claimCltLotteryReferrerRewardBatch([created.id]))
        .to.emit(f.rewarder, "CltLotteryRewardClaimedBatch")
        .withArgs(f.stranger.address, amount, [created.id]);
    });
  });

  describe("claimCltPerTicketReward", function () {
    it("should emit CltPerTicketRewardClaimed with the lottery, user, and amount", async function () {
      const f = await systemFixture();
      const created = await drawnUserLottery(f);
      const amount = ethers.parseEther("2");
      await f.rewarder.addCltPurchaseRewards(created.id, f.buyer.address, amount, ethers.ZeroAddress, 0);
      await expect(f.rewarder.connect(f.buyer).claimCltPerTicketReward(created.id))
        .to.emit(f.rewarder, "CltPerTicketRewardClaimed")
        .withArgs(created.id, f.buyer.address, amount);
    });
  });

  describe("claimCltPerTicketRewardBatch", function () {
    it("should emit CltPerTicketRewardClaimedBatch with the total and completed lottery ids", async function () {
      const f = await systemFixture();
      const created = await drawnUserLottery(f);
      const amount = ethers.parseEther("1");
      await f.rewarder.addCltPurchaseRewards(created.id, f.operator.address, amount, ethers.ZeroAddress, 0);
      await expect(f.rewarder.connect(f.operator).claimCltPerTicketRewardBatch([created.id]))
        .to.emit(f.rewarder, "CltPerTicketRewardClaimedBatch")
        .withArgs(f.operator.address, amount, [created.id]);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.rewarder.DEFAULT_ADMIN_ROLE();
      await expect(f.rewarder.grantRole(role, f.stranger.address))
        .to.emit(f.rewarder, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.rewarder.DEFAULT_ADMIN_ROLE();
      await f.rewarder.grantRole(role, f.stranger.address);
      await expect(f.rewarder.revokeRole(role, f.stranger.address))
        .to.emit(f.rewarder, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.rewarder.DEFAULT_ADMIN_ROLE();
      await f.rewarder.grantRole(role, f.stranger.address);
      await expect(f.rewarder.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.rewarder, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
