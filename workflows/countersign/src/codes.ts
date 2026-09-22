// Keep in sync with contracts/src/libraries/CountersignCodes.sol.

export const Verdict = {
	NONE: 0,
	APPROVED: 1,
	HELD: 2,
} as const
export type Verdict = (typeof Verdict)[keyof typeof Verdict]

export const Reason = {
	SOURCE_EVENT_NOT_FINAL: 1 << 0,
	MESSAGE_ID_MISMATCH: 1 << 1,
	SUPPLY_INVARIANT_BREACH: 1 << 2,
	RESERVE_SHORTFALL: 1 << 3,
	WINDOW_LIMIT_EXCEEDED: 1 << 4,
	VELOCITY_ANOMALY: 1 << 5,
	POLICY_DENIED: 1 << 6,
	MANUAL_REVIEW: 1 << 7,
	RESERVE_STALE: 1 << 8,
	MALFORMED_MESSAGE: 1 << 9,
} as const

export const reasonNames = (mask: number): string[] =>
	Object.entries(Reason)
		.filter(([, bit]) => (mask & bit) !== 0)
		.map(([name]) => name)
