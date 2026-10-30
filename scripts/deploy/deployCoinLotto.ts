import { deployCoinLotto } from "./steps";

deployCoinLotto()
  .then((address) => {
    console.log(`CoinLotto: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
