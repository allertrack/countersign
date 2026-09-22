// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {CountersignVerifier} from "../src/CountersignVerifier.sol";
import {RateLimitGuard} from "../src/RateLimitGuard.sol";
import {CREReceiverBase} from "../src/cre/CREReceiverBase.sol";
import {WorkflowNames} from "../src/cre/WorkflowNames.sol";

import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/contracts/ccvs/VersionedVerifierResolver.sol";
import {BaseVerifier} from "@chainlink/contracts-ccip/contracts/ccvs/components/BaseVerifier.sol";
import {IBurnMintERC20} from "@chainlink/contracts-ccip/contracts/interfaces/IBurnMintERC20.sol";
import {IRouter} from "@chainlink/contracts-ccip/contracts/interfaces/IRouter.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {AdvancedPoolHooks} from "@chainlink/contracts-ccip/contracts/pools/AdvancedPoolHooks.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {
  RegistryModuleOwnerCustom
} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/contracts/tokenAdminRegistry/TokenAdminRegistry.sol";

import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";

/// @notice Deploys and wires a Countersign-protected CCT on CCIP v2 lanes.
///
/// Three steps, each run once per chain with `--rpc-url <chain>`:
///   1. `deploy()`   token, v2 pool + AdvancedPoolHooks, CountersignVerifier + resolver, RateLimitGuard, TAR registration.
///   2. `connect(remoteChainId)`  after both sides exist: remote pool/token, Countersign at or above the threshold,
///      verifier/resolver lanes and the per-transfer verifier fee.
///   3. `send(remoteChainId, amount)` optional demo transfer from the deployer.
///
/// Addresses are read from and written to `deployments/<chainId>.json` (`DEPLOYMENTS_DIR=deployments-local` for the
/// anvil forks; any other folder must be added to `fs_permissions`). Secrets come from the environment only:
///   PRIVATE_KEY            deployer (use a fresh testnet-only key)
///   CRE_FORWARDER          KeystoneForwarder on this chain, or the MockKeystoneForwarder for `cre workflow simulate`
///   CRE_SIMULATION         true => accept any workflow the forwarder delivers (MockKeystoneForwarder has no metadata)
///   CRE_WORKFLOW_OWNER     production: workflow owner address (defaults to the deployer)
///   CRE_WORKFLOW_NAME      production: workflow name, checked together with the owner (default "countersign")
///   CRE_WORKFLOW_ID        production: optional exact workflow id
///   GUARDIAN               issuer multisig allowed to release holds (defaults to the deployer)
///   TREASURY               receives verifier fees (defaults to the deployer)
///   THRESHOLD              amount (wei) at or above which Countersign is required (default 1,000e18)
///   CCV_FEE_USD_CENTS      fee charged by Countersign per gated transfer, in USD cents (default 0)
///   POLICY_ENGINE          optional Chainlink ACE PolicyEngine attached to the pool hooks
contract CountersignScript is Script {
  bytes4 internal constant VERSION_TAG = 0xC5160001;

  struct ChainConfig {
    uint64 selector;
    address router;
    address rmn;
    address tokenAdminRegistry;
    address registryModule;
  }

  struct Deployment {
    BurnMintERC20 token;
    AdvancedPoolHooks hooks;
    BurnMintTokenPool pool;
    CountersignVerifier verifier;
    VersionedVerifierResolver resolver;
    RateLimitGuard guard;
  }

  function deploy() external {
    ChainConfig memory chain = _chain(block.chainid);
    uint256 key = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(key);
    CREReceiverBase.WorkflowIdentity memory identity = _identity(deployer);

    vm.startBroadcast(key);
    Deployment memory d = _deployPool(chain);
    _deployVerifier(chain, d, identity, deployer);
    vm.stopBroadcast();

    _writeDeployment(chain, d);
  }

  function _identity(
    address deployer
  ) internal view returns (CREReceiverBase.WorkflowIdentity memory identity) {
    identity.forwarder = vm.envAddress("CRE_FORWARDER");
    if (vm.envOr("CRE_SIMULATION", false)) {
      identity.trustForwarderOnly = true;
      return identity;
    }
    identity.workflowId = vm.envOr("CRE_WORKFLOW_ID", bytes32(0));
    identity.workflowOwner = vm.envOr("CRE_WORKFLOW_OWNER", deployer);
    identity.workflowName = WorkflowNames.encode(vm.envOr("CRE_WORKFLOW_NAME", string("countersign")));
  }

  function _deployPool(
    ChainConfig memory chain
  ) internal returns (Deployment memory d) {
    d.token = new BurnMintERC20("Countersign Test Token", "CST", 18, 0, 1_000_000 ether);
    d.hooks = new AdvancedPoolHooks(
      new address[](0),
      vm.envOr("THRESHOLD", uint256(1_000 ether)),
      vm.envOr("POLICY_ENGINE", address(0)),
      new address[](0)
    );
    d.pool = new BurnMintTokenPool(IBurnMintERC20(address(d.token)), 18, address(d.hooks), chain.rmn, chain.router);
    d.token.grantMintAndBurnRoles(address(d.pool));

    address[] memory callers = new address[](1);
    callers[0] = address(d.pool);
    d.hooks
      .applyAuthorizedCallerUpdates(
        AuthorizedCallers.AuthorizedCallerArgs({addedCallers: callers, removedCallers: new address[](0)})
      );

    RegistryModuleOwnerCustom(chain.registryModule).registerAdminViaGetCCIPAdmin(address(d.token));
    TokenAdminRegistry(chain.tokenAdminRegistry).acceptAdminRole(address(d.token));
    TokenAdminRegistry(chain.tokenAdminRegistry).setPool(address(d.token), address(d.pool));
  }

  function _deployVerifier(
    ChainConfig memory chain,
    Deployment memory d,
    CREReceiverBase.WorkflowIdentity memory identity,
    address deployer
  ) internal {
    address treasury = vm.envOr("TREASURY", deployer);
    string[] memory storageLocations = new string[](1);
    storageLocations[0] = vm.envOr("CCV_STORAGE_LOCATION", string("https://api.countersign.dev/v1"));
    d.verifier = new CountersignVerifier(
      storageLocations,
      CountersignVerifier.StaticConfig({
        rmn: chain.rmn,
        versionTag: VERSION_TAG,
        localChainSelector: chain.selector,
        guardian: vm.envOr("GUARDIAN", deployer),
        feeAggregator: treasury
      }),
      identity
    );
    d.verifier.setVerifiedToken(address(d.token), true);

    d.resolver = new VersionedVerifierResolver();
    VersionedVerifierResolver.InboundImplementationArgs[] memory inbound =
      new VersionedVerifierResolver.InboundImplementationArgs[](1);
    inbound[0] =
      VersionedVerifierResolver.InboundImplementationArgs({version: VERSION_TAG, verifier: address(d.verifier)});
    d.resolver.applyInboundImplementationUpdates(inbound);
    // CCIP pays CCV fees to the resolver (the address named in the message); withdrawals go to the treasury.
    d.resolver.setFeeAggregator(treasury);

    d.guard = new RateLimitGuard(chain.selector, identity);
    d.guard.setPoolManagement(address(d.pool), true);
    d.pool.setDynamicConfig(chain.router, address(d.guard), address(0));
  }

  function _writeDeployment(
    ChainConfig memory chain,
    Deployment memory d
  ) internal {
    string memory obj = "deployment";
    vm.serializeUint(obj, "chainId", block.chainid);
    vm.serializeUint(obj, "chainSelector", chain.selector);
    vm.serializeAddress(obj, "token", address(d.token));
    vm.serializeAddress(obj, "hooks", address(d.hooks));
    vm.serializeAddress(obj, "pool", address(d.pool));
    vm.serializeAddress(obj, "verifier", address(d.verifier));
    vm.serializeAddress(obj, "resolver", address(d.resolver));
    string memory json = vm.serializeAddress(obj, "rateLimitGuard", address(d.guard));
    vm.createDir(_dir(), true);
    vm.writeJson(json, _path(block.chainid));
    console2.log("Countersign stack deployed on chain", block.chainid);
    console2.log(json);
  }

  /// @param remoteChainId chain id of the other side (its deployment file must exist).
  function connect(
    uint256 remoteChainId
  ) external {
    address router = _chain(block.chainid).router;
    string memory local = vm.readFile(_path(block.chainid));
    string memory remote = vm.readFile(_path(remoteChainId));
    uint64 remoteSelector = uint64(vm.parseJsonUint(remote, ".chainSelector"));

    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    _connectPool(local, remote, remoteSelector);
    _connectHooks(local, remoteSelector);
    _connectVerifier(local, router, remoteSelector);
    vm.stopBroadcast();
    console2.log("Connected chain", block.chainid, "to", remoteChainId);
  }

  function _connectPool(
    string memory local,
    string memory remote,
    uint64 remoteSelector
  ) internal {
    bytes[] memory remotePools = new bytes[](1);
    remotePools[0] = abi.encode(vm.parseJsonAddress(remote, ".pool"));
    RateLimiter.Config memory limit = RateLimiter.Config({
      isEnabled: true,
      capacity: uint128(vm.envOr("RATE_LIMIT_CAPACITY", uint256(100_000 ether))),
      rate: uint128(vm.envOr("RATE_LIMIT_RATE", uint256(100 ether)))
    });
    TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
    updates[0] = TokenPool.ChainUpdate({
      remoteChainSelector: remoteSelector,
      remotePoolAddresses: remotePools,
      remoteTokenAddress: abi.encode(vm.parseJsonAddress(remote, ".token")),
      outboundRateLimiterConfig: limit,
      inboundRateLimiterConfig: limit
    });
    BurnMintTokenPool(vm.parseJsonAddress(local, ".pool")).applyChainUpdates(new uint64[](0), updates);
  }

  /// @dev Chainlink's default committee (address(0)) always; Countersign on top at or above the threshold, both ways.
  function _connectHooks(
    string memory local,
    uint64 remoteSelector
  ) internal {
    address[] memory base = new address[](1);
    address[] memory additional = new address[](1);
    additional[0] = vm.parseJsonAddress(local, ".resolver");
    AdvancedPoolHooks.CCVConfigArg[] memory ccvConfig = new AdvancedPoolHooks.CCVConfigArg[](1);
    ccvConfig[0] = AdvancedPoolHooks.CCVConfigArg({
      remoteChainSelector: remoteSelector,
      outboundCCVs: base,
      thresholdOutboundCCVs: additional,
      inboundCCVs: base,
      thresholdInboundCCVs: additional
    });
    AdvancedPoolHooks(vm.parseJsonAddress(local, ".hooks")).applyCCVConfigUpdates(ccvConfig);
  }

  function _connectVerifier(
    string memory local,
    address router,
    uint64 remoteSelector
  ) internal {
    CountersignVerifier verifier = CountersignVerifier(vm.parseJsonAddress(local, ".verifier"));
    BaseVerifier.RemoteChainConfigArgs[] memory laneConfig = new BaseVerifier.RemoteChainConfigArgs[](1);
    laneConfig[0] = BaseVerifier.RemoteChainConfigArgs({
      router: IRouter(router),
      remoteChainSelector: remoteSelector,
      allowlistEnabled: false,
      feeUSDCents: uint16(vm.envOr("CCV_FEE_USD_CENTS", uint256(0))),
      gasForVerification: 60_000,
      payloadSizeBytes: 4
    });
    verifier.applyRemoteChainConfigUpdates(laneConfig);

    VersionedVerifierResolver.OutboundImplementationArgs[] memory outbound =
      new VersionedVerifierResolver.OutboundImplementationArgs[](1);
    outbound[0] = VersionedVerifierResolver.OutboundImplementationArgs({
      destChainSelector: remoteSelector, verifier: address(verifier)
    });
    VersionedVerifierResolver(vm.parseJsonAddress(local, ".resolver")).applyOutboundImplementationUpdates(outbound);
  }

  /// @notice Demo transfer of `amount` CST to the deployer on `remoteChainId`, paying fees in native gas.
  function send(
    uint256 remoteChainId,
    uint256 amount
  ) external {
    ChainConfig memory chain = _chain(block.chainid);
    uint64 remoteSelector = _chain(remoteChainId).selector;
    address token = vm.parseJsonAddress(vm.readFile(_path(block.chainid)), ".token");
    uint256 key = vm.envUint("PRIVATE_KEY");

    Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
    tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});
    Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
      receiver: abi.encode(vm.addr(key)),
      data: "",
      tokenAmounts: tokenAmounts,
      feeToken: address(0),
      extraArgs: ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, bytes4(0))
    });

    vm.startBroadcast(key);
    BurnMintERC20(token).approve(chain.router, amount);
    uint256 fee = IRouterClient(chain.router).getFee(remoteSelector, message);
    bytes32 messageId = IRouterClient(chain.router).ccipSend{value: fee}(remoteSelector, message);
    vm.stopBroadcast();
    console2.log("ccipSend messageId:");
    console2.logBytes32(messageId);
  }

  function _dir() internal view returns (string memory) {
    return string.concat(vm.projectRoot(), "/", vm.envOr("DEPLOYMENTS_DIR", string("deployments")));
  }

  function _path(
    uint256 chainId
  ) internal view returns (string memory) {
    return string.concat(_dir(), "/", vm.toString(chainId), ".json");
  }

  /// @dev Live CCIP v2 testnet deployments (docs.chain.link CCIP directory, verified with typeAndVersion()).
  function _chain(
    uint256 chainId
  ) internal pure returns (ChainConfig memory) {
    if (chainId == 11155111) {
      return ChainConfig({
        selector: 16015286601757825753,
        router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
        rmn: 0xba3f6251de62dED61Ff98590cB2fDf6871FbB991,
        tokenAdminRegistry: 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82,
        registryModule: 0xa3c796d480638d7476792230da1E2ADa86e031b0
      });
    }
    if (chainId == 421614) {
      return ChainConfig({
        selector: 3478487238524512106,
        router: 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165,
        rmn: 0x9527E2d01A3064ef6b50c1Da1C0cC523803BCFF2,
        tokenAdminRegistry: 0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f,
        registryModule: 0xaD417c0611dBD225471D31F056b8B6beC1CBC153
      });
    }
    revert("unsupported chain");
  }
}
