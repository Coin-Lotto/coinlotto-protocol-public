# CoinLotto protocol

CoinLotto is an on-chain lottery protocol. Players buy tickets in user, regular, and super lotteries. Draws use Chainlink VRF. The CLT token is a LayerZero OFT, and CLT rewards are paid from a reward pool.

This repository contains the production Solidity sources, Hardhat tests for every event those contracts emit, and deployment scripts. It does not contain the off-chain services or the deployment pipeline used to publish the live contracts.

## Layout

| Path | Contents |
|---|---|
| `contracts/` | Production contracts, abstracts, libraries, interfaces, and structs |
| `scripts/deploy/` | One deploy script per contract, plus `deployAll.ts` |
| `scripts/local/` | Constructor-only stand-ins used by a local `deployAll.ts` run |
| `test/` | Event tests |
| `test/mocks/` | Test-only mocks. Deploy scripts do not import them |

`LotteryTickets` is inherited by the lottery managers and is not deployed on its own. `LotteryWinnerReader` is deployed and declares no events.

## Requirements

Node.js 20 or 22.

```bash
git clone https://github.com/Coin-Lotto/coinlotto-protocol-public.git
cd coinlotto-protocol-public
npm ci
npx hardhat compile
npx hardhat test
```

Compilation and tests do not need a `.env` file.

## Configuration

Copy `.env.example` to `.env` before a mainnet, Base, or BNB Chain deployment. `hardhat.config.ts` adds those networks only when both the RPC URL and `PRIVATE_KEY` are set.

| Variable | Used by |
|---|---|
| `PRIVATE_KEY` | Deployer key for mainnet, Base, and BNB Chain |
| `ETHEREUM_RPC_URL`, `BASE_RPC_URL`, `BNB_RPC_URL` | RPC endpoints |
| `ADMIN_ADDRESS` | Default admin, and the CoinLotto owner |
| `MINTER_ADDRESS` | CoinLotto minter. Empty means the zero address |
| `LZ_ENDPOINT` | LayerZero Endpoint V2 passed to CoinLotto |
| `VRF_WRAPPER` | Chainlink VRF v2.5 wrapper passed to RndConsumer |
| `CALLBACK_GAS_LIMIT`, `REQUEST_CONFIRMATIONS` | RndConsumer |
| `INITIAL_LOTTERY_ID` | First lottery id assigned by LotteryHub. Use `1` for a fresh deployment |
| `LOTTERY_PLACEHOLDER` | Non-zero address passed to CltMissions |
| `LINKER_ADDRESS` | Optional ReferralRegistry linker. Empty skips the grant |
| `LOTTERY_PRIZE_LIB`, `LOTTERY_CORE_LIB`, `PROTOCOL_MANAGER_LIB`, `LOTTERY_HUB` | Addresses required by the standalone scripts that link or reference them |
| `RESERVE_TOKEN`, `RESERVE_PROPOSERS`, `RESERVE_EXECUTORS`, `RESERVE_ADMIN` | Reserve. Proposers and executors are comma-separated. An empty admin is address zero |

## Deployment

Library linking:

1. `LotteryPrizeLib` has no link dependencies.
2. `LotteryCoreLib` links `LotteryPrizeLib`.
3. `ProtocolManagerLib` has no link dependencies.
4. `LotteryWinnerReader` and `UserLotteryManager` link `LotteryCoreLib`.
5. `ProtocolLotteryManager` links `LotteryCoreLib` and `ProtocolManagerLib`.

Deploy order:

1. `LotteryPrizeLib`
2. `LotteryCoreLib`
3. `ProtocolManagerLib`
4. `CoinLotto` — endpoint, owner, minter
5. `CltRewardPool` — admin
6. `ReferralRegistry` — admin, linker
7. `LotteryHub` — admin, initial lottery id
8. `LotteryWinnerReader`
9. `RndConsumer` — owner, VRF wrapper, callback gas limit, request confirmations
10. `UserLotteryManager` — admin, hub
11. `ProtocolLotteryManager` — admin, hub
12. `CltRewarder` — admin
13. `CltMissions` — admin, non-zero lottery placeholder
14. `Reserve` — token, proposers, executors, admin

`Reserve` is deployed on Ethereum mainnet only. The script is still included.

Each file under `scripts/deploy/` deploys one contract, waits for the transaction, and prints the address. Those scripts read constructor arguments from the environment. They do not deploy stand-ins.

`scripts/deploy/deployAll.ts` deploys the full set in the order above. When `LZ_ENDPOINT` or `VRF_WRAPPER` is unset, it first deploys `EndpointStandIn` or `VrfWrapperStandIn` from `scripts/local/`. Those stand-ins only implement `setDelegate` and `link()`, which is all the constructors call. On a local run with the remaining variables unset, `deployAll.ts` uses the deployer as admin, lottery placeholder, and Reserve roles, and uses the freshly deployed `CoinLotto` as the Reserve token.

