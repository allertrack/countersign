import { z } from 'zod'

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/, 'expected a 20-byte hex address')
const uintString = z.string().regex(/^\d+$/, 'expected a base-10 integer string')
/** CRE: PerWorkflow.ChainRead.LogQueryBlockLimit. */
const LOG_QUERY_BLOCK_LIMIT = 100
/** CRE: PerWorkflow.ChainRead.CallLimit. */
const CHAIN_READ_LIMIT = 15

const deployment = z.object({
	chainSelectorName: z.string(),
	token: address,
})

export const configSchema = z
	.object({
		/** Chains where Countersign-gated transfers originate. One log-trigger handler per source. */
		sources: z
			.array(
				z.object({
					chainSelectorName: z.string(),
					/** CountersignVerifier on this chain (emits CountersignRequested, keeps window counters). */
					verifier: address,
					/** Canonical CCIP v2 OnRamp(s) on this chain; the message must come from one of them. */
					onRamps: z.array(address).min(1),
				}),
			)
			.min(1)
			.max(5),
		/** Where attestations are written: the CountersignVerifier on each destination chain. */
		destinations: z
			.array(
				z.object({
					chainSelectorName: z.string(),
					verifier: address,
					gasLimit: uintString.default('400000'),
				}),
			)
			.min(1)
			.max(10),
		token: z.discriminatedUnion('mode', [
			z.object({
				mode: z.literal('burnMint'),
				deployments: z.array(deployment).min(1).max(8),
				/** Total supply across every chain (burn/mint keeps it constant). */
				canonicalSupply: uintString,
			}),
			z.object({
				mode: z.literal('lockRelease'),
				deployments: z.array(deployment).min(1).max(8),
				homeChainSelectorName: z.string(),
				/** LockBox (or pool) holding the locked tokens on the home chain. */
				lockBox: address,
			}),
		]),
		/** Optional Chainlink Proof of Reserve feed (Secure Mint check). */
		reserveFeed: z
			.object({
				chainSelectorName: z.string(),
				address,
				/** Decimals of the feed answer; the answer is rescaled to `tokenDecimals`. */
				decimals: z.number().int().min(0).max(36),
				tokenDecimals: z.number().int().min(0).max(36),
				/** Hold when the feed is older than this (set to the feed heartbeat plus margin). */
				maxAgeSeconds: z.number().int().positive(),
			})
			.optional(),
		policy: z.object({
			version: z.string().min(1),
			supplyTolerance: uintString.default('0'),
			/** Max Countersign-gated outflow per lane over the verifier's rolling window (2 epochs). */
			maxWindowOutflow: uintString.optional(),
			/** Max Countersign-gated transfers per sender over the same window. */
			maxTransfersPerSender: z.number().int().positive().optional(),
			denylist: z.array(address).default([]),
		}),
		/** Re-drive: attests Countersign requests that the log trigger missed. */
		sweep: z
			.object({
				schedule: z.string(),
				lookbackBlocks: z.number().int().positive().max(LOG_QUERY_BLOCK_LIMIT).default(LOG_QUERY_BLOCK_LIMIT),
				/** Keeps a run within CRE's 15 EVM reads (2 reads per swept message). */
				maxMessages: z.number().int().positive().max(4).default(4),
			})
			.optional(),
		/** Supply sentinel: freezes lanes through RateLimitGuard when the global invariant breaks. */
		sentinel: z
			.object({
				schedule: z.string(),
				guards: z
					.array(
						z.object({
							chainSelectorName: z.string(),
							guard: address,
							pools: z.array(
								z.object({
									pool: address,
									remoteChainSelectorNames: z.array(z.string()).min(1),
								}),
							),
							gasLimit: uintString.default('600000'),
						}),
					)
					.min(1)
					.max(10),
			})
			.optional(),
	})
	.superRefine((config, ctx) => {
		const supplyReads =
			config.token.deployments.length + (config.token.mode === 'lockRelease' ? 2 : 0) + (config.reserveFeed ? 1 : 0)
		// Log handler: supply reads + tx receipt + window usage.
		if (supplyReads + 2 > CHAIN_READ_LIMIT) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, message: `log handler needs ${supplyReads + 2} chain reads (> 15)` })
		}
		// Sweep: finalized header + filterLogs + one attestation read per destination + supply + 2 per message.
		const sweepReads = 2 + config.destinations.length + supplyReads + 2
		if (config.sweep && sweepReads > CHAIN_READ_LIMIT) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, message: `sweep needs at least ${sweepReads} chain reads (> 15)` })
		}
	})

export type Config = z.infer<typeof configSchema>
export type Source = Config['sources'][number]
