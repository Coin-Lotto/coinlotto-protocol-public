import { deployLotteryCoreLib } from "./steps";

deployLotteryCoreLib()
  .then((address) => {
    console.log(`LotteryCoreLib: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
