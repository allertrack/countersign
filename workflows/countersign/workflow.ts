import {
	CronCapability,
	type CronPayload,
	type EVMLog,
	LATEST_BLOCK_NUMBER,
	type Runtime,
	bigintToProtoBigInt,
	bytesToHex,
	encodeCallMsg,
	handler,
	hexToBase64,
	logTriggerConfig,
	protoBigIntToBigint,
} from '@chainlink/cre-sdk'
import {
	type Hex,
	decodeEventLog,
	decodeFunctionResult,
	encodeAbiParameters,
	encodeEventTopics,
	encodeFunctionData,
	keccak256,
	toHex,
	zeroAddress,
} from 'viem'
import { attestationReportParams, countersignVerifierAbi, tighteningReportParams } from './src/abi'
import { clientFor, finalizedHeight, selectorOf, writeReport } from './src/chain'
import { Reason, Verdict, reasonNames } from './src/codes'
import { type Config, type Source, configSchema } from './src/config'
import { decodeMessageV1, evmAddressFromAbiWord, evmAddressFromRaw, messageIdOf } from './src/messageV1'
import { onRampEventInTx, policyFrom, readSupply, windowUsage } from './src/observe'
import { type Observations, type SupplySnapshot, evaluate, snapshotHash, supplyReasons } from './src/policy'

export { configSchema }

/** CRE: PerWorkflow.ChainRead.CallLimit. */
const CHAIN_READ_LIMIT = 15

const COUNTERSIGN_REQUESTED = encodeEventTopics({ abi: countersignVerifierAbi, eventName: 'CountersignRequested' })[0] as Hex

export type RequestEvent = {
	messageId: Hex
	destChainSelector: bigint
	encodedMessage: Hex
	blockNumber: bigint
	txHash: Hex
}

export type Attestation = {
	messageId: Hex
	sourceChainSelector: bigint
	verdict: number
	reasonCodes: number
	evidenceHash: Hex
}

type EventLog = Pick<EVMLog, 'data' | 'topics' | 'txHash' | 'blockNumber'>

export const decodeRequest = (log: EventLog): RequestEvent => {
	const { args } = decodeEventLog({
		abi: countersignVerifierAbi,
		eventName: 'CountersignRequested',
		data: bytesToHex(log.data),
		topics: log.topics.map((t) => bytesToHex(t)) as [Hex, ...Hex[]],
	})
	return {
		messageId: args.messageId,
		destChainSelector: args.destChainSelector,
		encodedMessage: args.encodedMessage,
		blockNumber: log.blockNumber ? protoBigIntToBigint(log.blockNumber) : 0n,
		txHash: bytesToHex(log.txHash),
	}
}

const destinationFor = (config: Config, destChainSelector: bigint) =>
	config.destinations.find((d) => selectorOf(d.chainSelectorName) === destChainSelector)

/** Reads per message beyond the shared supply snapshot: tx receipt + window usage. */
const READS_PER_MESSAGE = 2

const supplyReads = (config: Config): number =>
	config.token.deployments.length + (config.token.mode === 'lockRelease' ? 2 : 0) + (config.reserveFeed ? 1 : 0)

/** EVM receivers are 20 raw bytes; other families (e.g. Solana, 32 bytes) are compared as raw hex. */
const receiverOf = (raw: Hex): Hex => (raw.length === 42 ? evmAddressFromRaw(raw) : (raw.toLowerCase() as Hex))

// ─── Assessment ─────────────────────────────────────────────────────────────

/** Verdict for one Countersign request, given a supply snapshot that already includes the request's burn/lock. */
export const assess = (
	runtime: Runtime<Config>,
	source: Source,
	event: RequestEvent,
	supply: SupplySnapshot,
): Attestation => {
	const sourceChainSelector = selectorOf(source.chainSelectorName)
	const policy = policyFrom(runtime.config, source.chainSelectorName)

	let message: ReturnType<typeof decodeMessageV1>
	try {
		message = decodeMessageV1(event.encodedMessage)
	} catch (error) {
		runtime.log(`${event.messageId}: undecodable message (${(error as Error).message})`)
		return {
			messageId: event.messageId,
			sourceChainSelector,
			verdict: Verdict.HELD,
			reasonCodes: Reason.MALFORMED_MESSAGE,
			evidenceHash: messageIdOf(event.encodedMessage),
		}
	}

	const transfer = message.tokenTransfer[0]
	const sender = evmAddressFromAbiWord(message.sender)
	const sourceToken = transfer ? evmAddressFromAbiWord(transfer.sourceTokenAddress) : zeroAddress
	const window = windowUsage(runtime, source, event.destChainSelector, sourceToken, sender, event.blockNumber)

	const observations: Observations = {
		...supply,
		messageId: event.messageId,
		sourceBlockNumber: event.blockNumber,
		messageIdMatches: messageIdOf(event.encodedMessage) === event.messageId,
		laneMatches:
			message.sourceChainSelector === sourceChainSelector && message.destChainSelector === event.destChainSelector,
		onRampEventFound: onRampEventInTx(runtime, source, event.txHash, event.messageId),
		sourceToken,
		amount: transfer?.amount ?? 0n,
		sender,
		tokenReceiver: transfer ? receiverOf(transfer.tokenReceiver) : zeroAddress,
		windowOutflow: window.outflow,
		senderTransfersInWindow: window.senderTransfers,
	}

	const decision = evaluate(policy, observations)
	runtime.log(
		`${event.messageId} amount=${observations.amount} circulating=${supply.circulating} backing=${supply.backing} ` +
			`window=${window.outflow} senderTransfers=${window.senderTransfers} -> ` +
			(decision.verdict === Verdict.APPROVED ? 'APPROVED' : `HELD [${reasonNames(decision.reasonCodes).join(',')}]`),
	)
	return { messageId: event.messageId, sourceChainSelector, ...decision }
}

