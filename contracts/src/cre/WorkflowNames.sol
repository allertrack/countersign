// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Encodes a CRE workflow name the way the CRE engine puts it in report metadata: the first 10 hex characters
/// of sha256(name), as ASCII bytes. Same algorithm as `ReceiverTemplate.setExpectedWorkflowName`.
library WorkflowNames {
  bytes private constant HEX = "0123456789abcdef";

  function encode(
    string memory name
  ) internal pure returns (bytes10 encoded) {
    bytes32 digest = sha256(bytes(name));
    bytes memory out = new bytes(10);
    for (uint256 i = 0; i < 5; ++i) {
      out[2 * i] = HEX[uint8(digest[i]) >> 4];
      out[2 * i + 1] = HEX[uint8(digest[i]) & 0x0f];
    }
    // forge-lint: disable-next-line(unsafe-typecast)
    encoded = bytes10(out); // `out` is exactly 10 bytes.
  }
}
