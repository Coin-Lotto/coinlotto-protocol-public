import { expect } from "chai";
import { ethers } from "hardhat";
import { systemFixture } from "./helpers/protocol";

describe("CltRewardPool", function () {
  describe("constructor", function () {
    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.rewardPool.DEFAULT_ADMIN_ROLE();
      await expect(f.rewardPool.deploymentTransaction())
        .to.emit(f.rewardPool, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("setCltToken", function () {
    it("should emit CltTokenSet with the token address", async function () {
      const f = await systemFixture();
      const clt = await f.coinLotto.getAddress();
      await expect(f.rewardPool.setCltToken(clt)).to.emit(f.rewardPool, "CltTokenSet").withArgs(clt);
    });
  });

  describe("withdrawClt", function () {
    it("should emit CltWithdrawn with the recipient and amount", async function () {
      const f = await systemFixture();
      const amount = ethers.parseEther("4");
      await expect(f.rewardPool.withdrawClt(f.buyer.address, amount))
        .to.emit(f.rewardPool, "CltWithdrawn")
        .withArgs(f.buyer.address, amount);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.rewardPool.DEFAULT_ADMIN_ROLE();
      await expect(f.rewardPool.grantRole(role, f.stranger.address))
        .to.emit(f.rewardPool, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.rewardPool.DEFAULT_ADMIN_ROLE();
      await f.rewardPool.grantRole(role, f.stranger.address);
      await expect(f.rewardPool.revokeRole(role, f.stranger.address))
        .to.emit(f.rewardPool, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.rewardPool.DEFAULT_ADMIN_ROLE();
      await f.rewardPool.grantRole(role, f.stranger.address);
      await expect(f.rewardPool.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.rewardPool, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
