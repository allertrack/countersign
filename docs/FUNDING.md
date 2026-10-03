# Funding plan

Researched on 2026-09-22. Re-check each program's page before applying; programs change.

## Where the money is

| Route | Status (2026-09-22) | Fit | Amount |
|---|---|---|---|
| **Arbitrum Foundation Grant Program** ([arbitrum.foundation/grants](https://arbitrum.foundation/grants)) | Open, rolling, milestone-based. "Infrastructure & Tools" track. Not for idea-stage or pre-testnet projects. | Strong: Countersign protects CCIP tokens landing on Arbitrum; the live lane is Sepolia → Arbitrum Sepolia | $20k–$150k in ARB depending on track (per [grant summaries](https://grantedai.com/grants/arbitrum-foundation-grant-program-arbitrum-foundation-fbe19f67); confirm on the form) |
| **Arbitrum Audit Program** ([blog](https://blog.arbitrum.foundation/arbitrums-10m-audit-program-is-live-apply-to-secure-your-smart-contracts/)) | $10M ARB subsidy for third-party audits | Pays the audit needed before mainnet | Audit cost |
| **Chainlink Labs, direct** | Public grants page offline (`chain.link/grants` → 404). Build moved to commercial agreements paid in LINK ([Jun 26, 2026](https://chain.link/blog/build-program-evolution)) | Countersign drives CCIP 2.0 and CRE adoption and CRE fees | Negotiated (BD grant, co-marketing, CRE deploy access) |
| **Next Chainlink hackathon** | Not announced yet. Convergence 2026 paid $16k–$20k per track winner plus $1.5k to the top 10 ([prizes](https://chain.link/hackathon/prizes)) | Risk & Compliance or DeFi & Tokenization | $16k–$20k |
| **Token issuers (B2B)** | Issuers that moved to CCIP after April 2026: KelpDAO (rsETH), Kraken (kBTC), Mantle (MNT), Solv, Virtuals ([Q2 review](https://chain.link/blog/quarterly-review-q2-2026)) | Direct customers: Countersign is their second verifier | Pilot fee + per-transfer CCIP fee |
| **Protocol revenue** | Built in: `feeUSDCents` per gated transfer, paid by CCIP to the resolver | Recurring | Per transfer |
| Inkworks (Ink) | Forge closed; Inkworks cohort open, terms not public ([ink.works](https://ink.works)) | Possible (kBTC lives on CCIP) | Unknown |

## Sequence

| When | Action | Unlocks |
|---|---|---|
| Day 0–2 | `scripts/testnet-e2e.sh` on public testnets; record the demo ([DEMO_SCRIPT.md](DEMO_SCRIPT.md)); push the repo public; CI green | Every application below requires testnet + video |
| Day 2–4 | Apply to the Arbitrum Foundation (answers below). Apply to the Arbitrum Audit Program in parallel | First cash |
| Day 2–4 | Message Chainlink (template below); open the `cre-templates` PR | Visibility, CRE deploy access, BD path |
| Day 3–7 | Publish the technical write-up: "CCIP v2 rate limits refill on update: a tighten-only breaker" | Credibility with Chainlink engineers |
| Week 2–6 | Issuer outreach (template below), pilots | Revenue |
| Nov 1–2 | SmartCon, New York: demo in person | Deals |
| When announced | Chainlink hackathon with new modules (AI incident agent, Confidential Workflows, more lanes). Old code alone is not eligible | $16k–$20k |

## Arbitrum Foundation application (ready to paste)

**Project name:** Countersign

**One-liner:** A second, issuer-controlled verifier for Chainlink CCIP v2 token transfers into Arbitrum, run as a Chainlink CRE workflow, so a forged or unbacked bridge transfer has to fool two independent verifier networks.

**Problem.** On April 18, 2026, KelpDAO lost about $292M because its bridge accepted messages from a single verifier; 47% of active LayerZero apps used the same 1-of-1 setup. Issuers are moving to Chainlink CCIP (more than $7B migrated in Q2 2026), and CCIP v2 lets every token pool require extra verifiers. Almost nobody uses that: across 67 CCIP mainnets, only Circle and Lombard run their own verifier, because a verifier means servers, databases and signing keys.

**Solution.** Countersign is an open-source Cross-Chain Verifier whose offchain half is a Chainlink Runtime Environment workflow, so issuers run no infrastructure. For every transfer above a threshold it independently checks the source burn at finality, the cross-chain supply invariant, Proof of Reserve, rolling outflow windows and sender velocity, and writes a DON-signed attestation on the destination chain. The Arbitrum token pool refuses to mint without it. A supply sentinel freezes lanes through a tighten-only rate-limit guard if supply ever becomes unbacked. It plugs into CCIP v2's standard extension points: CCV interface, threshold CCVs in token pools, the CCV Verifier Result API.

**Why Arbitrum.** Arbitrum is a primary destination for CCIP-bridged assets. Every protected transfer ends in an Arbitrum transaction (attestation plus execution), and the reference deployment and tests target the live CCIP v2 lane into Arbitrum Sepolia.

**Stage and traction.** Working testnet system: contracts, CRE workflow, executor and verifier API; 99 automated tests including integration tests against the live CCIP v2 contracts on Sepolia → Arbitrum Sepolia; a live end-to-end transfer on public testnets ([transactions](https://github.com/allertrack/countersign#live-on-public-testnets)). Repository: https://github.com/allertrack/countersign.

**Milestones** (adjust amounts to the track on the form):

| # | Deliverable | Verification | Amount |
|---|---|---|---|
| 1 | Countersign live on Arbitrum Sepolia with two inbound lanes (Ethereum Sepolia, Base Sepolia); hosted CCV Verifier Result API; public dashboard of attestations; operator docs | Public addresses, API URL, dashboard, CI green | $15,000 |
| 2 | External security audit (via the Arbitrum Audit Program) and fixes; Arbitrum One deployment for one pilot token with a real issuer | Audit report, mainnet addresses, pilot announcement | $25,000 |
| 3 | One-command onboarding for any CCIP token on Arbitrum (`countersign init` CLI + Agent Skill); monitoring and alerting for guardians | Published package, 3 external tokens onboarded on testnet | $15,000 |

**Budget:** $55,000 in ARB over 3 months: engineering 70%, infrastructure and RPC 10%, audit remediation 10%, docs and onboarding 10%.

**KPIs:** tokens protected; value secured by Countersign-gated pools on Arbitrum; transfers attested; mean time from source finality to attestation; holds raised and resolved.

**Team:** `<names, GitHub, previous work>`.

## Message to Chainlink Labs (CCIP / CRE DevRel)

> Subject: Countersign: an issuer CCV for CCIP v2 built on CRE (open source, testnet live)
>
> Hi <name>, we built Countersign, a Cross-Chain Verifier for CCIP v2 whose offchain component is a CRE workflow, so token issuers can require their own verification on top of the committee without running verifier infrastructure. It uses threshold CCVs in `AdvancedPoolHooks`, stores DON-signed attestations through the KeystoneForwarder, serves the CCV Verifier Result API, and includes a tighten-only `rateLimitAdmin` for v2 pools. Live on Sepolia → Arbitrum Sepolia, 99 tests including fork tests against the v2 contracts. Repo: <link>. Demo: <link>.
>
> Two things we noticed while building it that may help other integrators: (1) `RateLimiter._setTokenBucketConfig` refills the bucket to full capacity on every update, so an automated breaker that "lowers" limits during a drain can hand the attacker a fresh bucket; our guard clamps to the live token count. (2) The `MockKeystoneForwarder` sends no metadata, so receivers that pin a workflow identity cannot be simulated; we added an explicit simulation mode.
>
> We would like to (a) contribute a starter template to `cre-templates`, (b) get CRE deploy access for a production pilot, (c) have the CCIP indexer poll our verifier API, and (d) explore support through Chainlink's ecosystem programs. Happy to demo at SmartCon.

## `cre-templates` pull request

Contributions are welcome per the repo README (fork, add under `starter-templates/`, include a README, open a PR). Their CI runs YAML validation, `bun install`, typecheck and `bunx cre-compile main.ts`, the same steps as our CI.

1. Fork `smartcontractkit/cre-templates`; create `starter-templates/issuer-verifier-ccip/issuer-verifier-ccip-ts/` with `workflow.yaml`, `project.yaml`, `main.ts`, `workflow.ts`, `src/`, `config.staging.json`, `package.json`, `tsconfig.json`, and a `contracts/` folder with the verifier, guard and deploy script.
2. Add `starter-templates/issuer-verifier-ccip/README.md` (what it does, prerequisites, simulate, deploy).
3. Run `./scripts/check-templates.sh --verbose` locally, then open the PR, linking this repo and the demo.

## Message to issuers

> Subject: A second verifier for <TOKEN> on CCIP, no infrastructure
>
> Since the April bridge exploits, "defense in depth" is the question every bridged-asset issuer gets. CCIP v2 lets <TOKEN>'s pool require your own verifier next to Chainlink's committee, only above the amount you choose. Countersign is that verifier, run on Chainlink CRE: every large transfer is checked against your supply across chains, your Proof of Reserve and your limits before it can mint, and a sentinel freezes lanes if supply ever breaks. No servers, no keys to manage, open source, paid per protected transfer through CCIP's own fee mechanism. 15-minute demo on testnet: <link>. Pilot on testnet this month, mainnet after audit.

## Pricing (proposal)

- Pilot: fixed fee for integration and testnet rollout.
- Production: `feeUSDCents` per gated transfer (for example $1–$5 on transfers above the threshold), collected by CCIP into the resolver, plus an optional monthly SLA for guardian support and monitoring.