const writeAttestations = (
	runtime: Runtime<Config>,
	destination: Config['destinations'][number],
	attestations: Attestation[],
): Hex =>
	writeReport(
		runtime,
		destination.chainSelectorName,
		destination.verifier as Hex,
		encodeAbiParameters(attestationReportParams, [selectorOf(destination.chainSelectorName), attestations]),
		destination.gasLimit,
	)

const summary = (attestations: Attestation[]): string =>
	attestations.map((a) => `${a.verdict === Verdict.APPROVED ? 'approved' : 'held'}:${a.messageId}`).join(',')

// ─── Handler 1: log trigger ─────────────────────────────────────────────────

export const onCountersignRequested =
	(source: Source) =>
	(runtime: Runtime<Config>, log: EVMLog): string => {
		const event = decodeRequest(log)
		const destination = destinationFor(runtime.config, event.destChainSelector)
		if (!destination) {
			runtime.log(`No destination verifier for selector ${event.destChainSelector}; skipping ${event.messageId}`)
			return `skipped:${event.messageId}`
		}

		const supply = readSupply(runtime, { chain: source.chainSelectorName, block: event.blockNumber })
		const attestation = assess(runtime, source, event, supply)
		const tx = writeAttestations(runtime, destination, [attestation])
		return `${summary([attestation])}:${tx}`
	}

// ─── Handler 2: re-drive sweep ──────────────────────────────────────────────

const scheduledSeconds = (runtime: Runtime<Config>, payload?: CronPayload): bigint =>
	payload?.scheduledExecutionTime?.seconds ?? BigInt(Math.floor(runtime.now().getTime() / 1000))

/**
 * Which source a sweep run covers. Hashing the scheduled time spreads runs evenly over sources whatever the cron
 * interval is (a plain `minute % n` would never reach odd sources on an every-2-minutes schedule).
 */
export const sweepSourceIndex = (scheduledAt: bigint, sources: number): number =>
	Number(BigInt(keccak256(toHex(scheduledAt))) % BigInt(sources))

/**
 * Attests Countersign requests the log trigger missed (node outage, reverted write, quota backlog). One source per run
 * (round-robin on the schedule) keeps each execution inside CRE's 15 EVM reads. Duplicate attestations are ignored by
 * the verifier, so a stale read here only costs gas.
 */
export const onSweep = (runtime: Runtime<Config>, payload?: CronPayload): string => {
	const config = runtime.config
	const sweep = config.sweep
	if (!sweep) return 'sweep disabled'

	const scheduledAt = scheduledSeconds(runtime, payload)
	const source = config.sources[sweepSourceIndex(scheduledAt, config.sources.length)]
	const budget = CHAIN_READ_LIMIT - 2 - config.destinations.length - supplyReads(config)
	const maxMessages = Math.min(sweep.maxMessages, Math.floor(budget / READS_PER_MESSAGE))
	if (maxMessages < 1) return 'sweep skipped: not enough chain reads left in this execution'

	const toBlock = finalizedHeight(runtime, source.chainSelectorName)
	const fromBlock = toBlock >= BigInt(sweep.lookbackBlocks) ? toBlock - BigInt(sweep.lookbackBlocks) + 1n : 0n
	const logs = clientFor(source.chainSelectorName)
		.filterLogs(runtime, {
			filterQuery: {
				addresses: [hexToBase64(source.verifier)],
				topics: [{ topic: [hexToBase64(COUNTERSIGN_REQUESTED)] }],
				fromBlock: bigintToProtoBigInt(fromBlock),
				toBlock: bigintToProtoBigInt(toBlock),
			},
		})
		.result().logs
	if (logs.length === 0) return `sweep ${source.chainSelectorName}: nothing in blocks ${fromBlock}-${toBlock}`

	const pending = new Map<string, RequestEvent[]>()
	for (const event of logs.map(decodeRequest)) {
		const destination = destinationFor(config, event.destChainSelector)
		if (!destination) continue
		pending.set(destination.chainSelectorName, [...(pending.get(destination.chainSelectorName) ?? []), event])
	}

	let supply: SupplySnapshot | undefined
	let remaining = maxMessages
	const results: string[] = []
	for (const destination of config.destinations) {
		const events = pending.get(destination.chainSelectorName)
		if (!events || remaining === 0) continue

		const records = attestationRecords(runtime, destination, events.map((e) => e.messageId))
		if (!records) continue
		const missing = events.filter((_, i) => records[i].verdict === Verdict.NONE).slice(0, remaining)
		if (missing.length === 0) continue
		remaining -= missing.length

		// Every swept event is at or below the finalized head, so a finalized snapshot includes all their burns.
		supply ??= readSupply(runtime, undefined)
		const attestations = missing.map((event) => assess(runtime, source, event, supply as SupplySnapshot))
		const tx = writeAttestations(runtime, destination, attestations)
		results.push(`${summary(attestations)}:${tx}`)
	}
	return results.length ? results.join(' ') : `sweep ${source.chainSelectorName}: all attested`
}

