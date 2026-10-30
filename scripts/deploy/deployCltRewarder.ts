import { deployCltRewarder } from "./steps";

deployCltRewarder()
  .then((address) => {
    console.log(`CltRewarder: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
