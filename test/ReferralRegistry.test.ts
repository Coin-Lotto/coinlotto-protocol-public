import { expect } from "chai";
import { ethers } from "hardhat";
import { systemFixture } from "./helpers/protocol";

describe("ReferralRegistry", function () {
  describe("constructor", function () {
    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.registry.DEFAULT_ADMIN_ROLE();
      await expect(f.registry.deploymentTransaction())
        .to.emit(f.registry, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("linkReferrer", function () {
    it("should emit ReferrerLinked for a new external referrer", async function () {
      const f = await systemFixture();
      await f.registry.grantRole(await f.registry.REFERRAL_LINKER_ROLE(), f.deployer.address);
      await expect(f.registry.linkReferrer(f.buyer.address, f.referrer.address))
        .to.emit(f.registry, "ReferrerLinked")
        .withArgs(f.buyer.address, f.referrer.address);
    });

    it("should emit ReferrerLinked to the user on self-referral", async function () {
      const f = await systemFixture();
      await f.registry.grantRole(await f.registry.REFERRAL_LINKER_ROLE(), f.deployer.address);
      await expect(f.registry.linkReferrer(f.stranger.address, ethers.ZeroAddress))
        .to.emit(f.registry, "ReferrerLinked")
        .withArgs(f.stranger.address, f.stranger.address);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.registry.DEFAULT_ADMIN_ROLE();
      await expect(f.registry.grantRole(role, f.stranger.address))
        .to.emit(f.registry, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.registry.DEFAULT_ADMIN_ROLE();
      await f.registry.grantRole(role, f.stranger.address);
      await expect(f.registry.revokeRole(role, f.stranger.address))
        .to.emit(f.registry, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.registry.DEFAULT_ADMIN_ROLE();
      await f.registry.grantRole(role, f.stranger.address);
      await expect(f.registry.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.registry, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
