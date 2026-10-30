import { deployReferralRegistry } from "./steps";

deployReferralRegistry()
  .then((address) => {
    console.log(`ReferralRegistry: ${address}`);
  })
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
