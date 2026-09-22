// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MessageV1Codec} from "@chainlink/contracts-ccip/contracts/libraries/MessageV1Codec.sol";

/// @notice LOCAL FORKS ONLY. Replaces Chainlink's committee verifier resolver on an anvil fork (via `anvil_setCode`)
/// so a message can be executed without the committee's real signatures. Countersign is still fully enforced.
contract LocalCommitteeStub {
  function getInboundImplementation(
    bytes calldata
  ) external view returns (address) {
    return address(this);
  }

  function verifyMessage(
    MessageV1Codec.MessageV1 calldata,
    bytes32,
    bytes calldata
  ) external pure {}
}
