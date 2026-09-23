// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {TREXFixture} from "../fixtures/TREXFixture.sol";
import {IMandateModule} from "../../src/interfaces/IMandateModule.sol";

/// @notice Fuzzes the three limits a mandate enforces: per-transfer, daily cap, and expiry.
/// @dev Runs per profile: 1,024 fuzz runs by default, 10,000 under `FOUNDRY_PROFILE=ci` (see foundry.toml).
contract MandateLimitsFuzzTest is TREXFixture {
    uint256 internal constant MAX_SEQUENCE = 20;

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    /// @dev Grants a mandate with the given limits and funds the agent wallet.
    function _grantWith(uint256 maxPerTransfer, uint256 dailyCap, uint256 expiry) internal {
        IMandateModule.Mandate memory m = _defaultMandate();
        m.maxPerTransfer = maxPerTransfer;
        m.dailyCap = dailyCap;
        m.expiry = expiry;
        _grantMandate(m);
        _fund(aiAgent, AGENT_BALANCE);
    }

    function _spent() internal view returns (uint256) {
        return module.spent(address(compliance), aiAgent, block.timestamp / 1 days);
    }

    /// @dev Attempts an agent transfer to the investor and reports whether it went through.
    ///      Also checks that the preflight prediction agrees with the outcome.
    function _attempt(uint256 amount) internal returns (bool ok) {
        bool predicted = compliance.canTransfer(aiAgent, investor, amount);
        vm.prank(aiAgent);
        try token.transfer(investor, amount) returns (bool result) {
            ok = result;
        } catch {
            ok = false;
        }
        assertEq(predicted, ok, "preflight disagrees with outcome");
    }

    // ------------------------------------------------------------------------------------------------
    // Fuzz tests
    // ------------------------------------------------------------------------------------------------

    /// @dev A single transfer succeeds if and only if it is within both the per-transfer limit and the daily cap.
    function testFuzz_singleTransfer(uint256 maxPerTransfer, uint256 dailyCap, uint256 value) public {
        maxPerTransfer = bound(maxPerTransfer, 1, AGENT_BALANCE);
        dailyCap = bound(dailyCap, 1, AGENT_BALANCE);
        value = bound(value, 1, AGENT_BALANCE);
        _grantWith(maxPerTransfer, dailyCap, block.timestamp + 30 days);

        uint256 agentBefore = token.balanceOf(aiAgent);
        uint256 investorBefore = token.balanceOf(investor);

        bool ok = _attempt(value);

        assertEq(ok, value <= maxPerTransfer && value <= dailyCap);
        if (ok) {
            assertEq(token.balanceOf(aiAgent), agentBefore - value);
            assertEq(token.balanceOf(investor), investorBefore + value);
            assertEq(_spent(), value);
        } else {
            assertEq(token.balanceOf(aiAgent), agentBefore);
            assertEq(token.balanceOf(investor), investorBefore);
            assertEq(_spent(), 0);
        }
    }

    /// @dev Over a sequence of transfers in one UTC day, the cumulative amount never exceeds the daily cap, and each
    ///      rejection happens exactly when the transfer would have crossed a limit.
    function testFuzz_sequence(uint256 maxPerTransfer, uint256 dailyCap, uint256[] memory amounts) public {
        maxPerTransfer = bound(maxPerTransfer, 1, 2_000 ether);
        dailyCap = bound(dailyCap, 1, 5_000 ether);
        _grantWith(maxPerTransfer, dailyCap, block.timestamp + 30 days);

        uint256 count = amounts.length > MAX_SEQUENCE ? MAX_SEQUENCE : amounts.length;
        uint256 cumulative;

        for (uint256 i = 0; i < count; i++) {
            uint256 amount = bound(amounts[i], 1, 3_000 ether);
            bool wouldPass = amount <= maxPerTransfer && cumulative + amount <= dailyCap;

            bool ok = _attempt(amount);

            assertEq(ok, wouldPass, "rejected or accepted at the wrong point");
            if (ok) cumulative += amount;
            assertLe(cumulative, dailyCap, "cumulative spend passed the cap");
            assertEq(_spent(), cumulative, "recorded spend drifted");
        }
    }

    /// @dev Success flips to failure exactly at `expiry + 1`: valid through `expiry`, blocked after.
    function testFuzz_expiry(uint256 expiryOffset, uint256 probeOffset) public {
        uint256 expiry = START_TIME + bound(expiryOffset, 0, 60 days);
        _grantWith(1_000 ether, 2_500 ether, expiry);

        // The boundary itself, for every fuzzed expiry.
        vm.warp(expiry);
        assertTrue(_attempt(1 ether), "should pass at expiry");
        vm.warp(expiry + 1);
        assertFalse(_attempt(1 ether), "should fail at expiry + 1");

        // An arbitrary point in time.
        uint256 probe = START_TIME + bound(probeOffset, 0, 61 days);
        vm.warp(probe);
        assertEq(_attempt(1 ether), probe <= expiry);
    }
}
