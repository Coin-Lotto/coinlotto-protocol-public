import { ethers } from "hardhat";

const PRIZE = "contracts/libraries/LotteryPrizeLib.sol:LotteryPrizeLib";
const CORE = "contracts/libraries/LotteryCoreLib.sol:LotteryCoreLib";
const PROTO = "contracts/libraries/ProtocolManagerLib.sol:ProtocolManagerLib";

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Set ${name} before running this deploy script`);
  }
  return value;
}

function addressEnv(name: string): string {
  return ethers.getAddress(required(name));
}

function optionalAddress(name: string): string {
  const value = process.env[name]?.trim();
  return value ? ethers.getAddress(value) : ethers.ZeroAddress;
}

function integerEnv(name: string): number {
  const raw = required(name);
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return Number(raw);
}

function addressList(name: string): string[] {
  return required(name)
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0)
    .map((item) => ethers.getAddress(item));
}

async function deployed(contract: { waitForDeployment: () => Promise<unknown>; getAddress: () => Promise<string> }) {
  await contract.waitForDeployment();
  return contract.getAddress();
}

export async function deployLotteryPrizeLib(): Promise<string> {
  return deployed(await ethers.deployContract("LotteryPrizeLib"));
}

export async function deployLotteryCoreLib(): Promise<string> {
  const factory = await ethers.getContractFactory("LotteryCoreLib", {
    libraries: { [PRIZE]: addressEnv("LOTTERY_PRIZE_LIB") },
  });
  return deployed(await factory.deploy());
}

export async function deployProtocolManagerLib(): Promise<string> {
  return deployed(await ethers.deployContract("ProtocolManagerLib"));
}

export async function deployCoinLotto(): Promise<string> {
  return deployed(
    await ethers.deployContract("CoinLotto", [
      addressEnv("LZ_ENDPOINT"),
      addressEnv("ADMIN_ADDRESS"),
      optionalAddress("MINTER_ADDRESS"),
    ]),
  );
}

export async function deployCltRewardPool(): Promise<string> {
  return deployed(await ethers.deployContract("CltRewardPool", [addressEnv("ADMIN_ADDRESS")]));
}

export async function deployReferralRegistry(): Promise<string> {
  return deployed(
    await ethers.deployContract("ReferralRegistry", [addressEnv("ADMIN_ADDRESS"), optionalAddress("LINKER_ADDRESS")]),
  );
}

export async function deployLotteryHub(): Promise<string> {
  const initialLotteryId = integerEnv("INITIAL_LOTTERY_ID");
  if (initialLotteryId < 1) {
    throw new Error("INITIAL_LOTTERY_ID must be at least 1");
  }
  return deployed(await ethers.deployContract("LotteryHub", [addressEnv("ADMIN_ADDRESS"), initialLotteryId]));
}

export async function deployLotteryWinnerReader(): Promise<string> {
  const factory = await ethers.getContractFactory("LotteryWinnerReader", {
    libraries: { [CORE]: addressEnv("LOTTERY_CORE_LIB") },
  });
  return deployed(await factory.deploy());
}

export async function deployRndConsumer(): Promise<string> {
  return deployed(
    await ethers.deployContract("RndConsumer", [
      addressEnv("ADMIN_ADDRESS"),
      addressEnv("VRF_WRAPPER"),
      integerEnv("CALLBACK_GAS_LIMIT"),
      integerEnv("REQUEST_CONFIRMATIONS"),
    ]),
  );
}

export async function deployUserLotteryManager(): Promise<string> {
  const factory = await ethers.getContractFactory("UserLotteryManager", {
    libraries: { [CORE]: addressEnv("LOTTERY_CORE_LIB") },
  });
  return deployed(await factory.deploy(addressEnv("ADMIN_ADDRESS"), addressEnv("LOTTERY_HUB")));
}

export async function deployProtocolLotteryManager(): Promise<string> {
  const factory = await ethers.getContractFactory("ProtocolLotteryManager", {
    libraries: {
      [CORE]: addressEnv("LOTTERY_CORE_LIB"),
      [PROTO]: addressEnv("PROTOCOL_MANAGER_LIB"),
    },
  });
  return deployed(await factory.deploy(addressEnv("ADMIN_ADDRESS"), addressEnv("LOTTERY_HUB")));
}

export async function deployCltRewarder(): Promise<string> {
  return deployed(await ethers.deployContract("CltRewarder", [addressEnv("ADMIN_ADDRESS")]));
}

export async function deployCltMissions(): Promise<string> {
  return deployed(
    await ethers.deployContract("CltMissions", [addressEnv("ADMIN_ADDRESS"), addressEnv("LOTTERY_PLACEHOLDER")]),
  );
}

export async function deployReserve(): Promise<string> {
  return deployed(
    await ethers.deployContract("Reserve", [
      addressEnv("RESERVE_TOKEN"),
      addressList("RESERVE_PROPOSERS"),
      addressList("RESERVE_EXECUTORS"),
      optionalAddress("RESERVE_ADMIN"),
    ]),
  );
}
