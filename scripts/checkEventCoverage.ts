import fs from "fs";
import path from "path";

/**
 * Declared on a production ABI, but no reachable production function emits them.
 * RoleAdminChanged is inherited from AccessControl. These contracts never call
 * `_setRoleAdmin`, and neither AccessControl nor TimelockController does.
 * EtherRefundFailed is declared on RndConsumer for ABI stability. Excess native
 * value is credited with RefundCredited instead.
 * Reserve.updateDelay reverts with DelayImmutable, so it does not emit MinDelayChange.
 * The constructor is the only MinDelayChange path, and it is tested.
 */
export const UNEMITTED = [
  {
    event: "RoleAdminChanged",
    reason: "AccessControl declares it, but no production contract calls _setRoleAdmin.",
  },
  {
    event: "EtherRefundFailed",
    reason: "RndConsumer declares it for ABI stability. Excess native value is credited with RefundCredited.",
  },
] as const;

const NOT_EMITTED = new Set<string>(UNEMITTED.map((item) => item.event));

export type Emission = { contract: string; fn: string; event: string };

/**
 * Reachable production function -> event pairs. One entry per function that
 * emits the event, including inherited and library paths triggered by that function.
 */
export const REQUIRED: Emission[] = [
  ["CoinLotto", "constructor", "MinterSet"],
  ["CoinLotto", "constructor", "OwnershipTransferred"],
  ["CoinLotto", "mint", "MinterSet"],
  ["CoinLotto", "mint", "Transfer"],
  ["CoinLotto", "burn", "Transfer"],
  ["CoinLotto", "approve", "Approval"],
  ["CoinLotto", "transfer", "Transfer"],
  ["CoinLotto", "transferFrom", "Transfer"],
  ["CoinLotto", "setPeer", "PeerSet"],
  ["CoinLotto", "setEnforcedOptions", "EnforcedOptionSet"],
  ["CoinLotto", "setMsgInspector", "MsgInspectorSet"],
  ["CoinLotto", "setPreCrime", "PreCrimeSet"],
  ["CoinLotto", "send", "OFTSent"],
  ["CoinLotto", "send", "Transfer"],
  ["CoinLotto", "lzReceive", "OFTReceived"],
  ["CoinLotto", "lzReceive", "Transfer"],
  ["CoinLotto", "transferOwnership", "OwnershipTransferred"],
  ["CoinLotto", "renounceOwnership", "OwnershipTransferred"],

  ["CltRewardPool", "constructor", "RoleGranted"],
  ["CltRewardPool", "setCltToken", "CltTokenSet"],
  ["CltRewardPool", "withdrawClt", "CltWithdrawn"],
  ["CltRewardPool", "grantRole", "RoleGranted"],
  ["CltRewardPool", "revokeRole", "RoleRevoked"],
  ["CltRewardPool", "renounceRole", "RoleRevoked"],

  ["ReferralRegistry", "constructor", "RoleGranted"],
  ["ReferralRegistry", "linkReferrer", "ReferrerLinked"],
  ["ReferralRegistry", "grantRole", "RoleGranted"],
  ["ReferralRegistry", "revokeRole", "RoleRevoked"],
  ["ReferralRegistry", "renounceRole", "RoleRevoked"],

  ["LotteryHub", "constructor", "RoleGranted"],
  ["LotteryHub", "setRefRegistry", "RefRegistrySet"],
  ["LotteryHub", "setRewarder", "RewarderSet"],
  ["LotteryHub", "setWinnerReader", "WinnerReaderSet"],
  ["LotteryHub", "setLegacyHub", "LegacyHubSet"],
  ["LotteryHub", "registerManager", "ManagerRegistered"],
  ["LotteryHub", "registerManager", "ManagerStatusChanged"],
  ["LotteryHub", "setManagerStatus", "ManagerStatusChanged"],
  ["LotteryHub", "createLottery", "LotteryRegistered"],
  ["LotteryHub", "buyTickets", "TicketsBought"],
  ["LotteryHub", "grantRole", "RoleGranted"],
  ["LotteryHub", "revokeRole", "RoleRevoked"],
  ["LotteryHub", "renounceRole", "RoleRevoked"],

  ["RndConsumer", "constructor", "OwnershipTransferred"],
  ["RndConsumer", "setConsumer", "ConsumerSet"],
  ["RndConsumer", "setVrfConfig", "VrfConfigSet"],
  ["RndConsumer", "requestRandomness", "RefundCredited"],
  ["RndConsumer", "creditRefund", "RefundCredited"],
  ["RndConsumer", "withdrawRefund", "RefundWithdrawn"],
  ["RndConsumer", "forceCloseRequests", "RequestForceClosed"],
  ["RndConsumer", "fulfillRandomWords", "StaleVrfResponseIgnored"],
  ["RndConsumer", "transferOwnership", "OwnershipTransferred"],
  ["RndConsumer", "renounceOwnership", "OwnershipTransferred"],

  ["CltMissions", "constructor", "LotterySet"],
  ["CltMissions", "constructor", "RoleGranted"],
  ["CltMissions", "setLottery", "LotterySet"],
  ["CltMissions", "setHub", "HubSet"],
  ["CltMissions", "setLegacyAdapter", "LegacyAdapterSet"],
  ["CltMissions", "setRewardPool", "RewardPoolSet"],
  ["CltMissions", "setMissionBonusConfig", "MissionBonusConfigSet"],
  ["CltMissions", "claimGoldenTicketMission", "MissionClaimed"],
  ["CltMissions", "claimEarlyBirdMission", "MissionClaimed"],
  ["CltMissions", "claimStackTheOddsMission", "MissionClaimed"],
  ["CltMissions", "claimLuckInsuranceMission", "MissionClaimed"],
  ["CltMissions", "grantRole", "RoleGranted"],
  ["CltMissions", "revokeRole", "RoleRevoked"],
  ["CltMissions", "renounceRole", "RoleRevoked"],

  ["CltRewarder", "constructor", "RoleGranted"],
  ["CltRewarder", "setRewardPool", "RewardPoolSet"],
  ["CltRewarder", "setLotteryHub", "LotteryHubSet"],
  ["CltRewarder", "setCltReferrerWelcomeBonusAmount", "ReferrerWelcomeBonusSet"],
  ["CltRewarder", "addCltReferreWelcomeBonus", "CltReferrerWelcomeBonusAdded"],
  ["CltRewarder", "claimReferrerBonus", "CltReferrerBonusClaimed"],
  ["CltRewarder", "addCltPurchaseRewards", "CltPerTicketRewardAdded"],
  ["CltRewarder", "addCltPurchaseRewards", "CltLotteryRewardAdded"],
  ["CltRewarder", "claimCltLotteryReferrerReward", "CltLotteryRewardClaimed"],
  ["CltRewarder", "claimCltLotteryReferrerRewardBatch", "CltLotteryRewardClaimedBatch"],
  ["CltRewarder", "claimCltPerTicketReward", "CltPerTicketRewardClaimed"],
  ["CltRewarder", "claimCltPerTicketRewardBatch", "CltPerTicketRewardClaimedBatch"],
  ["CltRewarder", "grantRole", "RoleGranted"],
  ["CltRewarder", "revokeRole", "RoleRevoked"],
  ["CltRewarder", "renounceRole", "RoleRevoked"],

  ["Reserve", "constructor", "MinDelayChange"],
  ["Reserve", "constructor", "RoleGranted"],
  ["Reserve", "schedule", "CallScheduled"],
  ["Reserve", "schedule", "CallSalt"],
  ["Reserve", "scheduleBatch", "CallScheduled"],
  ["Reserve", "scheduleBatch", "CallSalt"],
  ["Reserve", "scheduleTransfer", "TransferScheduled"],
  ["Reserve", "scheduleTransfer", "CallScheduled"],
  ["Reserve", "scheduleTransfer", "CallSalt"],
  ["Reserve", "execute", "CallExecuted"],
  ["Reserve", "execute", "TransferExecuted"],
  ["Reserve", "executeBatch", "CallExecuted"],
  ["Reserve", "executeTransfer", "TransferExecuted"],
  ["Reserve", "executeTransfer", "CallExecuted"],
  ["Reserve", "cancel", "Cancelled"],
  ["Reserve", "cancel", "TransferCancelled"],
  ["Reserve", "cancelTransfer", "TransferCancelled"],
  ["Reserve", "cancelTransfer", "Cancelled"],
  ["Reserve", "grantRole", "RoleGranted"],
  ["Reserve", "revokeRole", "RoleRevoked"],
  ["Reserve", "renounceRole", "RoleRevoked"],
].map(([contract, fn, event]) => ({ contract, fn, event }));

