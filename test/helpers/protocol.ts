import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const PRIZE = "contracts/libraries/LotteryPrizeLib.sol:LotteryPrizeLib";
const CORE = "contracts/libraries/LotteryCoreLib.sol:LotteryCoreLib";
const PROTO = "contracts/libraries/ProtocolManagerLib.sol:ProtocolManagerLib";

export const KIND = { USER: 1, REGULAR: 2, SUPER: 3 } as const;
export const MODEL = { MULTIPLIER: 1, TIER: 2, WIN_RATE: 3 } as const;
export const STATUS = {
  ACTIVE: 2,
  DRAW_REQUESTED: 3,
  DRAW_COMPLETED: 4,
  FULLY_CLAIMED: 5,
  READY_TO_DRAW: 6,
  CANCELLED: 7,
} as const;

export const VRF_PRICE = ethers.parseEther("0.001");
export const TICKET_PRICE = 1_000_000n;
export const DAY = 24 * 60 * 60;

export async function deploySystem() {
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const buyer = signers[1];
  const referrer = signers[2];
  const operator = signers[3];
  const stranger = signers[4];

  const endpoint = await ethers.deployContract("LzEndpointMock");
  const vrf = await ethers.deployContract("VrfWrapperMock", [VRF_PRICE]);
  const token = await ethers.deployContract("TestERC20", ["Test USD", "TUSD", 6]);

  const coinLotto = await ethers.deployContract("CoinLotto", [
    await endpoint.getAddress(),
    deployer.address,
    deployer.address,
  ]);
  await coinLotto.mint(deployer.address);

  const rewardPool = await ethers.deployContract("CltRewardPool", [deployer.address]);
  await rewardPool.setCltToken(await coinLotto.getAddress());
  await coinLotto.transfer(await rewardPool.getAddress(), ethers.parseEther("1000000"));

  const prizeLib = await ethers.deployContract("LotteryPrizeLib");
  const coreLib = await ethers.getContractFactory("LotteryCoreLib", {
    libraries: { [PRIZE]: await prizeLib.getAddress() },
  });
  const lotteryCoreLib = await coreLib.deploy();
  const protocolManagerLib = await ethers.deployContract("ProtocolManagerLib");

  const coreLink = { libraries: { [CORE]: await lotteryCoreLib.getAddress() } };
  const protoLink = {
    libraries: {
      [CORE]: await lotteryCoreLib.getAddress(),
      [PROTO]: await protocolManagerLib.getAddress(),
    },
  };

  const rnd = await ethers.deployContract("RndConsumer", [deployer.address, await vrf.getAddress(), 500_000, 3]);
  const missions = await ethers.deployContract("CltMissions", [deployer.address, deployer.address]);
  const rewarder = await ethers.deployContract("CltRewarder", [deployer.address]);
  const hub = await ethers.deployContract("LotteryHub", [deployer.address, 1]);
  const hubAddrEarly = await hub.getAddress();
  const reader = await ethers.getContractFactory("LotteryWinnerReader", coreLink).then((f) => f.deploy());
  const registry = await ethers.deployContract("ReferralRegistry", [deployer.address, ethers.ZeroAddress]);
  const userManager = await ethers
    .getContractFactory("UserLotteryManager", coreLink)
    .then((f) => f.deploy(deployer.address, hubAddrEarly));
  const protocolManager = await ethers
    .getContractFactory("ProtocolLotteryManager", protoLink)
    .then((f) => f.deploy(deployer.address, hubAddrEarly));

  const hubAddr = await hub.getAddress();
  const rndAddr = await rnd.getAddress();
  const userAddr = await userManager.getAddress();
  const protoAddr = await protocolManager.getAddress();
  const rewarderAddr = await rewarder.getAddress();

  await userManager.setRndConsumer(rndAddr);
  await protocolManager.setRndConsumer(rndAddr);
  await rnd.setConsumer(userAddr, true);
  await rnd.setConsumer(protoAddr, true);

  await rewardPool.grantRole(await rewardPool.WITHDRAW_ROLE(), await missions.getAddress());
  await rewardPool.grantRole(await rewardPool.WITHDRAW_ROLE(), rewarderAddr);
  await rewardPool.grantRole(await rewardPool.WITHDRAW_ROLE(), deployer.address);

  await rewarder.grantRole(await rewarder.REWARD_OPERATOR_ROLE(), hubAddr);
  await rewarder.grantRole(await rewarder.REWARD_OPERATOR_ROLE(), protoAddr);
  await rewarder.grantRole(await rewarder.REWARD_OPERATOR_ROLE(), deployer.address);
  await rewarder.setLotteryHub(hubAddr);
  await rewarder.setRewardPool(await rewardPool.getAddress());
  await rewarder.setCltReferrerWelcomeBonusAmount(ethers.parseEther("10"));

  await registry.grantRole(await registry.REFERRAL_LINKER_ROLE(), hubAddr);
  await registry.grantRole(await registry.REFERRAL_LINKER_ROLE(), userAddr);
  await registry.grantRole(await registry.REFERRAL_LINKER_ROLE(), protoAddr);

  await protocolManager.grantRole(await protocolManager.REGULAR_OPERATOR_ROLE(), operator.address);
  await protocolManager.grantRole(await protocolManager.EXTERNAL_FEEDER_ROLE(), deployer.address);

  await hub.registerManager(await hub.USER_LOTTERY(), userAddr);
  await hub.registerManager(await hub.REGULAR_LOTTERY(), protoAddr);
  await hub.setRefRegistry(await registry.getAddress());
  await hub.setRewarder(rewarderAddr);
  await hub.setWinnerReader(await reader.getAddress());

  await missions.setRewardPool(await rewardPool.getAddress());
  await missions.setHub(hubAddr);
  await missions.setMissionBonusConfig({
    goldenTicket: ethers.parseEther("1"),
    earlyBird: ethers.parseEther("1"),
    luckInsurance: ethers.parseEther("1"),
    stackTheOdds: ethers.parseEther("1"),
  });

  await configureManager(userManager, deployer);
  await userManager.setProtocolFeeUserLotteriesBp(500);
  await userManager.setCreatorFeeUserLotteriesLimitBp(3000);
  await userManager.setMaxDurationUsers(30 * DAY);

  await configureManager(protocolManager, deployer);
  await protocolManager.setProtocolFeeProtocolLotteriesLimitBp(3000);
  await protocolManager.setRewarder(rewarderAddr);
  await protocolManager.setCltToken(await coinLotto.getAddress());
  await protocolManager.setRewardPool(await rewardPool.getAddress());
  await protocolManager.setCltTreasuryLimitBp(500);
  await protocolManager.setCltProtocolFeeBp(500);
  await protocolManager.setCltReferrerBonusBp(500);
  await protocolManager.setSuperLotteryAllocationLimitBp(2000);
  await protocolManager.setCltTicketRewardLimit(ethers.parseEther("10"));
  await protocolManager.setMaxDurationRegular(90 * DAY);
  await protocolManager.setMaxDurationSuper(180 * DAY);

  return {
    deployer,
    buyer,
    referrer,
    operator,
    stranger,
    endpoint,
    vrf,
    token,
    coinLotto,
    rewardPool,
    rnd,
    missions,
    rewarder,
    hub,
    reader,
    registry,
    userManager,
    protocolManager,
  };
}

