# Hackathon submission kit

Built to the requirements of Chainlink's CRE hackathons (Convergence 2026): a CRE workflow used as an orchestration layer that integrates a blockchain with an external system, a successful simulation or deployment, a public 3–5 minute video, public source code, and a README linking every file that uses Chainlink.

**Eligibility.** Chainlink hackathons only accept work done during the event unless a pre-existing project receives substantial updates. Enter with new modules built during the event (for example the AI incident agent, Confidential Workflows policy-as-secrets, or new lanes and chains) and describe them as the event's contribution.

**Tracks.** Risk & Compliance (primary), DeFi & Tokenization (secondary).

## Short description (≤ 280 characters)

Countersign: an issuer-run Cross-Chain Verifier for CCIP v2 built on CRE. Every large transfer is re-checked (finality, cross-chain supply, Proof of Reserve, limits) and needs a DON-signed attestation before the pool mints. Two verifier networks, zero servers.

## How it uses Chainlink

| Chainlink product | Where | Role |
|---|---|---|
| **CRE**: EVM log trigger (FINALIZED), cron triggers, EVM read, EVM write, DON time, report signing | [workflows/countersign/workflow.ts](../workflows/countersign/workflow.ts), [src/chain.ts](../workflows/countersign/src/chain.ts), [src/observe.ts](../workflows/countersign/src/observe.ts) | Verification, re-drive sweep, supply sentinel |
| **CRE**: `KeystoneForwarder` → `IReceiver` | [contracts/src/cre/CREReceiverBase.sol](../contracts/src/cre/CREReceiverBase.sol) | Authenticated, chain-bound report delivery |
| **CCIP v2**: `ICrossChainVerifierV1`, `BaseVerifier`, `VersionedVerifierResolver` | [contracts/src/CountersignVerifier.sol](../contracts/src/CountersignVerifier.sol) | The Countersign CCV |
| **CCIP v2**: token pools, `AdvancedPoolHooks` threshold CCVs, `TokenAdminRegistry` | [contracts/script/Countersign.s.sol](../contracts/script/Countersign.s.sol) | Cross-Chain Token that requires Countersign above a threshold |
| **CCIP v2**: `TokenPool.rateLimitAdmin`, `RateLimiter` | [contracts/src/RateLimitGuard.sol](../contracts/src/RateLimitGuard.sol) | Tighten-only circuit breaker |
| **CCIP v2**: OnRamp / OffRamp / Router (live testnets) | [contracts/test/fork/CountersignLane.fork.t.sol](../contracts/test/fork/CountersignLane.fork.t.sol) | Integration tests against the live lane |
| **CCIP v2**: public indexer, `OffRamp.execute` | [tools/executor/src/execute.ts](../tools/executor/src/execute.ts) | Permissionless execution with committee results |
| **CCIP v2**: CCV Verifier Result API | [services/verifier-api/src/handler.ts](../services/verifier-api/src/handler.ts) | Standard discovery endpoint for Countersign |
| **Data Feeds / Proof of Reserve** | [workflows/countersign/src/observe.ts](../workflows/countersign/src/observe.ts) (`readReserve`) | Secure Mint check with staleness |
| **ACE** (optional) | `POLICY_ENGINE` in [Countersign.s.sol](../contracts/script/Countersign.s.sol) | Attach an ACE PolicyEngine to the pool hooks |

## Long description

**Problem.** Bridge exploits keep coming from single points of verification: KelpDAO lost about $292M in April 2026 through a 1-of-1 verifier setup. CCIP v2 lets token pools require additional verifiers (CCVs), but running one means operating nodes, databases and keys, so almost no issuer does.

**What we built.** A CCV whose offchain half is a CRE workflow. The token pool requires it above a threshold. For each gated transfer the workflow waits for source finality, confirms the canonical OnRamp emitted the message in the same transaction, recomputes the message id, checks the cross-chain supply invariant, Proof of Reserve (with staleness), an onchain rolling window and sender velocity, and writes a DON-signed attestation to the destination verifier. The OffRamp cannot execute without it. A sweep re-drives anything the trigger missed, and a sentinel freezes lanes through a tighten-only rate-limit guard when supply becomes unbacked.

**What is new.** The first CCV built on CRE; issuer-defined checks enforced per message instead of monitored after the fact; a clamp-only rate-limit admin that avoids CCIP v2's refill-on-update footgun; the standard CCV Verifier Result API; an executor that works from public data only.

**Proof.** 99 automated tests, including fork tests against the live CCIP v2 OnRamp/OffRamp on Sepolia → Arbitrum Sepolia; a live end-to-end transfer on public testnets ([transactions](https://github.com/allertrack/countersign#live-on-public-testnets)); video: https://youtu.be/FKoKNaHxgg0.

## Checklist

- [ ] Repo public, CI green
- [x] `scripts/testnet-e2e.sh` run on public testnets; transaction links in the README
- [x] `DEMO_HOLD=1` run on public testnets
- [x] Video (2 min): https://youtu.be/FKoKNaHxgg0
- [ ] Event-period changes listed in the submission
