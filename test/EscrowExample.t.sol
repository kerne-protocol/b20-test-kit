// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MockB20} from "../src/MockB20.sol";
import {SimExec} from "../src/sim/SimExec.sol";
import {EscrowSim} from "../src/example/EscrowSim.sol";
import {ExampleEscrow} from "../src/example/ExampleEscrow.sol";

/// @notice The same orchestrator that `scripts/sim_live.py escrow` runs against the real precompile,
///         run here against the mock. One script, two backends.
contract EscrowExampleTest is Test {
    address constant TSLAC = 0xb2000000000000000000001e800a7f5189430cD0;
    address holder = makeAddr("holder");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.etch(TSLAC, type(MockB20).runtimeCode);
        vm.etch(holder, type(SimExec).runtimeCode);
        vm.etch(alice, type(SimExec).runtimeCode);
        MockB20(TSLAC).mockMint(holder, 10e8);
    }

    function test_escrowRoundTripOnTheMock() public {
        EscrowSim.Out memory o = new EscrowSim().run(TSLAC, holder, alice, 1_000_000);
        assertEq(o.aliceAfterFunding, 1_000_000);
        assertEq(o.escrowAfterDeposit, 1_000_000);
        assertEq(o.depositRecorded, 1_000_000);
        assertTrue(o.secondWithdrawReverted);
        assertEq(o.aliceAfterWithdraw, 1_000_000);
        assertEq(o.escrowAfterWithdraw, 0);
    }

    /// @notice What a policy block does to a contract that holds the token: the deposit is stuck
    ///         until the block is lifted. Worth a test in any vault that takes tokenized stocks.
    function test_blockedEscrowCannotPayOut() public {
        MockB20 token = MockB20(TSLAC);
        ExampleEscrow escrow = new ExampleEscrow(TSLAC);
        vm.prank(holder);
        token.transfer(alice, 5e8);
        vm.startPrank(alice);
        token.approve(address(escrow), 5e8);
        escrow.deposit(5e8);
        vm.stopPrank();

        token.mockSetBlocked(address(escrow), true);
        bytes memory forbidden =
            abi.encodeWithSelector(MockB20.PolicyForbids.selector, token.TRANSFER_EXECUTOR_POLICY(), uint64(0));
        vm.expectRevert(forbidden);
        vm.prank(alice);
        escrow.withdraw(5e8);
        assertEq(token.balanceOf(address(escrow)), 5e8);

        token.mockSetBlocked(address(escrow), false);
        vm.prank(alice);
        escrow.withdraw(5e8);
        assertEq(token.balanceOf(alice), 5e8);
    }
}
