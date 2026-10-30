import { expect } from "chai";
import { ethers } from "hardhat";
import { KIND, MODEL, buy, createUser, systemFixture } from "./helpers/protocol";

describe("LotteryHub", function () {
  describe("constructor", function () {
    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.hub.DEFAULT_ADMIN_ROLE();
      await expect(f.hub.deploymentTransaction())
        .to.emit(f.hub, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("setRefRegistry", function () {
    it("should emit RefRegistrySet with the registry", async function () {
      const f = await systemFixture();
      const registry = await f.registry.getAddress();
      await expect(f.hub.setRefRegistry(registry)).to.emit(f.hub, "RefRegistrySet").withArgs(registry);
    });
  });

  describe("setRewarder", function () {
    it("should emit RewarderSet with the rewarder", async function () {
      const f = await systemFixture();
      const rewarder = await f.rewarder.getAddress();
      await expect(f.hub.setRewarder(rewarder)).to.emit(f.hub, "RewarderSet").withArgs(rewarder);
    });
  });

  describe("setWinnerReader", function () {
    it("should emit WinnerReaderSet with the reader", async function () {
      const f = await systemFixture();
      const reader = await f.reader.getAddress();
      await expect(f.hub.setWinnerReader(reader)).to.emit(f.hub, "WinnerReaderSet").withArgs(reader);
    });
  });

  describe("setLegacyHub", function () {
    it("should emit LegacyHubSet with the legacy hub", async function () {
      const f = await systemFixture();
      await expect(f.hub.setLegacyHub(f.deployer.address))
        .to.emit(f.hub, "LegacyHubSet")
        .withArgs(f.deployer.address);
    });
  });

  describe("registerManager", function () {
    it("should emit ManagerRegistered with the type and manager", async function () {
      const f = await systemFixture();
      const managerType = ethers.id("EXTRA_MANAGER");
      await expect(f.hub.registerManager(managerType, f.stranger.address))
        .to.emit(f.hub, "ManagerRegistered")
        .withArgs(managerType, f.stranger.address);
    });

    it("should emit ManagerStatusChanged with ACTIVE", async function () {
      const f = await systemFixture();
      await expect(f.hub.registerManager(ethers.id("EXTRA_MANAGER"), f.stranger.address))
        .to.emit(f.hub, "ManagerStatusChanged")
        .withArgs(f.stranger.address, 1);
    });
  });

  describe("setManagerStatus", function () {
    it("should emit ManagerStatusChanged with the new status", async function () {
      const f = await systemFixture();
      await f.hub.registerManager(ethers.id("EXTRA_MANAGER"), f.stranger.address);
      await expect(f.hub.setManagerStatus(f.stranger.address, 2))
        .to.emit(f.hub, "ManagerStatusChanged")
        .withArgs(f.stranger.address, 2);
    });
  });

  describe("createLottery", function () {
    it("should emit LotteryRegistered with the id, manager, type, nonce, kind, and creator", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
      await expect(created.tx)
        .to.emit(f.hub, "LotteryRegistered")
        .withArgs(
          created.id,
          await f.userManager.getAddress(),
          await f.hub.USER_LOTTERY(),
          created.nonce,
          KIND.USER,
          f.buyer.address,
        );
    });
  });

  describe("buyTickets", function () {
    it("should emit TicketsBought with the buyer, quantity, and effective referrer", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 1, 0, MODEL.WIN_RATE);
      const purchase = await buy(f, f.userManager, f.referrer, created.id, 1, f.buyer.address);
      await expect(purchase)
        .to.emit(f.hub, "TicketsBought")
        .withArgs(created.id, f.referrer.address, 1, f.buyer.address);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.hub.DEFAULT_ADMIN_ROLE();
      await expect(f.hub.grantRole(role, f.stranger.address))
        .to.emit(f.hub, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.hub.DEFAULT_ADMIN_ROLE();
      await f.hub.grantRole(role, f.stranger.address);
      await expect(f.hub.revokeRole(role, f.stranger.address))
        .to.emit(f.hub, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.hub.DEFAULT_ADMIN_ROLE();
      await f.hub.grantRole(role, f.stranger.address);
      await expect(f.hub.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.hub, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
