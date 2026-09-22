import { parseAbi } from 'viem'

export const COUNTERSIGN_VERSION_TAG = '0xc5160001' as const

export const offRampAbi = parseAbi([
	'function execute(bytes encodedMessage, address[] ccvs, bytes[] verifierResults, uint32 gasLimitOverride)',
	'function getCCVsForMessage(bytes encodedMessage) view returns (address[] requiredCCVs, address[] optionalCCVs, uint8 threshold)',
	'function getExecutionState(bytes32 messageId) view returns (uint8)',
	'function typeAndVersion() view returns (string)',
	'event ExecutionStateChanged(uint64 indexed sourceChainSelector, uint64 indexed messageNumber, bytes32 indexed messageId, uint8 state, bytes returnData)',
])

export const routerAbi = parseAbi([
	'struct OffRamp { uint64 sourceChainSelector; address offRamp; }',
	'function getOffRamps() view returns (OffRamp[])',
	'function getOnRamp(uint64 destChainSelector) view returns (address)',
])

export const resolverAbi = parseAbi(['function getInboundImplementation(bytes verifierResults) view returns (address)'])

export const countersignVerifierAbi = parseAbi([
	'event CountersignRequested(bytes32 indexed messageId, uint64 indexed destChainSelector, uint64 messageNumber, bytes encodedMessage)',
	'struct AttestationRecord { uint64 sourceChainSelector; uint8 verdict; uint32 reasonCodes; uint40 updatedAt; bytes32 evidenceHash; }',
	'function getAttestation(bytes32 messageId) view returns (AttestationRecord)',
])

export const onRampAbi = parseAbi([
	'struct Receipt { address issuer; uint32 destGasLimit; uint32 destBytesOverhead; uint256 feeTokenAmount; bytes extraArgs; }',
	'event CCIPMessageSent(uint64 indexed destChainSelector, address indexed sender, bytes32 indexed messageId, address feeToken, uint256 tokenAmountBeforeTokenPoolFees, bytes encodedMessage, Receipt[] receipts, bytes[] verifierBlobs)',
])

export const ExecutionState = ['UNTOUCHED', 'IN_PROGRESS', 'SUCCESS', 'FAILURE'] as const
export const VerdictName = ['NONE', 'APPROVED', 'HELD'] as const
