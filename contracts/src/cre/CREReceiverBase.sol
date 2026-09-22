// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReceiver} from "../interfaces/IReceiver.sol";

/// @notice Authenticates CRE reports delivered by the Chainlink Forwarder and binds them to this chain.
/// @dev Differences from the CRE `ReceiverTemplate`:
/// - An identity with neither `workflowId` nor `workflowOwner` rejects every report, unless `trustForwarderOnly` is set
///   explicitly. That flag exists only for `cre workflow simulate`, whose `MockKeystoneForwarder` delivers no workflow
///   metadata; never set it with a production `KeystoneForwarder`.
/// - Reports carry the target chain selector (first ABI word) and are rejected on any other chain, closing the
///   cross-chain replay vector described in the CRE docs ("Replay attacks").
/// - Ownership is left to the concrete contract so it composes with CCIP's `Ownable2StepMsgSender`.
abstract contract CREReceiverBase is IReceiver {
  error InvalidForwarder(address sender);
  error WorkflowIdentityNotConfigured();
  error InvalidWorkflowId(bytes32 received);
  error InvalidWorkflowOwner(address received);
  error InvalidWorkflowName(bytes10 received);
  error InvalidMetadata();
  error WrongChain(uint64 received, uint64 expected);
  error ZeroAddress();

  event WorkflowIdentitySet(
    address forwarder, bytes32 workflowId, address workflowOwner, bytes10 workflowName, bool trustForwarderOnly
  );
  event SecurityWarning(string message);

  struct WorkflowIdentity {
    address forwarder; // Chainlink KeystoneForwarder on this chain (MockKeystoneForwarder for simulation).
    bytes32 workflowId; // Optional, pins one exact workflow version (changes on every redeploy).
    address workflowOwner; // Optional, pins the workflow owner. Recommended in production.
    bytes10 workflowName; // Optional, only checked together with workflowOwner.
    bool trustForwarderOnly; // SIMULATION ONLY: accept any workflow the forwarder delivers.
  }

  /// @dev abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner). The production forwarder
  /// delivers a 64-byte slice (these 62 bytes plus the 2-byte reportId), so only a minimum length is enforced.
  uint256 internal constant METADATA_MIN_LENGTH = 62;

  uint64 internal immutable i_localChainSelector;

  WorkflowIdentity internal s_workflowIdentity;

  constructor(
    uint64 localChainSelector,
    WorkflowIdentity memory workflowIdentity
  ) {
    i_localChainSelector = localChainSelector;
    _setWorkflowIdentity(workflowIdentity);
  }

  /// @inheritdoc IReceiver
  /// @dev Every report starts with `uint64 chainSelector` as its first ABI word.
  function onReport(
    bytes calldata metadata,
    bytes calldata report
  ) external {
    _assertValidReportOrigin(metadata);
    uint64 target = abi.decode(report[:32], (uint64));
    if (target != i_localChainSelector) revert WrongChain(target, i_localChainSelector);
    _processReport(report);
  }

  function getWorkflowIdentity() external view returns (WorkflowIdentity memory) {
    return s_workflowIdentity;
  }

  function getLocalChainSelector() external view returns (uint64) {
    return i_localChainSelector;
  }

  /// @notice Handles an authenticated report whose target chain has already been checked.
  function _processReport(
    bytes calldata report
  ) internal virtual;

  function _assertValidReportOrigin(
    bytes calldata metadata
  ) internal view {
    WorkflowIdentity memory identity = s_workflowIdentity;
    if (msg.sender != identity.forwarder) revert InvalidForwarder(msg.sender);
    if (identity.trustForwarderOnly) return;
    if (identity.workflowId == bytes32(0) && identity.workflowOwner == address(0)) {
      revert WorkflowIdentityNotConfigured();
    }
    if (metadata.length < METADATA_MIN_LENGTH) revert InvalidMetadata();

    bytes32 workflowId = bytes32(metadata[0:32]);
    bytes10 workflowName = bytes10(metadata[32:42]);
    address workflowOwner = address(bytes20(metadata[42:62]));

    if (identity.workflowId != bytes32(0) && workflowId != identity.workflowId) revert InvalidWorkflowId(workflowId);
    if (identity.workflowOwner != address(0)) {
      if (workflowOwner != identity.workflowOwner) revert InvalidWorkflowOwner(workflowOwner);
      if (identity.workflowName != bytes10(0) && workflowName != identity.workflowName) {
        revert InvalidWorkflowName(workflowName);
      }
    }
  }

  function _setWorkflowIdentity(
    WorkflowIdentity memory workflowIdentity
  ) internal {
    if (workflowIdentity.forwarder == address(0)) revert ZeroAddress();
    s_workflowIdentity = workflowIdentity;
    if (workflowIdentity.trustForwarderOnly) {
      emit SecurityWarning("trustForwarderOnly: any workflow can report through this forwarder (simulation only)");
    }
    emit WorkflowIdentitySet(
      workflowIdentity.forwarder,
      workflowIdentity.workflowId,
      workflowIdentity.workflowOwner,
      workflowIdentity.workflowName,
      workflowIdentity.trustForwarderOnly
    );
  }
}
