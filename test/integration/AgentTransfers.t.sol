// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {TREXFixture} from "../fixtures/TREXFixture.sol";
import {IMandateModule} from "../../src/interfaces/IMandateModule.sol";

/// @notice Walks the mandate lifecycle on a real T-REX token. Every test starts from `_grantMandate` (in `setUp`),
///         so the whole setup path (identity link, claim, ERC-8004 id, `setMandate`) runs every time.
/// @dev T-REX reverts at the token level with "Transfer not possible" when compliance fails. Each blocked case also
///      asserts `compliance.canTransfer` returned false for the same inputs.
contract AgentTransfersTest is TREXFixture {
    string internal constant TRANSFER_NOT_POSSIBLE = "Transfer not possible";

    IMandateModule.Mandate internal mandate;

    function setUp() public override {
        super.setUp();
        // Defaults: maxPerTransfer 1,000, dailyCap 2,500, expiry 30 days out.
        mandate = _grantMandate(_defaultMandate());
        _fund(aiAgent, AGENT_BALANCE);
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    function _spent() internal view returns (uint256) {
        return module.spent(address(compliance), aiAgent, block.timestamp / 1 days);
    }

    function _nextMidnight() internal view returns (uint256) {
        return (block.timestamp / 1 days + 1) * 1 days;
    }

    /// @dev Transfer from the agent to the investor that must succeed, with the preflight agreeing.
    function _assertAllowed(uint256 amount) internal {
        uint256 agentBefore = token.balanceOf(aiAgent);
        uint256 investorBefore = token.balanceOf(investor);
        uint256 spentBefore = _spent();

        assertTrue(compliance.canTransfer(aiAgent, investor, amount), "preflight should allow");
        vm.prank(aiAgent);
        token.transfer(investor, amount);

        assertEq(token.balanceOf(aiAgent), agentBefore - amount);
        assertEq(token.balanceOf(investor), investorBefore + amount);
        assertEq(_spent(), spentBefore + amount);
    }

    /// @dev Transfer from the agent to the investor that must revert, with the preflight agreeing and nothing moving.
    function _assertBlocked(uint256 amount) internal {
        uint256 agentBefore = token.balanceOf(aiAgent);
        uint256 investorBefore = token.balanceOf(investor);
        uint256 spentBefore = _spent();

        assertFalse(compliance.canTransfer(aiAgent, investor, amount), "preflight should block");
        vm.prank(aiAgent);
        vm.expectRevert(bytes(TRANSFER_NOT_POSSIBLE));
        token.transfer(investor, amount);

        assertEq(token.balanceOf(aiAgent), agentBefore);
        assertEq(token.balanceOf(investor), investorBefore);
        assertEq(_spent(), spentBefore);
    }

    /// @dev Attempts the transfer and reports whether it went through.
    function _attempt(uint256 amount) internal returns (bool) {
        vm.prank(aiAgent);
        try token.transfer(investor, amount) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @dev Asserts the preflight prediction equals the real outcome, and that the outcome is `expected`.
    function _assertPreflightMatches(uint256 amount, bool expected) internal {
        bool predicted = compliance.canTransfer(aiAgent, investor, amount);
        bool actual = _attempt(amount);
        assertEq(predicted, actual, "preflight disagrees with outcome");
        assertEq(actual, expected, "unexpected outcome");
    }

    function _revokeAsPrincipal() internal {
        vm.prank(principal);
        module.revokeMandate(address(compliance), aiAgent);
    }

    // ------------------------------------------------------------------------------------------------
    // Mandate limits
    // ------------------------------------------------------------------------------------------------

    function test_agentTransfer_withinMandate_succeeds() public {
        _assertAllowed(500 ether);

        assertEq(_spent(), 500 ether);
    }

    function test_agentTransfer_overPerTransferLimit_fails() public {
        _assertBlocked(mandate.maxPerTransfer + 1);
        // The limit itself is allowed.
        _assertAllowed(mandate.maxPerTransfer);
    }

    function test_agentTransfer_overDailyCap_fails() public {
        _assertAllowed(1_000 ether);
        _assertAllowed(1_000 ether);
        // 2,000 spent, so this second-or-later transfer would cross the 2,500 cap.
        _assertBlocked(501 ether);
        // Landing exactly on the cap is allowed, one more unit is not.
        _assertAllowed(500 ether);
        _assertBlocked(1);
    }

    function test_agentTransfer_capResets_nextDay() public {
        _assertAllowed(1_000 ether);
        _assertAllowed(1_000 ether);
        _assertAllowed(500 ether);
        _assertBlocked(1);

        // One second before UTC midnight the day's spend still applies.
        vm.warp(_nextMidnight() - 1);
        _assertBlocked(1);

        // At UTC midnight the bucket rolls over.
        vm.warp(_nextMidnight());
        assertEq(_spent(), 0);
        _assertAllowed(1_000 ether);
    }

    function test_agentTransfer_afterExpiry_fails() public {
        vm.warp(mandate.expiry);
        _assertAllowed(1 ether); // still valid at the expiry timestamp

        vm.warp(mandate.expiry + 1);
        _assertBlocked(1 ether);
    }

    function test_agentTransfer_afterRevocation_fails() public {
        uint256 agentId = mandate.agentId;
        address ownerBefore = agentRegistry.ownerOf(agentId);
        string memory uriBefore = agentRegistry.tokenURI(agentId);

        _assertAllowed(1 ether);
        _revokeAsPrincipal();
        _assertBlocked(1 ether);

        // Revocation acts on the mandate only. The ERC-8004 entry is untouched.
        assertEq(agentRegistry.ownerOf(agentId), ownerBefore);
        assertEq(agentRegistry.tokenURI(agentId), uriBefore);
        // The record survives.
        assertTrue(module.getMandate(address(compliance), aiAgent).revoked);
        assertEq(module.getMandate(address(compliance), aiAgent).dailyCap, mandate.dailyCap);
    }

    function test_agentTransferFrom_isAlsoEnforced() public {
        // A spender moving the agent's tokens is still a transfer from the agent wallet.
        vm.prank(aiAgent);
        token.approve(investor, type(uint256).max);

        assertFalse(compliance.canTransfer(aiAgent, investor, mandate.maxPerTransfer + 1));
        vm.prank(investor);
        vm.expectRevert(bytes(TRANSFER_NOT_POSSIBLE));
        token.transferFrom(aiAgent, investor, mandate.maxPerTransfer + 1);

        vm.prank(investor);
        token.transferFrom(aiAgent, investor, 100 ether);
        assertEq(_spent(), 100 ether);
    }

    // ------------------------------------------------------------------------------------------------
    // Interaction with T-REX's own controls
    // ------------------------------------------------------------------------------------------------

    function test_agentTransfer_toUnverifiedWallet_fails() public {
        assertFalse(identityRegistry.isVerified(stranger));
        // The module has no objection: the amount is inside the mandate. The identity registry blocks the transfer.
        assertTrue(compliance.canTransfer(aiAgent, stranger, 1 ether));

        uint256 agentBefore = token.balanceOf(aiAgent);
        vm.prank(aiAgent);
        vm.expectRevert(bytes(TRANSFER_NOT_POSSIBLE));
        token.transfer(stranger, 1 ether);

        assertEq(token.balanceOf(aiAgent), agentBefore);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(_spent(), 0);
    }

    function test_investorTransfer_unaffected() public {
        // Well above every agent limit, and no mandate exists for the investor.
        uint256 amount = 5_000 ether;
        assertEq(module.getMandate(address(compliance), investor).principal, address(0));
        assertTrue(compliance.canTransfer(investor, principal, amount));

        vm.prank(investor);
        token.transfer(principal, amount);

        assertEq(token.balanceOf(principal), amount);
        assertEq(token.balanceOf(investor), INVESTOR_BALANCE - amount);
        assertEq(module.spent(address(compliance), investor, block.timestamp / 1 days), 0);
    }

    function test_preflight_canTransfer_matchesOutcome() public {
        // Day 1: per-transfer limit, then the daily cap.
        _assertPreflightMatches(1_000 ether, true);
        _assertPreflightMatches(1_001 ether, false);
        _assertPreflightMatches(1_000 ether, true);
        _assertPreflightMatches(501 ether, false);
        _assertPreflightMatches(500 ether, true);
        _assertPreflightMatches(1, false);

        // Day 2: the cap resets.
        vm.warp(_nextMidnight());
        _assertPreflightMatches(1_000 ether, true);

        // Past expiry.
        vm.warp(mandate.expiry + 1);
        _assertPreflightMatches(1 ether, false);

        // A revoked mandate, checked at a time before expiry as well.
        vm.warp(mandate.expiry - 1 days);
        _assertPreflightMatches(1 ether, true);
        _revokeAsPrincipal();
        _assertPreflightMatches(1 ether, false);
    }

    function test_frozenAgent_blocked_byTrexAgent() public {
        vm.prank(trexAgent);
        token.setAddressFrozen(aiAgent, true);

        // The mandate is valid and the amount is inside it, yet the freeze wins.
        assertTrue(compliance.canTransfer(aiAgent, investor, 1 ether));
        vm.prank(aiAgent);
        vm.expectRevert("wallet is frozen");
        token.transfer(investor, 1 ether);

        vm.prank(trexAgent);
        token.setAddressFrozen(aiAgent, false);
        _assertAllowed(1 ether);
    }

    function test_forcedTransfer_bypassesMandate() public {
        // Well above maxPerTransfer and dailyCap.
        uint256 amount = 3_000 ether;
        assertGt(amount, mandate.dailyCap);
        assertFalse(compliance.canTransfer(aiAgent, investor, amount));

        // Even a revoked mandate does not stop the issuer.
        _revokeAsPrincipal();

        uint256 agentBefore = token.balanceOf(aiAgent);
        uint256 investorBefore = token.balanceOf(investor);
        vm.prank(trexAgent);
        token.forcedTransfer(aiAgent, investor, amount);

        assertEq(token.balanceOf(aiAgent), agentBefore - amount);
        assertEq(token.balanceOf(investor), investorBefore + amount);

        // T-REX's forcedTransfer calls compliance.transferred like any transfer, so the module cannot tell it apart
        // and records the amount as spend for the day. That is accepted behavior: the forced transfer is never
        // blocked, but it does count toward the agent's daily cap.
        assertEq(_spent(), amount);
    }

    function test_beneficialOwner_isPrincipal() public view {
        // The agent's holdings resolve to the principal's ONCHAINID, the same identity the principal's wallet uses.
        assertEq(address(identityRegistry.identity(aiAgent)), address(principalIdentity));
        assertEq(address(identityRegistry.identity(aiAgent)), address(identityRegistry.identity(principal)));
        assertEq(mandate.principal, address(principalIdentity));
        // And the principal controls that identity with a management key.
        assertTrue(principalIdentity.keyHasPurpose(keccak256(abi.encode(principal)), 1));
    }
}
