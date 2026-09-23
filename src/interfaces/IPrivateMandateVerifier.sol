// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @title IPrivateMandateVerifier
/// @notice Interface stub for the private mandate flow in section 5 of the post
///         "Know Your Agent for Tokenized Securities" (https://sereel.com/blog/24).
/// @dev Nothing in this repo implements or calls this interface. It marks where a verifier would attach:
///      the agent proves in zero knowledge that a transfer fits inside a mandate committed to under `claimsRoot`,
///      without revealing the mandate's limits on-chain. See the post for the design.
interface IPrivateMandateVerifier {
    /// @notice Verifies a zero-knowledge proof that a transfer satisfies the agent's mandate.
    /// @param proof The proof bytes.
    /// @param claimsRoot Root of the commitment to the principal's claims, including the mandate.
    /// @param transferCommitment Commitment to the transfer being checked.
    /// @return True if the proof is valid for the given root and commitment.
    function verify(bytes calldata proof, bytes32 claimsRoot, bytes32 transferCommitment) external view returns (bool);
}
