import { describe, expect, test } from 'bun:test'
import { decodeMessageV1, evmAddressFromAbiWord, evmAddressFromRaw, messageIdOf } from '../src/messageV1'
import { GOLDEN } from './fixtures'

describe('MessageV1 decoder (golden vector from live CCIP v2)', () => {
	const message = decodeMessageV1(GOLDEN.encodedMessage)

	test('messageId is keccak256 of the wire encoding', () => {
		expect(messageIdOf(GOLDEN.encodedMessage)).toBe(GOLDEN.messageId)
	})

	test('header fields', () => {
		expect(message.version).toBe(1)
		expect(message.sourceChainSelector).toBe(GOLDEN.sourceChainSelector)
		expect(message.destChainSelector).toBe(GOLDEN.destChainSelector)
		expect(message.messageNumber).toBe(GOLDEN.messageNumber)
		expect(message.executionGasLimit).toBe(519_400)
		expect(message.ccipReceiveGasLimit).toBe(0)
		expect(message.data).toBe('0x')
	})

	test('addresses use source-padded / destination-raw encodings', () => {
		expect(evmAddressFromAbiWord(message.onRampAddress)).toBe(GOLDEN.onRamp)
		expect(evmAddressFromRaw(message.offRampAddress)).toBe(GOLDEN.offRamp)
		expect(evmAddressFromAbiWord(message.sender)).toBe(GOLDEN.user)
		expect(evmAddressFromRaw(message.receiver)).toBe(GOLDEN.user)
	})

	test('token transfer', () => {
		expect(message.tokenTransfer).toHaveLength(1)
		const [transfer] = message.tokenTransfer
		expect(transfer.amount).toBe(GOLDEN.amount)
		expect(evmAddressFromAbiWord(transfer.sourcePoolAddress)).toBe(GOLDEN.sourcePool)
		expect(evmAddressFromAbiWord(transfer.sourceTokenAddress)).toBe(GOLDEN.sourceToken)
		expect(evmAddressFromRaw(transfer.destTokenAddress)).toBe(GOLDEN.destToken)
		expect(evmAddressFromRaw(transfer.tokenReceiver)).toBe(GOLDEN.user)
	})

	test('rejects truncated and trailing input', () => {
		expect(() => decodeMessageV1(GOLDEN.encodedMessage.slice(0, -2) as `0x${string}`)).toThrow()
		expect(() => decodeMessageV1(`${GOLDEN.encodedMessage}00`)).toThrow('trailing bytes')
	})
})
