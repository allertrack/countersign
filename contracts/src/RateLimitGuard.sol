// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CREReceiverBase} from "./cre/CREReceiverBase.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";

import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";

import {Ownable2StepMsgSender} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2StepMsgSender.sol";
import {IERC165} from "@openzeppelin/contracts@5.3.0/utils/introspection/IERC165.sol";

/// @title RateLimitGuard
/// @notice Lets the Countersign `supply-sentinel` CRE handler act as a circuit breaker on CCIP v2 token pools, with no
/// power to loosen anything. The pool owner installs it as the pool's `rateLimitAdmin`; loosening stays with the owner.
///
/// Every requested config is clamped against the live bucket before it is applied, per direction:
/// - a disabled limiter may become enabled (unlimited -> limited); an enabled limiter is never disabled;
/// - applied `capacity` = min(requested, tokens available right now);
/// - applied `rate` = min(requested, current rate, applied capacity).
///
/// The capacity bound matters because CCIP v2 refills a bucket to its full capacity whenever its config changes
/// (`RateLimiter._setTokenBucketConfig`). Lowering capacity from 1,000 to 500 while an attacker has drained the bucket to
/// 100 would hand them 400 fresh tokens. Clamping (rather than rejecting) also means a report that lands after the
/// bucket drained further still tightens instead of failing in the middle of an attack.
contract RateLimitGuard is Ownable2StepMsgSender, CREReceiverBase {
  error StaleReport(uint64 issuedAt, uint64 lastIssuedAt);

  event PoolManagementSet(address indexed pool, bool managed);
  event RateLimitTightened(
    address indexed pool,
    uint64 indexed remoteChainSelector,
    bool fastFinality,
    RateLimiter.Config outbound,
    RateLimiter.Config inbound,
    bytes32 evidenceHash
  );
  /// @dev reason: 1 = pool not managed, 2 = outbound would be disabled, 3 = inbound would be disabled,
  /// 4 = pool call reverted.
  event TighteningRejected(address indexed pool, uint64 indexed remoteChainSelector, uint8 reason);

  uint8 internal constant REJECT_POOL_NOT_MANAGED = 1;
  uint8 internal constant REJECT_OUTBOUND_DISABLE = 2;
  uint8 internal constant REJECT_INBOUND_DISABLE = 3;
  uint8 internal constant REJECT_POOL_CALL_REVERTED = 4;

  /// @notice One entry of a report. Report: `abi.encode(uint64 chainSelector, uint64 issuedAt, Tightening[])`.
  struct Tightening {
    address pool;
    uint64 remoteChainSelector;
    bool fastFinality;
    RateLimiter.Config outbound;
    RateLimiter.Config inbound;
    bytes32 evidenceHash; // Hash of the invariant snapshot that justified the action.
  }

  string public constant typeAndVersion = "RateLimitGuard 1.0.0";

  mapping(address pool => bool managed) internal s_managedPools;
  /// @dev Reports must be strictly newer than the last accepted one (same-chain replay protection).
  uint64 internal s_lastIssuedAt;

  constructor(
    uint64 localChainSelector,
    WorkflowIdentity memory workflowIdentity
  ) CREReceiverBase(localChainSelector, workflowIdentity) {}

  // forge-lint: disable-next-item(boolean-cst)
  /// @notice Clamps `requested` so that applying it can never loosen `current`.
  /// @return applied The config that would be applied.
  /// @return ok False when the request would disable the limiter.
  function clamp(
    RateLimiter.TokenBucket memory current,
    RateLimiter.Config memory requested
  ) public pure returns (RateLimiter.Config memory applied, bool ok) {
    if (!requested.isEnabled) return (requested, false);
    uint128 capacity = requested.capacity;
    uint128 rate = requested.rate;
    if (current.isEnabled) {
      if (current.tokens < capacity) capacity = current.tokens;
      if (current.rate < rate) rate = current.rate;
    }
    if (capacity < rate) rate = capacity;
    return (RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate}), true);
  }

  function isManaged(
    address pool
  ) external view returns (bool) {
    return s_managedPools[pool];
  }

  function getLastIssuedAt() external view returns (uint64) {
    return s_lastIssuedAt;
  }

  function setPoolManagement(
    address pool,
    bool managed
  ) external onlyOwner {
    if (pool == address(0)) revert ZeroAddress();
    s_managedPools[pool] = managed;
    emit PoolManagementSet(pool, managed);
  }

  function setWorkflowIdentity(
    WorkflowIdentity memory workflowIdentity
  ) external onlyOwner {
    _setWorkflowIdentity(workflowIdentity);
  }

  /// @dev Report: abi.encode(uint64 chainSelector, uint64 issuedAt, Tightening[]). One bad entry never blocks the rest.
  function _processReport(
    bytes calldata report
  ) internal override {
    (, uint64 issuedAt, Tightening[] memory tightenings) = abi.decode(report, (uint64, uint64, Tightening[]));
    if (issuedAt <= s_lastIssuedAt) revert StaleReport(issuedAt, s_lastIssuedAt);
    s_lastIssuedAt = issuedAt;

    for (uint256 i = 0; i < tightenings.length; ++i) {
      _applyTightening(tightenings[i]);
    }
  }

  // forge-lint: disable-next-item(calls-loop, reentrancy-events)
  /// @dev Pools are allowlisted by the owner (`setPoolManagement`), so the external calls and the events that follow
  /// them only touch trusted CCIP token pools. Per-pool try/catch keeps one faulty pool from blocking the others.
  function _applyTightening(
    Tightening memory t
  ) internal {
    if (!s_managedPools[t.pool]) {
      emit TighteningRejected(t.pool, t.remoteChainSelector, REJECT_POOL_NOT_MANAGED);
      return;
    }

    TokenPool pool = TokenPool(t.pool);
    TokenPool.RateLimitConfigArgs[] memory args = new TokenPool.RateLimitConfigArgs[](1);
    args[0].remoteChainSelector = t.remoteChainSelector;
    args[0].fastFinality = t.fastFinality;

    try pool.getCurrentRateLimiterState(t.remoteChainSelector, t.fastFinality) returns (
      RateLimiter.TokenBucket memory outboundState, RateLimiter.TokenBucket memory inboundState
    ) {
      bool ok;
      (args[0].outboundRateLimiterConfig, ok) = clamp(outboundState, t.outbound);
      if (!ok) {
        emit TighteningRejected(t.pool, t.remoteChainSelector, REJECT_OUTBOUND_DISABLE);
        return;
      }
      (args[0].inboundRateLimiterConfig, ok) = clamp(inboundState, t.inbound);
      if (!ok) {
        emit TighteningRejected(t.pool, t.remoteChainSelector, REJECT_INBOUND_DISABLE);
        return;
      }
    } catch {
      emit TighteningRejected(t.pool, t.remoteChainSelector, REJECT_POOL_CALL_REVERTED);
      return;
    }

    try pool.setRateLimitConfig(args) {
      emit RateLimitTightened(
        t.pool,
        t.remoteChainSelector,
        t.fastFinality,
        args[0].outboundRateLimiterConfig,
        args[0].inboundRateLimiterConfig,
        t.evidenceHash
      );
    } catch {
      emit TighteningRejected(t.pool, t.remoteChainSelector, REJECT_POOL_CALL_REVERTED);
    }
  }

  /// @inheritdoc IERC165
  function supportsInterface(
    bytes4 interfaceId
  ) external pure override returns (bool) {
    return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
  }
}
