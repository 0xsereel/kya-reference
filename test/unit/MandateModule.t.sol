// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ClaimIssuer} from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import {IClaimIssuer} from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TREXFixture} from "../fixtures/TREXFixture.sol";
import {MandateModule} from "../../src/MandateModule.sol";
import {IMandateModule} from "../../src/interfaces/IMandateModule.sol";
import {AgentClaim} from "../../src/libraries/AgentClaim.sol";

contract MandateModuleTest is TREXFixture {
    event MandateSet(
        address indexed compliance,
        address indexed agent,
        address indexed principal,
        uint256 agentId,
        bytes32 mandateHash
    );
    event MandateRevoked(address indexed compliance, address indexed agent, address indexed revokedBy);

    address internal otherWallet;

    function setUp() public override {
        super.setUp();
        otherWallet = makeAddr("otherWallet");
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    /// @dev Registers the agent wallet under the principal and an agentId, but issues no claim and sets no mandate.
    function _prepare() internal returns (IMandateModule.Mandate memory m) {
        _registerAgentWallet(aiAgent, address(principalIdentity));
        m = _defaultMandate();
        m.principal = address(principalIdentity);
        m.agentId = _registerAgentId(aiAgent);
    }

    function _revokeAsCompliance() internal {
        vm.prank(issuer);
        compliance.callModuleFunction(
            abi.encodeCall(IMandateModule.revokeMandate, (address(compliance), aiAgent)), address(module)
        );
    }

    function _day() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @dev Deploys another claim issuer that accepts `claimSigner`'s signatures, optionally trusted by the token.
    function _extraIssuer(bool trusted) internal returns (ClaimIssuer extra) {
        extra = new ClaimIssuer(claimIssuerAdmin);
        vm.prank(claimIssuerAdmin);
        extra.addKey(keccak256(abi.encode(claimSigner.addr)), 3, 1);
        if (trusted) {
            uint256[] memory topics = new uint256[](1);
            topics[0] = AGENT_MANDATE;
            vm.prank(issuer);
            issuersRegistry.addTrustedIssuer(IClaimIssuer(address(extra)), topics);
        }
    }

    function _addClaimFrom(ClaimIssuer from, bytes memory data) internal {
        bytes memory sig = _signClaim(address(principalIdentity), AGENT_MANDATE, data);
        vm.prank(principal);
        principalIdentity.addClaim(AGENT_MANDATE, CLAIM_SCHEME, address(from), sig, data, "");
    }

    // ------------------------------------------------------------------------------------------------
    // setMandate
    // ------------------------------------------------------------------------------------------------

    function test_setMandate_succeeds_withValidClaim() public {
        IMandateModule.Mandate memory m = _prepare();
        _issueMandateClaim(m, aiAgent);

        vm.expectEmit(true, true, true, true, address(module));
        emit MandateSet(address(compliance), aiAgent, address(principalIdentity), m.agentId, AgentClaim.mandateHash(m));
        _setMandate(aiAgent, m);

        IMandateModule.Mandate memory stored = module.getMandate(address(compliance), aiAgent);
        assertEq(stored.principal, address(principalIdentity));
        assertEq(stored.agentId, m.agentId);
        assertEq(stored.maxPerTransfer, m.maxPerTransfer);
        assertEq(stored.dailyCap, m.dailyCap);
        assertEq(stored.expiry, m.expiry);
        assertFalse(stored.revoked);
    }

    function test_setMandate_reverts_whenCallerNotCompliance() public {
        IMandateModule.Mandate memory m = _prepare();
        _issueMandateClaim(m, aiAgent);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IMandateModule.OnlyCompliance.selector, issuer));
        module.setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenClaimMissing() public {
        IMandateModule.Mandate memory m = _prepare();

        vm.expectRevert(abi.encodeWithSelector(IMandateModule.ClaimNotFound.selector, address(principalIdentity)));
        _setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenIssuerUntrusted() public {
        IMandateModule.Mandate memory m = _prepare();
        _issueMandateClaim(m, aiAgent);
        // The issuer loses trust after the claim was added.
        vm.prank(issuer);
        issuersRegistry.removeTrustedIssuer(IClaimIssuer(address(claimIssuerContract)));

        vm.expectRevert(
            abi.encodeWithSelector(IMandateModule.UntrustedClaimIssuer.selector, address(claimIssuerContract))
        );
        _setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenHashMismatch() public {
        IMandateModule.Mandate memory m = _prepare();
        _issueMandateClaim(m, aiAgent);
        // Submit a mandate with a higher cap than the one the claim commits to.
        IMandateModule.Mandate memory tampered =
            IMandateModule.Mandate(m.principal, m.agentId, m.maxPerTransfer, m.dailyCap + 1, m.expiry, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMandateModule.MandateHashMismatch.selector, AgentClaim.mandateHash(m), AgentClaim.mandateHash(tampered)
            )
        );
        _setMandate(aiAgent, tampered);
    }

    function test_setMandate_reverts_whenAgentWalletMismatch() public {
        IMandateModule.Mandate memory m = _prepare();
        _issueMandateClaim(m, otherWallet); // claim names a different wallet

        vm.expectRevert(abi.encodeWithSelector(IMandateModule.AgentWalletMismatch.selector, otherWallet, aiAgent));
        _setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenAgentIdUnknown() public {
        IMandateModule.Mandate memory m = _prepare();
        m.agentId = 999; // never registered in the ERC-8004 mock
        _issueMandateClaim(m, aiAgent);

        vm.expectRevert(abi.encodeWithSelector(IMandateModule.UnknownAgentId.selector, 999));
        _setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenWalletNotLinkedToPrincipal() public {
        // The wallet is registered, but under another holder's identity.
        _registerAgentWallet(aiAgent, address(investorIdentity));
        IMandateModule.Mandate memory m = _defaultMandate();
        m.principal = address(principalIdentity);
        m.agentId = _registerAgentId(aiAgent);
        _issueMandateClaim(m, aiAgent);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMandateModule.IdentityMismatch.selector, aiAgent, address(principalIdentity), address(investorIdentity)
            )
        );
        _setMandate(aiAgent, m);
    }

    // ------------------------------------------------------------------------------------------------
    // setMandate: additional paths
    // ------------------------------------------------------------------------------------------------

    function test_setMandate_reverts_whenWalletUnregistered() public {
        IMandateModule.Mandate memory m = _defaultMandate();
        m.principal = address(principalIdentity);
        m.agentId = _registerAgentId(aiAgent);
        _issueMandateClaim(m, aiAgent);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMandateModule.IdentityMismatch.selector, aiAgent, address(principalIdentity), address(0)
            )
        );
        _setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenClaimAgentIdMismatch() public {
        IMandateModule.Mandate memory m = _prepare();
        // The hash matches the mandate, but the claim data names a different agentId.
        _issueMandateClaim(AgentClaim.encode(m.agentId + 1, aiAgent, AgentClaim.mandateHash(m), m.expiry));

        vm.expectRevert(abi.encodeWithSelector(IMandateModule.AgentIdMismatch.selector, m.agentId + 1, m.agentId));
        _setMandate(aiAgent, m);
    }

    function test_setMandate_reverts_whenClaimRevokedByIssuer() public {
        IMandateModule.Mandate memory m = _prepare();
        _issueMandateClaim(m, aiAgent);

        bytes32 claimId = keccak256(abi.encode(address(claimIssuerContract), AGENT_MANDATE));
        (,,, bytes memory sig,,) = principalIdentity.getClaim(claimId);
        vm.prank(claimIssuerAdmin);
        claimIssuerContract.revokeClaimBySignature(sig);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMandateModule.ClaimNotValid.selector, address(principalIdentity), address(claimIssuerContract)
            )
        );
        _setMandate(aiAgent, m);
    }

    function test_setMandate_findsMatchingClaim_amongSeveral() public {
        IMandateModule.Mandate memory m = _prepare();
        ClaimIssuer secondTrusted = _extraIssuer(true);
        // First claim (claimIssuerContract) names another wallet, the second (secondTrusted) names the agent.
        _issueMandateClaim(m, otherWallet);
        _addClaimFrom(secondTrusted, AgentClaim.encode(m.agentId, aiAgent, AgentClaim.mandateHash(m), m.expiry));

        _setMandate(aiAgent, m);

        assertEq(module.getMandate(address(compliance), aiAgent).agentId, m.agentId);
    }

    function test_setMandate_skipsUntrustedClaims() public {
        IMandateModule.Mandate memory m = _prepare();
        ClaimIssuer rogue = _extraIssuer(false);
        bytes memory data = AgentClaim.encode(m.agentId, aiAgent, AgentClaim.mandateHash(m), m.expiry);
        _addClaimFrom(rogue, data); // untrusted issuer's claim comes first
        _issueMandateClaim(data);

        _setMandate(aiAgent, m);

        assertEq(module.getMandate(address(compliance), aiAgent).agentId, m.agentId);
    }

    function test_setMandate_afterRevocation_reinstatesMandate() public {
        IMandateModule.Mandate memory m = _grantMandate(_defaultMandate());
        _revokeAsCompliance();
        assertTrue(module.getMandate(address(compliance), aiAgent).revoked);

        _setMandate(aiAgent, m);

        assertFalse(module.getMandate(address(compliance), aiAgent).revoked);
    }

    function test_constructor_reverts_whenRegistryIsZero() public {
        vm.expectRevert(IMandateModule.ZeroAddress.selector);
        new MandateModule(IERC721(address(0)));
    }

    // ------------------------------------------------------------------------------------------------
    // revokeMandate
    // ------------------------------------------------------------------------------------------------

    function test_revoke_byCompliance() public {
        IMandateModule.Mandate memory m = _grantMandate(_defaultMandate());

        vm.expectEmit(true, true, true, true, address(module));
        emit MandateRevoked(address(compliance), aiAgent, address(compliance));
        _revokeAsCompliance();

        IMandateModule.Mandate memory stored = module.getMandate(address(compliance), aiAgent);
        assertTrue(stored.revoked);
        // The record survives revocation.
        assertEq(stored.principal, m.principal);
        assertEq(stored.dailyCap, m.dailyCap);
    }

    function test_revoke_byPrincipalManagementKey() public {
        _grantMandate(_defaultMandate());

        vm.expectEmit(true, true, true, true, address(module));
        emit MandateRevoked(address(compliance), aiAgent, principal);
        vm.prank(principal);
        module.revokeMandate(address(compliance), aiAgent);

        assertTrue(module.getMandate(address(compliance), aiAgent).revoked);
    }

    function test_revoke_reverts_forUnrelatedCaller() public {
        _grantMandate(_defaultMandate());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IMandateModule.NotAuthorizedToRevoke.selector, stranger));
        module.revokeMandate(address(compliance), aiAgent);

        assertFalse(module.getMandate(address(compliance), aiAgent).revoked);
    }

    function test_revoke_reverts_forTheAgentItself() public {
        _grantMandate(_defaultMandate());

        vm.prank(aiAgent);
        vm.expectRevert(abi.encodeWithSelector(IMandateModule.NotAuthorizedToRevoke.selector, aiAgent));
        module.revokeMandate(address(compliance), aiAgent);
    }

    function test_revoke_reverts_whenComplianceNotBound() public {
        address unbound = makeAddr("unboundCompliance");

        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IMandateModule.ComplianceNotBound.selector, unbound));
        module.revokeMandate(unbound, aiAgent);
    }

    function test_revoke_reverts_whenNoMandate() public {
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IMandateModule.MandateNotFound.selector, address(compliance), aiAgent));
        module.revokeMandate(address(compliance), aiAgent);
    }

    // ------------------------------------------------------------------------------------------------
    // IModule surface
    // ------------------------------------------------------------------------------------------------

    function test_moduleCheck_trueForNonAgentSender() public view {
        assertTrue(module.moduleCheck(investor, principal, type(uint256).max, address(compliance)));
    }

    function test_moduleTransferAction_ignoresNonAgentSender() public {
        vm.prank(address(compliance));
        module.moduleTransferAction(investor, principal, 100 ether);

        assertEq(module.spent(address(compliance), investor, _day()), 0);
    }

    function test_moduleTransferAction_recordsAgentSpend() public {
        _grantMandate(_defaultMandate());

        vm.prank(address(compliance));
        module.moduleTransferAction(aiAgent, investor, 100 ether);

        assertEq(module.spent(address(compliance), aiAgent, _day()), 100 ether);
    }

    function test_moduleActions_revert_whenCallerNotBoundCompliance() public {
        vm.startPrank(stranger);
        vm.expectRevert("only bound compliance can call");
        module.moduleTransferAction(aiAgent, investor, 1);
        vm.expectRevert("only bound compliance can call");
        module.moduleMintAction(investor, 1);
        vm.expectRevert("only bound compliance can call");
        module.moduleBurnAction(investor, 1);
        vm.stopPrank();
    }

    function test_moduleMintAndBurnActions_areNoOps() public {
        _grantMandate(_defaultMandate());

        vm.startPrank(address(compliance));
        module.moduleMintAction(aiAgent, 100 ether);
        module.moduleBurnAction(aiAgent, 100 ether);
        vm.stopPrank();

        assertEq(module.spent(address(compliance), aiAgent, _day()), 0);
    }

    function test_moduleMetadata() public view {
        assertEq(module.name(), "MandateModule");
        assertTrue(module.isPlugAndPlay());
        assertTrue(module.canComplianceBind(address(compliance)));
    }
}
