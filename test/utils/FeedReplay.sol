// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {MockAggregator} from "../../src/MockAggregator.sol";

/// @notice Loads recorded Chainlink rounds from a CSV written by `scripts/feed_rounds.py` into a
///         `MockAggregator`, with their real round ids, prices and timestamps.
///
///         Needs read access to the file in foundry.toml:
///           fs_permissions = [{ access = "read", path = "./data" }]
library FeedReplay {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @param phase only rows of this phase are loaded (two phases can overlap in time)
    /// @param until only rounds with `updatedAt <= until` are loaded; pass `type(uint256).max` for all
    /// @return loaded number of rounds pushed; the call reverts if that would be zero
    function load(MockAggregator feed, string memory path, uint256 phase, uint256 until)
        internal
        returns (uint256 loaded)
    {
        vm.closeFile(path); // start from the top even if the file was read before
        vm.readLine(path); // header
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) break;
            // round_id,phase,agg_round,answer,price,started_at,updated_at,updated_at_utc,seconds_since_prev
            string[] memory c = vm.split(line, ",");
            if (vm.parseUint(c[1]) != phase) continue;
            uint256 updatedAt = vm.parseUint(c[6]);
            if (updatedAt > until) break;
            feed.pushRound(uint80(vm.parseUint(c[0])), vm.parseInt(c[3]), vm.parseUint(c[5]), updatedAt);
            loaded++;
        }
        vm.closeFile(path);
        require(loaded != 0, "FeedReplay: no rounds loaded (wrong path, phase or cut-off?)");
    }
}