const MANAGER_SHARED: Array<[string, string]> = [
  ["constructor", "HubSet"],
  ["constructor", "RoleGranted"],
  ["setHub", "HubSet"],
  ["setHub", "RoleGranted"],
  ["setHub", "RoleRevoked"],
  ["setRndConsumer", "RndCoordinatorSet"],
  ["setRndConsumer", "RoleGranted"],
  ["setRndConsumer", "RoleRevoked"],
  ["setRndConsumer", "ConsumerRevocationDeferred"],
  ["finalizeConsumerRevocation", "RoleRevoked"],
  ["setMaximumTiers", "MaximumTiersSet"],
  ["setMinimumWinRateBp", "MinimumWinRateBpSet"],
  ["setMaximumWinRateBp", "MaximumWinRateBpSet"],
  ["setMinimumMultiplierBp", "MinimumMultiplierBpSet"],
  ["setMaximumMultiplierBp", "MaximumMultiplierBpSet"],
  ["setProtocolFeeRevenueShareBp", "ProtocolFeeRevenueShareBpSet"],
  ["setTicketLimit", "TicketLimitSet"],
  ["setTreasury", "TreasurySet"],
  ["createLotteryFromHub", "LotteryCreated"],
  ["createLotteryFromHub", "LotteryStatusUpdated"],
  ["registerTicketPurchase", "TicketsMinted"],
  ["registerTicketPurchase", "LotteryStatusUpdated"],
  ["claimReferrerFees", "ReferrerFeeClaimed"],
  ["requestDraw", "DrawRequested"],
  ["requestDraw", "LotteryStatusUpdated"],
  ["requestDraw", "DrawCompleted"],
  ["fulfillRandomness", "DrawCompleted"],
  ["fulfillRandomness", "LotteryStatusUpdated"],
  ["claimPrize", "PrizeClaimed"],
  ["claimPrize", "LotteryStatusUpdated"],
  ["claimPrizeBatch", "PrizeClaimedBatch"],
  ["claimPrizeBatch", "LotteryStatusUpdated"],
  ["recordDonationFor", "Donated"],
  ["withdrawDonation", "DonationWithdrawn"],
  ["withdrawDonationFor", "DonationWithdrawn"],
  ["grantRole", "RoleGranted"],
  ["revokeRole", "RoleRevoked"],
  ["renounceRole", "RoleRevoked"],
];

