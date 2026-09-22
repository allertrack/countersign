import { type Hex, getAddress, keccak256, toHex } from 'viem'

// TypeScript port of the decoder in CCIP v2 `MessageV1Codec` (wire format, not ABI encoding).
// messageId = keccak256(encodedMessage) on every chain, so the workflow can recompute it itself.

export type TokenTransferV1 = {
	amount: bigint
	sourcePoolAddress: Hex
	sourceTokenAddress: Hex
	destTokenAddress: Hex
	tokenReceiver: Hex
	extraData: Hex
}

export type MessageV1 = {
	version: number
	sourceChainSelector: bigint
	destChainSelector: bigint
	messageNumber: bigint
	executionGasLimit: number
	ccipReceiveGasLimit: number
	finality: Hex
	ccvAndExecutorHash: Hex
	onRampAddress: Hex
	offRampAddress: Hex
	sender: Hex
	receiver: Hex
	destBlob: Hex
	tokenTransfer: TokenTransferV1[]
	data: Hex
}

class Reader {
	private offset = 0
	constructor(private readonly buf: Uint8Array) {}

	uint(size: number): bigint {
		const slice = this.take(size)
		let value = 0n
		for (const byte of slice) value = (value << 8n) | BigInt(byte)
		return value
	}

	bytes(size: number): Hex {
		return toHex(this.take(size))
	}

	lengthPrefixed(prefixSize: 1 | 2): Hex {
		return this.bytes(Number(this.uint(prefixSize)))
	}

	done(): boolean {
		return this.offset === this.buf.length
	}

	private take(size: number): Uint8Array {
		if (this.offset + size > this.buf.length) {
			throw new Error(`MessageV1: read past end (offset ${this.offset}, size ${size}, len ${this.buf.length})`)
		}
		const slice = this.buf.subarray(this.offset, this.offset + size)
		this.offset += size
		return slice
	}
}

const hexToUint8 = (hex: Hex): Uint8Array => {
	const clean = hex.slice(2)
	const out = new Uint8Array(clean.length / 2)
	for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(clean.slice(i * 2, i * 2 + 2), 16)
	return out
}

const decodeTokenTransfer = (encoded: Hex): TokenTransferV1 => {
	const r = new Reader(hexToUint8(encoded))
	const version = Number(r.uint(1))
	if (version !== 1) throw new Error(`TokenTransferV1: unsupported version ${version}`)
	const transfer = {
		amount: r.uint(32),
		sourcePoolAddress: r.lengthPrefixed(1),
		sourceTokenAddress: r.lengthPrefixed(1),
		destTokenAddress: r.lengthPrefixed(1),
		tokenReceiver: r.lengthPrefixed(1),
		extraData: r.lengthPrefixed(2),
	}
	if (!r.done()) throw new Error('TokenTransferV1: trailing bytes')
	return transfer
}

export const decodeMessageV1 = (encoded: Hex): MessageV1 => {
	const r = new Reader(hexToUint8(encoded))
	const version = Number(r.uint(1))
	if (version !== 1) throw new Error(`MessageV1: unsupported version ${version}`)

	const message: MessageV1 = {
		version,
		sourceChainSelector: r.uint(8),
		destChainSelector: r.uint(8),
		messageNumber: r.uint(8),
		executionGasLimit: Number(r.uint(4)),
		ccipReceiveGasLimit: Number(r.uint(4)),
		finality: r.bytes(4),
		ccvAndExecutorHash: r.bytes(32),
		onRampAddress: r.lengthPrefixed(1),
		offRampAddress: r.lengthPrefixed(1),
		sender: r.lengthPrefixed(1),
		receiver: r.lengthPrefixed(1),
		destBlob: r.lengthPrefixed(2),
		tokenTransfer: [],
		data: '0x',
	}

	const tokenTransfer = r.lengthPrefixed(2)
	if (tokenTransfer !== '0x') message.tokenTransfer.push(decodeTokenTransfer(tokenTransfer))
	message.data = r.lengthPrefixed(2)
	if (!r.done()) throw new Error('MessageV1: trailing bytes')
	return message
}

export const messageIdOf = (encoded: Hex): Hex => keccak256(encoded)

/** Source-side EVM addresses are abi.encode(address): 32 bytes, address in the low 20. */
export const evmAddressFromAbiWord = (word: Hex): Hex => {
	if (word.length !== 66) throw new Error(`expected 32-byte abi word, got ${word}`)
	return getAddress(`0x${word.slice(26)}`)
}

/** Destination-side EVM addresses are raw 20 bytes. */
export const evmAddressFromRaw = (raw: Hex): Hex => {
	if (raw.length !== 42) throw new Error(`expected 20-byte address, got ${raw}`)
	return getAddress(raw)
}
