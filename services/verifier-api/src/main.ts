import { readFileSync } from 'node:fs'
import {
	type Address,
	type Hex,
	type PublicClient,
	createPublicClient,
	http,
	parseAbi,
	parseEventLogs,
} from 'viem'
import { CHAINS, chainBySelector } from '../../../tools/executor/src/chains'
import type { AttestationRecord, Deps, RequestRecord } from './handler'
import { handle } from './handler'

/**
 * Countersign CCV Verifier Result API.
 *
 * Config (JSON file at $COUNTERSIGN_API_CONFIG):
 * { "chains": [{ "name": "ethereum-testnet-sepolia", "verifier": "0x..", "resolver": "0x..", "lookbackBlocks": 200000 }] }
 * Every chain is both a possible source (CountersignRequested) and destination (attestations).
 */
type ChainConfig = { name: string; verifier: Address; resolver: Address; lookbackBlocks?: number; logRange?: number }

const verifierAbi = parseAbi([
	'event CountersignRequested(bytes32 indexed messageId, uint64 indexed destChainSelector, uint64 messageNumber, bytes encodedMessage)',
	'struct AttestationRecord { uint64 sourceChainSelector; uint8 verdict; uint32 reasonCodes; uint40 updatedAt; bytes32 evidenceHash; }',
	'function getAttestation(bytes32 messageId) view returns (AttestationRecord)',
])
const onRampAbi = parseAbi([
	'struct Receipt { address issuer; uint32 destGasLimit; uint32 destBytesOverhead; uint256 feeTokenAmount; bytes extraArgs; }',
	'event CCIPMessageSent(uint64 indexed destChainSelector, address indexed sender, bytes32 indexed messageId, address feeToken, uint256 tokenAmountBeforeTokenPoolFees, bytes encodedMessage, Receipt[] receipts, bytes[] verifierBlobs)',
])

const configs: ChainConfig[] = JSON.parse(readFileSync(process.env.COUNTERSIGN_API_CONFIG ?? 'config.json', 'utf8')).chains
const clients = new Map<string, PublicClient>(
	configs.map((c) => [c.name, createPublicClient({ chain: CHAINS[c.name].chain, transport: http(CHAINS[c.name].rpcUrl) })]),
)
/** Requests are immutable once finalized, so they are cached forever; attestations are always read live. */
const requests = new Map<Hex, RequestRecord>()

const findOnChain = async (config: ChainConfig, messageId: Hex): Promise<RequestRecord | undefined> => {
	const client = clients.get(config.name) as PublicClient
	const latest = await client.getBlockNumber()
	const range = BigInt(config.logRange ?? 10_000)
	const floor = latest - BigInt(config.lookbackBlocks ?? 200_000)
	for (let to = latest; to > floor && to > 0n; to -= range) {
		const from = to - range + 1n > 0n ? to - range + 1n : 0n
		const [log] = await client.getContractEvents({
			address: config.verifier,
			abi: verifierAbi,
			eventName: 'CountersignRequested',
			args: { messageId },
			fromBlock: from,
			toBlock: to,
		})
		if (!log) continue
		const receipt = await client.getTransactionReceipt({ hash: log.transactionHash })
		const [sent] = parseEventLogs({ abi: onRampAbi, logs: receipt.logs, eventName: 'CCIPMessageSent' })
		return {
			encodedMessage: log.args.encodedMessage as Hex,
			receipts: sent?.args.receipts ?? [],
			sourceResolver: config.resolver,
		}
	}
	return undefined
}

const deps: Deps = {
	async findRequest(messageId) {
		const cached = requests.get(messageId)
		if (cached) return cached
		for (const config of configs) {
			const found = await findOnChain(config, messageId)
			if (found) {
				requests.set(messageId, found)
				return found
			}
		}
		return undefined
	},
	async getAttestation(destChainSelector, messageId): Promise<AttestationRecord | undefined> {
		const dest = configs.find((c) => c.name === chainBySelector(destChainSelector).name)
		if (!dest) return undefined
		const record = await (clients.get(dest.name) as PublicClient).readContract({
			address: dest.verifier,
			abi: verifierAbi,
			functionName: 'getAttestation',
			args: [messageId],
		})
		return { verdict: record.verdict, updatedAt: Number(record.updatedAt), destResolver: dest.resolver }
	},
}

const port = Number(process.env.PORT ?? 8787)
Bun.serve({ port, fetch: (req) => handle(req, deps) })
console.log(`Countersign verifier API on :${port} (GET /v1/verifications?messageID=0x...)`)
