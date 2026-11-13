// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

/// @notice Lets a simulation act AS an address. Simulation only, never deploy it.
///
///         `eth_call` accepts a third argument, a state override, that swaps the code of any address
///         for the length of that one call. Put this code at an address (a token holder, a fresh
///         address standing in for a user) and the orchestrator contract can make that address call
///         anything: `SimExec(holder).exec(token, abi.encodeCall(IERC20.transfer, (to, amount)))`.
///         The target sees `msg.sender == holder`. Nothing is signed and nothing reaches the chain.
///
///         In a forge test the same thing is done with `vm.etch(holder, type(SimExec).runtimeCode)`.
contract SimExec {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
