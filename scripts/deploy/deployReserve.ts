import { deployReserve } from "./steps";

deployReserve()
  .then((address) => {
    console.log(`Reserve: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
