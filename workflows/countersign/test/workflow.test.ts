import { describe, expect } from 'bun:test'
import type { CronPayload } from '@chainlink/cre-sdk'
import { newTestRuntime, test } from '@chainlink/cre-sdk/test'
import { type Hex, decodeAbiParameters, keccak256, toHex } from 'viem'
import { attestationReportParams, tighteningReportParams } from '../src/abi'
import { Reason, Verdict } from '../src/codes'
import { type Config, configSchema } from '../src/config'
import { onCountersignRequested, onSentinel, onSweep, sweepSourceIndex } from '../workflow'
import { GOLDEN } from './fixtures'
import { type ChainState, asTriggerLog, countersignLog, onRampLog, wireChain } from './harness'

const E18 = 10n ** 18n
const SEPOLIA = 16015286601757825753n
const ARB_SEPOLIA = 3478487238524512106n
const SOURCE_VERIFIER = '0x1111111111111111111111111111111111111111' as Hex
const DEST_VERIFIER = '0x2222222222222222222222222222222222222222' as Hex
const LOCKBOX = '0x3333333333333333333333333333333333333333' as Hex
const FEED = '0x4444444444444444444444444444444444444444' as Hex
const ARB_GUARD = '0x5555555555555555555555555555555555555555' as Hex
const ARB_POOL = '0x6666666666666666666666666666666666666666' as Hex
const SOURCE_TX = `0x${'ab'.repeat(32)}` as Hex
const EVENT_BLOCK = 9_000_000n
const NOW = 1_800_000_000

const baseConfig = (overrides: Partial<Config> = {}): Config =>
	configSchema.parse({
		sources: [{ chainSelectorName: 'ethereum-testnet-sepolia', verifier: SOURCE_VERIFIER, onRamps: [GOLDEN.onRamp] }],
		destinations: [{ chainSelectorName: 'ethereum-testnet-sepolia-arbitrum-1', verifier: DEST_VERIFIER }],
		token: {
			mode: 'burnMint',
			deployments: [
				{ chainSelectorName: 'ethereum-testnet-sepolia', token: GOLDEN.sourceToken },
				{ chainSelectorName: 'ethereum-testnet-sepolia-arbitrum-1', token: GOLDEN.destToken },
			],
			canonicalSupply: (2_000_000n * E18).toString(),
		},
		policy: {
			version: 'test-1',
			maxWindowOutflow: (50_000n * E18).toString(),
			maxTransfersPerSender: 3,
		},
		...overrides,
	})

const requestLog = (overrides: { messageId?: Hex; destChainSelector?: bigint; encodedMessage?: Hex } = {}) =>
	countersignLog(
		SOURCE_VERIFIER,
		overrides.messageId ?? GOLDEN.messageId,
		overrides.destChainSelector ?? GOLDEN.destChainSelector,
		GOLDEN.messageNumber,
		overrides.encodedMessage ?? GOLDEN.encodedMessage,
		SOURCE_TX,
		EVENT_BLOCK,
	)

// 5,000 burned on Sepolia and in flight: 995,000 + 1,000,000 + 5,000 = 2,000,000 canonical.
const healthySource = (): ChainState => ({
	supplies: { [GOLDEN.sourceToken.toLowerCase()]: 1_000_000n * E18 - GOLDEN.amount },
	window: { outflow: GOLDEN.amount, senderTransfers: 1n },
	receiptLogs: [onRampLog(GOLDEN.onRamp, GOLDEN.destChainSelector, GOLDEN.user, GOLDEN.messageId, SOURCE_TX)],
	finalized: EVENT_BLOCK + 10n,
})
const healthyDest = (): ChainState => ({
	supplies: { [GOLDEN.destToken.toLowerCase()]: 1_000_000n * E18 },
})

