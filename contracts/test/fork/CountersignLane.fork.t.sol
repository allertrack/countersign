// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

import {CountersignVerifier} from "../../src/CountersignVerifier.sol";
import {CREReceiverBase} from "../../src/cre/CREReceiverBase.sol";
import {CountersignCodes} from "../../src/libraries/CountersignCodes.sol";

import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {
  ICrossChainVerifierResolver
} from "@chainlink/contracts-ccip/contracts/interfaces/ICrossChainVerifierResolver.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {Internal} from "@chainlink/contracts-ccip/contracts/libraries/Internal.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/contracts/libraries/MessageV1Codec.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {OffRamp} from "@chainlink/contracts-ccip/contracts/offRamp/OffRamp.sol";
import {OnRamp} from "@chainlink/contracts-ccip/contracts/onRamp/OnRamp.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {
  RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";

import {IBurnMintERC20} from "@chainlink/contracts-ccip/contracts/interfaces/IBurnMintERC20.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";

/// @dev Stands in for Chainlink's committee verifier on the destination fork. The committee's real signatures cannot
/// be produced in a fork, and verifying them is Chainlink's responsibility, not Countersign's.
contract AcceptAllVerifier {
  function verifyMessage(
    MessageV1Codec.MessageV1 calldata,
    bytes32,
    bytes calldata
  ) external pure {}
}

