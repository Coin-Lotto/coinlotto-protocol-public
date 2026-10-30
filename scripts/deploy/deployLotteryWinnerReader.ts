import { deployLotteryWinnerReader } from "./steps";

deployLotteryWinnerReader()
  .then((address) => {
    console.log(`LotteryWinnerReader: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
