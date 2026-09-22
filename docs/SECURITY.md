# Security model

Status: **unaudited**. Do not use on mainnet before an external audit.

## What Countersign guarantees

For a token whose pool requires Countersign at or above a threshold, a mint or release above the threshold happens only if **both**:
1. Chainlink's committee verified the message (default CCVs, `address(0)` in the pool config), and
2. the issuer's CRE workflow attested it as APPROVED on the destination chain, and no guardian holds it.

An attacker must therefore compromise two independent verifier networks, not one. Compromising Countersign alone (workflow, owner key, forwarder config) cannot forge a transfer; it can only delay transfers above the threshold.

## Trust assumptions

| Component | Trusted for | If compromised |
|---|---|---|
| Chainlink committee DON | Message authenticity (baseline CCIP) | Countersign still blocks unbacked or unattested transfers above the threshold |
| CRE workflow DON + `KeystoneForwarder` | Signing attestations (F+1 of the DON) | Can approve messages the committee also signs, or hold transfers (liveness only) |
| Workflow owner (identity in `CREReceiverBase`) | Which workflow may report | Same as above; production should pin `workflowOwner` + `workflowName` |
| Contract owner (issuer multisig) | Config, unpause, identity | Can change identity or resolver implementation; cannot bypass the committee |
| Guardian (issuer multisig) | Releasing held messages, pausing | Can release a held message it should not (the committee is still required) |
| Pool owner | Token pool config, including which CCVs are required | Already has mint authority over the token; out of scope |

## Threats considered

| Threat | Mitigation | Test |
|---|---|---|
| Forged message with no source burn (KelpDAO pattern) | No `CountersignRequested` on source → no attestation → `MessageNotAttested` | fork: `test_AboveThreshold_RequiresCountersignAndExecutesOnceApproved` |
| Unbacked supply on some chain | Invariant `circulating + inFlight <= backing` → HELD; sentinel freezes lanes | `holds when unbacked tokens appear…`, sentinel tests |
| Workflow tricked into loosening a hold | State machine: HELD → APPROVED only via guardian | `testFuzz_WorkflowNeverLoosensHold` |
| Report replayed on another chain | Chain selector in every report, checked onchain | `test_onReport_RevertWhen_ReportTargetsAnotherChain`, guard equivalent |
| Stale tightening replayed after a revert | Monotonic `issuedAt` in `RateLimitGuard` | `test_RevertWhen_ReplayedOrStaleReport` |
| Report from another workflow through the same Forwarder | `workflowOwner` (+ `workflowName`) / `workflowId` checks; empty identity rejects all | `test_onReport_RevertWhen_*` |
| Rate-limit update refilling a drained bucket | Clamp to live tokens, never raise rate, never disable | `test_ClampsToLiveTokens_AfterDrain`, `testFuzz_clamp_NeverLoosens` |
| Log-trigger flooding by naming the CCV in extraArgs | Source only accepts transfers of verified tokens | fork: `test_StrangerNamingCountersignForAnotherToken_Reverts` |
| Reorg of the source burn | Log trigger at `FINALIZED`; source reads at the event block | `reads source-chain state at the event block…` |
| Receiver reverts behind a successful Forwarder tx | Workflow checks `receiverContractExecutionStatus` and fails loudly; the sweep re-drives | `fails loudly when the receiver reverts…` |
| Missed trigger (outage, quota backlog) | Cron sweep attests unattested requests from the last 100 blocks | sweep tests |
| Burst draining just under limits | Onchain rolling window and per-sender velocity → HELD | `holds bursts using the onchain rolling window` |
| Stale or short Proof of Reserve | `RESERVE_STALE` / `RESERVE_SHORTFALL` against DON time | PoR test |
| One chain's freeze failing | Sentinel writes each guard independently, then reports failures | `a failing guard write does not stop…` |

## Known limitations and operator guidance

- **Held messages wait for a human.** CCIP v2 has no refund path for an unexecuted message: tokens burned on the source stay burned until the guardian releases the hold. Define a review SLA. Holds are the intended outcome for an exploit.
- **Faster-than-finality (FTF).** If the pool allows FTF below the threshold, a mint can briefly appear before its burn is finalized. Set `supplyTolerance` to at least the FTF rate-limit capacity, or the sentinel may freeze lanes on a false positive. Countersign's own verifier accepts only finalized messages (`s_allowedFinalityConfig` is the default wait-for-finality).
- **Simulation mode.** `trustForwarderOnly` accepts any workflow the forwarder delivers. It exists only because the CRE `MockKeystoneForwarder` sends no metadata. Deployments pointing at a production `KeystoneForwarder` must use an owner (+ name) or id identity. The contract emits a `SecurityWarning` whenever the flag is set.
- **Report-to-receiver binding.** CRE signatures do not commit to the receiver. A report could be delivered to another Countersign receiver on the same chain with the same workflow identity. That is harmless: attestations are keyed by messageId (which commits to the destination OffRamp and token pool), and tightenings name pools the other guard does not manage. Use one workflow identity per issuer.
- **Liveness depends on CRE.** If the workflow is down, transfers above the threshold wait; below-threshold transfers are unaffected. The sweep recovers automatically once CRE is back.
- **Sentinel granularity.** A breach freezes every configured lane (both finality buckets). Unfreezing is a deliberate owner action on the pool.
- **Supply reads.** The per-message check reads other chains at their finalized head. A mint that is not finalized yet is not counted, which errs toward approving; the sentinel catches the excess once finalized.

## Reporting a vulnerability

Please report privately to the maintainers before any public disclosure.
