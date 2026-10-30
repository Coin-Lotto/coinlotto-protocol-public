import { deployUserLotteryManager } from "./steps";

deployUserLotteryManager()
  .then((address) => {
    console.log(`UserLotteryManager: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
