import { describe, expect, test } from 'bun:test'
import { Reason, Verdict } from '../src/codes'
import { type Observations, type Policy, evaluate, snapshotHash, supplyReasons } from '../src/policy'

const E18 = 10n ** 18n
const TOKEN = '0x00000000000000000000000000000000000000aa'
const SENDER = '0x00000000000000000000000000000000000000bb'
const RECEIVER = '0x00000000000000000000000000000000000000cc'

const policy: Policy = {
	allowedSourceTokens: [TOKEN],
	denylist: [],
	supplyTolerance: 0n,
	maxWindowOutflow: 50_000n * E18,
	maxTransfersPerSender: 3n,
	maxReserveAgeSeconds: 3_600,
	version: 'test',
}

const healthy: Observations = {
	messageId: `0x${'11'.repeat(32)}`,
	sourceBlockNumber: 100n,
	messageIdMatches: true,
	laneMatches: true,
	onRampEventFound: true,
	sourceToken: TOKEN,
	amount: 5_000n * E18,
	sender: SENDER,
	tokenReceiver: RECEIVER,
	circulating: 1_995_000n * E18, // 2M canonical, 5k in flight
	backing: 2_000_000n * E18,
	liability: 1_995_000n * E18,
	windowOutflow: 5_000n * E18,
	senderTransfersInWindow: 1n,
}

describe('evaluate', () => {
	test('approves a healthy transfer', () => {
		const decision = evaluate(policy, healthy)
		expect(decision.verdict).toBe(Verdict.APPROVED)
		expect(decision.reasonCodes).toBe(0)
	})

	test('KelpDAO-style unbacked supply trips the invariant', () => {
		// 116,500 tokens appeared on a remote chain without a matching lock/burn.
		const decision = evaluate(policy, { ...healthy, circulating: healthy.circulating + 116_500n * E18 })
		expect(decision.verdict).toBe(Verdict.HELD)
		expect(decision.reasonCodes).toBe(Reason.SUPPLY_INVARIANT_BREACH)
	})

	test('exactly backed is approved; one wei over is held', () => {
		const exact = { ...healthy, circulating: healthy.backing - healthy.amount }
		expect(evaluate(policy, exact).verdict).toBe(Verdict.APPROVED)
		expect(evaluate(policy, { ...exact, circulating: exact.circulating + 1n }).verdict).toBe(Verdict.HELD)
	})

	test('supply tolerance absorbs rounding dust only', () => {
		const dusty = { ...healthy, circulating: healthy.backing - healthy.amount + 10n }
		expect(evaluate({ ...policy, supplyTolerance: 10n }, dusty).verdict).toBe(Verdict.APPROVED)
	})

	test('integrity failures are all reported', () => {
		const decision = evaluate(policy, { ...healthy, onRampEventFound: false, messageIdMatches: false, laneMatches: false })
		expect(decision.reasonCodes).toBe(
			Reason.SOURCE_EVENT_NOT_FINAL | Reason.MESSAGE_ID_MISMATCH | Reason.MALFORMED_MESSAGE,
		)
	})

	test('unknown token and denylisted parties are policy denials (case-insensitive)', () => {
		expect(evaluate(policy, { ...healthy, sourceToken: SENDER }).reasonCodes).toBe(Reason.POLICY_DENIED)
		expect(evaluate({ ...policy, denylist: [RECEIVER] }, healthy).reasonCodes).toBe(Reason.POLICY_DENIED)
		const upper = `0x${SENDER.slice(2).toUpperCase()}` as `0x${string}`
		expect(evaluate({ ...policy, denylist: [upper] }, healthy).verdict).toBe(Verdict.HELD)
	})

	test('proof of reserve: shortfall and staleness (Secure Mint)', () => {
		expect(evaluate(policy, { ...healthy, reserve: 1_000_000n * E18, reserveAgeSeconds: 10 }).reasonCodes).toBe(
			Reason.RESERVE_SHORTFALL,
		)
		expect(evaluate(policy, { ...healthy, reserve: 2_000_000n * E18, reserveAgeSeconds: 3_601 }).reasonCodes).toBe(
			Reason.RESERVE_STALE,
		)
		expect(evaluate(policy, { ...healthy, reserve: 2_000_000n * E18, reserveAgeSeconds: 3_600 }).verdict).toBe(
			Verdict.APPROVED,
		)
	})

	test('rolling window and velocity', () => {
		expect(evaluate(policy, { ...healthy, windowOutflow: 50_001n * E18 }).reasonCodes).toBe(Reason.WINDOW_LIMIT_EXCEEDED)
		expect(evaluate(policy, { ...healthy, senderTransfersInWindow: 4n }).reasonCodes).toBe(Reason.VELOCITY_ANOMALY)
	})

	test('evidence hash commits to observations and policy version', () => {
		const a = evaluate(policy, healthy).evidenceHash
		expect(evaluate(policy, healthy).evidenceHash).toBe(a)
		expect(evaluate(policy, { ...healthy, backing: healthy.backing + 1n }).evidenceHash).not.toBe(a)
		expect(evaluate({ ...policy, version: 'other' }, healthy).evidenceHash).not.toBe(a)
	})
})

describe('supplyReasons (sentinel)', () => {
	test('no in-flight amount: only an actual excess trips it', () => {
		const supply = { circulating: 2_000_000n * E18, backing: 2_000_000n * E18, liability: 0n }
		expect(supplyReasons(policy, supply, 0n)).toBe(0)
		expect(supplyReasons(policy, { ...supply, circulating: supply.circulating + 1n }, 0n)).toBe(
			Reason.SUPPLY_INVARIANT_BREACH,
		)
	})

	test('snapshot hash is deterministic and time-bound', () => {
		const supply = { circulating: 1n, backing: 2n, liability: 1n }
		expect(snapshotHash(policy, supply, 10n)).toBe(snapshotHash(policy, supply, 10n))
		expect(snapshotHash(policy, supply, 11n)).not.toBe(snapshotHash(policy, supply, 10n))
	})
})
