import { parseAbi, parseAbiParameters } from 'viem'

export const countersignVerifierAbi = parseAbi([
	'event CountersignRequested(bytes32 indexed messageId, uint64 indexed destChainSelector, uint64 messageNumber, bytes encodedMessage)',
	'struct AttestationRecord { uint64 sourceChainSelector; uint8 verdict; uint32 reasonCodes; uint40 updatedAt; bytes32 evidenceHash; }',
	'function getWindowUsage(uint64 destChainSelector, address token, address sender) view returns (uint256 outflow, uint256 senderTransfers)',
	'function getAttestations(bytes32[] messageIds) view returns (AttestationRecord[] records)',
])

export const onRampAbi = parseAbi([
	'struct Receipt { address issuer; uint32 destGasLimit; uint32 destBytesOverhead; uint256 feeTokenAmount; bytes extraArgs; }',
	'event CCIPMessageSent(uint64 indexed destChainSelector, address indexed sender, bytes32 indexed messageId, address feeToken, uint256 tokenAmountBeforeTokenPoolFees, bytes encodedMessage, Receipt[] receipts, bytes[] verifierBlobs)',
])

export const erc20Abi = parseAbi([
	'function totalSupply() view returns (uint256)',
	'function balanceOf(address) view returns (uint256)',
])

export const aggregatorV3Abi = parseAbi([
	'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
])

/** CountersignVerifier.onReport payload: abi.encode(uint64 chainSelector, Attestation[]). */
export const attestationReportParams = parseAbiParameters(
	'uint64 chainSelector, (bytes32 messageId, uint64 sourceChainSelector, uint8 verdict, uint32 reasonCodes, bytes32 evidenceHash)[] attestations',
)

/** RateLimitGuard.onReport payload: abi.encode(uint64 chainSelector, uint64 issuedAt, Tightening[]). */
export const tighteningReportParams = parseAbiParameters(
	'uint64 chainSelector, uint64 issuedAt, (address pool, uint64 remoteChainSelector, bool fastFinality, (bool isEnabled, uint128 capacity, uint128 rate) outbound, (bool isEnabled, uint128 capacity, uint128 rate) inbound, bytes32 evidenceHash)[] tightenings',
)
