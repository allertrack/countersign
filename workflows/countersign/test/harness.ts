import { bigintToBytes, bytesToBigint, bytesToHex, hexToBytes } from '@chainlink/cre-sdk'
import { EvmMock, REPORT_METADATA_HEADER_LENGTH } from '@chainlink/cre-sdk/test'
import {
	type Hex,
	decodeFunctionData,
	encodeAbiParameters,
	encodeEventTopics,
	encodeFunctionResult,
	pad,
	toHex,
} from 'viem'
import { aggregatorV3Abi, countersignVerifierAbi, erc20Abi, onRampAbi } from '../src/abi'

const b64 = (hex: Hex) => Buffer.from(hexToBytes(hex)).toString('base64')
const bigJson = (n: bigint) => ({ absVal: Buffer.from(bigintToBytes(n)).toString('base64'), sign: n === 0n ? '0' : '1' })
const readAbi = [...erc20Abi, ...countersignVerifierAbi, ...aggregatorV3Abi]

export type LogSpec = { address: Hex; topics: Hex[]; data: Hex; txHash: Hex; blockNumber: bigint }

export type ChainState = {
	/** totalSupply per token address. */
	supplies?: Record<string, bigint>
	/** balanceOf(holder) per token address (lock/release LockBox). */
	balances?: Record<string, bigint>
	/** CountersignVerifier.getWindowUsage result. */
	window?: { outflow: bigint; senderTransfers: bigint }
	/** Existing attestation verdicts per messageId on this chain's verifier. */
	verdicts?: Record<string, number>
	/** Proof of Reserve feed. */
	reserve?: { answer: bigint; updatedAt: bigint }
	finalized?: bigint
	/** Logs returned by filterLogs. */
	logs?: LogSpec[]
	/** Logs in the triggering transaction's receipt. */
	receiptLogs?: LogSpec[]
	/** Simulate the Forwarder delivering but the receiver reverting. */
	receiverReverts?: boolean
}

export type Write = { receiver: Hex; payload: Hex }
export type Wired = { writes: Write[]; readHeights: { fn: string; to: Hex; block: bigint | 'special' }[] }

const logJson = (log: LogSpec) => ({
	address: b64(log.address),
	topics: log.topics.map(b64),
	txHash: b64(log.txHash),
	data: b64(log.data),
	blockNumber: bigJson(log.blockNumber),
})

/** Installs EVM capability mocks for one chain selector. */
export const wireChain = (selector: bigint, state: ChainState): Wired => {
	const mock = EvmMock.testInstance(selector)
	const wired: Wired = { writes: [], readHeights: [] }

	mock.callContract = ((input: { call?: { to: Uint8Array; data: Uint8Array }; blockNumber?: { absVal: Uint8Array; sign: bigint } }) => {
		const to = bytesToHex(input.call!.to).toLowerCase() as Hex
		const call = decodeFunctionData({ abi: readAbi, data: bytesToHex(input.call!.data) })
		const fn: string = call.functionName
		const height = input.blockNumber && input.blockNumber.sign > 0n ? bytesToBigint(input.blockNumber.absVal) : 'special'
		wired.readHeights.push({ fn, to, block: height })

		let data: Hex
		switch (call.functionName) {
			case 'totalSupply':
				data = encodeFunctionResult({ abi: erc20Abi, functionName: 'totalSupply', result: state.supplies?.[to] ?? 0n })
				break
			case 'balanceOf':
				data = encodeFunctionResult({ abi: erc20Abi, functionName: 'balanceOf', result: state.balances?.[to] ?? 0n })
				break
			case 'getWindowUsage': {
				const w = state.window ?? { outflow: 0n, senderTransfers: 0n }
				data = encodeFunctionResult({
					abi: countersignVerifierAbi,
					functionName: 'getWindowUsage',
					result: [w.outflow, w.senderTransfers],
				})
				break
			}
			case 'getAttestations': {
				const ids = call.args[0] as readonly Hex[]
				data = encodeFunctionResult({
					abi: countersignVerifierAbi,
					functionName: 'getAttestations',
					result: ids.map((id) => ({
						sourceChainSelector: 0n,
						verdict: state.verdicts?.[id.toLowerCase()] ?? 0,
						reasonCodes: 0,
						updatedAt: 0,
						evidenceHash: pad('0x0'),
					})),
				})
				break
			}
			case 'latestRoundData': {
				const r = state.reserve ?? { answer: 0n, updatedAt: 0n }
				data = encodeFunctionResult({
					abi: aggregatorV3Abi,
					functionName: 'latestRoundData',
					result: [1n, r.answer, r.updatedAt, r.updatedAt, 1n],
				})
				break
			}
			default:
				throw new Error(`unexpected call ${fn}`)
		}
		return { data: b64(data) }
	}) as never

	mock.headerByNumber = (() => ({ header: { blockNumber: bigJson(state.finalized ?? 0n), timestamp: '0' } })) as never
	mock.filterLogs = (() => ({ logs: (state.logs ?? []).map(logJson) })) as never
	mock.getTransactionReceipt = (() => ({
		receipt: { status: '1', logs: (state.receiptLogs ?? []).map(logJson) },
	})) as never
	mock.writeReport = ((input: { receiver: Uint8Array; report?: { rawReport: Uint8Array } }) => {
		wired.writes.push({
			receiver: bytesToHex(input.receiver).toLowerCase() as Hex,
			payload: bytesToHex(input.report!.rawReport.subarray(REPORT_METADATA_HEADER_LENGTH)),
		})
		return {
			txStatus: 'TX_STATUS_SUCCESS',
			receiverContractExecutionStatus: state.receiverReverts
				? 'RECEIVER_CONTRACT_EXECUTION_STATUS_REVERTED'
				: 'RECEIVER_CONTRACT_EXECUTION_STATUS_SUCCESS',
			txHash: b64(pad(toHex(wired.writes.length))),
		}
	}) as never

	return wired
}

/** CountersignRequested log as emitted by the source verifier. */
export const countersignLog = (
	verifier: Hex,
	messageId: Hex,
	destChainSelector: bigint,
	messageNumber: bigint,
	encodedMessage: Hex,
	txHash: Hex,
	blockNumber: bigint,
): LogSpec => ({
	address: verifier,
	topics: encodeEventTopics({
		abi: countersignVerifierAbi,
		eventName: 'CountersignRequested',
		args: { messageId, destChainSelector },
	}) as Hex[],
	data: encodeAbiParameters([{ type: 'uint64' }, { type: 'bytes' }], [messageNumber, encodedMessage]),
	txHash,
	blockNumber,
})

/** CCIPMessageSent log as emitted by the OnRamp (only the topics matter to the workflow). */
export const onRampLog = (onRamp: Hex, destChainSelector: bigint, sender: Hex, messageId: Hex, txHash: Hex): LogSpec => ({
	address: onRamp,
	topics: encodeEventTopics({
		abi: onRampAbi,
		eventName: 'CCIPMessageSent',
		args: { destChainSelector, sender, messageId },
	}) as Hex[],
	data: '0x',
	txHash,
	blockNumber: 0n,
})

/** Converts a LogSpec into the EVMLog shape the log trigger delivers. */
export const asTriggerLog = (log: LogSpec) =>
	({
		address: hexToBytes(log.address),
		topics: log.topics.map((t) => hexToBytes(t)),
		txHash: hexToBytes(log.txHash),
		data: hexToBytes(log.data),
		blockNumber: { absVal: bigintToBytes(log.blockNumber), sign: 1n },
	}) as never
