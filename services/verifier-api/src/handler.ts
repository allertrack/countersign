import type { Address, Hex } from 'viem'
import { decodeMessageV1 } from '../../../workflows/countersign/src/messageV1'
import { type ApiResponse, type ApiVerifierResult, ccvsAndExecutor, stringify, toApiMessage } from './format'

export const COUNTERSIGN_VERSION_TAG = '0xc5160001' as const
const MAX_IDS = 20
const MESSAGE_ID = /^0x[0-9a-f]{64}$/

/** A Countersign request found on a source chain. */
export type RequestRecord = {
	encodedMessage: Hex
	/** OnRamp receipts of the same message (verifiers..., [token pool,] executor, network fee). */
	receipts: readonly { issuer: Address }[]
	/** Countersign resolver on the source chain (metadata only). */
	sourceResolver?: Address
}

export type AttestationRecord = { verdict: number; updatedAt: number; destResolver?: Address }

export type Deps = {
	findRequest(messageId: Hex): Promise<RequestRecord | undefined>
	getAttestation(destChainSelector: bigint, messageId: Hex): Promise<AttestationRecord | undefined>
}

const APPROVED = 1

/**
 * Builds the positive attestation for one message, or an error string. Unknown, pending and held messages never
 * produce an entry: the API fails safe and never publishes negative attestations.
 */
export const lookup = async (deps: Deps, messageId: Hex): Promise<ApiVerifierResult | string> => {
	const request = await deps.findRequest(messageId)
	if (!request) return `${messageId}: no Countersign request found`

	const message = decodeMessageV1(request.encodedMessage)
	const attestation = await deps.getAttestation(message.destChainSelector, messageId)
	if (!attestation || attestation.verdict !== APPROVED) return `${messageId}: not approved`

	const { ccvs, executor } = ccvsAndExecutor(request.receipts, message.tokenTransfer.length > 0)
	return {
		message: toApiMessage(message),
		message_ccv_addresses: ccvs,
		message_executor_address: executor,
		// The proof is the onchain attestation; verifierResults only has to route to the right implementation.
		ccv_data: COUNTERSIGN_VERSION_TAG,
		metadata: {
			timestamp: attestation.updatedAt * 1000,
			...(request.sourceResolver && { verifier_source_address: request.sourceResolver.toLowerCase() }),
			...(attestation.destResolver && { verifier_dest_address: attestation.destResolver.toLowerCase() }),
		},
	}
}

const json = (status: number, body: ApiResponse | { error: string }) =>
	new Response(stringify(body), {
		status,
		headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*' },
	})

/** `GET /v1/verifications?messageID=<a>&messageID=<b>` (also served without the /v1 prefix). */
export const handle = async (req: Request, deps: Deps): Promise<Response> => {
	const url = new URL(req.url)
	if (url.pathname === '/health') return new Response('ok')
	if (req.method !== 'GET' || !['/v1/verifications', '/verifications'].includes(url.pathname)) {
		return json(404, { error: 'not found' })
	}

	const ids = url.searchParams.getAll('messageID').map((id) => id.toLowerCase())
	if (ids.length === 0 || ids.length > MAX_IDS) return json(400, { error: `between 1 and ${MAX_IDS} messageID values` })
	const invalid = ids.find((id) => !MESSAGE_ID.test(id))
	if (invalid) return json(400, { error: `invalid messageID ${invalid}` })

	const outcomes = await Promise.all(
		ids.map((id) => lookup(deps, id as Hex).catch((e: Error) => `${id}: lookup failed (${e.message})`)),
	)
	const results = outcomes.filter((o): o is ApiVerifierResult => typeof o !== 'string')
	const errors = outcomes.filter((o): o is string => typeof o === 'string')
	const body: ApiResponse = errors.length ? { results, errors } : { results }
	return json(results.length ? 200 : 404, body)
}
