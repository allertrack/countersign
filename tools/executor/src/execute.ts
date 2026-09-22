import {
	type Address,
	type Hex,
	createPublicClient,
	createWalletClient,
	getAddress,
	http,
	parseEventLogs,
	zeroAddress,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { decodeMessageV1 } from '../../../workflows/countersign/src/messageV1'
import {
	COUNTERSIGN_VERSION_TAG,
	ExecutionState,
	VerdictName,
	countersignVerifierAbi,
	offRampAbi,
	onRampAbi,
	resolverAbi,
} from './abi'
import { TESTNET_INDEXER_URLS, chainByName, chainBySelector } from './chains'
import { type ExecutionPlan, fetchIndexerResults, planExecution } from './plan'

export type ExecuteOptions = {
	sourceChain: string
	txHash: Hex
	/** Poll until every required verifier result is available (and Countersign has attested). */
	wait?: boolean
	timeoutSeconds?: number
	pollSeconds?: number
	dryRun?: boolean
	privateKey?: Hex
	indexerUrls?: string[]
	log?: (line: string) => void
}

export type ExecuteResult = {
	messageId: Hex
	state: (typeof ExecutionState)[number]
	executionTx?: Hex
	plan?: ExecutionPlan
}

const sleep = (s: number) => new Promise((r) => setTimeout(r, s * 1000))

/**
 * Executes a CCIP v2 message whose token pool requires Countersign, using only public data: the committee's
 * verifier results from Chainlink's indexer and Countersign's onchain attestation. OffRamp.execute is permissionless.
 */
export async function executeMessage(opts: ExecuteOptions): Promise<ExecuteResult> {
	const log = opts.log ?? console.log
	const source = chainByName(opts.sourceChain)
	const sourceClient = createPublicClient({ chain: source.chain, transport: http(source.rpcUrl) })

	const receipt = await sourceClient.getTransactionReceipt({ hash: opts.txHash })
	const [sent] = parseEventLogs({ abi: onRampAbi, logs: receipt.logs, eventName: 'CCIPMessageSent' })
	if (!sent) throw new Error(`no CCIPMessageSent in ${opts.txHash}`)
	const { messageId, encodedMessage, destChainSelector } = sent.args
	const message = decodeMessageV1(encodedMessage)
	const dest = chainBySelector(destChainSelector)
	const offRamp = getAddress(message.offRampAddress)
	const destClient = createPublicClient({ chain: dest.chain, transport: http(dest.rpcUrl) })
	log(`message ${messageId}: ${source.name} -> ${dest.name}, OffRamp ${offRamp}`)

	const state = async () =>
		ExecutionState[
			Number(await destClient.readContract({ address: offRamp, abi: offRampAbi, functionName: 'getExecutionState', args: [messageId] }))
		]
	if ((await state()) === 'SUCCESS') {
		log('already executed')
		return { messageId, state: 'SUCCESS' }
	}

	const [required, optional, threshold] = await destClient.readContract({
		address: offRamp,
		abi: offRampAbi,
		functionName: 'getCCVsForMessage',
		args: [encodedMessage],
	})

	// A CCV is a Countersign CCV if its resolver routes Countersign's version tag to an implementation.
	const countersign = new Map<string, Address>()
	for (const ccv of [...required, ...optional]) {
		const impl = await destClient
			.readContract({ address: ccv, abi: resolverAbi, functionName: 'getInboundImplementation', args: [COUNTERSIGN_VERSION_TAG] })
			.catch(() => zeroAddress)
		if (impl !== zeroAddress) countersign.set(ccv.toLowerCase(), impl)
	}
	log(`required CCVs: ${required.join(', ')}${countersign.size ? ` (Countersign: ${[...countersign.keys()].join(', ')})` : ''}`)

	const deadline = Date.now() + (opts.timeoutSeconds ?? 1_800) * 1000
	let plan: ExecutionPlan
	for (;;) {
		const pending: string[] = []
		for (const [ccv, impl] of countersign) {
			const record = await destClient.readContract({
				address: impl,
				abi: countersignVerifierAbi,
				functionName: 'getAttestation',
				args: [messageId],
			})
			const verdict = VerdictName[record.verdict] ?? `UNKNOWN(${record.verdict})`
			if (verdict === 'HELD') {
				log(`Countersign ${ccv} HOLDS this message (reason bitmask ${record.reasonCodes}); a guardian must review it`)
				return { messageId, state: await state() }
			}
			if (verdict !== 'APPROVED') pending.push(`Countersign ${ccv} not attested yet`)
		}

		const indexerResults = await fetchIndexerResults(messageId, opts.indexerUrls ?? TESTNET_INDEXER_URLS)
		plan = planExecution(required, indexerResults, new Set(countersign.keys()))
		// Satisfy the optional quorum with whatever optional CCVs the indexer already has.
		for (const ccv of optional) {
			if (plan.ccvs.length - required.length >= threshold) break
			const result = indexerResults.find((r) => r.verifierDestAddress.toLowerCase() === ccv.toLowerCase())
			if (result) {
				plan.ccvs.push(ccv)
				plan.verifierResults.push(result.ccvData)
			}
		}
		for (const ccv of plan.missing) pending.push(`no indexer result for ${ccv} yet`)

		if (pending.length === 0) break
		if (!opts.wait || Date.now() > deadline) {
			throw new Error(`not executable yet: ${pending.join('; ')}`)
		}
		log(`waiting: ${pending.join('; ')}`)
		await sleep(opts.pollSeconds ?? 20)
	}

	if (opts.dryRun) {
		log(`dry run: execute(${plan.ccvs.length} CCVs)`)
		return { messageId, state: await state(), plan }
	}
	if (!opts.privateKey) throw new Error('PRIVATE_KEY is required to send the execution transaction')

	const wallet = createWalletClient({
		account: privateKeyToAccount(opts.privateKey),
		chain: dest.chain,
		transport: http(dest.rpcUrl),
	})
	const executionTx = await wallet.writeContract({
		address: offRamp,
		abi: offRampAbi,
		functionName: 'execute',
		args: [encodedMessage, plan.ccvs, plan.verifierResults, 0],
	})
	await destClient.waitForTransactionReceipt({ hash: executionTx })
	const finalState = await state()
	log(`execute tx ${executionTx}: ${finalState}`)
	return { messageId, state: finalState, executionTx, plan }
}
