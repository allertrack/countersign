# Operations

## 1. Public testnet in one command

1. Create a **fresh testnet-only** wallet (`cast wallet new`), put its key in `contracts/.env` (`cp contracts/.env.example contracts/.env`). Never reuse a key that holds real funds.
2. Fund it on [faucets.chain.link](https://faucets.chain.link): ≥ 0.05 Sepolia ETH and ≥ 0.01 Arbitrum Sepolia ETH. Deploying on Sepolia after Glamsterdam (2026-10-06) needs ≥ 0.3 Sepolia ETH instead (see section 5).
3. `cre login` once.
4. `bash scripts/testnet-e2e.sh` (or `DEMO_HOLD=1 bash scripts/testnet-e2e.sh`).

The script deploys (or reuses) the stack on both chains with the CRE simulation forwarders, sends 5,000 CST, waits for Sepolia finality, runs `cre workflow simulate --broadcast` (which writes a real attestation on Arbitrum Sepolia), and executes the message with `tools/executor` using the committee's signatures from Chainlink's public indexer. It prints the Etherscan, Arbiscan and [CCIP Explorer](https://ccip.chain.link) links. Add `ETHERSCAN_API_KEY` to `.env` to verify the contracts.

## 2. Production checklist

| Step | How |
|---|---|
| Deploy with the production forwarder | `CRE_FORWARDER=<KeystoneForwarder>` (e.g. Ethereum Sepolia `0xF8344CFd5c43616a4366C34E3EEE75af79a74482`, Arbitrum Sepolia `0x76c9cf548b4179F8901cda1f8623568b58215E62`; full list in the [forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts)). Do **not** set `CRE_SIMULATION`. |
| Pin the workflow identity | `CRE_WORKFLOW_OWNER=<owner>` and `CRE_WORKFLOW_NAME=countersign` (the name is encoded like `ReceiverTemplate.setExpectedWorkflowName`). Optionally `setWorkflowIdentity` with the exact `workflowId` after deployment. |
| Get CRE deploy access | `cre account access`, then `cre workflow deploy ./countersign -T <target>` with a production config. |
| Hand over roles | `transferOwnership` (2-step) of verifier, resolver, hooks, pool and guard to the issuer multisig; `setGuardian(<multisig>)`. |
| Pool config | `AdvancedPoolHooks`: threshold, `[address(0)]` base CCVs, `[resolver]` threshold CCVs, inbound and outbound. Keep rate limits enabled. |
| Fees (revenue) | `CCV_FEE_USD_CENTS` at connect time, or `applyRemoteChainConfigUpdates` later. Fees accrue in the resolver; anyone can call `resolver.withdrawFeeTokens([token])` to send them to the treasury (`setFeeAggregator`). |
| Monitoring | Watch `AttestationRecorded`, `AttestationRevoked`, `HoldPlaced`, `HoldReleased`, `RateLimitTightened`, `TighteningRejected`, `SecurityWarning`. |
| Standard CCV API | Host `services/verifier-api` and set its URL with `updateStorageLocations` so the CCIP indexer can discover Countersign. |

## 3. Guardian playbook

```bash
# Inspect a message
cast call $VERIFIER "getAttestation(bytes32)((uint64,uint8,uint32,uint40,bytes32))" $MESSAGE_ID --rpc-url $RPC
# verdict: 0 NONE, 1 APPROVED, 2 HELD. reasonCodes: see docs/ARCHITECTURE.md

# Release after review (records the hash of your review notes)
cast send $VERIFIER "releaseHold(bytes32,bytes32)" $MESSAGE_ID $(cast keccak "<review notes>") --rpc-url $RPC

# Hold proactively (e.g. a source chain incident)
cast send $VERIFIER "placeHold(bytes32,uint64,bytes32)" $MESSAGE_ID $SOURCE_SELECTOR $(cast keccak "<reason>") --rpc-url $RPC

# Emergency: stop new Countersign-gated sends and all verification (owner unpauses)
cast send $VERIFIER "pause()" --rpc-url $RPC

# Execute anything that is ready (permissionless)
cd tools/executor && bun src/cli.ts --source ethereum-testnet-sepolia --tx $SOURCE_TX --wait
```

After a sentinel freeze, investigate, then restore rate limits as the pool owner (`setRateLimitConfig`). The guard can never do that.

## 4. Tuning

| Setting | Where | Guidance |
|---|---|---|
| Threshold | `AdvancedPoolHooks.setThresholdAmount` | Above typical retail size; every gated transfer costs one attestation transaction |
| `maxWindowOutflow`, `maxTransfersPerSender` | workflow config | Size to a normal day; the window is 1–2 × `s_windowEpoch` |
| `setWindowEpoch` | verifier | 1 h default; changing it resets counters |
| `supplyTolerance` | workflow config | 0 for burn/mint without FTF; ≥ FTF capacity otherwise |
| `reserveFeed.maxAgeSeconds` | workflow config | Feed heartbeat plus margin |
| Sweep schedule | workflow config | Every 2–5 min; at most 4 messages per run |
| Sentinel schedule | workflow config | Every 1–5 min (CRE minimum is 30 s) |
| Write `gasLimit` | workflow config | Defaults: 2,000,000 per attestation report; 1,500,000 + 500,000 per extra lane per guard (enforced). CRE caps a write at 10,000,000 |

## 5. Ethereum Glamsterdam (gas repricing)

Glamsterdam reprices state on Ethereum L1 ([EIP-8037](https://eips.ethereum.org/EIPS/eip-8037), [EIP-8038](https://eips.ethereum.org/EIPS/eip-8038)): a new storage slot goes from 22,100 to about 110,000 gas, a storage update from 2,900 to 10,100, and deployed code from 200 to 1,530 gas per byte. Sepolia forks on 2026-10-06 13:53:36 UTC; Hoodi and mainnet follow in Q4 2026. Arbitrum is not affected.

Measured on the full CRE write path (real `KeystoneForwarder.report` with 2–6 DON signatures), plus the new prices applied to the storage each write creates:

| Write | New slots | Gas today | Gas after Glamsterdam | Default limit |
|---|---|---|---|---|
| Attestation report, 1 message (log trigger) | 3 | 178k–216k | ~445k–485k | 2,000,000 |
| Attestation report, 4 messages (sweep) | 9 | 332k–374k | ~1.12M–1.17M | 2,000,000 |
| Sentinel freeze, 1 lane (2 buckets) | 4 (+4 updated) | 277k–316k | ~660k–700k | 1,500,000 |

The former limits (400,000 and 600,000) fail after the fork in all three cases. Foundry's own Amsterdam model gives figures up to 30% higher; the defaults cover both. Unused gas is not charged.

- **Deploy before the fork if you can.** Deploying the stack on Sepolia goes from ~16M to ~123M gas of code deposit alone (~0.02 → ~0.15 ETH at 1 gwei).
- **Foundry:** `forge script` simulates with pre-Glamsterdam prices unless given `--hardfork amsterdam`, and its gas limits then run out on chain. `scripts/testnet-e2e.sh` adds the flag to Sepolia transactions once Sepolia's latest block is past the fork time.
- **Transition window (±30 min around the fork):** CRE writes to the forking chain may fail. Do not send gated transfers in that window. The sweep only reaches the last 100 blocks (~20 min on Ethereum); for an older message still at `NONE`, the guardian reviews it and approves it with `placeHold` followed by `releaseHold`.