/** Runs the log handler and returns the single attestation written to the destination verifier. */
const verify = (source: ChainState, dest: ChainState, config: Config = baseConfig(), log = requestLog()) => {
	const sepolia = wireChain(SEPOLIA, source)
	const arb = wireChain(ARB_SEPOLIA, dest)
	const runtime = newTestRuntime(null, { timeProvider: () => NOW * 1000 }, config)
	const result = onCountersignRequested(config.sources[0])(runtime, asTriggerLog(log))
	expect(arb.writes).toHaveLength(1)
	const [chainSelector, attestations] = decodeAbiParameters(attestationReportParams, arb.writes[0].payload)
	return { result, chainSelector, attestation: attestations[0], write: arb.writes[0], sepolia, arb, runtime }
}

describe('log trigger: per-message verification', () => {
	test('approves a healthy transfer and writes a chain-bound report to the destination verifier', () => {
		const { result, chainSelector, attestation, write } = verify(healthySource(), healthyDest())
		expect(write.receiver).toBe(DEST_VERIFIER)
		expect(chainSelector).toBe(ARB_SEPOLIA)
		expect(attestation.messageId).toBe(GOLDEN.messageId)
		expect(attestation.sourceChainSelector).toBe(SEPOLIA)
		expect(attestation.verdict).toBe(Verdict.APPROVED)
		expect(attestation.reasonCodes).toBe(0)
		expect(result.startsWith('approved:')).toBe(true)
	})

	test('reads source-chain state at the event block, other chains at finality', () => {
		const { sepolia, arb } = verify(healthySource(), healthyDest())
		expect(sepolia.readHeights.find((r) => r.fn === 'totalSupply')?.block).toBe(EVENT_BLOCK)
		expect(sepolia.readHeights.find((r) => r.fn === 'getWindowUsage')?.block).toBe(EVENT_BLOCK)
		expect(arb.readHeights.find((r) => r.fn === 'totalSupply')?.block).toBe('special')
	})

	test('holds when unbacked tokens appear on another chain (KelpDAO pattern)', () => {
		const dest = healthyDest()
		dest.supplies![GOLDEN.destToken.toLowerCase()] += 116_500n * E18
		const { attestation } = verify(healthySource(), dest)
		expect(attestation.verdict).toBe(Verdict.HELD)
		expect(attestation.reasonCodes).toBe(Reason.SUPPLY_INVARIANT_BREACH)
	})

	test('holds when the canonical OnRamp did not emit the message in that transaction', () => {
		const source = { ...healthySource(), receiptLogs: [] }
		expect(verify(source, healthyDest()).attestation.reasonCodes).toBe(Reason.SOURCE_EVENT_NOT_FINAL)
	})

	test('holds bursts using the onchain rolling window', () => {
		const source = { ...healthySource(), window: { outflow: 55_000n * E18, senderTransfers: 4n } }
		expect(verify(source, healthyDest()).attestation.reasonCodes).toBe(
			Reason.WINDOW_LIMIT_EXCEEDED | Reason.VELOCITY_ANOMALY,
		)
	})

	test('holds denylisted parties', () => {
		const config = baseConfig({ policy: { ...baseConfig().policy, denylist: [GOLDEN.user] } })
		expect(verify(healthySource(), healthyDest(), config).attestation.reasonCodes).toBe(Reason.POLICY_DENIED)
	})

	test('holds a message whose decoded lane disagrees with the event', () => {
		const log = requestLog({ destChainSelector: 10344971235874465080n }) // Base Sepolia, not Arbitrum
		const config = baseConfig({
			destinations: [{ chainSelectorName: 'ethereum-testnet-sepolia-base-1', verifier: DEST_VERIFIER, gasLimit: '400000' }],
		})
		const sepolia = wireChain(SEPOLIA, healthySource())
		wireChain(ARB_SEPOLIA, healthyDest())
		const base = wireChain(10344971235874465080n, {})
		const runtime = newTestRuntime(null, { timeProvider: () => NOW * 1000 }, config)
		onCountersignRequested(config.sources[0])(runtime, asTriggerLog(log))
		expect(sepolia.writes).toHaveLength(0)
		const [, [attestation]] = decodeAbiParameters(attestationReportParams, base.writes[0].payload)
		expect(attestation.reasonCodes & Reason.MALFORMED_MESSAGE).toBeTruthy()
	})

	test('holds an undecodable message instead of crashing', () => {
		const garbage = '0x02deadbeef' as Hex
		const log = requestLog({ encodedMessage: garbage, messageId: keccak256(garbage) })
		const { attestation } = verify(healthySource(), healthyDest(), baseConfig(), log)
		expect(attestation.verdict).toBe(Verdict.HELD)
		expect(attestation.reasonCodes).toBe(Reason.MALFORMED_MESSAGE)
	})

	test('skips lanes with no configured destination', () => {
		const log = requestLog({ destChainSelector: 10344971235874465080n })
		wireChain(SEPOLIA, healthySource())
		const arb = wireChain(ARB_SEPOLIA, healthyDest())
		const config = baseConfig()
		const runtime = newTestRuntime(null, undefined, config)
		expect(onCountersignRequested(config.sources[0])(runtime, asTriggerLog(log))).toStartWith('skipped:')
		expect(arb.writes).toHaveLength(0)
	})

	test('fails loudly when the receiver reverts behind a successful forwarder transaction', () => {
		wireChain(SEPOLIA, healthySource())
		wireChain(ARB_SEPOLIA, { ...healthyDest(), receiverReverts: true })
		const config = baseConfig()
		const runtime = newTestRuntime(null, undefined, config)
		expect(() => onCountersignRequested(config.sources[0])(runtime, asTriggerLog(requestLog()))).toThrow('reverted')
	})

	test('lock/release: remote supply must stay covered by the home LockBox', () => {
		const config = baseConfig({
			token: {
				mode: 'lockRelease',
				homeChainSelectorName: 'ethereum-testnet-sepolia',
				lockBox: LOCKBOX,
				deployments: baseConfig().token.deployments,
			},
		})
		// Home chain: 100k locked (5k of it for this transfer), remote circulating 95k -> exactly covered.
		const source = { ...healthySource(), balances: { [GOLDEN.sourceToken.toLowerCase()]: 100_000n * E18 } }
		const dest = { supplies: { [GOLDEN.destToken.toLowerCase()]: 95_000n * E18 } }
		expect(verify(source, dest, config).attestation.verdict).toBe(Verdict.APPROVED)

		dest.supplies[GOLDEN.destToken.toLowerCase()] += 1n
		expect(verify(source, dest, config).attestation.reasonCodes).toBe(Reason.SUPPLY_INVARIANT_BREACH)
	})

	test('proof of reserve: shortfall and staleness against DON time', () => {
		const feed = {
			chainSelectorName: 'ethereum-testnet-sepolia',
			address: FEED,
			decimals: 8,
			tokenDecimals: 18,
			maxAgeSeconds: 3_600,
		}
		const config = baseConfig({ reserveFeed: feed })
		// Reserve of 2,000,000 with 8 decimals, fresh: approved.
		const fresh = { ...healthySource(), reserve: { answer: 2_000_000n * 10n ** 8n, updatedAt: BigInt(NOW - 60) } }
		expect(verify(fresh, healthyDest(), config).attestation.verdict).toBe(Verdict.APPROVED)

		const short = { ...fresh, reserve: { answer: 1_500_000n * 10n ** 8n, updatedAt: BigInt(NOW - 60) } }
		expect(verify(short, healthyDest(), config).attestation.reasonCodes).toBe(Reason.RESERVE_SHORTFALL)

		const stale = { ...fresh, reserve: { answer: 2_000_000n * 10n ** 8n, updatedAt: BigInt(NOW - 7_200) } }
		expect(verify(stale, healthyDest(), config).attestation.reasonCodes).toBe(Reason.RESERVE_STALE)
	})
})

