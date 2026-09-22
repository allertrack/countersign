// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared verdicts and reason codes between the Countersign CRE workflows and the onchain verifier.
/// @dev Reason codes are a bitmask so a single HOLD can carry every failed check. Keep in sync with
/// `workflows/shared/codes.ts`.
library CountersignCodes {
  uint8 internal constant VERDICT_NONE = 0;
  uint8 internal constant VERDICT_APPROVED = 1;
  uint8 internal constant VERDICT_HELD = 2;

  /// @dev The burn/lock could not be found on the source chain at the required finality.
  uint32 internal constant SOURCE_EVENT_NOT_FINAL = 1 << 0;
  /// @dev The recomputed messageId does not match the one emitted by the OnRamp.
  uint32 internal constant MESSAGE_ID_MISMATCH = 1 << 1;
  /// @dev Sum of remote supplies plus this transfer exceeds what is locked on the home chain.
  uint32 internal constant SUPPLY_INVARIANT_BREACH = 1 << 2;
  /// @dev Proof of Reserve reports less collateral than circulating supply (Secure Mint).
  uint32 internal constant RESERVE_SHORTFALL = 1 << 3;
  /// @dev The rolling per-lane outflow window would be exceeded.
  uint32 internal constant WINDOW_LIMIT_EXCEEDED = 1 << 4;
  /// @dev Transfer velocity for the sender/receiver is anomalous.
  uint32 internal constant VELOCITY_ANOMALY = 1 << 5;
  /// @dev Denied by the issuer's compliance policy (ACE / sanctions / allowlist).
  uint32 internal constant POLICY_DENIED = 1 << 6;
  /// @dev Held manually by a guardian.
  uint32 internal constant MANUAL_REVIEW = 1 << 7;
  /// @dev The Proof of Reserve feed is older than the configured maximum age.
  uint32 internal constant RESERVE_STALE = 1 << 8;
  /// @dev The message could not be decoded or targets an unexpected lane.
  uint32 internal constant MALFORMED_MESSAGE = 1 << 9;
}
