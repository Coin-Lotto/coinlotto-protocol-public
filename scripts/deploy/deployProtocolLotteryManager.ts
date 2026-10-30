import { deployProtocolLotteryManager } from "./steps";

deployProtocolLotteryManager()
  .then((address) => {
    console.log(`ProtocolLotteryManager: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
