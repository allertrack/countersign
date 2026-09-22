import type { Address, Hex } from 'viem'
import type { MessageV1 } from '../../../workflows/countersign/src/messageV1'

/**
 * JSON shapes of the CCIP v2 CCV Verifier Result API (`verifications.v1.openapi.yaml`, OpenAPI 3.0.3).
 * uint64 values and token amounts are bare JSON numbers that may exceed 2^53; see `stringify`.
 */
export type ApiTokenTransfer = {
	amount: bigint
	source_pool_address: Hex
	source_token_address: Hex
	dest_token_address: Hex
	token_receiver: Hex
	extra_data: Hex
	version: number
	source_pool_address_length: number
	source_token_address_length: number
	dest_token_address_length: number
	token_receiver_length: number
	extra_data_length: number
}

export type ApiMessage = {
	version: number
	source_chain_selector: bigint
	dest_chain_selector: bigint
	sequence_number: bigint
	on_ramp_address: string
	off_ramp_address: string
	finality: number
	execution_gas_limit: number
	ccip_receive_gas_limit: number
	ccv_and_executor_hash: Hex
	sender: string
	receiver: string
	dest_blob: Hex
	token_transfer: ApiTokenTransfer | null
	data: Hex
	on_ramp_address_length: number
	off_ramp_address_length: number
	sender_length: number
	receiver_length: number
	dest_blob_length: number
	data_length: number
	token_transfer_length: number
}

export type ApiVerifierResult = {
	message: ApiMessage
	message_ccv_addresses: string[]
	message_executor_address: string
	ccv_data: Hex
	metadata?: { timestamp?: number; verifier_source_address?: string; verifier_dest_address?: string }
}

export type ApiResponse = { results: ApiVerifierResult[]; errors?: string[] }

const byteLength = (hex: Hex) => (hex.length - 2) / 2
const lower = <T extends string>(hex: T) => hex.toLowerCase() as T
/** Spec: an empty address serializes as "" (not "0x"). */
const address = (hex: Hex) => (hex === '0x' ? '' : lower(hex))

/** Wire length of the encoded TokenTransferV1 (1 version + 32 amount + 4 one-byte lengths + 2-byte extraData length). */
const tokenTransferLength = (t: MessageV1['tokenTransfer'][number]) =>
	1 + 32 + 1 + byteLength(t.sourcePoolAddress) + 1 + byteLength(t.sourceTokenAddress) + 1 + byteLength(t.destTokenAddress) +
	1 + byteLength(t.tokenReceiver) + 2 + byteLength(t.extraData)

export const toApiMessage = (m: MessageV1): ApiMessage => {
	const t = m.tokenTransfer[0]
	return {
		version: m.version,
		source_chain_selector: m.sourceChainSelector,
		dest_chain_selector: m.destChainSelector,
		sequence_number: m.messageNumber,
		on_ramp_address: address(m.onRampAddress),
		off_ramp_address: address(m.offRampAddress),
		finality: Number.parseInt(m.finality.slice(2), 16),
		execution_gas_limit: m.executionGasLimit,
		ccip_receive_gas_limit: m.ccipReceiveGasLimit,
		ccv_and_executor_hash: lower(m.ccvAndExecutorHash),
		sender: address(m.sender),
		receiver: address(m.receiver),
		dest_blob: lower(m.destBlob),
		token_transfer: t
			? {
					amount: t.amount,
					source_pool_address: lower(t.sourcePoolAddress),
					source_token_address: lower(t.sourceTokenAddress),
					dest_token_address: lower(t.destTokenAddress),
					token_receiver: lower(t.tokenReceiver),
					extra_data: lower(t.extraData),
					version: 1,
					source_pool_address_length: byteLength(t.sourcePoolAddress),
					source_token_address_length: byteLength(t.sourceTokenAddress),
					dest_token_address_length: byteLength(t.destTokenAddress),
					token_receiver_length: byteLength(t.tokenReceiver),
					extra_data_length: byteLength(t.extraData),
				}
			: null,
		data: lower(m.data),
		on_ramp_address_length: byteLength(m.onRampAddress),
		off_ramp_address_length: byteLength(m.offRampAddress),
		sender_length: byteLength(m.sender),
		receiver_length: byteLength(m.receiver),
		dest_blob_length: byteLength(m.destBlob),
		data_length: byteLength(m.data),
		token_transfer_length: t ? tokenTransferLength(t) : 0,
	}
}

/**
 * OnRamp receipts are ordered: verifiers..., [token pool,] executor, network fee.
 * Returns the CCV issuers and the executor named in the message.
 */
export const ccvsAndExecutor = (
	receipts: readonly { issuer: Address }[],
	hasTokenTransfer: boolean,
): { ccvs: string[]; executor: string } => {
	const trailing = hasTokenTransfer ? 3 : 2
	if (receipts.length < trailing) return { ccvs: [], executor: '' }
	return {
		ccvs: receipts.slice(0, receipts.length - trailing).map((r) => lower(r.issuer)),
		executor: lower(receipts[receipts.length - 2].issuer),
	}
}

/** JSON.stringify that writes bigints as bare JSON numbers, as the spec requires for uint64 and amounts. */
export const stringify = (value: unknown): string =>
	JSON.stringify(value, (_key, v) => (typeof v === 'bigint' ? `__bigint__${v.toString()}` : v)).replace(
		/"__bigint__(\d+)"/g,
		'$1',
	)
