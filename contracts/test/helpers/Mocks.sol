// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockRMN {
  mapping(bytes16 subject => bool cursed) internal s_cursed;

  function setCursed(
    uint64 chainSelector,
    bool cursed
  ) external {
    s_cursed[bytes16(uint128(chainSelector))] = cursed;
  }

  function isCursed(
    bytes16 subject
  ) external view returns (bool) {
    return s_cursed[subject];
  }

  function isCursed() external pure returns (bool) {
    return false;
  }

  function getCursedSubjects() external pure returns (bytes16[] memory) {
    return new bytes16[](0);
  }
}

/// @dev Only the router surface that verifiers and pools touch.
contract MockRouter {
  mapping(uint64 destChainSelector => address onRamp) internal s_onRamps;
  mapping(uint64 sourceChainSelector => mapping(address offRamp => bool allowed)) internal s_offRamps;

  function setOnRamp(
    uint64 destChainSelector,
    address onRamp
  ) external {
    s_onRamps[destChainSelector] = onRamp;
  }

  function setOffRamp(
    uint64 sourceChainSelector,
    address offRamp,
    bool allowed
  ) external {
    s_offRamps[sourceChainSelector][offRamp] = allowed;
  }

  function getOnRamp(
    uint64 destChainSelector
  ) external view returns (address) {
    return s_onRamps[destChainSelector];
  }

  function isOffRamp(
    uint64 sourceChainSelector,
    address offRamp
  ) external view returns (bool) {
    return s_offRamps[sourceChainSelector][offRamp];
  }
}
