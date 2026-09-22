// SPDX-License-Identifier: BUSL-1.1
// Derivative of Chainlink CCIP v2.0 `BaseVerifier`. Production use is permitted by Additional Use Grant 3(c) of the
// CCIP v2.0 license ("an independent verifier implementation that conforms to the verifier interface").
pragma solidity ^0.8.24;

import {IReceiver} from "./interfaces/IReceiver.sol";
import {ICrossChainVerifierV1} from "@chainlink/contracts-ccip/contracts/interfaces/ICrossChainVerifierV1.sol";

import {CREReceiverBase} from "./cre/CREReceiverBase.sol";
import {CountersignCodes} from "./libraries/CountersignCodes.sol";

import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {FeeTokenHandler} from "@chainlink/contracts-ccip/contracts/libraries/FeeTokenHandler.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/contracts/libraries/MessageV1Codec.sol";

import {Ownable2StepMsgSender} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2StepMsgSender.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";
import {EnumerableSet} from "@openzeppelin/contracts@5.3.0/utils/structs/EnumerableSet.sol";

/// @title CountersignVerifier
/// @notice An issuer-operated Cross-Chain Verifier (CCV) for CCIP v2 whose offchain component is a Chainlink Runtime
/// Environment (CRE) workflow instead of a self-hosted node.
///
/// Source chain: the OnRamp calls `forwardToVerifier` for every message whose token pool requires this CCV. The
/// contract records the transfer in rolling window counters and emits `CountersignRequested`, the log trigger of the
/// `countersign` CRE workflow. Only transfers of the issuer's own tokens are accepted, so third parties cannot flood the
/// workflow by naming this CCV in their extraArgs.
///
/// Destination chain: the workflow independently re-verifies the source burn/lock, the issuer's supply invariants and
/// policies, then delivers a DON-signed report through the Chainlink Forwarder (`onReport`). The attestation is stored
/// onchain and `verifyMessage` only passes for APPROVED messages.
///
/// Safety model ("automation can only tighten"):
/// - The workflow can move a message NONE -> APPROVED, NONE -> HELD and APPROVED -> HELD.
/// - Only the guardian (the issuer's multisig) can move HELD -> APPROVED.
/// - The guardian or owner can pause; while paused new Countersign-gated sends revert and nothing verifies.
///   Only the owner can unpause.
/// @dev Source and destination responsibilities live in the same contract, like `CommitteeVerifier`, so a single
/// `VersionedVerifierResolver` address can front it on every chain.
contract CountersignVerifier is Ownable2StepMsgSender, BaseVerifier, CREReceiverBase {
  using EnumerableSet for EnumerableSet.AddressSet;

  error InvalidVerifierResults();
  error InvalidCCVVersion(bytes4 verifierVersion);
  error MessageNotAttested(bytes32 messageId);
  error MessageHeld(bytes32 messageId, uint32 reasonCodes);
  error SourceChainMismatch(bytes32 messageId, uint64 expected, uint64 actual);
  error VerificationPaused();
  error UnsupportedMessage(bytes32 messageId);
  error OnlyGuardian(address caller);
  error OnlyGuardianOrOwner(address caller);
  error NotHeld(bytes32 messageId);
  error InvalidSourceChain();
  error InvalidWindowEpoch(uint32 epochSeconds);

  /// @notice Emitted on the source chain for every message that requires Countersign. CRE log trigger.
  event CountersignRequested(
    bytes32 indexed messageId, uint64 indexed destChainSelector, uint64 messageNumber, bytes encodedMessage
  );
  event AttestationRecorded(
    bytes32 indexed messageId,
    uint64 indexed sourceChainSelector,
    uint8 verdict,
    uint32 reasonCodes,
    bytes32 evidenceHash
  );
  /// @notice The workflow downgraded a previously approved message to HELD before it was executed.
  event AttestationRevoked(bytes32 indexed messageId, uint32 reasonCodes, bytes32 evidenceHash);
  /// @notice A report entry was not applied. Batches never revert because of a single entry.
  event AttestationIgnored(bytes32 indexed messageId, uint8 currentVerdict, uint8 requestedVerdict);
  event HoldReleased(bytes32 indexed messageId, address indexed guardian, bytes32 reviewHash);
  event HoldPlaced(bytes32 indexed messageId, address indexed guardian, bytes32 reviewHash);
  event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
  event FeeAggregatorSet(address indexed feeAggregator);
  event PausedSet(bool paused, address indexed by);
  event VerifiedTokenSet(address indexed token, bool verified);
  event WindowEpochSet(uint32 epochSeconds);

  /// @notice One entry of a CRE attestation report. Report: `abi.encode(uint64 chainSelector, Attestation[])`.
  struct Attestation {
    bytes32 messageId; // keccak256 of the encoded MessageV1, binds every field of the message.
    uint64 sourceChainSelector; // Must match the message's source chain at verification time.
    uint8 verdict; // CountersignCodes.VERDICT_*.
    uint32 reasonCodes; // Bitmask of failed checks, 0 when approved.
    bytes32 evidenceHash; // Hash of the evidence bundle (supply snapshot, policy version, window usage).
  }

  struct StaticConfig {
    address rmn; // RMN proxy used for curse checks.
    bytes4 versionTag; // Version tag routed by the VersionedVerifierResolver.
    uint64 localChainSelector; // CCIP chain selector of this chain; reports for other chains are rejected.
    address guardian; // Issuer multisig: releases holds, may pause.
    address feeAggregator; // Receives fees withdrawn from this contract.
  }

  struct AttestationRecord {
    uint64 sourceChainSelector; // ──╮
    uint8 verdict; //                │
    uint32 reasonCodes; //           │
    uint40 updatedAt; // ────────────╯
    bytes32 evidenceHash;
  }

  string public constant override typeAndVersion = "CountersignVerifier 1.0.0";

  uint256 internal constant VERIFIER_VERSION_BYTES = 4;
  uint32 internal constant MIN_WINDOW_EPOCH = 60;

  address internal s_guardian;
  address internal s_feeAggregator;
  bool internal s_paused;
  /// @dev Rolling windows are the sum of the current and previous epoch.
  uint32 internal s_windowEpoch = 1 hours;

  EnumerableSet.AddressSet internal s_verifiedTokens;
  mapping(bytes32 messageId => AttestationRecord record) internal s_attestations;
  /// @dev keccak256(destChainSelector, token, epochLength, epochIndex) => amount sent.
  mapping(bytes32 key => uint256 amount) internal s_laneOutflow;
  /// @dev keccak256(sender, epochLength, epochIndex) => Countersign-gated transfers sent.
  mapping(bytes32 key => uint256 count) internal s_senderTransfers;

  constructor(
    string[] memory storageLocations,
    StaticConfig memory config,
    WorkflowIdentity memory workflowIdentity
  )
    BaseVerifier(storageLocations, config.rmn, config.versionTag)
    CREReceiverBase(config.localChainSelector, workflowIdentity)
  {
    _setGuardian(config.guardian);
    _setFeeAggregator(config.feeAggregator);
  }

  // ================================================================
  // │                       Source chain                           │
  // ================================================================

  /// @inheritdoc ICrossChainVerifierV1
  /// @dev Only callable by the OnRamp registered on the configured router, so every `CountersignRequested` event was
  /// produced by a real `ccipSend`. The workflow still re-derives the messageId from the encoded message.
  function forwardToVerifier(
    MessageV1Codec.MessageV1 calldata message,
    bytes32 messageId,
    address, // feeToken
    uint256, // feeTokenAmount
    bytes calldata // verifierArgs
  ) external returns (bytes memory verifierReturnData) {
    if (s_paused) revert VerificationPaused();
    _assertNotCursedByRMN(message.destChainSelector);

    // For EVM, sender is abi encoded.
    address sender = abi.decode(message.sender, (address));
    _assertSenderIsAllowed(message.destChainSelector, sender);

    if (message.tokenTransfer.length != 1) revert UnsupportedMessage(messageId);
    address token = abi.decode(message.tokenTransfer[0].sourceTokenAddress, (address));
    if (!s_verifiedTokens.contains(token)) revert UnsupportedMessage(messageId);

    uint256 epoch = block.timestamp / s_windowEpoch;
    s_laneOutflow[_laneKey(message.destChainSelector, token, epoch)] += message.tokenTransfer[0].amount;
    ++s_senderTransfers[_senderKey(sender, epoch)];

    emit CountersignRequested(
      messageId, message.destChainSelector, message.messageNumber, MessageV1Codec._encodeMessageV1(message)
    );

    return abi.encodePacked(versionTag());
  }

  /// @notice Countersign-gated usage over the rolling window (current + previous epoch) at this block.
  /// @return outflow Amount of `token` sent towards `destChainSelector`.
  /// @return senderTransfers Countersign-gated transfers initiated by `sender` (all lanes and tokens).
  function getWindowUsage(
    uint64 destChainSelector,
    address token,
    address sender
  ) external view returns (uint256 outflow, uint256 senderTransfers) {
    uint256 epoch = block.timestamp / s_windowEpoch;
    outflow = s_laneOutflow[_laneKey(destChainSelector, token, epoch)];
    senderTransfers = s_senderTransfers[_senderKey(sender, epoch)];
    // forge-lint: disable-next-line(block-timestamp)
    if (epoch > 0) {
      outflow += s_laneOutflow[_laneKey(destChainSelector, token, epoch - 1)];
      senderTransfers += s_senderTransfers[_senderKey(sender, epoch - 1)];
    }
  }

  // ================================================================
  // │                    Destination chain                         │
  // ================================================================

  /// @inheritdoc ICrossChainVerifierV1
  /// @dev `verifierResults` only carries the version tag: the proof is the attestation stored by `onReport`, which was
  /// authenticated by the Forwarder (F+1 DON signatures) and the workflow identity checks.
  function verifyMessage(
    MessageV1Codec.MessageV1 calldata message,
    bytes32 messageId,
    bytes calldata verifierResults
  ) external view {
    if (s_paused) revert VerificationPaused();
    _assertNotCursedByRMN(message.sourceChainSelector);

    if (verifierResults.length < VERIFIER_VERSION_BYTES) revert InvalidVerifierResults();
    bytes4 verifierVersion = bytes4(verifierResults[:VERIFIER_VERSION_BYTES]);
    if (verifierVersion != versionTag()) revert InvalidCCVVersion(verifierVersion);

    AttestationRecord memory record = s_attestations[messageId];
    if (record.verdict == CountersignCodes.VERDICT_HELD) revert MessageHeld(messageId, record.reasonCodes);
    if (record.verdict != CountersignCodes.VERDICT_APPROVED) revert MessageNotAttested(messageId);
    if (record.sourceChainSelector != message.sourceChainSelector) {
      revert SourceChainMismatch(messageId, record.sourceChainSelector, message.sourceChainSelector);
    }
  }

  /// @dev Report: abi.encode(uint64 chainSelector, Attestation[]). Origin and chain checked by `CREReceiverBase`.
  function _processReport(
    bytes calldata report
  ) internal override {
    (, Attestation[] memory attestations) = abi.decode(report, (uint64, Attestation[]));
    for (uint256 i = 0; i < attestations.length; ++i) {
      _applyAttestation(attestations[i]);
    }
  }

  /// @notice Releases a message held by the workflow after human review.
  /// @param reviewHash Hash of the review record (e.g. the incident report).
  function releaseHold(
    bytes32 messageId,
    bytes32 reviewHash
  ) external {
    if (msg.sender != s_guardian) revert OnlyGuardian(msg.sender);
    AttestationRecord storage record = s_attestations[messageId];
    if (record.verdict != CountersignCodes.VERDICT_HELD) revert NotHeld(messageId);

    record.verdict = CountersignCodes.VERDICT_APPROVED;
    record.updatedAt = _timestamp40();
    emit HoldReleased(messageId, msg.sender, reviewHash);
  }

  /// @notice Holds a message proactively (e.g. the source chain is known to be compromised).
  /// @param sourceChainSelector Only used when the message has no record yet.
  function placeHold(
    bytes32 messageId,
    uint64 sourceChainSelector,
    bytes32 reviewHash
  ) external {
    if (msg.sender != s_guardian) revert OnlyGuardian(msg.sender);
    AttestationRecord storage record = s_attestations[messageId];
    if (record.verdict == CountersignCodes.VERDICT_NONE) {
      if (sourceChainSelector == 0) revert InvalidSourceChain();
      record.sourceChainSelector = sourceChainSelector;
    }
    record.verdict = CountersignCodes.VERDICT_HELD;
    record.reasonCodes |= CountersignCodes.MANUAL_REVIEW;
    record.updatedAt = _timestamp40();
    emit HoldPlaced(messageId, msg.sender, reviewHash);
  }

  function getAttestation(
    bytes32 messageId
  ) external view returns (AttestationRecord memory) {
    return s_attestations[messageId];
  }

  /// @notice Batch read used by the workflow's re-drive sweep (one EVM read instead of one per message).
  function getAttestations(
    bytes32[] calldata messageIds
  ) external view returns (AttestationRecord[] memory records) {
    records = new AttestationRecord[](messageIds.length);
    for (uint256 i = 0; i < messageIds.length; ++i) {
      records[i] = s_attestations[messageIds[i]];
    }
  }

  function _applyAttestation(
    Attestation memory attestation
  ) internal {
    AttestationRecord storage record = s_attestations[attestation.messageId];
    uint8 current = record.verdict;
    uint8 requested = attestation.verdict;

    bool validRequest = requested == CountersignCodes.VERDICT_APPROVED || requested == CountersignCodes.VERDICT_HELD;
    bool sameSource =
      current == CountersignCodes.VERDICT_NONE || record.sourceChainSelector == attestation.sourceChainSelector;

    if (validRequest && attestation.sourceChainSelector != 0 && current == CountersignCodes.VERDICT_NONE) {
      record.sourceChainSelector = attestation.sourceChainSelector;
      record.verdict = requested;
      record.reasonCodes = attestation.reasonCodes;
      record.updatedAt = _timestamp40();
      record.evidenceHash = attestation.evidenceHash;
      emit AttestationRecorded(
        attestation.messageId,
        attestation.sourceChainSelector,
        requested,
        attestation.reasonCodes,
        attestation.evidenceHash
      );
      return;
    }

    // Tightening an approval is allowed, loosening a hold is not.
    if (
      validRequest && sameSource && current == CountersignCodes.VERDICT_APPROVED
        && requested == CountersignCodes.VERDICT_HELD
    ) {
      record.verdict = CountersignCodes.VERDICT_HELD;
      record.reasonCodes = attestation.reasonCodes;
      record.updatedAt = _timestamp40();
      record.evidenceHash = attestation.evidenceHash;
      emit AttestationRevoked(attestation.messageId, attestation.reasonCodes, attestation.evidenceHash);
      return;
    }

    emit AttestationIgnored(attestation.messageId, current, requested);
  }

  function _laneKey(
    uint64 destChainSelector,
    address token,
    uint256 epoch
  ) internal view returns (bytes32) {
    return keccak256(abi.encode(destChainSelector, token, s_windowEpoch, epoch));
  }

  function _senderKey(
    address sender,
    uint256 epoch
  ) internal view returns (bytes32) {
    return keccak256(abi.encode(sender, s_windowEpoch, epoch));
  }

  // ================================================================
  // │                           Config                             │
  // ================================================================

  function applyRemoteChainConfigUpdates(
    RemoteChainConfigArgs[] calldata remoteChainConfigArgs
  ) external onlyOwner {
    _applyRemoteChainConfigUpdates(remoteChainConfigArgs);
  }

  function applyAllowlistUpdates(
    AllowlistConfigArgs[] calldata allowlistConfigArgsItems
  ) external onlyOwner {
    _applyAllowlistUpdates(allowlistConfigArgsItems);
  }

  function setAllowedFinalityConfig(
    bytes4 allowedFinality
  ) external onlyOwner {
    _setAllowedFinalityConfig(allowedFinality);
  }

  function updateStorageLocations(
    string[] memory newLocations
  ) external onlyOwner {
    _setStorageLocations(newLocations);
  }

  function setWorkflowIdentity(
    WorkflowIdentity memory workflowIdentity
  ) external onlyOwner {
    _setWorkflowIdentity(workflowIdentity);
  }

  /// @notice Tokens whose transfers this verifier accepts on the source chain.
  function setVerifiedToken(
    address token,
    bool verified
  ) external onlyOwner {
    if (token == address(0)) revert ZeroAddress();
    if (verified ? s_verifiedTokens.add(token) : s_verifiedTokens.remove(token)) {
      emit VerifiedTokenSet(token, verified);
    }
  }

  function getVerifiedTokens() external view returns (address[] memory) {
    return s_verifiedTokens.values();
  }

  /// @notice Changing the epoch starts fresh window counters.
  function setWindowEpoch(
    uint32 epochSeconds
  ) external onlyOwner {
    if (epochSeconds < MIN_WINDOW_EPOCH) revert InvalidWindowEpoch(epochSeconds);
    s_windowEpoch = epochSeconds;
    emit WindowEpochSet(epochSeconds);
  }

  function getWindowEpoch() external view returns (uint32) {
    return s_windowEpoch;
  }

  function getGuardian() external view returns (address) {
    return s_guardian;
  }

  function setGuardian(
    address guardian
  ) external onlyOwner {
    _setGuardian(guardian);
  }

  function isPaused() external view returns (bool) {
    return s_paused;
  }

  /// @notice Pausing is a tightening action, so the guardian may do it; unpausing is owner-only.
  function pause() external {
    if (msg.sender != s_guardian && msg.sender != owner()) revert OnlyGuardianOrOwner(msg.sender);
    s_paused = true;
    emit PausedSet(true, msg.sender);
  }

  function unpause() external onlyOwner {
    s_paused = false;
    emit PausedSet(false, msg.sender);
  }

  function getFeeAggregator() external view returns (address) {
    return s_feeAggregator;
  }

  /// @dev CCIP pays verifier fees to the address named in the message (normally the resolver, which has its own
  /// aggregator). This covers fees sent to the implementation directly.
  function setFeeAggregator(
    address feeAggregator
  ) external onlyOwner {
    _setFeeAggregator(feeAggregator);
  }

  /// @notice Withdraws any fee tokens held by this contract to the fee aggregator. Permissionless by design.
  function withdrawFeeTokens(
    address[] calldata feeTokens
  ) external {
    FeeTokenHandler._withdrawFeeTokens(feeTokens, s_feeAggregator);
  }

  function _setGuardian(
    address guardian
  ) internal {
    if (guardian == address(0)) revert ZeroAddress();
    address previous = s_guardian;
    s_guardian = guardian;
    emit GuardianSet(previous, guardian);
  }

  function _timestamp40() internal view returns (uint40) {
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint40(block.timestamp); // Fits until the year 36812.
  }

  function _setFeeAggregator(
    address feeAggregator
  ) internal {
    if (feeAggregator == address(0)) revert ZeroAddress();
    s_feeAggregator = feeAggregator;
    emit FeeAggregatorSet(feeAggregator);
  }

  /// @inheritdoc IERC165
  function supportsInterface(
    bytes4 interfaceId
  ) external pure override(BaseVerifier, IERC165) returns (bool) {
    return interfaceId == type(ICrossChainVerifierV1).interfaceId || interfaceId == type(IReceiver).interfaceId
      || interfaceId == type(IERC165).interfaceId;
  }
}
