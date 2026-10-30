import { ethers } from "hardhat";
import {
  deployCltMissions,
  deployCltRewarder,
  deployCltRewardPool,
  deployCoinLotto,
  deployLotteryCoreLib,
  deployLotteryHub,
  deployLotteryPrizeLib,
  deployLotteryWinnerReader,
  deployProtocolLotteryManager,
  deployProtocolManagerLib,
  deployReferralRegistry,
  deployReserve,
  deployRndConsumer,
  deployUserLotteryManager,
} from "./steps";

async function standIn(name: string): Promise<string> {
  const contract = await ethers.deployContract(name);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`${name}: ${address}`);
  return address;
}

async function step(name: string, deploy: () => Promise<string>, envName?: string): Promise<string> {
  const address = await deploy();
  if (envName) process.env[envName] = address;
  console.log(`${name}: ${address}`);
  return address;
}

async function main() {
  const [deployer] = await ethers.getSigners();

  if (!process.env.ADMIN_ADDRESS?.trim()) process.env.ADMIN_ADDRESS = deployer.address;
  if (!process.env.CALLBACK_GAS_LIMIT?.trim()) process.env.CALLBACK_GAS_LIMIT = "500000";
  if (!process.env.REQUEST_CONFIRMATIONS?.trim()) process.env.REQUEST_CONFIRMATIONS = "3";
  if (!process.env.INITIAL_LOTTERY_ID?.trim()) process.env.INITIAL_LOTTERY_ID = "1";
  if (!process.env.LOTTERY_PLACEHOLDER?.trim()) process.env.LOTTERY_PLACEHOLDER = deployer.address;

  if (!process.env.LZ_ENDPOINT?.trim()) {
    process.env.LZ_ENDPOINT = await standIn("EndpointStandIn");
  }
  if (!process.env.VRF_WRAPPER?.trim()) {
    process.env.VRF_WRAPPER = await standIn("VrfWrapperStandIn");
  }

  await step("LotteryPrizeLib", deployLotteryPrizeLib, "LOTTERY_PRIZE_LIB");
  await step("LotteryCoreLib", deployLotteryCoreLib, "LOTTERY_CORE_LIB");
  await step("ProtocolManagerLib", deployProtocolManagerLib, "PROTOCOL_MANAGER_LIB");
  const coinLotto = await step("CoinLotto", deployCoinLotto);
  await step("CltRewardPool", deployCltRewardPool);
  await step("ReferralRegistry", deployReferralRegistry);
  await step("LotteryHub", deployLotteryHub, "LOTTERY_HUB");
  await step("LotteryWinnerReader", deployLotteryWinnerReader);
  await step("RndConsumer", deployRndConsumer);
  await step("UserLotteryManager", deployUserLotteryManager);
  await step("ProtocolLotteryManager", deployProtocolLotteryManager);
  await step("CltRewarder", deployCltRewarder);
  await step("CltMissions", deployCltMissions);

  if (!process.env.RESERVE_TOKEN?.trim()) process.env.RESERVE_TOKEN = coinLotto;
  if (!process.env.RESERVE_PROPOSERS?.trim()) process.env.RESERVE_PROPOSERS = process.env.ADMIN_ADDRESS;
  if (!process.env.RESERVE_EXECUTORS?.trim()) process.env.RESERVE_EXECUTORS = process.env.ADMIN_ADDRESS;
  if (!process.env.RESERVE_ADMIN?.trim()) process.env.RESERVE_ADMIN = process.env.ADMIN_ADDRESS;
  await step("Reserve", deployReserve);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
