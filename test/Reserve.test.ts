import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

/**
 * updateDelay reverts with DelayImmutable, so MinDelayChange is emitted only
 * from the constructor. RoleAdminChanged is inherited from AccessControl and
 * is never emitted: nothing calls _setRoleAdmin.
 */
describe("Reserve", function () {
  const MIN_DELAY = 3 * 24 * 60 * 60;

  async function reserveFixture() {
    const [admin, proposer, recipient] = await ethers.getSigners();
    const token = await ethers.deployContract("TestERC20", ["Reserve Token", "RSV", 6]);
    const reserve = await ethers.deployContract("Reserve", [
      await token.getAddress(),
      [proposer.address],
      [proposer.address],
      admin.address,
    ]);
    return { admin, proposer, recipient, token, reserve };
  }

  function operationId(reserve: string, data: string, salt: string) {
    return ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "bytes", "bytes32", "bytes32"],
        [reserve, 0, data, ethers.ZeroHash, salt],
      ),
    );
  }

  describe("constructor", function () {
    it("should emit MinDelayChange from zero to the fixed delay", async function () {
      const { reserve } = await reserveFixture();
      await expect(reserve.deploymentTransaction()).to.emit(reserve, "MinDelayChange").withArgs(0, MIN_DELAY);
    });

    it("should emit RoleGranted for a constructor proposer", async function () {
      const { admin, proposer, reserve } = await reserveFixture();
      await expect(reserve.deploymentTransaction())
        .to.emit(reserve, "RoleGranted")
        .withArgs(await reserve.PROPOSER_ROLE(), proposer.address, admin.address);
    });
  });

  describe("schedule", function () {
    async function scheduled() {
      const ctx = await reserveFixture();
      const salt = ethers.id("schedule");
      const data = "0x";
      const id = await ctx.reserve.hashOperation(ctx.recipient.address, 0, data, ethers.ZeroHash, salt);
      const tx = await ctx.reserve
        .connect(ctx.proposer)
        .schedule(ctx.recipient.address, 0, data, ethers.ZeroHash, salt, MIN_DELAY);
      return { ...ctx, salt, data, id, tx };
    }

    it("should emit CallScheduled with the operation id, target, and delay", async function () {
      const { reserve, recipient, data, id, tx } = await scheduled();
      await expect(tx)
        .to.emit(reserve, "CallScheduled")
        .withArgs(id, 0, recipient.address, 0, data, ethers.ZeroHash, MIN_DELAY);
    });

    it("should emit CallSalt when the salt is non-zero", async function () {
      const { reserve, salt, id, tx } = await scheduled();
      await expect(tx).to.emit(reserve, "CallSalt").withArgs(id, salt);
    });
  });

  describe("scheduleBatch", function () {
    async function scheduled() {
      const ctx = await reserveFixture();
      const salt = ethers.id("batch");
      const targets = [ctx.recipient.address];
      const values = [0];
      const payloads = ["0x"];
      const id = await ctx.reserve.hashOperationBatch(targets, values, payloads, ethers.ZeroHash, salt);
      const tx = await ctx.reserve
        .connect(ctx.proposer)
        .scheduleBatch(targets, values, payloads, ethers.ZeroHash, salt, MIN_DELAY);
      return { ...ctx, salt, targets, values, payloads, id, tx };
    }

    it("should emit CallScheduled for the batched call", async function () {
      const { reserve, targets, payloads, id, tx } = await scheduled();
      await expect(tx)
        .to.emit(reserve, "CallScheduled")
        .withArgs(id, 0, targets[0], 0, payloads[0], ethers.ZeroHash, MIN_DELAY);
    });

    it("should emit CallSalt when the salt is non-zero", async function () {
      const { reserve, salt, id, tx } = await scheduled();
      await expect(tx).to.emit(reserve, "CallSalt").withArgs(id, salt);
    });
  });

  describe("scheduleTransfer", function () {
    async function scheduled() {
      const ctx = await reserveFixture();
      const amount = 1_000n;
      const salt = ethers.id("transfer");
      const data = ctx.reserve.interface.encodeFunctionData("release", [ctx.recipient.address, amount]);
      const id = operationId(await ctx.reserve.getAddress(), data, salt);
      const next = (await time.latest()) + 1;
      await time.setNextBlockTimestamp(next);
      const tx = await ctx.reserve.connect(ctx.proposer).scheduleTransfer(ctx.recipient.address, amount, salt);
      return { ...ctx, amount, salt, data, id, next, tx };
    }

    it("should emit TransferScheduled with the request, recipient, amount, and window", async function () {
      const { reserve, recipient, amount, id, next, tx } = await scheduled();
      await expect(tx)
        .to.emit(reserve, "TransferScheduled")
        .withArgs(id, recipient.address, amount, next, next + MIN_DELAY);
    });

    it("should emit CallScheduled for the release call", async function () {
      const { reserve, data, id, tx } = await scheduled();
      await expect(tx)
        .to.emit(reserve, "CallScheduled")
        .withArgs(id, 0, await reserve.getAddress(), 0, data, ethers.ZeroHash, MIN_DELAY);
    });

    it("should emit CallSalt for the transfer salt", async function () {
      const { reserve, salt, id, tx } = await scheduled();
      await expect(tx).to.emit(reserve, "CallSalt").withArgs(id, salt);
    });
  });

  describe("execute", function () {
    it("should emit CallExecuted for a ready operation", async function () {
      const { reserve, proposer, recipient } = await reserveFixture();
      const salt = ethers.id("execute-plain");
      const data = "0x";
      const id = await reserve.hashOperation(recipient.address, 0, data, ethers.ZeroHash, salt);
      await reserve.connect(proposer).schedule(recipient.address, 0, data, ethers.ZeroHash, salt, MIN_DELAY);
      await time.increase(MIN_DELAY + 1);
      await expect(reserve.connect(proposer).execute(recipient.address, 0, data, ethers.ZeroHash, salt))
        .to.emit(reserve, "CallExecuted")
        .withArgs(id, 0, recipient.address, 0, data);
    });

    it("should emit TransferExecuted when the operation is a scheduled transfer", async function () {
      const { reserve, proposer, recipient, token } = await reserveFixture();
      const amount = 1_000n;
      const salt = ethers.id("execute-transfer");
      await token.mint(await reserve.getAddress(), amount);
      const data = reserve.interface.encodeFunctionData("release", [recipient.address, amount]);
      const id = operationId(await reserve.getAddress(), data, salt);
      await reserve.connect(proposer).scheduleTransfer(recipient.address, amount, salt);
      await time.increase(MIN_DELAY + 1);
      await expect(reserve.connect(proposer).execute(await reserve.getAddress(), 0, data, ethers.ZeroHash, salt))
        .to.emit(reserve, "TransferExecuted")
        .withArgs(id, recipient.address, amount);
    });
  });

  describe("executeBatch", function () {
    it("should emit CallExecuted for each batched call", async function () {
      const { reserve, proposer, recipient } = await reserveFixture();
      const salt = ethers.id("execute-batch");
      const targets = [recipient.address];
      const values = [0];
      const payloads = ["0x"];
      const id = await reserve.hashOperationBatch(targets, values, payloads, ethers.ZeroHash, salt);
      await reserve.connect(proposer).scheduleBatch(targets, values, payloads, ethers.ZeroHash, salt, MIN_DELAY);
      await time.increase(MIN_DELAY + 1);
      await expect(reserve.connect(proposer).executeBatch(targets, values, payloads, ethers.ZeroHash, salt))
        .to.emit(reserve, "CallExecuted")
        .withArgs(id, 0, targets[0], 0, payloads[0]);
    });
  });

  describe("executeTransfer", function () {
    async function ready() {
      const ctx = await reserveFixture();
      const amount = 1_000n;
      const salt = ethers.id("execute-transfer-fn");
      await ctx.token.mint(await ctx.reserve.getAddress(), amount);
      const data = ctx.reserve.interface.encodeFunctionData("release", [ctx.recipient.address, amount]);
      const id = operationId(await ctx.reserve.getAddress(), data, salt);
      await ctx.reserve.connect(ctx.proposer).scheduleTransfer(ctx.recipient.address, amount, salt);
      await time.increase(MIN_DELAY + 1);
      return { ...ctx, amount, data, id };
    }

    it("should emit TransferExecuted with the request, recipient, and amount", async function () {
      const { reserve, proposer, recipient, amount, id } = await ready();
      await expect(reserve.connect(proposer).executeTransfer(id))
        .to.emit(reserve, "TransferExecuted")
        .withArgs(id, recipient.address, amount);
    });

    it("should emit CallExecuted for the release call", async function () {
      const { reserve, proposer, data, id } = await ready();
      await expect(reserve.connect(proposer).executeTransfer(id))
        .to.emit(reserve, "CallExecuted")
        .withArgs(id, 0, await reserve.getAddress(), 0, data);
    });
  });

  describe("cancel", function () {
    it("should emit Cancelled for a pending operation", async function () {
      const { reserve, proposer, recipient } = await reserveFixture();
      const salt = ethers.id("cancel-plain");
      const data = "0x";
      const id = await reserve.hashOperation(recipient.address, 0, data, ethers.ZeroHash, salt);
      await reserve.connect(proposer).schedule(recipient.address, 0, data, ethers.ZeroHash, salt, MIN_DELAY);
      await expect(reserve.connect(proposer).cancel(id)).to.emit(reserve, "Cancelled").withArgs(id);
    });

    it("should emit TransferCancelled when the operation is a scheduled transfer", async function () {
      const { reserve, proposer, recipient } = await reserveFixture();
      const amount = 1_000n;
      const salt = ethers.id("cancel-transfer-generic");
      const data = reserve.interface.encodeFunctionData("release", [recipient.address, amount]);
      const id = operationId(await reserve.getAddress(), data, salt);
      await reserve.connect(proposer).scheduleTransfer(recipient.address, amount, salt);
      await expect(reserve.connect(proposer).cancel(id)).to.emit(reserve, "TransferCancelled").withArgs(id);
    });
  });

  describe("cancelTransfer", function () {
    async function pending() {
      const ctx = await reserveFixture();
      const amount = 1_000n;
      const salt = ethers.id("cancel-transfer");
      const data = ctx.reserve.interface.encodeFunctionData("release", [ctx.recipient.address, amount]);
      const id = operationId(await ctx.reserve.getAddress(), data, salt);
      await ctx.reserve.connect(ctx.proposer).scheduleTransfer(ctx.recipient.address, amount, salt);
      return { ...ctx, id };
    }

    it("should emit TransferCancelled with the request id", async function () {
      const { reserve, proposer, id } = await pending();
      await expect(reserve.connect(proposer).cancelTransfer(id)).to.emit(reserve, "TransferCancelled").withArgs(id);
    });

    it("should emit Cancelled with the request id", async function () {
      const { reserve, proposer, id } = await pending();
      await expect(reserve.connect(proposer).cancelTransfer(id)).to.emit(reserve, "Cancelled").withArgs(id);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const { admin, reserve } = await reserveFixture();
      const role = await reserve.DEFAULT_ADMIN_ROLE();
      const [, , , stranger] = await ethers.getSigners();
      await expect(reserve.connect(admin).grantRole(role, stranger.address))
        .to.emit(reserve, "RoleGranted")
        .withArgs(role, stranger.address, admin.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const { admin, reserve } = await reserveFixture();
      const role = await reserve.DEFAULT_ADMIN_ROLE();
      const [, , , stranger] = await ethers.getSigners();
      await reserve.connect(admin).grantRole(role, stranger.address);
      await expect(reserve.connect(admin).revokeRole(role, stranger.address))
        .to.emit(reserve, "RoleRevoked")
        .withArgs(role, stranger.address, admin.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const { admin, reserve } = await reserveFixture();
      const role = await reserve.DEFAULT_ADMIN_ROLE();
      const [, , , stranger] = await ethers.getSigners();
      await reserve.connect(admin).grantRole(role, stranger.address);
      await expect(reserve.connect(stranger).renounceRole(role, stranger.address))
        .to.emit(reserve, "RoleRevoked")
        .withArgs(role, stranger.address, stranger.address);
    });
  });
});
