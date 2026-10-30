import { deployRndConsumer } from "./steps";

deployRndConsumer()
  .then((address) => {
    console.log(`RndConsumer: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
