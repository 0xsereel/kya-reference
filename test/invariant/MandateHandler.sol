// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {Token} from "@trex/contracts/token/Token.sol";
import {ModularCompliance} from "@trex/contracts/compliance/modular/ModularCompliance.sol";

import {MandateModule} from "../../src/MandateModule.sol";

/// @notice Invariant-test handler. Exposes bounded actions and records ghost variables the invariants read.
/// @dev The invariant target is this contract only. Every call is wrapped so a rejected transfer is an outcome, not a
///      revert of the handler.
contract MandateHandler is Test {
    Token public immutable token;
    ModularCompliance public immutable compliance;
    MandateModule public immutable module;

    address public immutable aiAgent;
    address public immutable investor;
    address public immutable principal;

    /// @dev The mandate's terms, copied at construction.
    uint256 public immutable dailyCap;
    uint256 public immutable expiry;

    // Ghost variables.
    bool public revoked;
    uint256 public revokedAtBlock;
    /// @dev Agent transfers that succeeded at any point after `revokeMandate` ran, including in the same block.
    uint256 public successesAfterRevocation;
    /// @dev Agent transfers that succeeded while `block.timestamp > expiry`.
    uint256 public successesAfterExpiry;
    uint256 public agentSuccesses;
    uint256 public agentRejections;

    uint256[] internal _daysTouched;
    mapping(uint256 => bool) internal _dayRecorded;
    /// @dev What the agent actually sent per UTC day, counted here from successful transfers, not read from the module.
    mapping(uint256 => uint256) public sentByDay;

    constructor(
        Token token_,
        ModularCompliance compliance_,
        MandateModule module_,
        address aiAgent_,
        address investor_,
        address principal_,
        uint256 dailyCap_,
        uint256 expiry_
    ) {
        token = token_;
        compliance = compliance_;
        module = module_;
        aiAgent = aiAgent_;
        investor = investor_;
        principal = principal_;
        dailyCap = dailyCap_;
        expiry = expiry_;
    }

    // ------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------

    /// @notice The agent sends a random amount to the investor. Amounts run past the mandate's limits on purpose.
    function agentTransfer(uint256 amount) external {
        uint256 balance = token.balanceOf(aiAgent);
        if (balance == 0) return;
        amount = bound(amount, 1, balance < 3_000 ether ? balance : 3_000 ether);

        vm.prank(aiAgent);
        try token.transfer(investor, amount) returns (bool ok) {
            if (ok) _recordAgentSuccess(amount);
            else agentRejections++;
        } catch {
            agentRejections++;
        }
    }

    /// @notice Time passes, from a second up to five days, so runs cross UTC boundaries and the expiry.
    function warp(uint256 delta) external {
        delta = bound(delta, 1, 5 days);
        vm.warp(block.timestamp + delta);
        vm.roll(block.number + 1);
    }

    /// @notice The principal revokes the mandate with the management key on their ONCHAINID.
    /// @dev Gated to about 1 call in 32. Revocation ends every later agent transfer, so if it fired early in most
    ///      runs, the daily cap and expiry paths would never be exercised.
    function revoke(uint256 seed) external {
        if (seed % 32 != 0) return;
        vm.prank(principal);
        module.revokeMandate(address(compliance), aiAgent);
        if (!revoked) {
            revoked = true;
            revokedAtBlock = block.number;
        }
    }

    /// @notice The investor, who has no mandate, sends to the principal wallet or tops up the agent wallet.
    function investorTransfer(uint256 amount, bool toAgent) external {
        uint256 balance = token.balanceOf(investor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance < 3_000 ether ? balance : 3_000 ether);

        vm.prank(investor);
        // An investor transfer is never expected to fail, but a failure here is not what the invariants test.
        try token.transfer(toAgent ? aiAgent : principal, amount) returns (bool) {} catch {}
    }

    // ------------------------------------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------------------------------------

    function daysTouchedLength() external view returns (uint256) {
        return _daysTouched.length;
    }

    function dayTouchedAt(uint256 i) external view returns (uint256) {
        return _daysTouched[i];
    }

    // ------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------

    function _recordAgentSuccess(uint256 amount) private {
        agentSuccesses++;
        if (revoked) successesAfterRevocation++;
        if (block.timestamp > expiry) successesAfterExpiry++;

        uint256 day = block.timestamp / 1 days;
        sentByDay[day] += amount;
        if (!_dayRecorded[day]) {
            _dayRecorded[day] = true;
            _daysTouched.push(day);
        }
    }
}
