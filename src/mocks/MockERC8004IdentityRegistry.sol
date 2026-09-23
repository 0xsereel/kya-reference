// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title MockERC8004IdentityRegistry
/// @notice Test mock of the ERC-8004 Identity Registry. Reference code, unaudited, not for production.
/// @dev Follows ERC-8004 as published at https://eips.ethereum.org/EIPS/eip-8004, status Draft, created
///      2025-08-13, as read on 2026-09-23. The draft carries no revision number, so that date is the pin.
///      ERC-8004 is still a draft: re-check the function names below against the current text before tagging.
///
///      Mirrors only the subset the MandateModule needs, which is existence and ownership of an `agentId`
///      (through ERC-721 `ownerOf`, which reverts for an unknown id). From the draft it implements
///      `register(string agentURI)`, `setAgentURI(uint256,string)`, `tokenURI`, and the `Registered` and
///      `URIUpdated` events. Omitted: the `register()` and `register(string,MetadataEntry[])` overloads,
///      metadata, and agent wallet functions.
contract MockERC8004IdentityRegistry is ERC721URIStorage {
    /// @dev Emitted when an agent is registered.
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    /// @dev Emitted when an agent's URI changes.
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);

    /// @dev Caller does not own the agentId.
    error NotAgentOwner(uint256 agentId, address caller);

    uint256 private _lastAgentId;

    constructor() ERC721("MockAgentIdentity", "MAGENT") {}

    /// @notice Mints a new `agentId` to the caller.
    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = ++_lastAgentId;
        // _mint, not _safeMint: no receiver callback is needed in a mock, and it avoids reentrancy in tests.
        _mint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        emit Registered(agentId, agentURI, msg.sender);
    }

    /// @notice Updates the URI of `agentId`. Only the owner may call.
    function setAgentURI(uint256 agentId, string calldata newURI) external {
        if (ownerOf(agentId) != msg.sender) revert NotAgentOwner(agentId, msg.sender);
        _setTokenURI(agentId, newURI);
        emit URIUpdated(agentId, newURI, msg.sender);
    }
}