describe('sweep: re-drive missed requests', () => {
	const cron = { scheduledExecutionTime: { seconds: BigInt(NOW), nanos: 0 } } as unknown as CronPayload

	test('attests only requests without an attestation, in one batch', () => {
		const missed = { messageId: keccak256(toHex('missed')) }
		const config = baseConfig({ sweep: { schedule: '0 */2 * * * *', lookbackBlocks: 100, maxMessages: 4 } })
		const sepolia = wireChain(SEPOLIA, {
			...healthySource(),
			logs: [requestLog(), requestLog(missed)],
			receiptLogs: [
				onRampLog(GOLDEN.onRamp, GOLDEN.destChainSelector, GOLDEN.user, GOLDEN.messageId, SOURCE_TX),
				onRampLog(GOLDEN.onRamp, GOLDEN.destChainSelector, GOLDEN.user, missed.messageId, SOURCE_TX),
			],
		})
		const arb = wireChain(ARB_SEPOLIA, { ...healthyDest(), verdicts: { [GOLDEN.messageId.toLowerCase()]: Verdict.APPROVED } })
		const runtime = newTestRuntime(null, { timeProvider: () => NOW * 1000 }, config)

		onSweep(runtime, cron)

		expect(arb.writes).toHaveLength(1)
		const [chainSelector, attestations] = decodeAbiParameters(attestationReportParams, arb.writes[0].payload)
		expect(chainSelector).toBe(ARB_SEPOLIA)
		expect(attestations.map((a) => a.messageId)).toEqual([missed.messageId])
		// The replayed request's messageId does not hash its (golden) payload, so it is held, not approved.
		expect(attestations[0].reasonCodes & Reason.MESSAGE_ID_MISMATCH).toBeTruthy()
		expect(sepolia.readHeights.length).toBeLessThanOrEqual(15)
	})

	test('rotation reaches every source on an every-2-minutes schedule', () => {
		const seen = new Set<number>()
		for (let i = 0; i < 20; i++) seen.add(sweepSourceIndex(BigInt(NOW + i * 120), 2))
		expect([...seen].sort()).toEqual([0, 1])
	})

	test('does nothing when everything is attested', () => {
		const config = baseConfig({ sweep: { schedule: '0 */2 * * * *', lookbackBlocks: 100, maxMessages: 4 } })
		wireChain(SEPOLIA, { ...healthySource(), logs: [requestLog()] })
		const arb = wireChain(ARB_SEPOLIA, { ...healthyDest(), verdicts: { [GOLDEN.messageId.toLowerCase()]: Verdict.HELD } })
		const runtime = newTestRuntime(null, undefined, config)
		expect(onSweep(runtime, cron)).toContain('all attested')
		expect(arb.writes).toHaveLength(0)
	})
})

