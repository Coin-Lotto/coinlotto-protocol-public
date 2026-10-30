import { deployCltMissions } from "./steps";

deployCltMissions()
  .then((address) => {
    console.log(`CltMissions: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
