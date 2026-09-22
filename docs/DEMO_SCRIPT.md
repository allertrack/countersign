# Demo video (4 minutes)

Record after running `scripts/testnet-e2e.sh` once (so the stack exists), then run `DEMO_HOLD=1 bash scripts/testnet-e2e.sh` on camera. Chainlink hackathons require a public 3–5 minute video that shows the CRE workflow executing.

| Time | Screen | Say |
|---|---|---|
| 0:00–0:25 | KelpDAO headline, then the README diagram | "April 2026: $292M lost because a bridge trusted one verifier. CCIP v2 lets every token require its own verifier on top of Chainlink's committee, yet almost nobody runs one, because it means running infrastructure. Countersign is that verifier, as a Chainlink CRE workflow." |
| 0:25–0:50 | `AdvancedPoolHooks` config in `Countersign.s.sol` (`_connectHooks`) | "Below 1,000 tokens, Chainlink's committee is enough. At or above, the pool also requires Countersign, in both directions. That is native CCIP v2, no fork." |
| 0:50–1:20 | Terminal: step 2, `ccipSend` of 5,000 CST, the CCIP Explorer link | "A real transfer on the live CCIP v2 lane from Ethereum Sepolia to Arbitrum Sepolia. Our verifier contract recorded it and emitted the event that triggers the workflow." |
| 1:20–2:10 | Step 4: `cre workflow simulate` output: the workflow log line with circulating, backing, window, then `HELD [POLICY_DENIED]` | "Once the source block is final, CRE runs the workflow. It checks the OnRamp event in the same transaction, recomputes the message id, reads supply on both chains, Proof of Reserve and the rolling window, then writes a DON-signed attestation on Arbitrum. For the demo the receiver is on the denylist, so the verdict is HOLD." |
| 2:10–2:40 | Step 4b: executor refusing, then `releaseHold` | "The executor refuses: the pool will not mint without Countersign. Only the issuer's guardian multisig can release a hold. The workflow itself can never loosen anything." |
| 2:40–3:20 | Step 5: executor fetching committee signatures from Chainlink's indexer, execution SUCCESS, CST balance on Arbitrum, Arbiscan events | "Execution is permissionless: committee signatures come from Chainlink's public indexer, Countersign's proof is already onchain. Two independent verifier networks agreed, so the tokens are minted." |
| 3:20–3:45 | `RateLimitGuard.sol` doc comment, then `test_ClampsToLiveTokens_AfterDrain` passing | "If supply ever breaks, the sentinel freezes the lanes. CCIP v2 refills a bucket when you change its limits; a naive breaker would hand an attacker a fresh bucket. Our guard clamps to what is left." |
| 3:45–4:00 | `make test` summary (96 passing) and the repo URL | "Open source, 96 tests including live CCIP v2 fork tests, zero servers for the issuer. Countersign: make every bridge transfer need a second signature." |

Tips: 1080p, terminal font 16+, cut the finality wait (about 13 minutes on Sepolia), show transaction links on screen.