Local deployment, with no `.env`:

```bash
npx hardhat run scripts/deploy/deployAll.ts --network hardhat
```

A public-network deployment is started manually, for example:

```bash
npx hardhat run scripts/deploy/deployCoinLotto.ts --network base
```

## Deployed addresses

Recorded on 2026-10-27. `CoinLotto` and `RndConsumer` differ by chain. The other addresses are the same on every chain where that contract is deployed. `Reserve` is on Ethereum mainnet only.

### Ethereum mainnet (chain id 1)

Deployed at 2026-10-27T08:13:18.059Z.

| Contract | Address |
|---|---|
| CoinLotto | [`0xe9A8834dCbC55A661Fa39bD70c213A366aBe99AA`](https://etherscan.io/address/0xe9A8834dCbC55A661Fa39bD70c213A366aBe99AA) |
| LotteryPrizeLib | [`0x5DdFc1B72BB8bF925438f2495eA579E856Eb8f92`](https://etherscan.io/address/0x5DdFc1B72BB8bF925438f2495eA579E856Eb8f92) |
| LotteryCoreLib | [`0x82db0AD5631209E15149CbE06511C09C599A0557`](https://etherscan.io/address/0x82db0AD5631209E15149CbE06511C09C599A0557) |
| ProtocolManagerLib | [`0xd48b2CB27D8df1B1a8FbFcE6b29Aa955F095FE62`](https://etherscan.io/address/0xd48b2CB27D8df1B1a8FbFcE6b29Aa955F095FE62) |
| LotteryWinnerReader | [`0x7969C22D6351AaccC5c99030B97A839a2F25687F`](https://etherscan.io/address/0x7969C22D6351AaccC5c99030B97A839a2F25687F) |
| CltRewardPool | [`0x62234a450A6514b9E2C6b00c425Dc00f9BBE333D`](https://etherscan.io/address/0x62234a450A6514b9E2C6b00c425Dc00f9BBE333D) |
| RndConsumer | [`0x2Dd2a50e94AD89449134917CC9D9b0CcbC2f291e`](https://etherscan.io/address/0x2Dd2a50e94AD89449134917CC9D9b0CcbC2f291e) |
| ReferralRegistry | [`0xb2f2772FBe8BB173FE120BE010204aEd34caF337`](https://etherscan.io/address/0xb2f2772FBe8BB173FE120BE010204aEd34caF337) |
| CltMissions | [`0xFB02E19a67bb7853faaa78B9aFC3Dc9D42F74736`](https://etherscan.io/address/0xFB02E19a67bb7853faaa78B9aFC3Dc9D42F74736) |
| CltRewarder | [`0x0AC02fa7e7799C63c2B2C94F0dEC000A8354638A`](https://etherscan.io/address/0x0AC02fa7e7799C63c2B2C94F0dEC000A8354638A) |
| LotteryHub | [`0x4958CB13Fa5881B2c67bde408708e72411Bb3bbb`](https://etherscan.io/address/0x4958CB13Fa5881B2c67bde408708e72411Bb3bbb) |
| UserLotteryManager | [`0x9D247A82c1e645af0b6DBA10785A26fa0b6552eA`](https://etherscan.io/address/0x9D247A82c1e645af0b6DBA10785A26fa0b6552eA) |
| ProtocolLotteryManager | [`0x98f29223fB9c399fa0efA65d837BdB581032Cc44`](https://etherscan.io/address/0x98f29223fB9c399fa0efA65d837BdB581032Cc44) |
| Reserve | [`0x0Cc0054Cc422d147b6e15722cc01FD80395D002B`](https://etherscan.io/address/0x0Cc0054Cc422d147b6e15722cc01FD80395D002B) |

### Base (chain id 8453)

Deployed at 2026-10-27T08:16:32.864Z.

| Contract | Address |
|---|---|
| CoinLotto | [`0x56fAC0f4B20919aF094827E567e7Ce988B88a762`](https://basescan.org/address/0x56fAC0f4B20919aF094827E567e7Ce988B88a762) |
| LotteryPrizeLib | [`0x5DdFc1B72BB8bF925438f2495eA579E856Eb8f92`](https://basescan.org/address/0x5DdFc1B72BB8bF925438f2495eA579E856Eb8f92) |
| LotteryCoreLib | [`0x82db0AD5631209E15149CbE06511C09C599A0557`](https://basescan.org/address/0x82db0AD5631209E15149CbE06511C09C599A0557) |
| ProtocolManagerLib | [`0xd48b2CB27D8df1B1a8FbFcE6b29Aa955F095FE62`](https://basescan.org/address/0xd48b2CB27D8df1B1a8FbFcE6b29Aa955F095FE62) |
| LotteryWinnerReader | [`0x7969C22D6351AaccC5c99030B97A839a2F25687F`](https://basescan.org/address/0x7969C22D6351AaccC5c99030B97A839a2F25687F) |
| CltRewardPool | [`0x62234a450A6514b9E2C6b00c425Dc00f9BBE333D`](https://basescan.org/address/0x62234a450A6514b9E2C6b00c425Dc00f9BBE333D) |
| RndConsumer | [`0x4B2cf1B8314eA391051373D41B41d697a5FB20D8`](https://basescan.org/address/0x4B2cf1B8314eA391051373D41B41d697a5FB20D8) |
| ReferralRegistry | [`0xb2f2772FBe8BB173FE120BE010204aEd34caF337`](https://basescan.org/address/0xb2f2772FBe8BB173FE120BE010204aEd34caF337) |
| CltMissions | [`0xFB02E19a67bb7853faaa78B9aFC3Dc9D42F74736`](https://basescan.org/address/0xFB02E19a67bb7853faaa78B9aFC3Dc9D42F74736) |
| CltRewarder | [`0x0AC02fa7e7799C63c2B2C94F0dEC000A8354638A`](https://basescan.org/address/0x0AC02fa7e7799C63c2B2C94F0dEC000A8354638A) |
| LotteryHub | [`0x4958CB13Fa5881B2c67bde408708e72411Bb3bbb`](https://basescan.org/address/0x4958CB13Fa5881B2c67bde408708e72411Bb3bbb) |
| UserLotteryManager | [`0x9D247A82c1e645af0b6DBA10785A26fa0b6552eA`](https://basescan.org/address/0x9D247A82c1e645af0b6DBA10785A26fa0b6552eA) |
| ProtocolLotteryManager | [`0x98f29223fB9c399fa0efA65d837BdB581032Cc44`](https://basescan.org/address/0x98f29223fB9c399fa0efA65d837BdB581032Cc44) |

### BNB Chain (chain id 56)

Deployed at 2026-10-27T08:19:52.632Z.

| Contract | Address |
|---|---|
| CoinLotto | [`0x56fAC0f4B20919aF094827E567e7Ce988B88a762`](https://bscscan.com/address/0x56fAC0f4B20919aF094827E567e7Ce988B88a762) |
| LotteryPrizeLib | [`0x5DdFc1B72BB8bF925438f2495eA579E856Eb8f92`](https://bscscan.com/address/0x5DdFc1B72BB8bF925438f2495eA579E856Eb8f92) |
| LotteryCoreLib | [`0x82db0AD5631209E15149CbE06511C09C599A0557`](https://bscscan.com/address/0x82db0AD5631209E15149CbE06511C09C599A0557) |
| ProtocolManagerLib | [`0xd48b2CB27D8df1B1a8FbFcE6b29Aa955F095FE62`](https://bscscan.com/address/0xd48b2CB27D8df1B1a8FbFcE6b29Aa955F095FE62) |
| LotteryWinnerReader | [`0x7969C22D6351AaccC5c99030B97A839a2F25687F`](https://bscscan.com/address/0x7969C22D6351AaccC5c99030B97A839a2F25687F) |
| CltRewardPool | [`0x62234a450A6514b9E2C6b00c425Dc00f9BBE333D`](https://bscscan.com/address/0x62234a450A6514b9E2C6b00c425Dc00f9BBE333D) |
| RndConsumer | [`0xA98dd9a729d1A54Ff8893c03511e2348Faed3544`](https://bscscan.com/address/0xA98dd9a729d1A54Ff8893c03511e2348Faed3544) |
| ReferralRegistry | [`0xb2f2772FBe8BB173FE120BE010204aEd34caF337`](https://bscscan.com/address/0xb2f2772FBe8BB173FE120BE010204aEd34caF337) |
| CltMissions | [`0xFB02E19a67bb7853faaa78B9aFC3Dc9D42F74736`](https://bscscan.com/address/0xFB02E19a67bb7853faaa78B9aFC3Dc9D42F74736) |
| CltRewarder | [`0x0AC02fa7e7799C63c2B2C94F0dEC000A8354638A`](https://bscscan.com/address/0x0AC02fa7e7799C63c2B2C94F0dEC000A8354638A) |
| LotteryHub | [`0x4958CB13Fa5881B2c67bde408708e72411Bb3bbb`](https://bscscan.com/address/0x4958CB13Fa5881B2c67bde408708e72411Bb3bbb) |
| UserLotteryManager | [`0x9D247A82c1e645af0b6DBA10785A26fa0b6552eA`](https://bscscan.com/address/0x9D247A82c1e645af0b6DBA10785A26fa0b6552eA) |
| ProtocolLotteryManager | [`0x98f29223fB9c399fa0efA65d837BdB581032Cc44`](https://bscscan.com/address/0x98f29223fB9c399fa0efA65d837BdB581032Cc44) |

## Security audit

A CertiK review of these contracts is the intended audit. The final report is not linked here. This repository does not claim that the report has been published.

## Compiler

Solidity 0.8.34, optimizer enabled with 200 runs, `viaIR`, and the Paris EVM. Those settings are in `hardhat.config.ts`.
