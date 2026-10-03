# Countersign

**An issuer-operated Cross-Chain Verifier (CCV) for Chainlink CCIP v2, run as a Chainlink Runtime Environment (CRE) workflow instead of a server.**

On April 18, 2026, KelpDAO lost about $292M in rsETH on a bridge that accepted messages checked by a single verifier (a 1-of-1 DVN); 47% of active LayerZero OApps were using the same setup ([CoinDesk](https://www.coindesk.com/web3/2026/05/05/kelp-claims-that-layerzero-approved-the-setup-it-blamed-for-usd292-million-bridge-hack)). Kelp and others moved to CCIP: more than $7B of cross-chain token value migrated to CCIP in Q2 2026 alone ([Chainlink Q2 review](https://chain.link/blog/quarterly-review-q2-2026)).

CCIP v2 (contracts v2.0.0, June 18, 2026) makes verification composable: every token pool can require its own verifiers on top of Chainlink's committee, even only above an amount threshold. Yet across the 67 mainnets in Chainlink's CCIP directory, the only verifiers besides the committee are Circle's (CCTP) and Lombard's, because running a verifier means running infrastructure (Kubernetes, Postgres, an aggregator, signing keys).

**Countersign removes that infrastructure.** A CRE workflow independently re-checks every large transfer and writes a DON-signed attestation to the destination chain; the token pool refuses to mint or release without it. A forged or unbacked transfer now has to fool two independent verifier networks.

```
 Source chain (Ethereum Sepolia)                              Destination chain (Arbitrum Sepolia)
 ccipSend -> OnRamp v2 -> TokenPool v2 + AdvancedPoolHooks     OffRamp v2.execute(msg, [committee, countersign], proofs)
   -> CommitteeVerifier (Chainlink)                              -> pool.getRequiredCCVs(amount >= threshold)
   -> CountersignVerifier.forwardToVerifier                      -> CountersignVerifier.verifyMessage (APPROVED only)
        window counters + CountersignRequested ─┐                -> releaseOrMint
                                                │ EVM log trigger, FINALIZED            ▲
           ┌────────────────────────────────────▼──────────────────────┐                │ onReport via KeystoneForwarder
           │ CRE workflow `countersign`                                 │────────────────┘ (F+1 DON signatures)
           │  1. verify: OnRamp event in same tx, messageId, lane       │
           │     supply invariant · Proof of Reserve (+ staleness)      │
           │     rolling window · velocity · denylist -> APPROVED/HELD  │
           │  2. sweep (cron): re-drive anything the trigger missed     │
           │  3. sentinel (cron): global invariant -> RateLimitGuard    │──> freeze lanes (tighten-only)
           └────────────────────────────────────────────────────────────┘
```

## Why it matters

| | Without Countersign | With Countersign |
|---|---|---|
| Verifiers a forged large transfer must fool | Chainlink committee | Chainlink committee **and** the issuer's own DON-run checks |
| Issuer-defined rules (supply, reserves, limits, compliance) | Offchain monitoring, human reaction time | Enforced before mint/release, per message |
| Infrastructure the issuer runs | — (or a full verifier stack) | None: a CRE workflow and five contracts |
| How the verifier gets paid | — | CCIP-native per-transfer fee (`feeUSDCents`), accrues in the resolver |

## Safety model: automation can only tighten

| Actor | Can | Cannot |
|---|---|---|
| CRE workflow | NONE→APPROVED, NONE→HELD, APPROVED→HELD (revoke before execution) | HELD→APPROVED |
| Guardian (issuer multisig) | Release or place holds, pause (blocks new sends and verification) | Unpause |
| Owner | Unpause, configure | — |
| `RateLimitGuard` (sentinel) | Lower pool rate limits, freeze a lane | Raise limits, disable limiters, refill a drained bucket |

**CCIP v2 rate-limit refill footgun.** `RateLimiter._setTokenBucketConfig` refills a bucket to full capacity on every config change. A breaker that "lowers" capacity from 1,000 to 500 while an attacker has drained the bucket to 100 hands them 400 fresh tokens. `RateLimitGuard` clamps every request to the tokens available right now (`test_ClampsToLiveTokens_AfterDrain`, `testFuzz_clamp_NeverLoosens`).

## Repository

| Path | What |
|---|---|
| [contracts/src/CountersignVerifier.sol](contracts/src/CountersignVerifier.sol) | The CCV: source events + window counters, onchain attestations, `verifyMessage`, guardian holds, pause |
| [contracts/src/RateLimitGuard.sol](contracts/src/RateLimitGuard.sol) | CRE-driven, clamp-only rate-limit admin for v2 token pools |
| [contracts/src/cre/CREReceiverBase.sol](contracts/src/cre/CREReceiverBase.sol) | Forwarder + workflow identity checks, chain-bound reports |
| [contracts/script/Countersign.s.sol](contracts/script/Countersign.s.sol) | `deploy()` · `connect(remoteChainId)` · `send(remoteChainId, amount)` |
| [contracts/test/fork/](contracts/test/fork/CountersignLane.fork.t.sol) | Integration against the **live** CCIP v2 lane Ethereum Sepolia → Arbitrum Sepolia |
| [workflows/countersign/](workflows/countersign/workflow.ts) | CRE workflow (TypeScript → WASM): verify, sweep, sentinel |
| [tools/executor/](tools/executor/src/execute.ts) | Permissionless executor: committee results from Chainlink's public indexer + Countersign attestation |
| [services/verifier-api/](services/verifier-api/src/handler.ts) | The standard CCIP v2 **CCV Verifier Result API** (`GET /v1/verifications`) |
| [scripts/testnet-e2e.sh](scripts/testnet-e2e.sh) | Full run on public testnets, no mocks |

Docs: [architecture](docs/ARCHITECTURE.md) · [security & threat model](docs/SECURITY.md) · [operations](docs/OPERATIONS.md) · [demo script](docs/DEMO_SCRIPT.md) · [funding plan & applications](docs/FUNDING.md) · [hackathon submission](docs/HACKATHON_SUBMISSION.md)

## Run it

Prerequisites: Foundry ≥ 1.8, Bun ≥ 1.3, Node ≥ 20, CRE CLI ≥ 1.35 (for simulation). On Windows, use Git Bash and a short checkout path (e.g. `C:\dev\countersign`): Foundry refuses `vm.readFile` on paths longer than about 255 characters.

```bash
make install
make test              # 99 tests: contracts (unit, fuzz, live forks), workflow, executor, API
make build-workflow    # cre-compile to WASM
```

End to end on the public testnets (real CCIP v2, real committee signatures, real attestation), after `cre login` and with a funded testnet-only key in `contracts/.env`:

```bash
bash scripts/testnet-e2e.sh                 # approve path
DEMO_HOLD=1 bash scripts/testnet-e2e.sh     # hold -> guardian release -> execute
```

`scripts/local-e2e.sh` runs the same flow on fresh anvil forks (it writes to `contracts/deployments-local/`, never over the testnet deployments). Arbitrum Sepolia defaults to the official `https://sepolia-rollup.arbitrum.io/rpc`: it serves the finalized block the workflow reads, which some public nodes (e.g. publicnode) do not.

## Live on public testnets

**[Demo video (2 min)](https://youtu.be/FKoKNaHxgg0)**

On October 3 and 4, 2026, 5,000 CST transfers went from Ethereum Sepolia to Arbitrum Sepolia over live CCIP v2 with no mocks. The OffRamp released them only with both Chainlink's committee signatures and Countersign's attestation. The attestations were written by `cre workflow simulate --broadcast`; a DON-hosted deployment awaits CRE deploy access.

**Approved transfer**

| Step | Transaction |
|---|---|
| `ccipSend` on Ethereum Sepolia | [0x033b…bf5e](https://sepolia.etherscan.io/tx/0x033b714f0809a5a3096f3deeb0cd2853654a1fd88c1d868c7b97e52b7a18bf5e) |
| CCIP message | [0xded3…6141](https://ccip.chain.link/msg/0xded350df86b2cb1132ed7ba96e58a1208a9d3385cf97c4d9ee0054f181fb6141) |
| Countersign attestation (APPROVED) on Arbitrum Sepolia | [0x69b5…6d78](https://sepolia.arbiscan.io/tx/0x69b54039d3ca13917c8197b72c8e1da0de47b2fff469ba64eb8439be2bcc6d78) |
| `OffRamp.execute` with committee + Countersign, mint on Arbitrum Sepolia | [0x26a9…344e](https://sepolia.arbiscan.io/tx/0x26a9fc9365360024b7821260e550481071dad4dd3ae38dd58c6703d6786e344e) |

**Held, reviewed and released** (`DEMO_HOLD=1`, receiver on the issuer's denylist)

| Step | Transaction |
|---|---|
| `ccipSend` on Ethereum Sepolia | [0x274c…f27a](https://sepolia.etherscan.io/tx/0x274c13c795b9060b7b8456e1d5aa944acdaa6c9883197ccb384bcc8d7853f27a) |
| Countersign attestation HELD (`POLICY_DENIED`); the executor refuses to execute | [0xc842…3ba7](https://sepolia.arbiscan.io/tx/0xc842ebc4339f36a53afd80a4fb520b3b3936eccaa922bb72134135e886043ba7) |
| Guardian `releaseHold` after review | [0x68c7…49c0](https://sepolia.arbiscan.io/tx/0x68c781945848b70f649a15b6bbc5d882c2ec8c7339ab3a57dff0d5efdd9549c0) |
| `OffRamp.execute`, mint on Arbitrum Sepolia | [0xbc7e…f99d](https://sepolia.arbiscan.io/tx/0xbc7ef802ca73bcf9168a69cec2fc006a854ffc598051759f9e96e484b2ebf99d) |

| Contract | Ethereum Sepolia | Arbitrum Sepolia |
|---|---|---|
| `CountersignVerifier` | [0x51f6…5163](https://sepolia.etherscan.io/address/0x51f6276886Cccf2fB716A522dd6aB4922Be15163) | [0x71e3…35Fb](https://sepolia.arbiscan.io/address/0x71e3485d56Cc80Fbe7B79188805c50FCE82C35Fb) |
| Resolver (the CCV the pool requires) | [0x24a9…333b](https://sepolia.etherscan.io/address/0x24a9eBeD8D228f275EFa77CEA586e94F831A333b) | [0x8c64…699d](https://sepolia.arbiscan.io/address/0x8c645c6DFAac49Bb03cf90D71aB388881dF2699d) |
| `BurnMintTokenPool` | [0x84C3…D829](https://sepolia.etherscan.io/address/0x84C3fFabb258503A27d58ddab7b1787Dce2bD829) | [0xb024…Aa35](https://sepolia.arbiscan.io/address/0xb0249Ba599064cdB34B172186DA065030326Aa35) |
| `RateLimitGuard` | [0xDc0a…271f](https://sepolia.etherscan.io/address/0xDc0a57d0F9853C22baC206E800ac4F7748DF271f) | [0x25A7…83a3](https://sepolia.arbiscan.io/address/0x25A7039bFcdc36b1Aa8426f4913B82D2CF0883a3) |
| CST token | [0xb264…1FA3](https://sepolia.etherscan.io/address/0xb264128bE526A1e780e4ea3D322EFf8A63251FA3) | [0x7578…Fd93](https://sepolia.arbiscan.io/address/0x757818b6057410e887b146b2933599260Cc2Fd93) |

## Status

- [x] Public testnet deployment, approved transfer and hold → guardian release on Sepolia → Arbitrum Sepolia (links above), demo video
- [x] Integration validated against live CCIP v2 (OnRamp/OffRamp 2.0.0) on Sepolia → Arbitrum Sepolia (5 fork tests)
- [x] Contracts: 46 unit and fuzz tests; chain-bound reports, simulation mode, anti-spam, onchain rolling windows
- [x] CRE workflow: 39 tests; verify, sweep and sentinel handlers within CRE quotas (15 reads, 100-block log queries)
- [x] Executor validated against real Sepolia messages and Chainlink's public CCIP indexer
- [x] Standard CCV Verifier Result API
- [ ] Production workflow deployment (CRE deploy access), external audit
- [ ] AI incident agent (read-only, proposes Safe transactions), Agent Skill

## License

MIT, except `CountersignVerifier.sol` (BUSL-1.1 derivative of CCIP v2 `BaseVerifier`; production use permitted by Additional Use Grant 3(c)). See [NOTICE](NOTICE).