/// @notice Phase 0 spike: a Countersign-protected CCT on the live CCIP v2 lane Ethereum Sepolia -> Arbitrum Sepolia.
/// @dev Run with `forge test --match-path test/fork/*`. Uses public RPCs unless SEPOLIA_RPC_URL /
/// ARBITRUM_SEPOLIA_RPC_URL are set.
contract CountersignLaneForkTest is Test {
  struct Side {
    uint256 fork;
    uint64 selector;
    address router;
    address rmn;
    address tokenAdminRegistry;
    address registryModule;
    BurnMintERC20 token;
    AdvancedPoolHooks hooks;
    BurnMintTokenPool pool;
    CountersignVerifier verifier;
    VersionedVerifierResolver resolver;
  }

  struct SentMessage {
    bytes32 messageId;
    bytes encodedMessage;
    bool countersignRequested;
  }

  // Live CCIP v2 deployments (docs.chain.link CCIP directory, verified onchain with typeAndVersion()).
  uint64 internal constant SEPOLIA_SELECTOR = 16015286601757825753;
  uint64 internal constant ARB_SEPOLIA_SELECTOR = 3478487238524512106;
  address internal constant COMMITTEE_RESOLVER = 0x8f3ee3c77D2B27c32306a89D367654F959Db223D;
  address internal constant ARB_SEPOLIA_OFFRAMP = 0xC93218EB7B778bC0c13E5296140C8E4Fa1C440DA;

  bytes4 internal constant VERSION_TAG = 0xC5160001;
  uint256 internal constant THRESHOLD = 1_000 ether;

  address internal deployer = makeAddr("issuer-deployer");
  address internal guardian = makeAddr("issuer-guardian-safe");
  address internal forwarder = makeAddr("cre-forwarder");
  address internal workflowOwner = makeAddr("cre-workflow-owner");
  bytes32 internal workflowId = keccak256("countersign-verifier");
  address internal user = makeAddr("user");

  Side internal src;
  Side internal dst;

  function setUp() public {
    src = Side({
      fork: vm.createFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com"))),
      selector: SEPOLIA_SELECTOR,
      router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
      rmn: 0xba3f6251de62dED61Ff98590cB2fDf6871FbB991,
      tokenAdminRegistry: 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82,
      registryModule: 0xa3c796d480638d7476792230da1E2ADa86e031b0,
      token: BurnMintERC20(address(0)),
      hooks: AdvancedPoolHooks(address(0)),
      pool: BurnMintTokenPool(address(0)),
      verifier: CountersignVerifier(address(0)),
      resolver: VersionedVerifierResolver(address(0))
    });
    dst = Side({
      fork: vm.createFork(vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string("https://sepolia-rollup.arbitrum.io/rpc"))),
      selector: ARB_SEPOLIA_SELECTOR,
      router: 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165,
      rmn: 0x9527E2d01A3064ef6b50c1Da1C0cC523803BCFF2,
      tokenAdminRegistry: 0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f,
      registryModule: 0xaD417c0611dBD225471D31F056b8B6beC1CBC153,
      token: BurnMintERC20(address(0)),
      hooks: AdvancedPoolHooks(address(0)),
      pool: BurnMintTokenPool(address(0)),
      verifier: CountersignVerifier(address(0)),
      resolver: VersionedVerifierResolver(address(0))
    });

    _deploy(src);
    _deploy(dst);
    _connect(src, dst);
    _connect(dst, src);

    vm.selectFork(src.fork);
    vm.prank(deployer);
    src.token.transfer(user, 10_000 ether);
    vm.deal(user, 10 ether);
  }

  // ================================================================
  // │                            Tests                             │
  // ================================================================

  function test_AboveThreshold_RequiresCountersignAndExecutesOnceApproved() public {
    SentMessage memory sent = _send(5_000 ether);
    assertTrue(sent.countersignRequested, "source verifier must emit CountersignRequested");

    vm.selectFork(dst.fork);
    (address[] memory required,,) = OffRamp(ARB_SEPOLIA_OFFRAMP).getCCVsForMessage(sent.encodedMessage);
    assertTrue(_contains(required, address(dst.resolver)), "pool must require Countersign above threshold");
    assertTrue(_contains(required, COMMITTEE_RESOLVER), "committee stays required (defense in depth)");

    // Without an attestation the message cannot be executed.
    _execute(sent, required);
    assertEq(uint8(_state(sent.messageId)), uint8(Internal.MessageExecutionState.FAILURE));
    assertEq(dst.token.balanceOf(user), 0);

    // The CRE workflow approves; the permissionless retry now succeeds.
    _attest(sent.messageId, CountersignCodes.VERDICT_APPROVED, 0);
    _execute(sent, required);
    assertEq(uint8(_state(sent.messageId)), uint8(Internal.MessageExecutionState.SUCCESS));
    assertEq(dst.token.balanceOf(user), 5_000 ether);
  }

  function test_HeldMessage_OnlyGuardianCanRelease() public {
    SentMessage memory sent = _send(2_000 ether);

    vm.selectFork(dst.fork);
    (address[] memory required,,) = OffRamp(ARB_SEPOLIA_OFFRAMP).getCCVsForMessage(sent.encodedMessage);

    _attest(sent.messageId, CountersignCodes.VERDICT_HELD, CountersignCodes.SUPPLY_INVARIANT_BREACH);
    _execute(sent, required);
    assertEq(uint8(_state(sent.messageId)), uint8(Internal.MessageExecutionState.FAILURE));

    // A later APPROVED report from the workflow cannot loosen a hold.
    _attest(sent.messageId, CountersignCodes.VERDICT_APPROVED, 0);
    assertEq(dst.verifier.getAttestation(sent.messageId).verdict, CountersignCodes.VERDICT_HELD);

    vm.prank(guardian);
    dst.verifier.releaseHold(sent.messageId, keccak256("incident-report-001"));
    _execute(sent, required);
    assertEq(uint8(_state(sent.messageId)), uint8(Internal.MessageExecutionState.SUCCESS));
    assertEq(dst.token.balanceOf(user), 2_000 ether);
  }

  function test_BelowThreshold_OnlyCommitteeRequired() public {
    SentMessage memory sent = _send(10 ether);
    assertFalse(sent.countersignRequested, "small transfers skip Countersign");

    vm.selectFork(dst.fork);
    (address[] memory required,,) = OffRamp(ARB_SEPOLIA_OFFRAMP).getCCVsForMessage(sent.encodedMessage);
    assertFalse(_contains(required, address(dst.resolver)));

    _execute(sent, required);
    assertEq(uint8(_state(sent.messageId)), uint8(Internal.MessageExecutionState.SUCCESS));
    assertEq(dst.token.balanceOf(user), 10 ether);
  }

  /// @dev Anyone can name a CCV in extraArgs. Naming Countersign for a token it does not protect must fail at the
  /// source instead of flooding the workflow with events (CRE log triggers are rate-limited).
  function test_StrangerNamingCountersignForAnotherToken_Reverts() public {
    vm.selectFork(src.fork);
    vm.startPrank(deployer);
    BurnMintERC20 other = new BurnMintERC20("Other", "OTH", 18, 0, 1_000 ether);
    BurnMintTokenPool otherPool =
      new BurnMintTokenPool(IBurnMintERC20(address(other)), 18, address(0), src.rmn, src.router);
    other.grantMintAndBurnRoles(address(otherPool));
    RegistryModuleOwnerCustom(src.registryModule).registerAdminViaGetCCIPAdmin(address(other));
    TokenAdminRegistry(src.tokenAdminRegistry).acceptAdminRole(address(other));
    TokenAdminRegistry(src.tokenAdminRegistry).setPool(address(other), address(otherPool));
    bytes[] memory remotePools = new bytes[](1);
    remotePools[0] = abi.encode(makeAddr("remote-other-pool"));
    TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
    updates[0] = TokenPool.ChainUpdate({
      remoteChainSelector: dst.selector,
      remotePoolAddresses: remotePools,
      remoteTokenAddress: abi.encode(makeAddr("remote-other-token")),
      outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
      inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
    });
    otherPool.applyChainUpdates(new uint64[](0), updates);
    other.transfer(user, 100 ether);
    vm.stopPrank();

    ExtraArgsCodec.GenericExtraArgsV3 memory args;
    args.ccvs = new address[](1);
    args.ccvs[0] = address(src.resolver);
    args.ccvArgs = new bytes[](1);
    Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
    tokenAmounts[0] = Client.EVMTokenAmount({token: address(other), amount: 100 ether});
    Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
      receiver: abi.encode(user),
      data: "",
      tokenAmounts: tokenAmounts,
      feeToken: address(0),
      extraArgs: ExtraArgsCodec._encodeGenericExtraArgsV3(args)
    });

    vm.startPrank(user);
    other.approve(src.router, 100 ether);
    uint256 fee = IRouterClient(src.router).getFee(dst.selector, message);
    vm.expectRevert();
    IRouterClient(src.router).ccipSend{value: fee}(dst.selector, message);
    vm.stopPrank();
  }

  /// @dev The rolling-window counters the workflow reads are written by the real OnRamp call path.
  function test_WindowCountersRecordedThroughRealOnRamp() public {
    _send(2_000 ether);
    _send(3_000 ether);
    vm.selectFork(src.fork);
    (uint256 outflow, uint256 transfers) = src.verifier.getWindowUsage(dst.selector, address(src.token), user);
    assertEq(outflow, 5_000 ether);
    assertEq(transfers, 2);
  }

  // ================================================================
  // │                           Helpers                            │
  // ================================================================

  function _deploy(
    Side storage side
  ) internal {
    vm.selectFork(side.fork);
    vm.startPrank(deployer);

    side.token = new BurnMintERC20("Countersign Test Token", "CST", 18, 0, 1_000_000 ether);
    side.hooks = new AdvancedPoolHooks(new address[](0), THRESHOLD, address(0), new address[](0));
    side.pool =
      new BurnMintTokenPool(IBurnMintERC20(address(side.token)), 18, address(side.hooks), side.rmn, side.router);
    side.token.grantMintAndBurnRoles(address(side.pool));

    address[] memory callers = new address[](1);
    callers[0] = address(side.pool);
    side.hooks
      .applyAuthorizedCallerUpdates(
        AuthorizedCallers.AuthorizedCallerArgs({addedCallers: callers, removedCallers: new address[](0)})
      );

    RegistryModuleOwnerCustom(side.registryModule).registerAdminViaGetCCIPAdmin(address(side.token));
    TokenAdminRegistry(side.tokenAdminRegistry).acceptAdminRole(address(side.token));
    TokenAdminRegistry(side.tokenAdminRegistry).setPool(address(side.token), address(side.pool));

    string[] memory storageLocations = new string[](1);
    storageLocations[0] = "https://api.countersign.dev/v1";
    side.verifier = new CountersignVerifier(
      storageLocations,
      CountersignVerifier.StaticConfig({
        rmn: side.rmn,
        versionTag: VERSION_TAG,
        localChainSelector: side.selector,
        guardian: guardian,
        feeAggregator: makeAddr("treasury")
      }),
      CREReceiverBase.WorkflowIdentity({
        forwarder: forwarder,
        workflowId: workflowId,
        workflowOwner: workflowOwner,
        workflowName: bytes10(0),
        trustForwarderOnly: false
      })
    );
    side.verifier.setVerifiedToken(address(side.token), true);
    side.resolver = new VersionedVerifierResolver();

    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    inbound[0] =
      VersionedVerifierResolver.InboundImplementationArgs({version: VERSION_TAG, verifier: address(side.verifier)});
    side.resolver.applyInboundImplementationUpdates(inbound);

    vm.stopPrank();
  }

  function _connect(
    Side storage local,
    Side storage remote
  ) internal {
    vm.selectFork(local.fork);
    vm.startPrank(deployer);

    bytes[] memory remotePools = new bytes[](1);
    remotePools[0] = abi.encode(address(remote.pool));
    TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
    updates[0] = TokenPool.ChainUpdate({
      remoteChainSelector: remote.selector,
      remotePoolAddresses: remotePools,
      remoteTokenAddress: abi.encode(address(remote.token)),
      outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
      inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
    });
    local.pool.applyChainUpdates(new uint64[](0), updates);

    // Chainlink's default CCVs (address(0)) always; Countersign on top at or above THRESHOLD, both directions.
    address[] memory base = new address[](1);
    address[] memory additional = new address[](1);
    additional[0] = address(local.resolver);
    AdvancedPoolHooks.CCVConfigArg[] memory ccvConfig = new AdvancedPoolHooks.CCVConfigArg[](1);
    ccvConfig[0] = AdvancedPoolHooks.CCVConfigArg({
      remoteChainSelector: remote.selector,
      outboundCCVs: base,
      thresholdOutboundCCVs: additional,
      inboundCCVs: base,
      thresholdInboundCCVs: additional
    });
    local.hooks.applyCCVConfigUpdates(ccvConfig);

    BaseVerifier.RemoteChainConfigArgs[] memory remoteConfig = new BaseVerifier.RemoteChainConfigArgs[](1);
    remoteConfig[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(local.router),
      remoteChainSelector: remote.selector,
      allowlistEnabled: false,
      feeUSDCents: 0,
      gasForVerification: 60_000,
      payloadSizeBytes: 4
    });
    local.verifier.applyRemoteChainConfigUpdates(remoteConfig);

    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: remote.selector, verifier: address(local.verifier)
    });
    local.resolver.applyOutboundImplementationUpdates(outbound);

    vm.stopPrank();
  }

  function _send(
    uint256 amount
  ) internal returns (SentMessage memory sent) {
    vm.selectFork(src.fork);
    Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
    tokenAmounts[0] = Client.EVMTokenAmount({token: address(src.token), amount: amount});
    Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
      receiver: abi.encode(user),
      data: "",
      tokenAmounts: tokenAmounts,
      feeToken: address(0),
      extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, bytes4(0))
    });

    vm.startPrank(user);
    src.token.approve(src.router, amount);
    uint256 fee = IRouterClient(src.router).getFee(dst.selector, message);
    vm.recordLogs();
    IRouterClient(src.router).ccipSend{value: fee}(dst.selector, message);
    vm.stopPrank();

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address onRamp = _router(src.router).getOnRamp(dst.selector);
    for (uint256 i = 0; i < logs.length; ++i) {
      if (logs[i].emitter == onRamp && logs[i].topics[0] == OnRamp.CCIPMessageSent.selector) {
        sent.messageId = logs[i].topics[3];
        (,, sent.encodedMessage,,) = abi.decode(logs[i].data, (address, uint256, bytes, OnRamp.Receipt[], bytes[]));
      }
      if (
        logs[i].emitter == address(src.verifier)
          && logs[i].topics[0] == CountersignVerifier.CountersignRequested.selector
      ) {
        sent.countersignRequested = true;
        (, bytes memory encoded) = abi.decode(logs[i].data, (uint64, bytes));
        assertEq(keccak256(encoded), logs[i].topics[1], "event messageId must hash the encoded message");
      }
    }
    assertEq(keccak256(sent.encodedMessage), sent.messageId, "OnRamp messageId");
  }

  function _execute(
    SentMessage memory sent,
    address[] memory ccvs
  ) internal {
    vm.selectFork(dst.fork);
    AcceptAllVerifier committee = new AcceptAllVerifier();
    vm.mockCall(
      COMMITTEE_RESOLVER,
      abi.encodeWithSelector(ICrossChainVerifierResolver.getInboundImplementation.selector),
      abi.encode(address(committee))
    );

    bytes[] memory results = new bytes[](ccvs.length);
    for (uint256 i = 0; i < ccvs.length; ++i) {
      results[i] = abi.encodePacked(ccvs[i] == address(dst.resolver) ? VERSION_TAG : bytes4(0xdeadbeef));
    }
    OffRamp(ARB_SEPOLIA_OFFRAMP).execute(sent.encodedMessage, ccvs, results, 0);
  }

  function _attest(
    bytes32 messageId,
    uint8 verdict,
    uint32 reasonCodes
  ) internal {
    vm.selectFork(dst.fork);
    CountersignVerifier.Attestation[] memory attestations = new CountersignVerifier.Attestation[](1);
    attestations[0] = CountersignVerifier.Attestation({
      messageId: messageId,
      sourceChainSelector: src.selector,
      verdict: verdict,
      reasonCodes: reasonCodes,
      evidenceHash: keccak256(abi.encode(messageId, verdict))
    });
    vm.prank(forwarder);
    dst.verifier
      .onReport(abi.encodePacked(workflowId, bytes10(0), workflowOwner), abi.encode(dst.selector, attestations));
  }

  function _state(
    bytes32 messageId
  ) internal view returns (Internal.MessageExecutionState) {
    return OffRamp(ARB_SEPOLIA_OFFRAMP).getExecutionState(messageId);
  }

  function _router(
    address router
  ) internal pure returns (IRouterLike) {
    return IRouterLike(router);
  }

  function _contains(
    address[] memory list,
    address item
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < list.length; ++i) {
      if (list[i] == item) return true;
    }
    return false;
  }
}

interface IRouterLike {
  function getOnRamp(
    uint64 destChainSelector
  ) external view returns (address);
}
