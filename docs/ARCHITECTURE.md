# Architecture

Countersign plugs into three extension points that CCIP v2 and CRE already expose. It forks nothing and wraps nothing.

| Extension point | Provided by | Countersign uses it for |
|---|---|---|
| `ICrossChainVerifierV1` + `VersionedVerifierResolver` | CCIP v2 (`contracts-ccip` 2.0.0) | `CountersignVerifier`, fronted by a resolver so the address never changes |
| `AdvancedPoolHooks` threshold CCVs | CCIP v2 token pools | Require Countersign only at or above an amount, in both directions |
| `TokenPool.rateLimitAdmin` | CCIP v2 token pools | `RateLimitGuard`, the sentinel's tighten-only circuit breaker |
| EVM log trigger, cron trigger, EVM read/write, DON time | CRE | The `countersign` workflow |
| `KeystoneForwarder` → `IReceiver.onReport` | CRE | Authenticated delivery of attestations and tightenings |
| CCV Verifier Result API (`GET /v1/verifications`) | CCIP v2 indexer contract | `services/verifier-api`, so Chainlink's indexer can discover Countersign |

## Message lifecycle

1. **Send.** A user calls `ccipSend` for the issuer's token. The pool's hooks return `[committee]` below the threshold and `[committee, countersign]` at or above it (`AdvancedPoolHooks.thresholdOutboundCCVs`). The OnRamp calls `CountersignVerifier.forwardToVerifier`, which:
   - only accepts calls from the router's OnRamp for that lane (`BaseVerifier._assertSenderIsAllowed`);
   - rejects messages that are not a transfer of a *verified token* (anyone can name any CCV in `extraArgs`; this keeps third parties from flooding the workflow, whose log trigger is rate-limited to 10 events per 6 s);
   - adds the amount to the lane's rolling window and increments the sender's counter (epochs of `s_windowEpoch`, default 1 h; the window is the current plus previous epoch);
   - emits `CountersignRequested(messageId, destChainSelector, messageNumber, encodedMessage)`.
2. **Verify.** When the source block is **finalized**, CRE fires the workflow's log trigger. The handler:
   - decodes the MessageV1 wire format and recomputes `messageId = keccak256(encodedMessage)`;
   - checks the decoded source/destination selectors against the lane;
   - checks that the canonical OnRamp emitted `CCIPMessageSent` for that `messageId` in the **same transaction** (`getTransactionReceipt`);
   - reads the supply snapshot (source chain at the event's block, other chains at their finalized head), the Proof of Reserve feed and the window counters (at the event's block);
   - evaluates the policy and writes `abi.encode(uint64 destChainSelector, Attestation[])` to the destination verifier through the Forwarder, then checks `receiverContractExecutionStatus` (the Forwarder does not revert when the receiver does).
3. **Execute.** Anyone calls `OffRamp.execute(encodedMessage, ccvs, verifierResults, 0)`. For Countersign, `verifierResults` is just the 4-byte version tag `0xc5160001`; the proof is the attestation already stored onchain. The committee's results come from Chainlink's indexer. `tools/executor` does this with public data only.

## Supply invariant

One inequality covers both pool designs: `circulating + inFlight <= backing (+ tolerance)`.

| Pool design | circulating | backing |
|---|---|---|
| Burn/mint | `totalSupply` summed over every chain | canonical supply (config) |
| Lock/release | `totalSupply` summed over remote chains | LockBox balance on the home chain |

When a message is verified its burn (or lock) is already included and its mint (or release) is not, so the in-flight amount is added once. The sentinel runs the same check with `inFlight = 0`. Because CCIP executes only after source finality and Countersign reads finalized state, a mint is never visible before its burn. Tokens that allow **faster-than-finality** transfers below the threshold must set `supplyTolerance` to at least the FTF rate-limit capacity (see [SECURITY.md](SECURITY.md)).

Proof of Reserve (optional): `liability + inFlight <= reserve`, and the feed's `updatedAt` must be within `maxAgeSeconds` of DON time (`runtime.now()`).

## Reports

| Receiver | Payload | Replay protection |
|---|---|---|
| `CountersignVerifier` | `abi.encode(uint64 chainSelector, (bytes32 messageId, uint64 sourceChainSelector, uint8 verdict, uint32 reasonCodes, bytes32 evidenceHash)[])` | Chain selector checked in `CREReceiverBase`; state machine only moves forward or tighter |
| `RateLimitGuard` | `abi.encode(uint64 chainSelector, uint64 issuedAt, (address pool, uint64 remoteChainSelector, bool fastFinality, Config outbound, Config inbound, bytes32 evidenceHash)[])` | Chain selector; `issuedAt` (the cron slot time) must strictly increase |

Both follow the CRE guidance on [cross-chain and same-chain replay](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts#replay-attacks). The `evidenceHash` commits to every input of the decision, so an auditor can recompute it from chain history.

Reason codes (bitmask, `CountersignCodes.sol` / `src/codes.ts`): `SOURCE_EVENT_NOT_FINAL`, `MESSAGE_ID_MISMATCH`, `SUPPLY_INVARIANT_BREACH`, `RESERVE_SHORTFALL`, `WINDOW_LIMIT_EXCEEDED`, `VELOCITY_ANOMALY`, `POLICY_DENIED`, `MANUAL_REVIEW`, `RESERVE_STALE`, `MALFORMED_MESSAGE`.

## Workflow handlers and CRE quotas

The workflow respects the published [CRE service quotas](https://docs.chain.link/cre/service-quotas); the config schema rejects settings that would exceed them.

| Handler | Trigger | EVM reads | Writes |
|---|---|---|---|
| `onCountersignRequested` | EVM log, `FINALIZED`, one per source chain | supply (N) + reserve (0/1) + receipt + window | 1 (destination verifier) |
| `onSweep` | cron | finalized header + `filterLogs` (≤ 100 blocks) + 1 per destination + supply + 2 per message (≤ 4 messages) | 1 per destination with gaps |
| `onSentinel` | cron | supply (N) + reserve | 1 per guard chain, isolated failures |

- `PerWorkflow.ChainRead.CallLimit` = 15 reads per execution.
- `ChainRead.LogQueryBlockLimit` = 100 blocks. That is why the rolling window lives onchain in the verifier (100 blocks is 25 s on Arbitrum).
- `LogTrigger.EventRateLimit` = 10 per 6 s. Hence the source-side anti-spam.
- `ChainWrite.EVM.TransactionGasLimit` = 10,000,000 gas per write. Write limits are sized for Glamsterdam pricing ([operations](OPERATIONS.md#5-ethereum-glamsterdam-gas-repricing)).
- The sweep picks one source per run from a hash of the cron slot, so every source is reached whatever the interval.

## Why the attestation is stored onchain

`verifyMessage` could instead verify DON signatures carried in `verifierResults`. Storing the attestation through the Forwarder is simpler and stronger:
- signature and quorum checks stay in Chainlink's audited `KeystoneForwarder`;
- attestations are public, auditable state with events;
- a guardian can hold or release a message before execution;
- the executor needs no Countersign-specific data beyond a 4-byte tag.

The cost is one destination transaction per gated transfer, which is why Countersign is required only above a threshold.

## Deployment topology (per chain)

`BurnMintERC20` (or the issuer's token) · `BurnMintTokenPool`/`LockReleaseTokenPool` v2 · `AdvancedPoolHooks` (threshold, optional ACE `PolicyEngine`) · `CountersignVerifier` · `VersionedVerifierResolver` (fee aggregator = treasury) · `RateLimitGuard` (pool `rateLimitAdmin`). One `countersign` workflow serves every chain.
