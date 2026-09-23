// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IIdentity} from "@onchain-id/solidity/contracts/interface/IIdentity.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {AbstractModule} from "@trex/contracts/compliance/modular/modules/AbstractModule.sol";
import {IModule} from "@trex/contracts/compliance/modular/modules/IModule.sol";
import {IModularCompliance} from "@trex/contracts/compliance/modular/IModularCompliance.sol";
import {IToken} from "@trex/contracts/token/IToken.sol";
import {IIdentityRegistry} from "@trex/contracts/registry/interface/IIdentityRegistry.sol";
import {ITrustedIssuersRegistry} from "@trex/contracts/registry/interface/ITrustedIssuersRegistry.sol";

import {IMandateModule} from "./interfaces/IMandateModule.sol";
import {AgentClaim} from "./libraries/AgentClaim.sol";

/// @title MandateModule
/// @notice T-REX compliance module that enforces a principal's mandate on every transfer an AI agent sends.
/// @dev Reference code, unaudited, not for production. Here "agent" is the AI agent, not a T-REX token agent.
///      Mandates are stored by compliance contract, then agent wallet. A sender with no mandate is untouched.
contract MandateModule is AbstractModule, IMandateModule {
    /// @notice ERC-8004 identity registry used to confirm that an `agentId` exists.
    IERC721 public immutable agentRegistry;

    /// @notice Amount sent per compliance, agent wallet, and UTC day (`block.timestamp / 1 days`).
    mapping(address => mapping(address => mapping(uint256 => uint256))) public override spent;

    mapping(address => mapping(address => Mandate)) private _mandates;

    constructor(IERC721 agentRegistry_) {
        if (address(agentRegistry_) == address(0)) revert ZeroAddress();
        agentRegistry = agentRegistry_;
    }

    // ---------------------------------------------------------------------------------------------
    // Mandate management
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IMandateModule
    /// @dev Registries are reached through the compliance contract: compliance -> token -> identity registry
    ///      -> trusted issuers registry.
    function setMandate(address agent, Mandate calldata mandate) external override {
        // isComplianceBound is external in AbstractModule and its mapping is private, hence the self-call.
        if (!this.isComplianceBound(msg.sender)) revert OnlyCompliance(msg.sender);

        IIdentityRegistry registry = IToken(IModularCompliance(msg.sender).getTokenBound()).identityRegistry();

        // 1. The agent wallet is registered under the principal's ONCHAINID.
        if (!registry.contains(agent) || address(registry.identity(agent)) != mandate.principal) {
            revert IdentityMismatch(agent, mandate.principal, address(registry.identity(agent)));
        }

        // 2-4. The principal holds an AGENT_MANDATE claim from a trusted issuer that matches the mandate.
        (uint256 claimedAgentId, bytes32 claimedHash) = _matchingClaim(registry, mandate.principal, agent);
        bytes32 hash = AgentClaim.mandateHash(mandate);
        if (claimedHash != hash) revert MandateHashMismatch(claimedHash, hash);
        if (claimedAgentId != mandate.agentId) revert AgentIdMismatch(claimedAgentId, mandate.agentId);

        // 5. The agentId exists in the ERC-8004 registry.
        try agentRegistry.ownerOf(mandate.agentId) returns (address) {}
        catch {
            revert UnknownAgentId(mandate.agentId);
        }

        _mandates[msg.sender][agent] = Mandate({
            principal: mandate.principal,
            agentId: mandate.agentId,
            maxPerTransfer: mandate.maxPerTransfer,
            dailyCap: mandate.dailyCap,
            expiry: mandate.expiry,
            revoked: false
        });
        emit MandateSet(msg.sender, agent, mandate.principal, mandate.agentId, hash);
    }

    /// @inheritdoc IMandateModule
    /// @dev The management-key check mirrors ONCHAINID: the key is `keccak256(abi.encode(address))`, purpose 1.
    function revokeMandate(address compliance, address agent) external override {
        // Stops a caller from writing into the slot of a compliance contract that is not bound to this module.
        if (!this.isComplianceBound(compliance)) revert ComplianceNotBound(compliance);

        Mandate storage m = _mandates[compliance][agent];
        if (m.principal == address(0)) revert MandateNotFound(compliance, agent);

        if (msg.sender != compliance) {
            if (!IIdentity(m.principal).keyHasPurpose(keccak256(abi.encode(msg.sender)), 1)) {
                revert NotAuthorizedToRevoke(msg.sender);
            }
        }

        m.revoked = true;
        emit MandateRevoked(compliance, agent, msg.sender);
    }

    /// @inheritdoc IMandateModule
    function getMandate(address compliance, address agent) external view override returns (Mandate memory) {
        return _mandates[compliance][agent];
    }

    // ---------------------------------------------------------------------------------------------
    // IModule
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IModule
    function moduleCheck(address _from, address, uint256 _value, address _compliance)
        external
        view
        override
        returns (bool)
    {
        Mandate storage m = _mandates[_compliance][_from];
        if (m.principal == address(0)) return true;
        if (m.revoked || block.timestamp > m.expiry) return false;
        if (_value > m.maxPerTransfer) return false;
        return spent[_compliance][_from][block.timestamp / 1 days] + _value <= m.dailyCap;
    }

    /// @inheritdoc IModule
    function moduleTransferAction(address _from, address, uint256 _value) external override onlyComplianceCall {
        if (_mandates[msg.sender][_from].principal == address(0)) return;
        spent[msg.sender][_from][block.timestamp / 1 days] += _value;
    }

    /// @inheritdoc IModule
    function moduleMintAction(address, uint256) external override onlyComplianceCall {}

    /// @inheritdoc IModule
    function moduleBurnAction(address, uint256) external override onlyComplianceCall {}

    /// @inheritdoc IModule
    function canComplianceBind(address) external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    function isPlugAndPlay() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IModule
    function name() external pure override returns (string memory) {
        return "MandateModule";
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev Finds the AGENT_MANDATE claim on `principal` that names `agent`, among claims from issuers trusted for
    ///      the topic. Reverts with ClaimNotFound if the principal has no such claim at all, UntrustedClaimIssuer if
    ///      none comes from a trusted issuer, AgentWalletMismatch if no trusted claim names `agent`, and
    ///      ClaimNotValid if the matching claim fails the issuer's `isClaimValid` (bad signature or revoked).
    function _matchingClaim(IIdentityRegistry registry, address principal, address agent)
        private
        view
        returns (uint256 agentId, bytes32 hash)
    {
        bytes32[] memory ids = IIdentity(principal).getClaimIdsByTopic(AgentClaim.AGENT_MANDATE);
        if (ids.length == 0) revert ClaimNotFound(principal);

        ITrustedIssuersRegistry issuers = registry.issuersRegistry();
        address firstTrustedWallet;
        bool trustedSeen;

        for (uint256 i = 0; i < ids.length; i++) {
            (address issuer, bytes memory data) = _claimData(principal, ids[i], issuers);
            if (issuer == address(0)) continue;

            (uint256 claimAgentId, address claimWallet, bytes32 claimHash,) = AgentClaim.decode(data);
            if (claimWallet == agent) {
                _requireValid(principal, ids[i], issuer);
                return (claimAgentId, claimHash);
            }
            if (!trustedSeen) {
                trustedSeen = true;
                firstTrustedWallet = claimWallet;
            }
        }

        if (!trustedSeen) {
            (,, address firstIssuer,,,) = IIdentity(principal).getClaim(ids[0]);
            revert UntrustedClaimIssuer(firstIssuer);
        }
        revert AgentWalletMismatch(firstTrustedWallet, agent);
    }

    /// @dev Returns the claim's issuer and data, or a zero issuer if the issuer is not trusted for the topic.
    function _claimData(address principal, bytes32 id, ITrustedIssuersRegistry issuers)
        private
        view
        returns (address, bytes memory)
    {
        (,, address issuer,, bytes memory data,) = IIdentity(principal).getClaim(id);
        if (!issuers.isTrustedIssuer(issuer) || !issuers.hasClaimTopic(issuer, AgentClaim.AGENT_MANDATE)) {
            return (address(0), data);
        }
        return (issuer, data);
    }

    /// @dev Re-checks the claim with its issuer at mandate time, so a claim the issuer revoked after `addClaim`
    ///      is refused.
    function _requireValid(address principal, bytes32 id, address issuer) private view {
        (,,, bytes memory sig, bytes memory data,) = IIdentity(principal).getClaim(id);
        if (!IClaimIssuer(issuer).isClaimValid(IIdentity(principal), AgentClaim.AGENT_MANDATE, sig, data)) {
            revert ClaimNotValid(principal, issuer);
        }
    }
}