for (const contract of ["UserLotteryManager", "ProtocolLotteryManager"]) {
  for (const [fn, event] of MANAGER_SHARED) REQUIRED.push({ contract, fn, event });
}

REQUIRED.push(
  { contract: "UserLotteryManager", fn: "setCreatorFeeUserLotteriesLimitBp", event: "CreatorFeeUserLotteriesLimitBpSet" },
  { contract: "UserLotteryManager", fn: "setMaxDurationUsers", event: "MaxDurationUsersSet" },
  { contract: "UserLotteryManager", fn: "setProtocolFeeUserLotteriesBp", event: "ProtocolFeeUserLotteriesBpSet" },
  { contract: "UserLotteryManager", fn: "registerTicketPurchase", event: "CreatorFeeAdded" },
  { contract: "UserLotteryManager", fn: "registerTicketPurchase", event: "ReferrerFeeAdded" },
  { contract: "UserLotteryManager", fn: "claimCreatorFee", event: "CreatorFeeClaimed" },
  { contract: "ProtocolLotteryManager", fn: "setSuperLotteryAllocationLimitBp", event: "SuperLotteryAllocationLimitBpSet" },
  { contract: "ProtocolLotteryManager", fn: "setProtocolFeeProtocolLotteriesLimitBp", event: "ProtocolFeeLimitBpSet" },
  { contract: "ProtocolLotteryManager", fn: "setCltTicketRewardLimit", event: "CltTicketRewardLimitSet" },
  { contract: "ProtocolLotteryManager", fn: "setMaxDurationRegular", event: "MaxDurationRegularSet" },
  { contract: "ProtocolLotteryManager", fn: "setMaxDurationSuper", event: "MaxDurationSuperSet" },
  { contract: "ProtocolLotteryManager", fn: "setCltToken", event: "CltTokenSet" },
  { contract: "ProtocolLotteryManager", fn: "setRewardPool", event: "RewardPoolSet" },
  { contract: "ProtocolLotteryManager", fn: "setCltTreasuryLimitBp", event: "CltTreasuryLimitBpSet" },
  { contract: "ProtocolLotteryManager", fn: "setCltProtocolFeeBp", event: "CltProtocolFeeBpSet" },
  { contract: "ProtocolLotteryManager", fn: "setCltReferrerBonusBp", event: "CltReferrerBonusBpSet" },
  { contract: "ProtocolLotteryManager", fn: "setRewarder", event: "RewarderSet" },
  { contract: "ProtocolLotteryManager", fn: "createLotteryFromHub", event: "FeederLinked" },
  { contract: "ProtocolLotteryManager", fn: "registerTicketPurchase", event: "ReferrerFeeAdded" },
  { contract: "ProtocolLotteryManager", fn: "registerTicketPurchase", event: "FeederFundsForwarded" },
  { contract: "ProtocolLotteryManager", fn: "registerTicketPurchase", event: "FeederFundsSkipped" },
  { contract: "ProtocolLotteryManager", fn: "registerTicketPurchase", event: "CltUserPerTicketRewardAdded" },
  { contract: "ProtocolLotteryManager", fn: "registerTicketPurchase", event: "CltReferrerBonusAdded" },
  { contract: "ProtocolLotteryManager", fn: "forwardExternalFeederFunds", event: "FeederFundsForwarded" },
  { contract: "ProtocolLotteryManager", fn: "forwardExternalFeederFunds", event: "FeederFundsSkipped" },
  { contract: "ProtocolLotteryManager", fn: "recoverStrandedFunds", event: "StrandedFundsRecovered" },
  { contract: "ProtocolLotteryManager", fn: "recoverStrandedFunds", event: "LotteryStatusUpdated" },
);