async function configureManager(
  manager: {
    setMaximumMultiplierBp: (v: number) => Promise<unknown>;
    setMinimumMultiplierBp: (v: number) => Promise<unknown>;
    setMaximumWinRateBp: (v: number) => Promise<unknown>;
    setMinimumWinRateBp: (v: number) => Promise<unknown>;
    setMaximumTiers: (v: number) => Promise<unknown>;
    setProtocolFeeRevenueShareBp: (v: number) => Promise<unknown>;
    setTreasury: (v: string) => Promise<unknown>;
  },
  deployer: HardhatEthersSigner,
) {
  await manager.setMaximumMultiplierBp(100_000);
  await manager.setMinimumMultiplierBp(15_000);
  await manager.setMaximumWinRateBp(7_500);
  await manager.setMinimumWinRateBp(10);
  await manager.setMaximumTiers(10);
  await manager.setProtocolFeeRevenueShareBp(5_000);
  await manager.setTreasury(deployer.address);
}

export function systemFixture() {
  return loadFixture(deploySystem);
}

export async function impersonate(address: string) {
  const signer = await ethers.getImpersonatedSigner(address);
  await ethers.provider.send("hardhat_setBalance", [address, "0x3635C9ADC5DEA00000"]);
  return signer;
}

export type System = Awaited<ReturnType<typeof deploySystem>>;