/** Latest-block hint of which messages already have an attestation; undefined if the read fails. */
const attestationRecords = (
	runtime: Runtime<Config>,
	destination: Config['destinations'][number],
	messageIds: Hex[],
): readonly { verdict: number }[] | undefined => {
	try {
		const reply = clientFor(destination.chainSelectorName)
			.callContract(runtime, {
				call: encodeCallMsg({
					from: zeroAddress,
					to: destination.verifier as Hex,
					data: encodeFunctionData({ abi: countersignVerifierAbi, functionName: 'getAttestations', args: [messageIds] }),
				}),
				blockNumber: LATEST_BLOCK_NUMBER,
			})
			.result()
		return decodeFunctionResult({
			abi: countersignVerifierAbi,
			functionName: 'getAttestations',
			data: bytesToHex(reply.data),
		})
	} catch (error) {
		runtime.log(`sweep: could not read attestations on ${destination.chainSelectorName}: ${(error as Error).message}`)
		return undefined
	}
}

// ─── Handler 3: supply sentinel ─────────────────────────────────────────────

const FROZEN = { isEnabled: true, capacity: 0n, rate: 0n } as const

/**
 * Checks the global supply invariant and Proof of Reserve. On a breach it freezes every configured lane (normal and
 * fast-finality buckets) through each chain's RateLimitGuard, which clamps against live state and can never loosen.
 */
export const onSentinel = (runtime: Runtime<Config>, payload?: CronPayload): string => {
	const config = runtime.config
	const sentinel = config.sentinel
	if (!sentinel) return 'sentinel disabled'

	const scheduledAt = scheduledSeconds(runtime, payload)
	const policy = policyFrom(config)
	const supply = readSupply(runtime, undefined)
	const reasons = supplyReasons(policy, supply, 0n)
	if (reasons === 0) {
		runtime.log(`sentinel healthy: circulating=${supply.circulating} backing=${supply.backing} reserve=${supply.reserve ?? '-'}`)
		return 'healthy'
	}

	runtime.log(`sentinel BREACH [${reasonNames(reasons).join(',')}]: circulating=${supply.circulating} backing=${supply.backing}`)
	const evidenceHash = snapshotHash(policy, supply, scheduledAt)
	// Freeze every chain independently: one failing write must not leave the other lanes open.
	const txs: string[] = []
	const failures: string[] = []
	for (const guard of sentinel.guards) {
		const tightenings = guard.pools.flatMap(({ pool, remoteChainSelectorNames }) =>
			remoteChainSelectorNames.flatMap((remote) =>
				[false, true].map((fastFinality) => ({
					pool: pool as Hex,
					remoteChainSelector: selectorOf(remote),
					fastFinality,
					outbound: FROZEN,
					inbound: FROZEN,
					evidenceHash,
				})),
			),
		)
		const payloadHex = encodeAbiParameters(tighteningReportParams, [
			selectorOf(guard.chainSelectorName),
			scheduledAt,
			tightenings,
		])
		try {
			txs.push(writeReport(runtime, guard.chainSelectorName, guard.guard as Hex, payloadHex, guard.gasLimit))
		} catch (error) {
			failures.push(`${guard.chainSelectorName}: ${(error as Error).message}`)
		}
	}
	if (failures.length) throw new Error(`sentinel could not freeze ${failures.join('; ')} (frozen: ${txs.join(',') || 'none'})`)
	return `frozen:${reasonNames(reasons).join(',')}:${txs.join(',')}`
}

// ─── Workflow ───────────────────────────────────────────────────────────────

export function initWorkflow(config: Config) {
	const logHandlers = config.sources.map((source) =>
		handler(
			clientFor(source.chainSelectorName).logTrigger(
				logTriggerConfig({
					addresses: [source.verifier as Hex],
					topics: [[COUNTERSIGN_REQUESTED]],
					// Only act once the source burn/lock can no longer be reorged away.
					confidence: 'FINALIZED',
				}),
			),
			onCountersignRequested(source),
		),
	)
	const cron = new CronCapability()
	const cronHandlers = [
		...(config.sweep ? [handler(cron.trigger({ schedule: config.sweep.schedule }), onSweep)] : []),
		...(config.sentinel ? [handler(cron.trigger({ schedule: config.sentinel.schedule }), onSentinel)] : []),
	]
	return [...logHandlers, ...cronHandlers]
}
