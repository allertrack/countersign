// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RateLimitGuard} from "../src/RateLimitGuard.sol";
import {CREReceiverBase} from "../src/cre/CREReceiverBase.sol";
import {MockRMN, MockRouter} from "./helpers/Mocks.sol";

import {IBurnMintERC20} from "@chainlink/contracts-ccip/contracts/interfaces/IBurnMintERC20.sol";
import {Pool} from "@chainlink/contracts-ccip/contracts/libraries/Pool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";

import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";

contract RateLimitGuardTest is Test {
  uint64 internal constant LOCAL = 16015286601757825753;
  uint64 internal constant REMOTE = 3478487238524512106;

  address internal owner = makeAddr("issuer");
  address internal forwarder = makeAddr("forwarder");
  address internal workflowOwner = makeAddr("workflow-owner");
  address internal onRamp = makeAddr("onRamp");

  MockRouter internal router;
  BurnMintERC20 internal token;
  BurnMintTokenPool internal pool;
  RateLimitGuard internal guard;
  uint64 internal issuedAt = 1_000;

  function setUp() public {
    MockRMN rmn = new MockRMN();
    router = new MockRouter();
    router.setOnRamp(REMOTE, onRamp);

    vm.startPrank(owner);
    token = new BurnMintERC20("Token", "TKN", 18, 0, 1_000_000 ether);
    pool = new BurnMintTokenPool(IBurnMintERC20(address(token)), 18, address(0), address(rmn), address(router));
    token.grantMintAndBurnRoles(address(pool));

    bytes[] memory remotePools = new bytes[](1);
    remotePools[0] = abi.encode(makeAddr("remote-pool"));
    TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
    updates[0] = TokenPool.ChainUpdate({
      remoteChainSelector: REMOTE,
      remotePoolAddresses: remotePools,
      remoteTokenAddress: abi.encode(makeAddr("remote-token")),
      outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000 ether, rate: 10 ether}),
      inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: 1_000 ether, rate: 10 ether})
    });
    pool.applyChainUpdates(new uint64[](0), updates);

    guard = new RateLimitGuard(
      LOCAL,
      CREReceiverBase.WorkflowIdentity({
        forwarder: forwarder,
        workflowId: bytes32(0),
        workflowOwner: workflowOwner,
        workflowName: bytes10(0),
        trustForwarderOnly: false
      })
    );
    guard.setPoolManagement(address(pool), true);
    pool.setDynamicConfig(address(router), address(guard), address(0));
    vm.stopPrank();
  }

  function test_TightensWithinLiveTokens() public {
    _deliver(_tightening(500 ether, 5 ether, 500 ether, 5 ether));
    (RateLimiter.TokenBucket memory outbound, RateLimiter.TokenBucket memory inbound) =
      pool.getCurrentRateLimiterState(REMOTE, false);
    assertEq(outbound.capacity, 500 ether);
    assertEq(inbound.rate, 5 ether);
  }

  function test_CanFreezeLane() public {
    _deliver(_tightening(0, 0, 0, 0));
    (RateLimiter.TokenBucket memory outbound,) = pool.getCurrentRateLimiterState(REMOTE, false);
    assertTrue(outbound.isEnabled);
    assertEq(outbound.tokens, 0);
  }

  /// @dev The refill footgun: after an attacker drains the bucket to 100, a "lower" capacity of 500 would refill it to
  /// 500. The guard clamps to the 100 still available instead, so the attacker gets nothing new and the lane still
  /// tightens even though the report was computed before the last drain.
  function test_ClampsToLiveTokens_AfterDrain() public {
    _drainOutbound(900 ether);
    (RateLimiter.TokenBucket memory before,) = pool.getCurrentRateLimiterState(REMOTE, false);
    assertEq(before.tokens, 100 ether);

    _deliver(_tightening(500 ether, 5 ether, 500 ether, 5 ether));

    (RateLimiter.TokenBucket memory afterward, RateLimiter.TokenBucket memory inbound) =
      pool.getCurrentRateLimiterState(REMOTE, false);
    assertEq(afterward.tokens, 100 ether, "no fresh bucket for the attacker");
    assertEq(afterward.capacity, 100 ether);
    assertEq(afterward.rate, 5 ether);
    assertEq(inbound.capacity, 500 ether, "inbound was not drained");
  }

  function test_NeverRaisesRate() public {
    _deliver(_tightening(500 ether, 5 ether, 500 ether, 50 ether));
    (, RateLimiter.TokenBucket memory inbound) = pool.getCurrentRateLimiterState(REMOTE, false);
    assertEq(inbound.rate, 10 ether, "requested 50, kept the current 10");
  }

  function test_RejectsDisabling() public {
    RateLimitGuard.Tightening[] memory batch = _tightening(0, 0, 0, 0);
    batch[0].outbound = RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
    vm.expectEmit(address(guard));
    emit RateLimitGuard.TighteningRejected(address(pool), REMOTE, 2);
    _deliver(batch);
  }

  function test_RejectsUnmanagedPool() public {
    vm.prank(owner);
    guard.setPoolManagement(address(pool), false);
    vm.expectEmit(address(guard));
    emit RateLimitGuard.TighteningRejected(address(pool), REMOTE, 1);
    _deliver(_tightening(500 ether, 5 ether, 500 ether, 5 ether));
  }

  function test_PoolCallRevert_IsReportedNotBubbled() public {
    RateLimitGuard.Tightening[] memory batch = _tightening(500 ether, 5 ether, 500 ether, 5 ether);
    batch[0].remoteChainSelector = 42; // not configured on the pool: setRateLimitConfig reverts
    vm.expectEmit(address(guard));
    emit RateLimitGuard.TighteningRejected(address(pool), 42, 4);
    _deliver(batch);
  }

  function test_OnlyForwarder() public {
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.InvalidForwarder.selector, address(this)));
    guard.onReport(_metadata(), abi.encode(LOCAL, issuedAt, _tightening(1, 1, 1, 1)));
  }

  function test_RevertWhen_ReportForAnotherChain() public {
    vm.prank(forwarder);
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.WrongChain.selector, REMOTE, LOCAL));
    guard.onReport(_metadata(), abi.encode(REMOTE, issuedAt, _tightening(1, 1, 1, 1)));
  }

  /// @dev CRE docs "same-chain replay on failure": reports must be strictly newer than the last accepted one.
  function test_RevertWhen_ReplayedOrStaleReport() public {
    _deliver(_tightening(900 ether, 9 ether, 900 ether, 9 ether));
    uint64 last = guard.getLastIssuedAt();
    vm.prank(forwarder);
    vm.expectRevert(abi.encodeWithSelector(RateLimitGuard.StaleReport.selector, last, last));
    guard.onReport(_metadata(), abi.encode(LOCAL, last, _tightening(1, 1, 1, 1)));
  }

  /// @dev Whatever is requested, the applied config never lets more tokens flow than the live bucket allows.
  function testFuzz_clamp_NeverLoosens(
    uint128 tokens,
    uint128 capacity,
    uint128 rate,
    bool enabled,
    uint128 requestedCapacity,
    uint128 requestedRate,
    bool requestedEnabled
  ) public view {
    RateLimiter.TokenBucket memory current = RateLimiter.TokenBucket({
      tokens: enabled ? uint128(bound(tokens, 0, capacity)) : 0,
      lastUpdated: 0,
      isEnabled: enabled,
      capacity: capacity,
      rate: rate
    });
    (RateLimiter.Config memory applied, bool ok) = guard.clamp(
      current, RateLimiter.Config({isEnabled: requestedEnabled, capacity: requestedCapacity, rate: requestedRate})
    );

    if (!requestedEnabled) {
      assertFalse(ok);
      return;
    }
    assertTrue(ok);
    assertTrue(applied.isEnabled);
    assertLe(applied.rate, applied.capacity, "pool invariant: rate <= capacity");
    assertLe(applied.capacity, requestedCapacity);
    assertLe(applied.rate, requestedRate);
    if (enabled) {
      assertLe(applied.capacity, current.tokens, "never more than what can flow right now");
      assertLe(applied.rate, current.rate);
    }
  }

  function _drainOutbound(
    uint256 amount
  ) internal {
    vm.prank(owner);
    token.transfer(address(pool), amount);
    vm.prank(onRamp);
    pool.lockOrBurn(
      Pool.LockOrBurnInV1({
        receiver: abi.encode(address(0xBEEF)),
        remoteChainSelector: REMOTE,
        originalSender: address(0xBEEF),
        amount: amount,
        localToken: address(token)
      })
    );
  }

  function _tightening(
    uint128 outCapacity,
    uint128 outRate,
    uint128 inCapacity,
    uint128 inRate
  ) internal view returns (RateLimitGuard.Tightening[] memory batch) {
    batch = new RateLimitGuard.Tightening[](1);
    batch[0] = RateLimitGuard.Tightening({
      pool: address(pool),
      remoteChainSelector: REMOTE,
      fastFinality: false,
      outbound: RateLimiter.Config({isEnabled: true, capacity: outCapacity, rate: outRate}),
      inbound: RateLimiter.Config({isEnabled: true, capacity: inCapacity, rate: inRate}),
      evidenceHash: keccak256("supply snapshot")
    });
  }

  function _metadata() internal view returns (bytes memory) {
    return abi.encodePacked(bytes32(0), bytes10(0), workflowOwner);
  }

  function _deliver(
    RateLimitGuard.Tightening[] memory batch
  ) internal {
    vm.prank(forwarder);
    guard.onReport(_metadata(), abi.encode(LOCAL, ++issuedAt, batch));
  }
}
