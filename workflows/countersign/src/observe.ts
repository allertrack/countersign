import { type Runtime, bytesToHex, hexToBase64 } from '@chainlink/cre-sdk'
import { type Hex, decodeFunctionResult, encodeEventTopics, encodeFunctionData } from 'viem'
import { aggregatorV3Abi, countersignVerifierAbi, erc20Abi, onRampAbi } from './abi'
import { type BlockRef, call, clientFor } from './chain'
import type { Config, Source } from './config'
import type { Policy, SupplySnapshot } from './policy'

const CCIP_MESSAGE_SENT = encodeEventTopics({ abi: onRampAbi, eventName: 'CCIPMessageSent' })[0] as Hex

/** Read height for `chain`: the event block on the chain the event came from, finalized elsewhere. */
export type ReadAt = { chain: string; block: bigint } | undefined
const heightFor = (chain: string, at: ReadAt): BlockRef => (at && at.chain === chain ? at.block : 'finalized')

const totalSupply = (runtime: Runtime<Config>, chain: string, token: Hex, at: ReadAt): bigint =>
	decodeFunctionResult({
		abi: erc20Abi,
		functionName: 'totalSupply',
		data: call(runtime, chain, token, encodeFunctionData({ abi: erc20Abi, functionName: 'totalSupply' }), heightFor(chain, at)),
	})

const balanceOf = (runtime: Runtime<Config>, chain: string, token: Hex, holder: Hex, at: ReadAt): bigint =>
	decodeFunctionResult({
		abi: erc20Abi,
		functionName: 'balanceOf',
		data: call(
			runtime,
			chain,
			token,
			encodeFunctionData({ abi: erc20Abi, functionName: 'balanceOf', args: [holder] }),
			heightFor(chain, at),
		),
	})

/**
 * Global supply state. Reads on the source chain use the event's block so the burn/lock being verified is always
 * included, even if the trigger fired as soon as that block finalized; other chains use their finalized head.
 */
export const readSupply = (runtime: Runtime<Config>, at: ReadAt): SupplySnapshot => {
	const token = runtime.config.token
	let snapshot: SupplySnapshot
	if (token.mode === 'burnMint') {
		const all = token.deployments.reduce((sum, d) => sum + totalSupply(runtime, d.chainSelectorName, d.token as Hex, at), 0n)
		snapshot = { circulating: all, backing: BigInt(token.canonicalSupply), liability: all }
	} else {
		const home = token.deployments.find((d) => d.chainSelectorName === token.homeChainSelectorName)
		if (!home) throw new Error('lockRelease: home chain missing from deployments')
		const remote = token.deployments
			.filter((d) => d.chainSelectorName !== token.homeChainSelectorName)
			.reduce((sum, d) => sum + totalSupply(runtime, d.chainSelectorName, d.token as Hex, at), 0n)
		snapshot = {
			circulating: remote,
			backing: balanceOf(runtime, home.chainSelectorName, home.token as Hex, token.lockBox as Hex, at),
			liability: totalSupply(runtime, home.chainSelectorName, home.token as Hex, at),
		}
	}
	return { ...snapshot, ...readReserve(runtime) }
}

/** Proof of Reserve answer rescaled to token decimals, and its age against DON time. */
const readReserve = (runtime: Runtime<Config>): Pick<SupplySnapshot, 'reserve' | 'reserveAgeSeconds'> => {
	const feed = runtime.config.reserveFeed
	if (!feed) return {}
	const [, answer, , updatedAt] = decodeFunctionResult({
		abi: aggregatorV3Abi,
		functionName: 'latestRoundData',
		data: call(
			runtime,
			feed.chainSelectorName,
			feed.address as Hex,
			encodeFunctionData({ abi: aggregatorV3Abi, functionName: 'latestRoundData' }),
		),
	})
	const shift = feed.tokenDecimals - feed.decimals
	const positive = answer < 0n ? 0n : answer
	const reserve = shift >= 0 ? positive * 10n ** BigInt(shift) : positive / 10n ** BigInt(-shift)
	const nowSeconds = BigInt(Math.floor(runtime.now().getTime() / 1000))
	const age = nowSeconds > updatedAt ? Number(nowSeconds - updatedAt) : 0
	return { reserve, reserveAgeSeconds: age }
}

/** The canonical OnRamp must have emitted CCIPMessageSent for this messageId in the very same transaction. */
export const onRampEventInTx = (runtime: Runtime<Config>, source: Source, txHash: Hex, messageId: Hex): boolean => {
	const reply = clientFor(source.chainSelectorName).getTransactionReceipt(runtime, { hash: hexToBase64(txHash) }).result()
	const onRamps = source.onRamps.map((a) => a.toLowerCase())
	return (reply.receipt?.logs ?? []).some((log) => {
		const topics = log.topics.map((t) => bytesToHex(t))
		return (
			onRamps.includes(bytesToHex(log.address).toLowerCase()) &&
			topics[0] === CCIP_MESSAGE_SENT &&
			topics[3]?.toLowerCase() === messageId.toLowerCase()
		)
	})
}

/** Rolling-window usage kept onchain by the source CountersignVerifier, read at the event's block. */
export const windowUsage = (
	runtime: Runtime<Config>,
	source: Source,
	destChainSelector: bigint,
	token: Hex,
	sender: Hex,
	block: bigint,
): { outflow: bigint; senderTransfers: bigint } => {
	const [outflow, senderTransfers] = decodeFunctionResult({
		abi: countersignVerifierAbi,
		functionName: 'getWindowUsage',
		data: call(
			runtime,
			source.chainSelectorName,
			source.verifier as Hex,
			encodeFunctionData({
				abi: countersignVerifierAbi,
				functionName: 'getWindowUsage',
				args: [destChainSelector, token, sender],
			}),
			block,
		),
	})
	return { outflow, senderTransfers }
}

export const policyFrom = (config: Config, sourceChain?: string): Policy => ({
	allowedSourceTokens: config.token.deployments
		.filter((d) => sourceChain === undefined || d.chainSelectorName === sourceChain)
		.map((d) => d.token as Hex),
	denylist: config.policy.denylist as Hex[],
	supplyTolerance: BigInt(config.policy.supplyTolerance),
	maxWindowOutflow: config.policy.maxWindowOutflow ? BigInt(config.policy.maxWindowOutflow) : undefined,
	maxTransfersPerSender:
		config.policy.maxTransfersPerSender !== undefined ? BigInt(config.policy.maxTransfersPerSender) : undefined,
	maxReserveAgeSeconds: config.reserveFeed?.maxAgeSeconds,
	version: config.policy.version,
})
