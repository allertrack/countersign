// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";

/// @notice CRE report receiver interface (same selector as `@chainlink/contracts` keystone IReceiver).
/// @dev Redeclared against OpenZeppelin 5.3.0's IERC165 so it can be combined with CCIP v2 verifiers, which use that
/// version. The interface ID is identical to the upstream one.
interface IReceiver is IERC165 {
  /// @notice Handles incoming CRE reports delivered by the Chainlink Forwarder.
  /// @param metadata abi.encodePacked(workflowId, workflowName, workflowOwner).
  /// @param report The workflow report.
  function onReport(
    bytes calldata metadata,
    bytes calldata report
  ) external;
}
