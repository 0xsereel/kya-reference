// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {TREXFixture} from "../fixtures/TREXFixture.sol";
import {MandateHandler} from "./MandateHandler.sol";
import {IMandateModule} from "../../src/interfaces/IMandateModule.sol";

/// @notice Properties that must hold across any sequence of agent transfers, time jumps, revocation, and investor
///         transfers. Runs and depth come from foundry.toml (256 runs, depth 64).
contract MandateInvariantsTest is TREXFixture {
    MandateHandler internal handler;
    IMandateModule.Mandate internal mandate;

    function setUp() public override {
        super.setUp();
        mandate = _grantMandate(_defaultMandate());
        _fund(aiAgent, AGENT_BALANCE);

        handler = new MandateHandler(
            token, compliance, module, aiAgent, investor, principal, mandate.dailyCap, mandate.expiry
        );

        // The handler is the only target. Selectors are repeated to weight the mix towards agent transfers and time
        // jumps, so runs reach the daily cap and the expiry before any revocation.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = MandateHandler.agentTransfer.selector;
        selectors[1] = MandateHandler.agentTransfer.selector;
        selectors[2] = MandateHandler.agentTransfer.selector;
        selectors[3] = MandateHandler.warp.selector;
        selectors[4] = MandateHandler.warp.selector;
        selectors[5] = MandateHandler.revoke.selector;
        selectors[6] = MandateHandler.investorTransfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Daily spend never exceeds the cap on any day the agent transferred. The handler counts what actually
    ///      moved, so the check also fails if the module under-records spend.
    function invariant_dailySpendNeverExceedsCap() public view {
        uint256 length = handler.daysTouchedLength();
        for (uint256 i = 0; i < length; i++) {
            uint256 day = handler.dayTouchedAt(i);
            uint256 recorded = module.spent(address(compliance), aiAgent, day);
            assertLe(handler.sentByDay(day), mandate.dailyCap, "day over cap");
            assertEq(recorded, handler.sentByDay(day), "recorded spend differs from what moved");
        }
    }

    /// @dev No agent transfer succeeds once the mandate has been revoked, including in the revocation block.
    function invariant_noAgentTransferAfterRevocation() public view {
        assertEq(handler.successesAfterRevocation(), 0);
    }

    /// @dev No agent transfer succeeds with `block.timestamp > expiry`.
    function invariant_noAgentTransferAfterExpiry() public view {
        assertEq(handler.successesAfterExpiry(), 0);
    }

    /// @dev The module never creates or destroys tokens: all balances sum to total supply.
    function invariant_balancesSumToTotalSupply() public view {
        uint256 sum = token.balanceOf(investor) + token.balanceOf(aiAgent) + token.balanceOf(principal);
        assertEq(sum, token.totalSupply());
    }
}
