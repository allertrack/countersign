import { type Hex, encodeAbiParameters, keccak256, parseAbiParameters, stringToHex } from 'viem'
import { Reason, Verdict } from './codes'

/** Global supply state, read at deterministic heights. */
export type SupplySnapshot = {
	/** Supply that must stay backed, excluding in-flight transfers (see `evaluate`). */
	circulating: bigint
	/** What backs `circulating`: LockBox balance (lock/release) or the canonical supply (burn/mint). */
	backing: bigint
	/** Supply the Proof of Reserve must cover. */
	liability: bigint
	/** Proof of Reserve answer scaled to token decimals, when a feed is configured. */
	reserve?: bigint
	/** Seconds since the reserve feed last updated (DON time minus updatedAt). */
	reserveAgeSeconds?: number
}

/**
 * Everything the workflow observed for one message. All values come from finalized (or event-height) chain state, so
 * every node in the DON computes the same observations and therefore the same verdict.
 */
export type Observations = SupplySnapshot & {
	messageId: Hex
	sourceBlockNumber: bigint
	/** keccak256(encodedMessage) equals the messageId emitted by the verifier. */
	messageIdMatches: boolean
	/** Decoded source/destination selectors match the lane the event was emitted on. */
	laneMatches: boolean
	/** The canonical OnRamp emitted CCIPMessageSent for this messageId in the same transaction. */
	onRampEventFound: boolean
	sourceToken: Hex
	amount: bigint
	sender: Hex
	tokenReceiver: Hex
	/** Countersign-gated outflow on this lane over the verifier's rolling window, including this transfer. */
	windowOutflow?: bigint
	/** Countersign-gated transfers from this sender over the same window, including this one. */
	senderTransfersInWindow?: bigint
}

export type Policy = {
	allowedSourceTokens: Hex[]
	denylist: Hex[]
	supplyTolerance: bigint
	maxWindowOutflow?: bigint
	maxTransfersPerSender?: bigint
	maxReserveAgeSeconds?: number
	version: string
}

export type Decision = {
	verdict: Verdict
	reasonCodes: number
	evidenceHash: Hex
}

const sameAddress = (a: Hex, b: Hex) => a.toLowerCase() === b.toLowerCase()

/**
 * Supply checks shared by per-message verification and the sentinel. `inFlight` is the transfer being verified (0 for
 * the sentinel). The invariant is the same inequality for both pool designs:
 *   circulating + inFlight <= backing (+ tolerance)
 * - lock/release: circulating = supply on remote chains, backing = LockBox balance on the home chain. On the way out
 *   the LockBox already holds the amount; on the way home the remote burn already removed it. Either way the in-flight
 *   amount must still be covered.
 * - burn/mint: circulating = supply on every chain, backing = canonical supply. The source burn already removed the
 *   amount, which is about to be minted on the destination.
 */
export const supplyReasons = (policy: Policy, supply: SupplySnapshot, inFlight: bigint): number => {
	let reasons = 0
	if (supply.circulating + inFlight > supply.backing + policy.supplyTolerance) reasons |= Reason.SUPPLY_INVARIANT_BREACH
	if (supply.reserve !== undefined) {
		if (supply.liability + inFlight > supply.reserve + policy.supplyTolerance) reasons |= Reason.RESERVE_SHORTFALL
		if (
			policy.maxReserveAgeSeconds !== undefined &&
			supply.reserveAgeSeconds !== undefined &&
			supply.reserveAgeSeconds > policy.maxReserveAgeSeconds
		) {
			reasons |= Reason.RESERVE_STALE
		}
	}
	return reasons
}

/** Deterministic verdict for one message. */
export const evaluate = (policy: Policy, obs: Observations): Decision => {
	let reasons = supplyReasons(policy, obs, obs.amount)

	if (!obs.messageIdMatches) reasons |= Reason.MESSAGE_ID_MISMATCH
	if (!obs.laneMatches) reasons |= Reason.MALFORMED_MESSAGE
	if (!obs.onRampEventFound) reasons |= Reason.SOURCE_EVENT_NOT_FINAL

	const tokenAllowed = policy.allowedSourceTokens.some((t) => sameAddress(t, obs.sourceToken))
	const denied = policy.denylist.some((d) => sameAddress(d, obs.sender) || sameAddress(d, obs.tokenReceiver))
	if (!tokenAllowed || denied) reasons |= Reason.POLICY_DENIED

	if (policy.maxWindowOutflow !== undefined && obs.windowOutflow !== undefined) {
		if (obs.windowOutflow > policy.maxWindowOutflow) reasons |= Reason.WINDOW_LIMIT_EXCEEDED
	}
	if (policy.maxTransfersPerSender !== undefined && obs.senderTransfersInWindow !== undefined) {
		if (obs.senderTransfersInWindow > policy.maxTransfersPerSender) reasons |= Reason.VELOCITY_ANOMALY
	}

	return {
		verdict: reasons === 0 ? Verdict.APPROVED : Verdict.HELD,
		reasonCodes: reasons,
		evidenceHash: evidenceHash(policy, obs),
	}
}

/** Commits to every input of the decision so an auditor can recompute it from chain history. */
export const evidenceHash = (policy: Policy, obs: Observations): Hex =>
	keccak256(
		encodeAbiParameters(
			parseAbiParameters(
				'bytes32 messageId, uint256 sourceBlock, uint256 amount, uint256 circulating, uint256 backing, uint256 reserve, uint256 windowOutflow, uint256 senderTransfers, bytes32 policyVersion',
			),
			[
				obs.messageId,
				obs.sourceBlockNumber,
				obs.amount,
				obs.circulating,
				obs.backing,
				obs.reserve ?? 0n,
				obs.windowOutflow ?? 0n,
				obs.senderTransfersInWindow ?? 0n,
				keccak256(stringToHex(policy.version)),
			],
		),
	)

/** Evidence for a sentinel action: the supply snapshot that justified it. */
export const snapshotHash = (policy: Policy, supply: SupplySnapshot, scheduledAt: bigint): Hex =>
	keccak256(
		encodeAbiParameters(
			parseAbiParameters(
				'uint256 scheduledAt, uint256 circulating, uint256 backing, uint256 liability, uint256 reserve, bytes32 policyVersion',
			),
			[
				scheduledAt,
				supply.circulating,
				supply.backing,
				supply.liability,
				supply.reserve ?? 0n,
				keccak256(stringToHex(policy.version)),
			],
		),
	)
