import { describe, expect, test } from 'bun:test'
import type { Address, Hex } from 'viem'
import { GOLDEN } from '../../../workflows/countersign/test/fixtures'
import { stringify } from '../src/format'
import { COUNTERSIGN_VERSION_TAG, type Deps, handle } from '../src/handler'

const COMMITTEE = '0x8f3ee3c77D2B27c32306a89D367654F959Db223D' as Address
const COUNTERSIGN = '0x4Fdcd0e856c7Fa092Ad710668F529fac277f9d8f' as Address
const POOL = GOLDEN.sourcePool
const EXECUTOR = '0x66f9e0738a4a6fe54ae62ded00ca1f72bdecc092' as Address
const NETWORK = '0x0000000000000000000000000000000000000000' as Address

const deps = (verdict: number): Deps => ({
	async findRequest(messageId) {
		if (messageId !== GOLDEN.messageId) return undefined
		return {
			encodedMessage: GOLDEN.encodedMessage,
			receipts: [COMMITTEE, COUNTERSIGN, POOL, EXECUTOR, NETWORK].map((issuer) => ({ issuer })),
			sourceResolver: COUNTERSIGN,
		}
	},
	async getAttestation(destChainSelector) {
		expect(destChainSelector).toBe(GOLDEN.destChainSelector)
		return { verdict, updatedAt: 1_790_000_000, destResolver: COUNTERSIGN }
	},
})

const get = (query: string, d: Deps) => handle(new Request(`http://api.test/v1/verifications?${query}`), d)

describe('CCV Verifier Result API (verifications.v1.openapi.yaml)', () => {
	test('returns the spec shape for an approved token transfer', async () => {
		const res = await get(`messageID=${GOLDEN.messageId}`, deps(1))
		expect(res.status).toBe(200)
		const text = await res.text()
		// uint64 selectors and amounts are bare JSON numbers, even above 2^53.
		expect(text).toContain('"source_chain_selector":16015286601757825753')
		expect(text).toContain('"amount":5000000000000000000000')

		const body = JSON.parse(text)
		const [result] = body.results
		expect(body.errors).toBeUndefined()
		expect(result.ccv_data).toBe(COUNTERSIGN_VERSION_TAG)
		expect(result.message_ccv_addresses).toEqual([COMMITTEE.toLowerCase(), COUNTERSIGN.toLowerCase()])
		expect(result.message_executor_address).toBe(EXECUTOR)
		expect(result.metadata).toEqual({
			timestamp: 1_790_000_000_000,
			verifier_source_address: COUNTERSIGN.toLowerCase(),
			verifier_dest_address: COUNTERSIGN.toLowerCase(),
		})

		const m = result.message
		expect(m.version).toBe(1)
		expect(m.sequence_number).toBe(56)
		expect(m.on_ramp_address).toBe(`0x000000000000000000000000${GOLDEN.onRamp.slice(2).toLowerCase()}`)
		expect(m.on_ramp_address_length).toBe(32)
		expect(m.off_ramp_address).toBe(GOLDEN.offRamp.toLowerCase())
		expect(m.off_ramp_address_length).toBe(20)
		expect(m.sender_length).toBe(32)
		expect(m.receiver_length).toBe(20)
		expect(m.execution_gas_limit).toBe(519_400)
		expect(m.finality).toBe(0)
		expect(m.dest_blob).toBe('0x')
		expect(m.data).toBe('0x')
		expect(m.data_length).toBe(0)
		expect(m.token_transfer_length).toBe(175)
		expect(m.token_transfer.source_pool_address_length).toBe(32)
		expect(m.token_transfer.dest_token_address_length).toBe(20)
		expect(m.token_transfer.extra_data_length).toBe(32)
		expect(Object.keys(m).sort()).toEqual(
			[
				'version', 'source_chain_selector', 'dest_chain_selector', 'sequence_number', 'on_ramp_address',
				'off_ramp_address', 'finality', 'execution_gas_limit', 'ccip_receive_gas_limit', 'ccv_and_executor_hash',
				'sender', 'receiver', 'dest_blob', 'token_transfer', 'data', 'on_ramp_address_length',
				'off_ramp_address_length', 'sender_length', 'receiver_length', 'dest_blob_length', 'data_length',
				'token_transfer_length',
			].sort(),
		)
	})

	test('fails safe: held or unknown messages are never published, 404 when nothing is attested', async () => {
		const held = await get(`messageID=${GOLDEN.messageId}`, deps(2))
		expect(held.status).toBe(404)
		expect((await held.json()).results).toEqual([])

		const unknown = `0x${'00'.repeat(32)}`
		const mixed = await get(`messageID=${GOLDEN.messageId}&messageID=${unknown}`, deps(1))
		expect(mixed.status).toBe(200)
		const body = await mixed.json()
		expect(body.results).toHaveLength(1)
		expect(body.errors).toEqual([`${unknown}: no Countersign request found`])
	})

	test('validates input and batch size', async () => {
		expect((await get('', deps(1))).status).toBe(400)
		expect((await get('messageID=0x1234', deps(1))).status).toBe(400)
		const tooMany = Array.from({ length: 21 }, () => `messageID=${GOLDEN.messageId}`).join('&')
		expect((await get(tooMany, deps(1))).status).toBe(400)
		expect((await handle(new Request('http://api.test/other'), deps(1))).status).toBe(404)
	})

	test('stringify keeps big integers exact', () => {
		expect(stringify({ a: 2n ** 64n - 1n, b: 'x' })).toBe('{"a":18446744073709551615,"b":"x"}')
	})
})
