import { describe, expect, test } from 'bun:test'
import type { Address, Hex } from 'viem'
import { COUNTERSIGN_VERSION_TAG } from '../src/abi'
import { fetchIndexerResults, parseIndexerResponse, planExecution } from '../src/plan'

const COMMITTEE = '0x8f3ee3c77D2B27c32306a89D367654F959Db223D' as Address
const COUNTERSIGN = '0xCB1ea2f72104b71b224BD7F6254Ceb51E0A5B0aE' as Address
const SIGS = '0xe9a05a2002' as Hex

/** Shape captured from https://indexer-1.testnet.ccip.chain.link/v1/verifierresults/<id> (2026-09-22). */
const indexerBody = {
	success: true,
	results: [
		{
			verifierResult: {
				ccv_data: SIGS,
				verifier_source_address: '0x8f3ee3c77d2b27c32306a89d367654f959db223d',
				verifier_dest_address: '0x8f3ee3c77d2b27c32306a89d367654f959db223d',
			},
		},
	],
}

describe('indexer', () => {
	test('parses verifier results', () => {
		expect(parseIndexerResponse(indexerBody as never)).toEqual([
			{
				ccvData: SIGS,
				verifierDestAddress: '0x8f3ee3c77d2b27c32306a89d367654f959db223d',
				verifierSourceAddress: '0x8f3ee3c77d2b27c32306a89d367654f959db223d',
			},
		])
		expect(parseIndexerResponse({ success: false })).toEqual([])
	})

	test('races indexers and survives a dead one', async () => {
		const fetcher = (async (url: string) =>
			url.startsWith('https://dead')
				? new Response('down', { status: 503 })
				: Response.json(indexerBody)) as unknown as typeof fetch
		const results = await fetchIndexerResults('0x01', ['https://dead.example', 'https://ok.example'], fetcher)
		expect(results).toHaveLength(1)
	})

	test('returns nothing when every indexer fails', async () => {
		const fetcher = (async () => new Response('nope', { status: 404 })) as unknown as typeof fetch
		expect(await fetchIndexerResults('0x01', ['https://a.example'], fetcher)).toEqual([])
	})
})

describe('planExecution', () => {
	test('committee data from the indexer, Countersign by version tag', () => {
		const plan = planExecution([COMMITTEE, COUNTERSIGN], parseIndexerResponse(indexerBody as never), new Set([COUNTERSIGN.toLowerCase()]))
		expect(plan.ccvs).toEqual([COMMITTEE, COUNTERSIGN])
		expect(plan.verifierResults).toEqual([SIGS, COUNTERSIGN_VERSION_TAG])
		expect(plan.missing).toEqual([])
	})

	test('reports CCVs the indexer has not verified yet', () => {
		const plan = planExecution([COMMITTEE, COUNTERSIGN], [], new Set([COUNTERSIGN.toLowerCase()]))
		expect(plan.missing).toEqual([COMMITTEE])
	})
})
