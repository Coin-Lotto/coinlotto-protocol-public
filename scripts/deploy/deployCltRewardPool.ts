import { deployCltRewardPool } from "./steps";

deployCltRewardPool()
  .then((address) => {
    console.log(`CltRewardPool: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
