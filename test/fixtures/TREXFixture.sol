// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Identity} from "@onchain-id/solidity/contracts/Identity.sol";
import {ClaimIssuer} from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {Token} from "@trex/contracts/token/Token.sol";
import {ModularCompliance} from "@trex/contracts/compliance/modular/ModularCompliance.sol";
import {IdentityRegistry} from "@trex/contracts/registry/implementation/IdentityRegistry.sol";
import {IdentityRegistryStorage} from "@trex/contracts/registry/implementation/IdentityRegistryStorage.sol";
import {ClaimTopicsRegistry} from "@trex/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {TrustedIssuersRegistry} from "@trex/contracts/registry/implementation/TrustedIssuersRegistry.sol";

import {MandateModule} from "../../src/MandateModule.sol";
import {IMandateModule} from "../../src/interfaces/IMandateModule.sol";
import {AgentClaim} from "../../src/libraries/AgentClaim.sol";
import {MockERC8004IdentityRegistry} from "../../src/mocks/MockERC8004IdentityRegistry.sol";

/// @notice Stands up a full T-REX token with the MandateModule bound, plus the actors and helpers the tests share.
/// @dev Naming: `trexAgent` is the T-REX token agent (issuer-side operator), `aiAgent` is the mandated wallet.
///      T-REX contracts sit behind ERC-1967 proxies with `init` called through the proxy. ONCHAINID identities are
///      deployed directly with `new Identity(managementKey, false)`. The T-REX factory is not used.
abstract contract TREXFixture is Test {
    // ------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------

    uint256 internal constant KYC_TOPIC = uint256(keccak256("KYC"));
    uint256 internal constant AGENT_MANDATE = AgentClaim.AGENT_MANDATE;
    uint256 internal constant CLAIM_SCHEME = 1;
    uint16 internal constant COUNTRY = 840;

    /// @dev Midnight UTC of a day, plus 12 hours, so tests can move within and across a UTC day boundary.
    uint256 internal constant START_TIME = 20_000 days + 12 hours;

    uint256 internal constant INVESTOR_BALANCE = 10_000 ether;
    uint256 internal constant AGENT_BALANCE = 10_000 ether;

    // ------------------------------------------------------------------------------------------------
    // Actors
    // ------------------------------------------------------------------------------------------------

    /// @dev Token owner. Owns every T-REX contract and reaches the module through `callModuleFunction`.
    address internal issuer;
    /// @dev T-REX token agent: mints, freezes, forces transfers, registers identities. Separate from `issuer`.
    address internal trexAgent;
    /// @dev Management key holder of the claim issuer's own ONCHAINID contract.
    address internal claimIssuerAdmin;
    /// @dev Wallet that holds a management key on `principalIdentity`.
    address internal principal;
    /// @dev The AI agent's wallet, the one the mandate constrains.
    address internal aiAgent;
    /// @dev Ordinary verified holder with no mandate.
    address internal investor;
    /// @dev A wallet with no identity, so it is not verified.
    address internal stranger;

    /// @dev Key that signs claims on behalf of the claim issuer contract.
    Vm.Wallet internal claimSigner;

    // ------------------------------------------------------------------------------------------------
    // Deployed contracts
    // ------------------------------------------------------------------------------------------------

    ClaimTopicsRegistry internal topicsRegistry;
    TrustedIssuersRegistry internal issuersRegistry;
    IdentityRegistryStorage internal identityStorage;
    IdentityRegistry internal identityRegistry;
    ModularCompliance internal compliance;
    Token internal token;

    ClaimIssuer internal claimIssuerContract;
    Identity internal principalIdentity;
    Identity internal investorIdentity;

    MockERC8004IdentityRegistry internal agentRegistry;
    MandateModule internal module;

    function setUp() public virtual {
        vm.warp(START_TIME);

        issuer = makeAddr("issuer");
        trexAgent = makeAddr("trexAgent");
        claimIssuerAdmin = makeAddr("claimIssuer");
        principal = makeAddr("principal");
        aiAgent = makeAddr("aiAgent");
        investor = makeAddr("investor");
        stranger = makeAddr("stranger");
        claimSigner = vm.createWallet("claimSigner");

        _deployIdentities();
        _deployTrex();
        _deployMandateModule();
        _onboardHolders();
    }

    // ------------------------------------------------------------------------------------------------
    // Setup steps
    // ------------------------------------------------------------------------------------------------

    function _deployIdentities() private {
        claimIssuerContract = new ClaimIssuer(claimIssuerAdmin);
        // The signer gets a CLAIM key (purpose 3), which is what ClaimIssuer.isClaimValid checks.
        vm.prank(claimIssuerAdmin);
        claimIssuerContract.addKey(keccak256(abi.encode(claimSigner.addr)), 3, 1);

        principalIdentity = new Identity(principal, false);
        investorIdentity = new Identity(investor, false);
    }

    function _deployTrex() private {
        vm.startPrank(issuer);

        topicsRegistry = ClaimTopicsRegistry(
            _proxy(address(new ClaimTopicsRegistry()), abi.encodeCall(ClaimTopicsRegistry.init, ()))
        );
        issuersRegistry = TrustedIssuersRegistry(
            _proxy(address(new TrustedIssuersRegistry()), abi.encodeCall(TrustedIssuersRegistry.init, ()))
        );
        identityStorage = IdentityRegistryStorage(
            _proxy(address(new IdentityRegistryStorage()), abi.encodeCall(IdentityRegistryStorage.init, ()))
        );
        identityRegistry = IdentityRegistry(
            _proxy(
                address(new IdentityRegistry()),
                abi.encodeCall(
                    IdentityRegistry.init, (address(issuersRegistry), address(topicsRegistry), address(identityStorage))
                )
            )
        );
        compliance =
            ModularCompliance(_proxy(address(new ModularCompliance()), abi.encodeCall(ModularCompliance.init, ())));
        token = Token(
            _proxy(
                address(new Token()),
                abi.encodeCall(
                    Token.init,
                    (address(identityRegistry), address(compliance), "KYA Test Token", "KYA", 18, address(0))
                )
            )
        );

        // TEST-ONLY SIMPLIFICATION: only KYC is a required topic. T-REX's isVerified demands every required topic
        // from every holder, so requiring AGENT_MANDATE here would make ordinary investors unverifiable. In a real
        // deployment, decide deliberately which topics are required. The claim issuer is still trusted for both
        // topics, which is what MandateModule checks.
        topicsRegistry.addClaimTopic(KYC_TOPIC);
        uint256[] memory topics = new uint256[](2);
        topics[0] = KYC_TOPIC;
        topics[1] = AGENT_MANDATE;
        issuersRegistry.addTrustedIssuer(IClaimIssuer(address(claimIssuerContract)), topics);

        identityStorage.bindIdentityRegistry(address(identityRegistry));
        identityRegistry.addAgent(trexAgent);
        token.addAgent(trexAgent);

        vm.stopPrank();
    }

    function _deployMandateModule() private {
        agentRegistry = new MockERC8004IdentityRegistry();
        module = new MandateModule(agentRegistry);

        vm.prank(issuer);
        compliance.addModule(address(module));
    }

    function _onboardHolders() private {
        // principal wallet and investor are ordinary verified holders. Both identities carry a KYC claim.
        _addClaim(principalIdentity, principal, KYC_TOPIC, "");
        _addClaim(investorIdentity, investor, KYC_TOPIC, "");

        vm.startPrank(trexAgent);
        identityRegistry.registerIdentity(principal, principalIdentity, COUNTRY);
        identityRegistry.registerIdentity(investor, investorIdentity, COUNTRY);
        token.unpause();
        token.mint(investor, INVESTOR_BALANCE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------
    // Mandate helpers
    // ------------------------------------------------------------------------------------------------

    /// @notice A mandate with the default limits. `principal` and `agentId` are filled in by `_grantMandate`.
    function _defaultMandate() internal view returns (IMandateModule.Mandate memory m) {
        m.maxPerTransfer = 1_000 ether;
        m.dailyCap = 2_500 ether;
        m.expiry = block.timestamp + 30 days;
    }

    /// @notice Runs the whole setup path for `aiAgent`: registers the wallet under the principal's identity,
    ///         registers an agentId in the ERC-8004 mock, issues the AGENT_MANDATE claim, and calls `setMandate`
    ///         through the compliance contract. `m.principal` and `m.agentId` are overwritten. Returns the stored form.
    /// @dev The agentId is registered before the claim because the claim data and the mandate hash include it.
    function _grantMandate(IMandateModule.Mandate memory m) internal returns (IMandateModule.Mandate memory) {
        _registerAgentWallet(aiAgent, address(principalIdentity));
        m.principal = address(principalIdentity);
        m.agentId = _registerAgentId(aiAgent);
        _issueMandateClaim(m, aiAgent);
        _setMandate(aiAgent, m);
        return m;
    }

    /// @notice Registers `wallet` in the token's identity registry under `identity`, as the T-REX token agent.
    function _registerAgentWallet(address wallet, address identity) internal {
        vm.prank(trexAgent);
        identityRegistry.registerIdentity(wallet, Identity(identity), COUNTRY);
    }

    /// @notice Registers `owner_` in the ERC-8004 mock and returns its agentId.
    function _registerAgentId(address owner_) internal returns (uint256) {
        vm.prank(owner_);
        return agentRegistry.register("ipfs://kya-test-agent");
    }

    /// @notice Signs an AGENT_MANDATE claim for `wallet` from the claim issuer and adds it to the principal's identity.
    function _issueMandateClaim(IMandateModule.Mandate memory m, address wallet) internal {
        _issueMandateClaim(AgentClaim.encode(m.agentId, wallet, AgentClaim.mandateHash(m), m.expiry));
    }

    /// @notice Adds an AGENT_MANDATE claim with arbitrary `data` to the principal's identity.
    function _issueMandateClaim(bytes memory data) internal {
        _addClaim(principalIdentity, principal, AGENT_MANDATE, data);
    }

    /// @notice Calls `MandateModule.setMandate` the way the token owner does, through the compliance contract.
    function _setMandate(address agent, IMandateModule.Mandate memory m) internal {
        vm.prank(issuer);
        compliance.callModuleFunction(abi.encodeCall(IMandateModule.setMandate, (agent, m)), address(module));
    }

    /// @notice Mints `amount` to `to` as the T-REX token agent. `to` must already be verified.
    function _fund(address to, uint256 amount) internal {
        vm.prank(trexAgent);
        token.mint(to, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // Claim helpers
    // ------------------------------------------------------------------------------------------------

    /// @notice Signs `(identity, topic, data)` the way ONCHAINID's `ClaimIssuer.isClaimValid` expects:
    ///         an Ethereum signed message over `keccak256(abi.encode(identity, topic, data))`.
    function _signClaim(address identity, uint256 topic, bytes memory data) internal view returns (bytes memory) {
        bytes32 dataHash = keccak256(abi.encode(identity, topic, data));
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimSigner.privateKey, prefixed);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Signs a claim and adds it to `identity` through the standard `addClaim` path, called by `keyHolder`,
    ///         so the issuer's signature is verified for real.
    function _addClaim(Identity identity, address keyHolder, uint256 topic, bytes memory data) internal {
        bytes memory sig = _signClaim(address(identity), topic, data);
        vm.prank(keyHolder);
        identity.addClaim(topic, CLAIM_SCHEME, address(claimIssuerContract), sig, data, "");
    }

    function _proxy(address implementation, bytes memory initData) private returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }
}
