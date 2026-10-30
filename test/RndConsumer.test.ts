import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { VRF_PRICE, buy, createUser, impersonate, systemFixture } from "./helpers/protocol";

/**
 * EtherRefundFailed is declared on RndConsumer for ABI stability. No production
 * function emits it. Excess native value is credited with RefundCredited.
 */
describe("RndConsumer", function () {
  describe("constructor", function () {
    it("should emit OwnershipTransferred from the zero address to the owner", async function () {
      const f = await systemFixture();
      await expect(f.rnd.deploymentTransaction())
        .to.emit(f.rnd, "OwnershipTransferred")
        .withArgs(ethers.ZeroAddress, f.deployer.address);
    });
  });

  describe("setConsumer", function () {
    it("should emit ConsumerSet with the consumer and the allowed flag", async function () {
      const f = await systemFixture();
      await expect(f.rnd.setConsumer(f.stranger.address, true))
        .to.emit(f.rnd, "ConsumerSet")
        .withArgs(f.stranger.address, true);
    });
  });

  describe("setVrfConfig", function () {
    it("should emit VrfConfigSet with the gas limit and confirmations", async function () {
      const f = await systemFixture();
      await expect(f.rnd.setVrfConfig(400_000, 5)).to.emit(f.rnd, "VrfConfigSet").withArgs(400_000, 5);
    });
  });

  describe("requestRandomness", function () {
    it("should emit RefundCredited for the native amount above the VRF fee", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      const tx = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE + 1n });
      await expect(tx).to.emit(f.rnd, "RefundCredited").withArgs(f.buyer.address, 1);
    });
  });

  describe("creditRefund", function () {
    it("should emit RefundCredited for the value sent by a registered consumer", async function () {
      const f = await systemFixture();
      const manager = await impersonate(await f.userManager.getAddress());
      await expect(f.rnd.connect(manager).creditRefund(f.buyer.address, { value: 7n }))
        .to.emit(f.rnd, "RefundCredited")
        .withArgs(f.buyer.address, 7);
    });
  });

  describe("withdrawRefund", function () {
    it("should emit RefundWithdrawn with the caller, recipient, and amount", async function () {
      const f = await systemFixture();
      const manager = await impersonate(await f.userManager.getAddress());
      await f.rnd.connect(manager).creditRefund(f.buyer.address, { value: 7n });
      await expect(f.rnd.connect(f.buyer).withdrawRefund(f.referrer.address))
        .to.emit(f.rnd, "RefundWithdrawn")
        .withArgs(f.buyer.address, f.referrer.address, 7);
    });
  });

  describe("forceCloseRequests", function () {
    it("should emit RequestForceClosed with the request, consumer, and lottery", async function () {
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
      await time.increase(24 * 60 * 60 + 1);
      await expect(f.rnd.forceCloseRequests([requestId]))
        .to.emit(f.rnd, "RequestForceClosed")
        .withArgs(requestId, await f.userManager.getAddress(), created.id);
    });
  });

  describe("fulfillRandomWords", function () {
    it("should emit StaleVrfResponseIgnored when the draw generation has moved on", async function () {
      const f = await systemFixture();
      const created = await createUser(f, f.buyer, 2);
      await buy(f, f.userManager, f.buyer, created.id, 2);
      const first = await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      const firstReceipt = await first.wait();
      const requestId = firstReceipt!.logs
        .map((log) => {
          try {
            return f.userManager.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((log) => log?.name === "DrawRequested")!.args.requestId as bigint;
      await time.increase(15 * 60 + 1);
      await f.hub.connect(f.buyer).requestDraw(created.id, { value: VRF_PRICE });
      await expect(f.vrf.fulfill(requestId, [100n]))
        .to.emit(f.rnd, "StaleVrfResponseIgnored")
        .withArgs(requestId, await f.userManager.getAddress(), created.id, 1, 2);
    });
  });

  describe("transferOwnership", function () {
    it("should emit OwnershipTransferred to the new owner", async function () {
      const f = await systemFixture();
      await expect(f.rnd.transferOwnership(f.stranger.address))
        .to.emit(f.rnd, "OwnershipTransferred")
        .withArgs(f.deployer.address, f.stranger.address);
    });
  });

  describe("renounceOwnership", function () {
    it("should emit OwnershipTransferred to the zero address", async function () {
      const f = await systemFixture();
      await expect(f.rnd.renounceOwnership())
        .to.emit(f.rnd, "OwnershipTransferred")
        .withArgs(f.deployer.address, ethers.ZeroAddress);
    });
  });
});
