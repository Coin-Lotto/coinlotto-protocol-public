import { HardhatUserConfig, subtask } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names";
import "dotenv/config";
import fs from "fs";
import path from "path";

function collectSolidityFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  const files: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectSolidityFiles(fullPath));
    } else if (entry.name.endsWith(".sol")) {
      files.push(fullPath);
    }
  }
  return files;
}

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, hre, runSuper) => {
  const sources: string[] = await runSuper();
  const root = hre.config.paths.root;
  return [
    ...sources,
    ...collectSolidityFiles(path.join(root, "test", "mocks")),
    ...collectSolidityFiles(path.join(root, "scripts", "local")),
  ];
});

const compilerSettings = {
  optimizer: { enabled: true, runs: 200 },
  evmVersion: "paris" as const,
  viaIR: true,
};

function externalNetwork(url: string | undefined, chainId: number) {
  const privateKey = process.env.PRIVATE_KEY;
  if (!url || !privateKey) return undefined;
  return { url, chainId, accounts: [privateKey] };
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.34",
    settings: compilerSettings,
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },
  mocha: {
    timeout: 180_000,
  },
};

const mainnet = externalNetwork(process.env.ETHEREUM_RPC_URL, 1);
const base = externalNetwork(process.env.BASE_RPC_URL, 8453);
const bnb = externalNetwork(process.env.BNB_RPC_URL, 56);
if (mainnet) config.networks!.mainnet = mainnet;
if (base) config.networks!.base = base;
if (bnb) config.networks!.bnb = bnb;

export default config;