const coder = ethers.AbiCoder.defaultAbiCoder();

export function encodeUint(value: bigint | number): string {
  return coder.encode(["uint256"], [value]);
}

export function encodeRegular(
  multiplierBp: number,
  superId: bigint = 0n,
  allocBp: number = 0,
  cltPerTicket: bigint = 0n,
): string {
  return coder.encode(["uint256", "uint256", "uint256", "uint256"], [multiplierBp, superId, allocBp, cltPerTicket]);
}

export function encodeSuperWinRate(winRateBp: number, prizeAsset: string): string {
  return coder.encode(["uint256", "address"], [winRateBp, prizeAsset]);
}

export async function params(
  asset: string,
  maxTickets: number,
  duration: number,
  feeBp = 0,
  ticketPrice: bigint = TICKET_PRICE,
) {
  const now = (await ethers.provider.getBlock("latest"))!.timestamp;
  return {
    ticketPrice,
    asset,
    feeBp,
    maxTickets,
    startTime: 0,
    endTime: now + duration,
  };
}

export async function createUser(
  f: System,
  creator: HardhatEthersSigner,
  maxTickets: number,
  feeBp = 0,
  model: number = MODEL.MULTIPLIER,
  extra?: string,
) {
  const p = await params(await f.token.getAddress(), maxTickets, 7 * DAY, feeBp);
  const data = extra ?? (model === MODEL.WIN_RATE ? encodeUint(1_000) : encodeUint(15_000));
  const tx = await f.hub.connect(creator).createLottery(await f.hub.USER_LOTTERY(), KIND.USER, model, p, data);
  const receipt = await tx.wait();
  const parsed = receipt!.logs
    .map((log) => {
      try {
        return f.hub.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((log) => log?.name === "LotteryRegistered");
  return { tx, id: parsed!.args.lotteryId as bigint, nonce: parsed!.args.nonce as bigint };
}

export async function createProtocol(
  f: System,
  kind: number,
  model: number,
  extra: string,
  maxTickets: number,
  duration: number,
  feeBp = 0,
  asset?: string,
) {
  const p = await params(asset ?? (await f.token.getAddress()), maxTickets, duration, feeBp);
  const tx = await f.hub
    .connect(f.operator)
    .createLottery(await f.hub.REGULAR_LOTTERY(), kind, model, p, extra);
  const receipt = await tx.wait();
  const parsed = receipt!.logs
    .map((log) => {
      try {
        return f.hub.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((log) => log?.name === "LotteryRegistered");
  return { tx, id: parsed!.args.lotteryId as bigint };
}

export function paymentCost(q: {
  toTreasury: bigint;
  prizeAmount: bigint;
  refShare: bigint;
  netFeeder: bigint;
  creatorFee: bigint;
}): bigint {
  return q.toTreasury + q.prizeAmount + q.refShare + q.netFeeder + q.creatorFee;
}

export async function buy(
  f: System,
  manager: { quoteTicketPurchase: (id: bigint, qty: bigint, referrer: string) => Promise<{
    toTreasury: bigint;
    prizeAmount: bigint;
    refShare: bigint;
    netFeeder: bigint;
    creatorFee: bigint;
    cltPayment: boolean;
    cltToTreasury: bigint;
    cltToBank: bigint;
  }> },
  buyer: HardhatEthersSigner,
  id: bigint,
  qty: number,
  referrer: string = ethers.ZeroAddress,
) {
  const q = await manager.quoteTicketPurchase(id, BigInt(qty), referrer);
  const cost = paymentCost(q);
  if (cost > 0n) {
    await f.token.mint(buyer.address, cost);
    await f.token.connect(buyer).approve(await f.hub.getAddress(), cost);
  }
  if (q.cltPayment) {
    const cltCost = q.cltToTreasury + q.cltToBank;
    await f.coinLotto.transfer(buyer.address, cltCost);
    await f.coinLotto.connect(buyer).approve(await f.hub.getAddress(), cltCost);
  }
  return f.hub.connect(buyer).buyTickets(id, qty, referrer, buyer.address);
}
