import { expect } from "chai";
import { ethers } from "hardhat";
import { KIND, MODEL, VRF_PRICE, buy, createProtocol, encodeRegular, systemFixture } from "./helpers/protocol";

describe("CltMissions", function () {
  describe("constructor", function () {
    it("should emit LotterySet with the placeholder lottery", async function () {
      const f = await systemFixture();
      await expect(f.missions.deploymentTransaction())
        .to.emit(f.missions, "LotterySet")
        .withArgs(f.deployer.address);
    });

    it("should emit RoleGranted for the default admin", async function () {
      const f = await systemFixture();
      const role = await f.missions.DEFAULT_ADMIN_ROLE();
      await expect(f.missions.deploymentTransaction())
        .to.emit(f.missions, "RoleGranted")
        .withArgs(role, f.deployer.address, f.deployer.address);
    });
  });

  describe("setLottery", function () {
    it("should emit LotterySet with the new lottery", async function () {
      const f = await systemFixture();
      await expect(f.missions.setLottery(f.deployer.address))
        .to.emit(f.missions, "LotterySet")
        .withArgs(f.deployer.address);
    });
  });

  describe("setHub", function () {
    it("should emit HubSet with the hub", async function () {
      const f = await systemFixture();
      const hub = await f.hub.getAddress();
      await expect(f.missions.setHub(hub)).to.emit(f.missions, "HubSet").withArgs(hub);
    });
  });

  describe("setLegacyAdapter", function () {
    it("should emit LegacyAdapterSet with the adapter", async function () {
      const f = await systemFixture();
      await expect(f.missions.setLegacyAdapter(f.deployer.address))
        .to.emit(f.missions, "LegacyAdapterSet")
        .withArgs(f.deployer.address);
    });
  });

  describe("setRewardPool", function () {
    it("should emit RewardPoolSet with the pool", async function () {
      const f = await systemFixture();
      const pool = await f.rewardPool.getAddress();
      await expect(f.missions.setRewardPool(pool)).to.emit(f.missions, "RewardPoolSet").withArgs(pool);
    });
  });

  describe("setMissionBonusConfig", function () {
    it("should emit MissionBonusConfigSet with the four bonus amounts", async function () {
      const f = await systemFixture();
      const cfg = {
        goldenTicket: ethers.parseEther("2"),
        earlyBird: ethers.parseEther("2"),
        luckInsurance: ethers.parseEther("2"),
        stackTheOdds: ethers.parseEther("2"),
      };
      await expect(f.missions.setMissionBonusConfig(cfg))
        .to.emit(f.missions, "MissionBonusConfigSet")
        .withArgs([cfg.goldenTicket, cfg.earlyBird, cfg.luckInsurance, cfg.stackTheOdds]);
    });
  });

  async function regular(f: Awaited<ReturnType<typeof systemFixture>>, maxTickets: number, model = MODEL.MULTIPLIER, extra?: string) {
    return createProtocol(f, KIND.REGULAR, model, extra ?? encodeRegular(15_000), maxTickets, 7 * 24 * 60 * 60);
  }

  describe("claimGoldenTicketMission", function () {
    it("should emit MissionClaimed with the golden-ticket flag set", async function () {
      const f = await systemFixture();
      const created = await regular(f, 1, MODEL.WIN_RATE, encodeRegular(1_000));
      await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await expect(f.missions.connect(f.buyer).claimGoldenTicketMission(created.id, 1))
        .to.emit(f.missions, "MissionClaimed")
        .withArgs(f.buyer.address, [true, false, false, false]);
    });
  });

  describe("claimEarlyBirdMission", function () {
    it("should emit MissionClaimed with the early-bird flag set", async function () {
      const f = await systemFixture();
      const created = await regular(f, 1, MODEL.WIN_RATE, encodeRegular(1_000));
      await buy(f, f.protocolManager, f.buyer, created.id, 1);
      await expect(f.missions.connect(f.buyer).claimEarlyBirdMission(created.id, 1))
        .to.emit(f.missions, "MissionClaimed")
        .withArgs(f.buyer.address, [false, true, false, false]);
    });
  });

  describe("claimStackTheOddsMission", function () {
    it("should emit MissionClaimed with the stack-the-odds flag set", async function () {
      const f = await systemFixture();
      const created = await regular(f, 10);
      await buy(f, f.protocolManager, f.buyer, created.id, 10);
      await expect(f.missions.connect(f.buyer).claimStackTheOddsMission(created.id, 1))
        .to.emit(f.missions, "MissionClaimed")
        .withArgs(f.buyer.address, [false, false, false, true]);
    });
  });

  describe("claimLuckInsuranceMission", function () {
    it("should emit MissionClaimed with the luck-insurance flag set", async function () {
      const f = await systemFixture();
      const created = await regular(f, 11, MODEL.WIN_RATE, encodeRegular(10));
      await buy(f, f.protocolManager, f.buyer, created.id, 11);
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
      await f.vrf.fulfill(requestId, [100n]);
      const winners = await f.reader.getWinnersInfo(await f.protocolManager.getAddress(), created.id, 0, 5);
      const winnerIds = new Set(winners.map((info) => info.ticketIdx.toString()));
      const losers: bigint[] = [];
      for (let id = 1n; id <= 11n; id++) {
        if (!winnerIds.has(id.toString())) losers.push(id);
      }
      await expect(
        f.missions.connect(f.buyer).claimLuckInsuranceMission([{ lotteryId: created.id, ticketIds: losers }]),
      )
        .to.emit(f.missions, "MissionClaimed")
        .withArgs(f.buyer.address, [false, false, true, false]);
    });
  });

  describe("grantRole", function () {
    it("should emit RoleGranted with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.missions.DEFAULT_ADMIN_ROLE();
      await expect(f.missions.grantRole(role, f.stranger.address))
        .to.emit(f.missions, "RoleGranted")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("revokeRole", function () {
    it("should emit RoleRevoked with the role, account, and sender", async function () {
      const f = await systemFixture();
      const role = await f.missions.DEFAULT_ADMIN_ROLE();
      await f.missions.grantRole(role, f.stranger.address);
      await expect(f.missions.revokeRole(role, f.stranger.address))
        .to.emit(f.missions, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.deployer.address);
    });
  });

  describe("renounceRole", function () {
    it("should emit RoleRevoked with the account as the sender", async function () {
      const f = await systemFixture();
      const role = await f.missions.DEFAULT_ADMIN_ROLE();
      await f.missions.grantRole(role, f.stranger.address);
      await expect(f.missions.connect(f.stranger).renounceRole(role, f.stranger.address))
        .to.emit(f.missions, "RoleRevoked")
        .withArgs(role, f.stranger.address, f.stranger.address);
    });
  });
});
