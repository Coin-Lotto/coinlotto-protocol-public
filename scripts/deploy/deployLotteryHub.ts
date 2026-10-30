import { deployLotteryHub } from "./steps";

deployLotteryHub()
  .then((address) => {
    console.log(`LotteryHub: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