describe('sentinel: global invariant circuit breaker', () => {
	const cron = { scheduledExecutionTime: { seconds: BigInt(NOW), nanos: 0 } } as unknown as CronPayload
	const sentinelConfig = () =>
		baseConfig({
			sentinel: {
				schedule: '0 */5 * * * *',
				guards: [
					{
						chainSelectorName: 'ethereum-testnet-sepolia-arbitrum-1',
						guard: ARB_GUARD,
						pools: [{ pool: ARB_POOL, remoteChainSelectorNames: ['ethereum-testnet-sepolia'] }],
						gasLimit: '600000',
					},
				],
			},
		})

	test('stays quiet while supply is backed', () => {
		wireChain(SEPOLIA, { supplies: { [GOLDEN.sourceToken.toLowerCase()]: 1_000_000n * E18 } })
		const arb = wireChain(ARB_SEPOLIA, healthyDest())
		const runtime = newTestRuntime(null, undefined, sentinelConfig())
		expect(onSentinel(runtime, cron)).toBe('healthy')
		expect(arb.writes).toHaveLength(0)
	})

	test('freezes every lane (both finality buckets) through RateLimitGuard on a breach', () => {
		wireChain(SEPOLIA, { supplies: { [GOLDEN.sourceToken.toLowerCase()]: 1_000_000n * E18 } })
		const arb = wireChain(ARB_SEPOLIA, { supplies: { [GOLDEN.destToken.toLowerCase()]: 1_116_500n * E18 } })
		const runtime = newTestRuntime(null, undefined, sentinelConfig())

		expect(onSentinel(runtime, cron)).toStartWith('frozen:SUPPLY_INVARIANT_BREACH')
		expect(arb.writes).toHaveLength(1)
		expect(arb.writes[0].receiver).toBe(ARB_GUARD)
		const [chainSelector, issuedAt, tightenings] = decodeAbiParameters(tighteningReportParams, arb.writes[0].payload)
		expect(chainSelector).toBe(ARB_SEPOLIA)
		expect(issuedAt).toBe(BigInt(NOW))
		expect(tightenings).toHaveLength(2)
		expect(tightenings.map((t) => t.fastFinality)).toEqual([false, true])
		for (const t of tightenings) {
			expect(t.pool.toLowerCase()).toBe(ARB_POOL)
			expect(t.remoteChainSelector).toBe(SEPOLIA)
			expect(t.outbound).toEqual({ isEnabled: true, capacity: 0n, rate: 0n })
			expect(t.inbound).toEqual({ isEnabled: true, capacity: 0n, rate: 0n })
		}
	})
})

