// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IMandateModule} from "../interfaces/IMandateModule.sol";

/// @title AgentClaim
/// @notice Claim topic and data format for the AGENT_MANDATE claim, plus the mandate hash.
/// @dev The issuer, the module, and the tests all use this library so the mandate is hashed one way.
library AgentClaim {
    /// @notice ONCHAINID claim topic for an agent mandate.
    uint256 internal constant AGENT_MANDATE = uint256(keccak256("AGENT_MANDATE"));

    /// @notice Encodes claim data as `abi.encode(agentId, agentWallet, mandateHash, expiry)`.
    /// @param expiry The claim's own expiry, which is separate from the mandate's expiry.
    function encode(uint256 agentId, address agentWallet, bytes32 hash, uint256 expiry)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(agentId, agentWallet, hash, expiry);
    }

    /// @notice Decodes claim data produced by `encode`.
    function decode(bytes memory data)
        internal
        pure
        returns (uint256 agentId, address agentWallet, bytes32 hash, uint256 expiry)
    {
        return abi.decode(data, (uint256, address, bytes32, uint256));
    }

    /// @notice Hash of every field of the mandate except `revoked`, so revoking never changes the hash.
    function mandateHash(IMandateModule.Mandate memory m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m.principal, m.agentId, m.maxPerTransfer, m.dailyCap, m.expiry));
    }
}
