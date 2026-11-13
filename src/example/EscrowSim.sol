// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {SimExec} from "../sim/SimExec.sol";
import {ExampleEscrow, IERC20Min} from "./ExampleEscrow.sol";

interface IERC20Approve {
    function approve(address, uint256) external returns (bool);
}

/// @notice Example orchestrator: the pattern to copy for your own contract.
///
///         It runs the same way in two places:
///           - `scripts/sim_live.py escrow` places this code at an unused address with a state
///             override and calls `run` once. The token is the REAL precompile on a live node.
///           - `test/EscrowExample.t.sol` deploys it in a forge test against `MockB20`.
///
///         Two things worth copying:
///           1. The contract under test is created with `new` INSIDE the call, so its constructor
///              runs and its immutables are set. Code placed by a state override gets neither.
///           2. `SimExec` at `holder` and `alice` lets the script act as those addresses in turn.
contract EscrowSim {
    struct Out {
        address escrow;
        uint256 aliceAfterFunding;
        uint256 escrowAfterDeposit;
        uint256 depositRecorded;
        bool secondWithdrawReverted;
        uint256 aliceAfterWithdraw;
        uint256 escrowAfterWithdraw;
    }

    /// @param holder any address that owns `amount` of the token; it funds alice inside the call
    /// @param alice  an address with a zero balance that plays the user
    function run(address token, address holder, address alice, uint256 amount) external returns (Out memory o) {
        IERC20Min t = IERC20Min(token);
        ExampleEscrow escrow = new ExampleEscrow(token);
        o.escrow = address(escrow);

        SimExec(holder).exec(token, abi.encodeCall(t.transfer, (alice, amount)));
        o.aliceAfterFunding = t.balanceOf(alice);

        SimExec(alice).exec(token, abi.encodeCall(IERC20Approve.approve, (address(escrow), amount)));
        SimExec(alice).exec(address(escrow), abi.encodeCall(escrow.deposit, (amount)));
        o.escrowAfterDeposit = t.balanceOf(address(escrow));
        o.depositRecorded = escrow.deposited(alice);

        SimExec(alice).exec(address(escrow), abi.encodeCall(escrow.withdraw, (amount)));
        try SimExec(alice).exec(address(escrow), abi.encodeCall(escrow.withdraw, (1))) {
            o.secondWithdrawReverted = false;
        } catch {
            o.secondWithdrawReverted = true;
        }
        o.aliceAfterWithdraw = t.balanceOf(alice);
        o.escrowAfterWithdraw = t.balanceOf(address(escrow));
    }
}