const ROOT = path.join(__dirname, "..");

function productionEventNames(): Set<string> {
  const names = new Set<string>();
  const dir = path.join(ROOT, "artifacts", "contracts");
  const stack = [dir];
  while (stack.length > 0) {
    const current = stack.pop()!;
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }
      if (!entry.name.endsWith(".json") || entry.name.endsWith(".dbg.json")) continue;
      const artifact = JSON.parse(fs.readFileSync(fullPath, "utf8")) as {
        abi?: { type?: string; name?: string }[];
      };
      for (const item of artifact.abi ?? []) {
        if (item.type === "event" && item.name) names.add(item.name);
      }
    }
  }
  return names;
}

export function assertedEmissions(): Emission[] {
  const hits: Emission[] = [];
  const testDir = path.join(ROOT, "test");
  for (const file of fs.readdirSync(testDir).filter((name) => name.endsWith(".test.ts"))) {
    hits.push(...scanSource(fs.readFileSync(path.join(testDir, file), "utf8")));
  }
  return hits;
}

function scanSource(source: string): Emission[] {
  const hits: Emission[] = [];
  const stack: { name: string; depth: number }[] = [];
  let pending: string | null = null;
  let depth = 0;
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === "/" && source[i + 1] === "/") {
      const next = source.indexOf("\n", i);
      i = next < 0 ? source.length : next + 1;
      continue;
    }
    if (c === "/" && source[i + 1] === "*") {
      const next = source.indexOf("*/", i + 2);
      i = next < 0 ? source.length : next + 2;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      i++;
      while (i < source.length) {
        if (source[i] === "\\") {
          i += 2;
          continue;
        }
        if (source[i] === quote) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (source.startsWith("describe(", i)) {
      const match = /^describe\(\s*"([^"]+)"/.exec(source.slice(i));
      if (match) {
        pending = match[1];
        i += match[0].length;
        continue;
      }
    }
    if (c === "{") {
      depth++;
      if (pending) {
        stack.push({ name: pending, depth });
        pending = null;
      }
      i++;
      continue;
    }
    if (c === "}") {
      while (stack.length > 0 && stack[stack.length - 1].depth === depth) stack.pop();
      depth--;
      i++;
      continue;
    }
    if (source.startsWith(".to.emit(", i) && stack.length >= 2) {
      const match = /^\.to\.emit\(\s*[^,]+,\s*"([^"]+)"/.exec(source.slice(i));
      if (match) {
        hits.push({ contract: stack[0].name, fn: stack[1].name, event: match[1] });
      }
    }
    i++;
  }
  return hits;
}

function key(item: Emission): string {
  return `${item.contract}.${item.fn} -> ${item.event}`;
}

export function missingFunctionEmissions(): string[] {
  const found = new Set(assertedEmissions().map(key));
  return REQUIRED.filter((item) => !found.has(key(item))).map(key).sort();
}

export function missingProductionEvents(): string[] {
  const found = new Set(assertedEmissions().map((item) => item.event));
  return [...productionEventNames()].filter((name) => !NOT_EMITTED.has(name) && !found.has(name)).sort();
}

if (require.main === module) {
  const missingFns = missingFunctionEmissions();
  const missingEvents = missingProductionEvents();
  if (missingFns.length > 0 || missingEvents.length > 0) {
    if (missingFns.length > 0) console.error(`Missing function coverage:\n${missingFns.join("\n")}`);
    if (missingEvents.length > 0) console.error(`Missing events: ${missingEvents.join(", ")}`);
    process.exitCode = 1;
  } else {
    console.log(`${REQUIRED.length} function/event pairs are asserted.`);
  }
}
