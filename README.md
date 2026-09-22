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
make test              # 96 tests: contracts (unit, fuzz, live forks), workflow, executor, API
make build-workflow    # cre-compile to WASM
```

End to end on the public testnets (real CCIP v2, real committee signatures, real attestation), after `cre login` and with a funded testnet-only key in `contracts/.env`:

```bash
bash scripts/testnet-e2e.sh                 # approve path
DEMO_HOLD=1 bash scripts/testnet-e2e.sh     # hold -> guardian release -> execute
```

`scripts/local-e2e.sh` runs the same flow on fresh anvil forks (it writes to `contracts/deployments-local/`, never over the testnet deployments). Arbitrum Sepolia defaults to the official `https://sepolia-rollup.arbitrum.io/rpc`: it serves the finalized block the workflow reads, which some public nodes (e.g. publicnode) do not.

## Status

- [x] Integration validated against live CCIP v2 (OnRamp/OffRamp 2.0.0) on Sepolia → Arbitrum Sepolia (5 fork tests)
- [x] Contracts: 46 unit and fuzz tests; chain-bound reports, simulation mode, anti-spam, onchain rolling windows
- [x] CRE workflow: 36 tests; verify, sweep and sentinel handlers within CRE quotas (15 reads, 100-block log queries)
- [x] Executor validated against real Sepolia messages and Chainlink's public CCIP indexer
- [x] Standard CCV Verifier Result API
- [ ] Public testnet deployment + recorded demo (one command: `scripts/testnet-e2e.sh`)
- [ ] Production workflow deployment (CRE deploy access), external audit
- [ ] AI incident agent (read-only, proposes Safe transactions), Agent Skill

## License

MIT, except `CountersignVerifier.sol` (BUSL-1.1 derivative of CCIP v2 `BaseVerifier`; production use permitted by Additional Use Grant 3(c)). See [NOTICE](NOTICE).
