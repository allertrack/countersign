#!/usr/bin/env bun
import { parseArgs } from 'node:util'
import type { Hex } from 'viem'
import { CHAINS } from './chains'
import { executeMessage } from './execute'

const usage = `countersign-execute --source <chain> --tx <sourceTxHash> [--wait] [--timeout 1800] [--dry-run] [--indexer <url>]

Executes a CCIP v2 message protected by Countersign on its destination chain, with the committee's verifier results
from Chainlink's public indexer and Countersign's onchain attestation. Signs with PRIVATE_KEY (execution is
permissionless: any funded account works).

chains: ${Object.keys(CHAINS).join(', ')}`

const { values } = parseArgs({
	options: {
		source: { type: 'string' },
		tx: { type: 'string' },
		wait: { type: 'boolean', default: false },
		timeout: { type: 'string', default: '1800' },
		'dry-run': { type: 'boolean', default: false },
		indexer: { type: 'string', multiple: true },
		help: { type: 'boolean', default: false },
	},
})

if (values.help || !values.source || !values.tx) {
	console.log(usage)
	process.exit(values.help ? 0 : 1)
}

try {
	const result = await executeMessage({
		sourceChain: values.source,
		txHash: values.tx as Hex,
		wait: values.wait,
		timeoutSeconds: Number(values.timeout),
		dryRun: values['dry-run'],
		privateKey: process.env.PRIVATE_KEY as Hex | undefined,
		indexerUrls: values.indexer,
	})
	console.log(JSON.stringify({ messageId: result.messageId, state: result.state, executionTx: result.executionTx }))
	process.exit(result.state === 'SUCCESS' ? 0 : 2)
} catch (error) {
	console.error((error as Error).message)
	process.exit(1)
}
