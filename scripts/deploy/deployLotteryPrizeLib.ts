import { deployLotteryPrizeLib } from "./steps";

deployLotteryPrizeLib()
  .then((address) => {
    console.log(`LotteryPrizeLib: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
