// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {TREXFixture} from "../fixtures/TREXFixture.sol";

/// @notice Shared setup and measurement for the gas tests below.
/// @dev Each scenario is its own test so every measurement starts with cold storage, as a real transaction would.
///      The "no module" runs remove the module from the compliance contract first, so the only difference between a
///      pair is the module: `moduleCheck` and `moduleTransferAction` plus their dispatch through `ModularCompliance`.
abstract contract ModuleGasBase is TREXFixture {
    uint256 internal constant AMOUNT = 100 ether;

    function setUp() public virtual override {
        super.setUp();
        _grantMandate(_defaultMandate());
        _fund(aiAgent, AGENT_BALANCE);
    }

    function _removeModule() internal {
        vm.prank(issuer);
        compliance.removeModule(address(module));
    }

    function _transferGas(address from, address to) internal returns (uint256 used) {
        vm.prank(from);
        uint256 before = gasleft();
        token.transfer(to, AMOUNT);
        used = before - gasleft();
    }
}

/// @notice Run with `forge test --match-path test/integration/ModuleGas.t.sol -vv` to print the numbers reported in
///         the README. Subtract a "no module" run from its "module bound" pair to get what the module adds.
contract ModuleGasTest is ModuleGasBase {
    function test_gas_agentTransfer_firstOfDay_withModule() public {
        emit log_named_uint("agent transfer, first of the day, module bound", _transferGas(aiAgent, investor));
    }

    function test_gas_agentTransfer_withoutModule() public {
        _removeModule();
        emit log_named_uint("agent transfer, no module", _transferGas(aiAgent, investor));
    }

    function test_gas_investorTransfer_withModule() public {
        emit log_named_uint("investor transfer, module bound", _transferGas(investor, principal));
    }

    function test_gas_investorTransfer_withoutModule() public {
        _removeModule();
        emit log_named_uint("investor transfer, no module", _transferGas(investor, principal));
    }
}

/// @notice The agent already sent once today (in `setUp`, a separate transaction), so the day's spend slot is
///         already non-zero. Compare with `ModuleGasTest.test_gas_agentTransfer_withoutModule`.
contract ModuleGasLaterInDayTest is ModuleGasBase {
    function setUp() public override {
        super.setUp();
        _transferGas(aiAgent, investor);
    }

    function test_gas_agentTransfer_laterInDay_withModule() public {
        emit log_named_uint("agent transfer, later the same day, module bound", _transferGas(aiAgent, investor));
    }
}