describe('sentinel: failure isolation', () => {
	test('a failing guard write does not stop the other chains from freezing', () => {
		const cron = { scheduledExecutionTime: { seconds: BigInt(NOW), nanos: 0 } } as unknown as CronPayload
		const SEP_GUARD = '0x7777777777777777777777777777777777777777' as Hex
		const SEP_POOL = '0x8888888888888888888888888888888888888888' as Hex
		const config = baseConfig({
			sentinel: {
				schedule: '0 */5 * * * *',
				guards: [
					{
						chainSelectorName: 'ethereum-testnet-sepolia-arbitrum-1',
						guard: ARB_GUARD,
						pools: [{ pool: ARB_POOL, remoteChainSelectorNames: ['ethereum-testnet-sepolia'] }],
						gasLimit: '600000',
					},
					{
						chainSelectorName: 'ethereum-testnet-sepolia',
						guard: SEP_GUARD,
						pools: [{ pool: SEP_POOL, remoteChainSelectorNames: ['ethereum-testnet-sepolia-arbitrum-1'] }],
						gasLimit: '600000',
					},
				],
			},
		})
		const sepolia = wireChain(SEPOLIA, { supplies: { [GOLDEN.sourceToken.toLowerCase()]: 1_000_000n * E18 } })
		wireChain(ARB_SEPOLIA, {
			supplies: { [GOLDEN.destToken.toLowerCase()]: 1_116_500n * E18 },
			receiverReverts: true,
		})
		const runtime = newTestRuntime(null, undefined, config)
		expect(() => onSentinel(runtime, cron)).toThrow('could not freeze ethereum-testnet-sepolia-arbitrum-1')
		expect(sepolia.writes).toHaveLength(1)
		expect(sepolia.writes[0].receiver).toBe(SEP_GUARD)
	})
})

describe('config', () => {
	test('rejects a sweep lookback above the CRE log query limit (100 blocks)', () => {
		expect(() =>
			baseConfig({ sweep: { schedule: '0 * * * * *', lookbackBlocks: 101, maxMessages: 4 } } as Partial<Config>),
		).toThrow()
	})

	test('rejects configs that would exceed 15 chain reads per execution', () => {
		const destinations = Array.from({ length: 10 }, (_, i) => ({
			chainSelectorName: 'ethereum-testnet-sepolia-arbitrum-1',
			verifier: `0x${(i + 1).toString(16).padStart(40, '0')}`,
		}))
		expect(() =>
			baseConfig({
				destinations,
				sweep: { schedule: '0 * * * * *', lookbackBlocks: 100, maxMessages: 4 },
			} as Partial<Config>),
		).toThrow('chain reads')
	})
})
