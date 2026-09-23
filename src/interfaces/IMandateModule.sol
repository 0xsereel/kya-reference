// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @title IMandateModule
/// @notice Interface for the compliance module that enforces an AI agent's mandate on every transfer it sends.
/// @dev "Agent" here means the AI agent (`aiAgent` in the tests), not a T-REX token agent.
///      Mandates are keyed by compliance contract, then agent wallet.
interface IMandateModule {
    /// @notice The limits a principal grants to an agent wallet.
    /// @param principal The principal's ONCHAINID address.
    /// @param agentId The agent's ERC-8004 identity id.
    /// @param maxPerTransfer Largest single transfer the agent may send, in token base units.
    /// @param dailyCap Largest cumulative amount the agent may send per UTC day, in token base units.
    /// @param expiry Unix timestamp after which the agent may no longer transfer.
    /// @param revoked Set once the mandate is revoked. The record is kept, not deleted.
    struct Mandate {
        address principal;
        uint256 agentId;
        uint256 maxPerTransfer;
        uint256 dailyCap;
        uint256 expiry;
        bool revoked;
    }

    /// @notice Emitted when a mandate is stored.
    event MandateSet(
        address indexed compliance,
        address indexed agent,
        address indexed principal,
        uint256 agentId,
        bytes32 mandateHash
    );

    /// @notice Emitted when a mandate is revoked. `revokedBy` is the compliance contract or the principal's wallet.
    event MandateRevoked(address indexed compliance, address indexed agent, address indexed revokedBy);

    /// @dev Caller is not a compliance contract acting through `callModuleFunction`.
    error OnlyCompliance(address caller);
    /// @dev The compliance contract is not bound to a token, so its registries cannot be resolved.
    error ComplianceNotBound(address compliance);
    /// @dev The agent wallet is not registered under the mandate's principal in the identity registry.
    error IdentityMismatch(address agent, address expectedPrincipal, address actualIdentity);
    /// @dev The principal holds no AGENT_MANDATE claim.
    error ClaimNotFound(address principal);
    /// @dev The claim issuer is not trusted for the AGENT_MANDATE topic.
    error UntrustedClaimIssuer(address issuer);
    /// @dev The claim's agent wallet differs from the wallet in the mandate call.
    error AgentWalletMismatch(address claimed, address actual);
    /// @dev The claim's mandate hash differs from the hash of the submitted mandate.
    error MandateHashMismatch(bytes32 claimed, bytes32 actual);
    /// @dev The agentId is not registered in the ERC-8004 identity registry, or differs from the claim's.
    error UnknownAgentId(uint256 agentId);
    /// @dev No mandate is stored for this compliance and agent.
    error MandateNotFound(address compliance, address agent);
    /// @dev Caller is neither the compliance contract nor a management key holder on the principal's identity.
    error NotAuthorizedToRevoke(address caller);

    /// @notice Stores a mandate for `agent`. Callable only by a compliance contract (the token owner reaches it
    ///         through `ModularCompliance.callModuleFunction`). The compliance contract is `msg.sender`.
    /// @dev Reverts with a custom error unless the identity link, claim, issuer trust, and agentId checks pass.
    function setMandate(address agent, Mandate calldata mandate) external;

    /// @notice Revokes the mandate for `agent` under `compliance`.
    /// @dev Callable by the compliance contract, or by a wallet holding a management key on the principal's ONCHAINID.
    ///      Sets `revoked` and keeps the rest of the record.
    function revokeMandate(address compliance, address agent) external;

    /// @notice Returns the stored mandate. All fields are zero when none exists.
    function getMandate(address compliance, address agent) external view returns (Mandate memory);

    /// @notice Amount `agent` has sent under `compliance` on the UTC day bucket `day` (`timestamp / 1 days`).
    function spent(address compliance, address agent, uint256 day) external view returns (uint256);
}
