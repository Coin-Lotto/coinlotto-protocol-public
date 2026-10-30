import { deployProtocolManagerLib } from "./steps";

deployProtocolManagerLib()
  .then((address) => {
    console.log(`ProtocolManagerLib: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
