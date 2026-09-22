// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CountersignVerifier} from "../src/CountersignVerifier.sol";
import {CREReceiverBase} from "../src/cre/CREReceiverBase.sol";
import {WorkflowNames} from "../src/cre/WorkflowNames.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {CountersignCodes} from "../src/libraries/CountersignCodes.sol";
import {MockRMN, MockRouter} from "./helpers/Mocks.sol";

import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {ICrossChainVerifierV1} from "@chainlink/contracts-ccip/contracts/interfaces/ICrossChainVerifierV1.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {MessageV1Codec} from "@chainlink/contracts-ccip/contracts/libraries/MessageV1Codec.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";

contract CountersignVerifierTest is Test {
  uint64 internal constant SOURCE = 16015286601757825753;
  uint64 internal constant DEST = 3478487238524512106;
  bytes4 internal constant TAG = 0xC5160001;

  address internal owner = makeAddr("owner");
  address internal guardian = makeAddr("guardian");
  address internal forwarder = makeAddr("forwarder");
  address internal workflowOwner = makeAddr("workflow-owner");
  address internal onRamp = makeAddr("onRamp");
  address internal stranger = makeAddr("stranger");
  address internal token = makeAddr("token");
  address internal sender = address(0x5E4D);
  bytes32 internal workflowId = keccak256("countersign");
  bytes10 internal workflowName = WorkflowNames.encode("countersign");

  MockRMN internal rmn;
  MockRouter internal router;
  /// @dev One instance per role: `source` lives on SOURCE (forwardToVerifier), `dest` on DEST (attestations), so the
  /// chain-binding checks are exercised honestly.
  CountersignVerifier internal source;
  CountersignVerifier internal dest;

  function setUp() public {
    rmn = new MockRMN();
    router = new MockRouter();
    router.setOnRamp(DEST, onRamp);

    vm.startPrank(owner);
    source = _deploy(SOURCE);
    dest = _deploy(DEST);

    BaseVerifier.RemoteChainConfigArgs[] memory cfg = new BaseVerifier.RemoteChainConfigArgs[](1);
    cfg[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(address(router)),
      remoteChainSelector: DEST,
      allowlistEnabled: false,
      feeUSDCents: 50,
      gasForVerification: 60_000,
      payloadSizeBytes: 4
    });
    source.applyRemoteChainConfigUpdates(cfg);
    source.setVerifiedToken(token, true);
    vm.stopPrank();
  }

  function _deploy(
    uint64 localChainSelector
  ) internal returns (CountersignVerifier) {
    return new CountersignVerifier(
      new string[](0),
      CountersignVerifier.StaticConfig({
        rmn: address(rmn),
        versionTag: TAG,
        localChainSelector: localChainSelector,
        guardian: guardian,
        feeAggregator: makeAddr("treasury")
      }),
      CREReceiverBase.WorkflowIdentity({
        forwarder: forwarder,
        workflowId: bytes32(0),
        workflowOwner: workflowOwner,
        workflowName: workflowName,
        trustForwarderOnly: false
      })
    );
  }

  // ================================================================
  // │                    Report authentication                     │
  // ================================================================

  function test_onReport_RevertWhen_NotForwarder() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.InvalidForwarder.selector, stranger));
    dest.onReport(_metadata(workflowId, workflowName, workflowOwner), _report(DEST, _one(1, SOURCE, 1, 0)));
  }

  function test_onReport_RevertWhen_WrongWorkflowOwner() public {
    vm.prank(forwarder);
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.InvalidWorkflowOwner.selector, stranger));
    dest.onReport(_metadata(workflowId, workflowName, stranger), _report(DEST, _one(1, SOURCE, 1, 0)));
  }

  /// @dev Workflow names are unique per owner only; the owner check comes first, the name narrows it down.
  function test_onReport_RevertWhen_WrongWorkflowName() public {
    bytes10 other = WorkflowNames.encode("another-workflow");
    vm.prank(forwarder);
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.InvalidWorkflowName.selector, other));
    dest.onReport(_metadata(workflowId, other, workflowOwner), _report(DEST, _one(1, SOURCE, 1, 0)));
  }

  function test_onReport_RevertWhen_WrongWorkflowId() public {
    vm.prank(owner);
    dest.setWorkflowIdentity(_identity(workflowId, address(0), bytes10(0), false));
    bytes32 wrong = keccak256("attacker-workflow");
    vm.prank(forwarder);
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.InvalidWorkflowId.selector, wrong));
    dest.onReport(_metadata(wrong, workflowName, workflowOwner), _report(DEST, _one(1, SOURCE, 1, 0)));
  }

  function test_onReport_RevertWhen_IdentityNotConfigured() public {
    vm.prank(owner);
    dest.setWorkflowIdentity(_identity(bytes32(0), address(0), bytes10(0), false));
    vm.prank(forwarder);
    vm.expectRevert(CREReceiverBase.WorkflowIdentityNotConfigured.selector);
    dest.onReport(_metadata(workflowId, workflowName, workflowOwner), _report(DEST, _one(1, SOURCE, 1, 0)));
  }

  function test_onReport_RevertWhen_MetadataTooShort() public {
    vm.prank(forwarder);
    vm.expectRevert(CREReceiverBase.InvalidMetadata.selector);
    dest.onReport(hex"1234", _report(DEST, _one(1, SOURCE, 1, 0)));
  }

  /// @dev The production KeystoneForwarder delivers 64 bytes: the 62-byte identity plus the 2-byte reportId.
  function test_onReport_Accepts64ByteProductionMetadata() public {
    bytes memory metadata = abi.encodePacked(_metadata(workflowId, workflowName, workflowOwner), bytes2(0x0001));
    assertEq(metadata.length, 64);
    vm.prank(forwarder);
    dest.onReport(metadata, _report(DEST, _one(1, SOURCE, 1, 0)));
    assertEq(dest.getAttestation(bytes32(uint256(1))).verdict, CountersignCodes.VERDICT_APPROVED);
  }

  /// @dev `cre workflow simulate` uses a MockKeystoneForwarder that sends no workflow metadata at all.
  function test_onReport_SimulationMode_AcceptsEmptyMetadata() public {
    vm.prank(owner);
    vm.expectEmit(address(dest));
    emit CREReceiverBase.SecurityWarning("trustForwarderOnly: any workflow can report through this forwarder (simulation only)");
    dest.setWorkflowIdentity(_identity(bytes32(0), address(0), bytes10(0), true));
    vm.prank(forwarder);
    dest.onReport("", _report(DEST, _one(1, SOURCE, 1, 0)));
    assertEq(dest.getAttestation(bytes32(uint256(1))).verdict, CountersignCodes.VERDICT_APPROVED);
  }

  /// @dev A report signed for another chain cannot be replayed here (CRE docs: "cross-chain replay").
  function test_onReport_RevertWhen_ReportTargetsAnotherChain() public {
    vm.prank(forwarder);
    vm.expectRevert(abi.encodeWithSelector(CREReceiverBase.WrongChain.selector, SOURCE, DEST));
    dest.onReport(_metadata(workflowId, workflowName, workflowOwner), _report(SOURCE, _one(1, SOURCE, 1, 0)));
  }

  function test_WorkflowNamesEncoding_MatchesCRE() public pure {
    // CRE docs: "my_workflow" -> sha256 -> "b76f3ae1de..." -> 0x62373666336165316465
    assertEq(WorkflowNames.encode("my_workflow"), bytes10(0x62373666336165316465));
  }

  // ================================================================
  // │                      State transitions                       │
  // ================================================================

  function test_Approve_ThenVerify() public {
    _deliver(7, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(7)), abi.encodePacked(TAG));
  }

  function test_Revoke_ApprovedToHeld() public {
    bytes32 id = bytes32(uint256(7));
    _deliver(7, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    vm.expectEmit(address(dest));
    emit CountersignVerifier.AttestationRevoked(id, CountersignCodes.VELOCITY_ANOMALY, keccak256("evidence"));
    _deliver(7, SOURCE, CountersignCodes.VERDICT_HELD, CountersignCodes.VELOCITY_ANOMALY);

    vm.expectRevert(
      abi.encodeWithSelector(CountersignVerifier.MessageHeld.selector, id, CountersignCodes.VELOCITY_ANOMALY)
    );
    dest.verifyMessage(_message(SOURCE, DEST), id, abi.encodePacked(TAG));
  }

  function test_WorkflowCannotLoosenHold() public {
    bytes32 id = bytes32(uint256(7));
    _deliver(7, SOURCE, CountersignCodes.VERDICT_HELD, CountersignCodes.SUPPLY_INVARIANT_BREACH);
    vm.expectEmit(address(dest));
    emit CountersignVerifier.AttestationIgnored(id, CountersignCodes.VERDICT_HELD, CountersignCodes.VERDICT_APPROVED);
    _deliver(7, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    assertEq(dest.getAttestation(id).verdict, CountersignCodes.VERDICT_HELD);
  }

  function test_IgnoresSourceChainChange() public {
    bytes32 id = bytes32(uint256(7));
    _deliver(7, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    _deliver(7, DEST, CountersignCodes.VERDICT_HELD, 0);
    assertEq(dest.getAttestation(id).verdict, CountersignCodes.VERDICT_APPROVED);
    assertEq(dest.getAttestation(id).sourceChainSelector, SOURCE);
  }

  function test_IgnoresInvalidVerdictAndZeroSource() public {
    _deliver(7, SOURCE, 9, 0);
    _deliver(8, 0, CountersignCodes.VERDICT_APPROVED, 0);
    assertEq(dest.getAttestation(bytes32(uint256(7))).verdict, CountersignCodes.VERDICT_NONE);
    assertEq(dest.getAttestation(bytes32(uint256(8))).verdict, CountersignCodes.VERDICT_NONE);
  }

  function test_BatchAppliesEachEntryIndependently_AndBatchRead() public {
    CountersignVerifier.Attestation[] memory batch = new CountersignVerifier.Attestation[](3);
    batch[0] = _attestation(1, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    batch[1] = _attestation(2, SOURCE, 42, 0); // invalid, ignored
    batch[2] = _attestation(3, SOURCE, CountersignCodes.VERDICT_HELD, CountersignCodes.POLICY_DENIED);
    vm.prank(forwarder);
    dest.onReport(_metadata(workflowId, workflowName, workflowOwner), _report(DEST, batch));

    bytes32[] memory ids = new bytes32[](3);
    ids[0] = bytes32(uint256(1));
    ids[1] = bytes32(uint256(2));
    ids[2] = bytes32(uint256(3));
    CountersignVerifier.AttestationRecord[] memory records = dest.getAttestations(ids);
    assertEq(records[0].verdict, CountersignCodes.VERDICT_APPROVED);
    assertEq(records[1].verdict, CountersignCodes.VERDICT_NONE);
    assertEq(records[2].verdict, CountersignCodes.VERDICT_HELD);
    assertEq(records[2].reasonCodes, CountersignCodes.POLICY_DENIED);
  }

  /// @dev Whatever sequence of verdicts the workflow sends, a HELD message never becomes verifiable without the guardian.
  function testFuzz_WorkflowNeverLoosensHold(
    uint8[8] memory verdicts
  ) public {
    bool everHeld;
    for (uint256 i = 0; i < verdicts.length; ++i) {
      _deliver(99, SOURCE, verdicts[i] % 3, 0);
      if (dest.getAttestation(bytes32(uint256(99))).verdict == CountersignCodes.VERDICT_HELD) everHeld = true;
    }
    if (everHeld) assertEq(dest.getAttestation(bytes32(uint256(99))).verdict, CountersignCodes.VERDICT_HELD);
  }

  // ================================================================
  // │                        verifyMessage                         │
  // ================================================================

  function test_verifyMessage_RevertWhen_NotAttested() public {
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.MessageNotAttested.selector, bytes32(uint256(8))));
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(8)), abi.encodePacked(TAG));
  }

  function test_verifyMessage_RevertWhen_WrongVersionTag() public {
    _deliver(8, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.InvalidCCVVersion.selector, bytes4(0xdeadbeef)));
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(8)), abi.encodePacked(bytes4(0xdeadbeef)));
  }

  function test_verifyMessage_RevertWhen_ResultsTooShort() public {
    vm.expectRevert(CountersignVerifier.InvalidVerifierResults.selector);
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(8)), hex"c516");
  }

  function test_verifyMessage_RevertWhen_SourceMismatch() public {
    bytes32 id = bytes32(uint256(8));
    _deliver(8, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.SourceChainMismatch.selector, id, SOURCE, DEST));
    dest.verifyMessage(_message(DEST, DEST), id, abi.encodePacked(TAG));
  }

  function test_verifyMessage_RevertWhen_SourceCursed() public {
    _deliver(8, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);
    rmn.setCursed(SOURCE, true);
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.CursedByRMN.selector, SOURCE));
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(8)), abi.encodePacked(TAG));
  }

  function test_Pause_BlocksBothSides_GuardianPauses_OnlyOwnerUnpauses() public {
    _deliver(8, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);

    vm.prank(guardian);
    dest.pause();
    vm.expectRevert(CountersignVerifier.VerificationPaused.selector);
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(8)), abi.encodePacked(TAG));

    // A paused source refuses new sends instead of letting users burn into a stuck message.
    vm.prank(guardian);
    source.pause();
    (MessageV1Codec.MessageV1 memory message, bytes32 id) = _outbound(2_000 ether);
    vm.prank(onRamp);
    vm.expectRevert(CountersignVerifier.VerificationPaused.selector);
    source.forwardToVerifier(message, id, address(0), 0, "");

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.OnlyGuardianOrOwner.selector, stranger));
    dest.pause();

    vm.prank(guardian);
    vm.expectRevert(Ownable2Step.OnlyCallableByOwner.selector);
    dest.unpause();

    vm.prank(owner);
    dest.unpause();
    dest.verifyMessage(_message(SOURCE, DEST), bytes32(uint256(8)), abi.encodePacked(TAG));
  }

  // ================================================================
  // │                           Guardian                           │
  // ================================================================

  function test_releaseHold_OnlyGuardian() public {
    bytes32 id = bytes32(uint256(9));
    _deliver(9, SOURCE, CountersignCodes.VERDICT_HELD, CountersignCodes.RESERVE_SHORTFALL);

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.OnlyGuardian.selector, stranger));
    dest.releaseHold(id, bytes32(0));

    vm.prank(guardian);
    dest.releaseHold(id, keccak256("review"));
    dest.verifyMessage(_message(SOURCE, DEST), id, abi.encodePacked(TAG));
  }

  function test_releaseHold_RevertWhen_NotHeld() public {
    bytes32 id = bytes32(uint256(9));
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.NotHeld.selector, id));
    dest.releaseHold(id, bytes32(0));
  }

  function test_placeHold_BeforeWorkflow_BlocksLaterApproval() public {
    bytes32 id = bytes32(uint256(10));
    vm.prank(guardian);
    dest.placeHold(id, SOURCE, keccak256("source chain incident"));
    _deliver(10, SOURCE, CountersignCodes.VERDICT_APPROVED, 0);

    CountersignVerifier.AttestationRecord memory record = dest.getAttestation(id);
    assertEq(record.verdict, CountersignCodes.VERDICT_HELD);
    assertEq(record.reasonCodes, CountersignCodes.MANUAL_REVIEW);
  }

  function test_placeHold_RevertWhen_NewRecordWithoutSource() public {
    vm.prank(guardian);
    vm.expectRevert(CountersignVerifier.InvalidSourceChain.selector);
    dest.placeHold(bytes32(uint256(11)), 0, bytes32(0));
  }

  // ================================================================
  // │                         Source side                          │
  // ================================================================

  function test_forwardToVerifier_EmitsRequestRecordsWindowAndReturnsTag() public {
    (MessageV1Codec.MessageV1 memory message, bytes32 id) = _outbound(2_000 ether);

    vm.expectEmit(address(source));
    emit CountersignVerifier.CountersignRequested(
      id, DEST, message.messageNumber, MessageV1Codec._encodeMessageV1(message)
    );
    vm.prank(onRamp);
    bytes memory ret = source.forwardToVerifier(message, id, address(0), 0, "");
    assertEq(ret, abi.encodePacked(TAG));

    (uint256 outflow, uint256 transfers) = source.getWindowUsage(DEST, token, sender);
    assertEq(outflow, 2_000 ether);
    assertEq(transfers, 1);
  }

  function test_WindowUsage_RollsOverAfterTwoEpochs() public {
    uint32 epoch = source.getWindowEpoch();
    vm.warp(uint256(epoch) * 1_000);
    _forward(1_000 ether);
    vm.warp(block.timestamp + epoch);
    _forward(3_000 ether);

    (uint256 outflow, uint256 transfers) = source.getWindowUsage(DEST, token, sender);
    assertEq(outflow, 4_000 ether, "current + previous epoch");
    assertEq(transfers, 2);

    vm.warp(block.timestamp + epoch);
    (outflow, transfers) = source.getWindowUsage(DEST, token, sender);
    assertEq(outflow, 3_000 ether, "oldest epoch left the window");
    assertEq(transfers, 1);

    vm.warp(block.timestamp + 2 * uint256(epoch));
    (outflow, transfers) = source.getWindowUsage(DEST, token, sender);
    assertEq(outflow, 0);
    assertEq(transfers, 0);
  }

  /// @dev Anyone can name this CCV in extraArgs; only the issuer's token transfers may reach the workflow.
  function test_forwardToVerifier_RevertWhen_UnknownToken() public {
    (MessageV1Codec.MessageV1 memory message, bytes32 id) = _outbound(2_000 ether);
    message.tokenTransfer[0].sourceTokenAddress = abi.encode(makeAddr("other-token"));
    vm.prank(onRamp);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.UnsupportedMessage.selector, id));
    source.forwardToVerifier(message, id, address(0), 0, "");
  }

  function test_forwardToVerifier_RevertWhen_DataOnlyMessage() public {
    (MessageV1Codec.MessageV1 memory message, bytes32 id) = _outbound(2_000 ether);
    message.tokenTransfer = new MessageV1Codec.TokenTransferV1[](0);
    vm.prank(onRamp);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.UnsupportedMessage.selector, id));
    source.forwardToVerifier(message, id, address(0), 0, "");
  }

  function test_forwardToVerifier_RevertWhen_NotOnRamp() public {
    (MessageV1Codec.MessageV1 memory message, bytes32 id) = _outbound(2_000 ether);
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(BaseVerifier.CallerIsNotARampOnRouter.selector, stranger));
    source.forwardToVerifier(message, id, address(0), 0, "");
  }

  /// @dev The per-transfer fee is how the verifier operator gets paid by CCIP.
  function test_getFee_ReturnsConfiguredVerifierFee() public view {
    Client.EVM2AnyMessage memory message;
    (uint16 feeUSDCents, uint32 gas, uint32 payload) = source.getFee(DEST, message, "", bytes4(0));
    assertEq(feeUSDCents, 50);
    assertEq(gas, 60_000);
    assertEq(payload, 4);
  }

  function test_Config_SettersValidateInput() public {
    vm.startPrank(owner);
    source.setVerifiedToken(token, false);
    assertEq(source.getVerifiedTokens().length, 0);
    vm.expectRevert(CREReceiverBase.ZeroAddress.selector);
    source.setVerifiedToken(address(0), true);
    vm.expectRevert(abi.encodeWithSelector(CountersignVerifier.InvalidWindowEpoch.selector, uint32(59)));
    source.setWindowEpoch(59);
    source.setWindowEpoch(600);
    vm.expectRevert(CREReceiverBase.ZeroAddress.selector);
    source.setFeeAggregator(address(0));
    vm.expectRevert(CREReceiverBase.ZeroAddress.selector);
    source.setGuardian(address(0));
    source.setFeeAggregator(stranger);
    vm.stopPrank();
    assertEq(source.getWindowEpoch(), 600);
    assertEq(source.getFeeAggregator(), stranger);

    vm.prank(stranger);
    vm.expectRevert(Ownable2Step.OnlyCallableByOwner.selector);
    source.setVerifiedToken(token, true);
  }

  function test_supportsInterface() public view {
    assertTrue(dest.supportsInterface(type(ICrossChainVerifierV1).interfaceId));
    assertTrue(dest.supportsInterface(type(IReceiver).interfaceId));
    assertFalse(dest.supportsInterface(0xffffffff));
    assertEq(dest.getLocalChainSelector(), DEST);
  }

  // ================================================================
  // │                           Helpers                            │
  // ================================================================

  function _deliver(
    uint256 id,
    uint64 sourceSelector,
    uint8 verdict,
    uint32 reasons
  ) internal {
    vm.prank(forwarder);
    dest.onReport(
      _metadata(workflowId, workflowName, workflowOwner), _report(DEST, _one(id, sourceSelector, verdict, reasons))
    );
  }

  function _forward(
    uint256 amount
  ) internal {
    (MessageV1Codec.MessageV1 memory message, bytes32 id) = _outbound(amount);
    vm.prank(onRamp);
    source.forwardToVerifier(message, id, address(0), 0, "");
  }

  function _one(
    uint256 id,
    uint64 sourceSelector,
    uint8 verdict,
    uint32 reasons
  ) internal pure returns (CountersignVerifier.Attestation[] memory batch) {
    batch = new CountersignVerifier.Attestation[](1);
    batch[0] = _attestation(id, sourceSelector, verdict, reasons);
  }

  function _attestation(
    uint256 id,
    uint64 sourceSelector,
    uint8 verdict,
    uint32 reasons
  ) internal pure returns (CountersignVerifier.Attestation memory) {
    return CountersignVerifier.Attestation({
      messageId: bytes32(id),
      sourceChainSelector: sourceSelector,
      verdict: verdict,
      reasonCodes: reasons,
      evidenceHash: keccak256("evidence")
    });
  }

  function _report(
    uint64 target,
    CountersignVerifier.Attestation[] memory batch
  ) internal pure returns (bytes memory) {
    return abi.encode(target, batch);
  }

  function _metadata(
    bytes32 id,
    bytes10 name,
    address wfOwner
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(id, name, wfOwner);
  }

  function _identity(
    bytes32 id,
    address wfOwner,
    bytes10 name,
    bool trustForwarderOnly
  ) internal view returns (CREReceiverBase.WorkflowIdentity memory) {
    return CREReceiverBase.WorkflowIdentity({
      forwarder: forwarder,
      workflowId: id,
      workflowOwner: wfOwner,
      workflowName: name,
      trustForwarderOnly: trustForwarderOnly
    });
  }

  function _message(
    uint64 sourceSelector,
    uint64 destSelector
  ) internal view returns (MessageV1Codec.MessageV1 memory m) {
    m.sourceChainSelector = sourceSelector;
    m.destChainSelector = destSelector;
    m.messageNumber = 1;
    m.onRampAddress = abi.encode(onRamp);
    m.offRampAddress = abi.encodePacked(address(0xBEEF));
    m.sender = abi.encode(sender);
    m.receiver = abi.encodePacked(address(0xAECE));
  }

  function _outbound(
    uint256 amount
  ) internal view returns (MessageV1Codec.MessageV1 memory m, bytes32 id) {
    m = _message(SOURCE, DEST);
    m.tokenTransfer = new MessageV1Codec.TokenTransferV1[](1);
    m.tokenTransfer[0] = MessageV1Codec.TokenTransferV1({
      amount: amount,
      sourcePoolAddress: abi.encode(address(0x9001)),
      sourceTokenAddress: abi.encode(token),
      destTokenAddress: abi.encodePacked(address(0x7001)),
      tokenReceiver: abi.encodePacked(address(0xAECE)),
      extraData: abi.encode(uint256(18))
    });
    id = keccak256(MessageV1Codec._encodeMessageV1(m));
  }
}
