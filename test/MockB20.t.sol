// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MockB20} from "../src/MockB20.sol";

/// @notice Unit tests of the mock itself. The comparison with the real token is in Conformance.t.sol.
contract MockB20Test is Test {
    // The real TSLAc address on Base. The mock is etched there, as you would on a fork.
    address constant TSLAC = 0xb2000000000000000000001e800a7f5189430cD0;
    MockB20 token = MockB20(TSLAC);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.etch(TSLAC, type(MockB20).runtimeCode);
        token.mockMint(alice, 5e8);
    }

    /// @notice The address already has data in its low storage slots, as a real contract would.
    ///         The mock keeps its state in a namespaced slot, so it must not read any of it.
    function test_startsEmptyWhereEtched() public {
        address other = address(0xB20B20);
        for (uint256 slot = 0; slot < 12; slot++) {
            vm.store(other, bytes32(slot), bytes32(uint256(0xdeadbeefdeadbeefdeadbeef) + slot));
        }
        vm.etch(other, type(MockB20).runtimeCode);
        MockB20 t = MockB20(other);
        assertEq(t.balanceOf(alice), 0);
        assertEq(t.allowance(alice, bob), 0);
        assertFalse(t.mockIsBlocked(alice));
        assertEq(t.policyId(bytes32(0)), 0);
        assertEq(t.totalSupply(), 0);
        assertEq(t.decimals(), 8);
        assertEq(t.name(), "Mock B20");
        assertEq(t.symbol(), "mB20");
        assertFalse(t.isPaused(0));
    }

    function test_metadata() public {
        token.mockSetMetadata("Tesla Inc.", "TSLAc", 8);
        assertEq(token.name(), "Tesla Inc.");
        assertEq(token.symbol(), "TSLAc");
        assertEq(token.decimals(), 8);
        token.mockSetMetadata("Six", "SIX", 6);
        assertEq(token.decimals(), 6);
        token.mockSetMetadata("Zero", "ZERO", 0);
        assertEq(token.decimals(), 0);
        token.mockSetMetadata("Wide", "WIDE", 255);
        assertEq(token.decimals(), 255);
    }

    /// @notice Only a simulation can call from the zero address. The real token answers InvalidSender,
    ///         after the receiver check (seen with a plain eth_call on 2026-11-13).
    function test_transferFromTheZeroAddress() public {
        token.mockMint(address(0), 10);
        vm.expectRevert(abi.encodeWithSelector(MockB20.InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(MockB20.InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(bob, 0);
        vm.expectRevert(abi.encodeWithSelector(MockB20.InvalidReceiver.selector, address(0)));
        vm.prank(address(0));
        token.transfer(address(0), 1);
    }

    function test_mintAndBurn() public {
        assertEq(token.totalSupply(), 5e8);
        token.mockBurn(alice, 2e8);
        assertEq(token.balanceOf(alice), 3e8);
        assertEq(token.totalSupply(), 3e8);
        vm.expectRevert(abi.encodeWithSelector(MockB20.InsufficientBalance.selector, alice, 3e8, 4e8));
        token.mockBurn(alice, 4e8);
    }

    function test_transferAndEvents() public {
        vm.expectEmit(true, true, false, true, TSLAC);
        emit MockB20.Transfer(alice, bob, 1e8);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e8));
        assertEq(token.balanceOf(alice), 4e8);
        assertEq(token.balanceOf(bob), 1e8);
        assertEq(token.totalSupply(), 5e8);
    }

    function test_transferFromSpendsAllowance() public {
        vm.expectEmit(true, true, false, true, TSLAC);
        emit MockB20.Approval(alice, bob, 3e8);
        vm.prank(alice);
        token.approve(bob, 3e8);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1e8);
        assertEq(token.allowance(alice, bob), 2e8);
        assertEq(token.balanceOf(carol), 1e8);
    }

    function test_unlimitedAllowanceIsNotSpent() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1e8);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_errorsCarryTheRealSelectors() public pure {
        assertEq(MockB20.InsufficientBalance.selector, bytes4(0xdb42144d));
        assertEq(MockB20.InsufficientAllowance.selector, bytes4(0x192b9e4e));
        assertEq(MockB20.InvalidSender.selector, bytes4(0x4c14f64c));
        assertEq(MockB20.InvalidReceiver.selector, bytes4(0x9cfea583));
        assertEq(MockB20.InvalidSpender.selector, bytes4(0x4e15efda));
        assertEq(MockB20.ContractPaused.selector, bytes4(0xfd8c4245));
        assertEq(MockB20.PolicyForbids.selector, bytes4(0xa43fec12));
    }

    function test_policyScopesMatchTheirNames() public view {
        assertEq(token.TRANSFER_SENDER_POLICY(), keccak256("TRANSFER_SENDER_POLICY"));
        assertEq(token.TRANSFER_RECEIVER_POLICY(), keccak256("TRANSFER_RECEIVER_POLICY"));
        assertEq(token.TRANSFER_EXECUTOR_POLICY(), keccak256("TRANSFER_EXECUTOR_POLICY"));
    }

    function test_blockedSenderReceiverExecutor() public {
        token.mockSetPolicyId(5);
        assertEq(token.policyId(token.TRANSFER_SENDER_POLICY()), 5);
        // Built before any prank: a call to read a constant would use the prank up.
        bytes memory receiverForbidden =
            abi.encodeWithSelector(MockB20.PolicyForbids.selector, token.TRANSFER_RECEIVER_POLICY(), uint64(5));
        bytes memory senderForbidden =
            abi.encodeWithSelector(MockB20.PolicyForbids.selector, token.TRANSFER_SENDER_POLICY(), uint64(5));
        bytes memory executorForbidden =
            abi.encodeWithSelector(MockB20.PolicyForbids.selector, token.TRANSFER_EXECUTOR_POLICY(), uint64(5));

        // receiver
        token.mockSetBlocked(bob, true);
        assertTrue(token.mockIsBlocked(bob));
        vm.expectRevert(receiverForbidden);
        vm.prank(alice);
        token.transfer(bob, 1);
        token.mockSetBlocked(bob, false);

        // sender, by transferFrom: carol executes, alice is the blocked source
        vm.prank(alice);
        token.approve(carol, 10);
        token.mockSetBlocked(alice, true);
        vm.expectRevert(senderForbidden);
        vm.prank(carol);
        token.transferFrom(alice, bob, 1);
        // a holder-initiated transfer is stopped at the executor scope first
        vm.expectRevert(executorForbidden);
        vm.prank(alice);
        token.transfer(bob, 1);
        token.mockSetBlocked(alice, false);

        // executor
        token.mockSetBlocked(carol, true);
        vm.expectRevert(executorForbidden);
        vm.prank(carol);
        token.transferFrom(alice, bob, 1);

        // approve is never policy gated
        vm.prank(carol);
        assertTrue(token.approve(bob, 1));

        // nothing moved
        assertEq(token.balanceOf(alice), 5e8);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @notice Order of checks in transferFrom, from the IB20 natspec: allowance, then policy, then balance.
    function test_transferFromCheckOrder() public {
        bytes memory executorForbidden =
            abi.encodeWithSelector(MockB20.PolicyForbids.selector, token.TRANSFER_EXECUTOR_POLICY(), uint64(0));
        token.mockSetBlocked(carol, true);
        // no allowance and blocked: the allowance error comes first
        vm.expectRevert(abi.encodeWithSelector(MockB20.InsufficientAllowance.selector, carol, 0, 6e8));
        vm.prank(carol);
        token.transferFrom(alice, bob, 6e8);
        // allowance given, blocked and over balance: the policy error comes before the balance error
        vm.prank(alice);
        token.approve(carol, 6e8);
        vm.expectRevert(executorForbidden);
        vm.prank(carol);
        token.transferFrom(alice, bob, 6e8);
        // unblocked: the balance error is last
        token.mockSetBlocked(carol, false);
        vm.expectRevert(abi.encodeWithSelector(MockB20.InsufficientBalance.selector, alice, 5e8, 6e8));
        vm.prank(carol);
        token.transferFrom(alice, bob, 6e8);
        assertEq(token.allowance(alice, carol), 6e8);
    }

    function test_blockedFundsStayPut() public {
        token.mockSetBlocked(alice, true);
        bytes memory forbidden =
            abi.encodeWithSelector(MockB20.PolicyForbids.selector, token.TRANSFER_EXECUTOR_POLICY(), uint64(0));
        vm.expectRevert(forbidden);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 5e8);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_pauseStopsTransfersNotApprovals() public {
        token.mockSetPaused(true);
        assertTrue(token.isPaused(0));
        assertFalse(token.isPaused(1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockB20.ContractPaused.selector, uint8(0)));
        token.transfer(bob, 1);
        vm.prank(alice);
        assertTrue(token.approve(bob, 5));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MockB20.ContractPaused.selector, uint8(0)));
        token.transferFrom(alice, bob, 1);
        token.mockSetPaused(false);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_unknownSelectorRevertsWithTheSelector() public {
        (bool ok, bytes memory ret) = TSLAC.call(hex"deadbeef01");
        assertFalse(ok);
        assertEq(ret, hex"deadbeef");
        (ok, ret) = TSLAC.call(hex"de");
        assertFalse(ok);
        assertEq(ret, hex"00000000");
        (ok, ret) = TSLAC.call("");
        assertFalse(ok);
        assertEq(ret, hex"00000000");
    }

    function testFuzz_transferKeepsSupply(uint256 amount, address to) public {
        vm.assume(to != address(0) && to != TSLAC);
        amount = bound(amount, 0, 5e8);
        uint256 beforeTo = token.balanceOf(to);
        vm.prank(alice);
        token.transfer(to, amount);
        assertEq(token.totalSupply(), 5e8);
        if (to == alice) {
            assertEq(token.balanceOf(alice), 5e8);
        } else {
            assertEq(token.balanceOf(alice), 5e8 - amount);
            assertEq(token.balanceOf(to), beforeTo + amount);
        }
    }
}
