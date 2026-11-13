// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MockB20} from "../src/MockB20.sol";
import {SimExec} from "../src/sim/SimExec.sol";
import {B20Probe} from "../src/sim/B20Probe.sol";

/// @notice Keeps the mock honest. `data/tslac_live_probe.json` holds what the REAL TSLAc precompile
///         answered to the 41 calls of `B20Probe` (recorded by `scripts/sim_live.py probe
///         --write-fixture` in one read-only eth_call). This test runs the same probe, with the same
///         addresses and amount, against `MockB20` and requires the same success flag and the same
///         bytes at every step.
contract ConformanceTest is Test {
    function test_mockMatchesTheLiveTokenStepByStep() public {
        string memory json = vm.readFile("data/tslac_live_probe.json");
        B20Probe.In memory i = B20Probe.In({
            token: vm.parseJsonAddress(json, ".token"),
            holder: vm.parseJsonAddress(json, ".holder"),
            alice: vm.parseJsonAddress(json, ".alice"),
            bob: vm.parseJsonAddress(json, ".bob"),
            carol: vm.parseJsonAddress(json, ".carol"),
            amount: vm.parseUint(vm.parseJsonString(json, ".amount"))
        });

        // The mock goes where the real token lives, and the four actors get executor code.
        vm.etch(i.token, type(MockB20).runtimeCode);
        bytes memory exec = type(SimExec).runtimeCode;
        vm.etch(i.holder, exec);
        vm.etch(i.alice, exec);
        vm.etch(i.bob, exec);
        vm.etch(i.carol, exec);

        // Same decimals and the same total supply as the recording, so every step can match.
        uint256 liveSupply = abi.decode(vm.parseJsonBytes(json, ".steps[1].ret"), (uint256));
        MockB20 mock = MockB20(i.token);
        mock.mockSetMetadata(
            "Tesla Inc.", vm.parseJsonString(json, ".symbol"), uint8(vm.parseJsonUint(json, ".decimals"))
        );
        mock.mockMint(i.holder, i.amount);
        mock.mockMint(address(0xdead), liveSupply - i.amount);

        B20Probe probe = new B20Probe();
        B20Probe.Result[] memory got = probe.run(i);
        assertEq(got.length, probe.STEPS(), "step count");

        for (uint256 n = 0; n < got.length; n++) {
            string memory at = string.concat(".steps[", vm.toString(n), "]");
            string memory label = vm.parseJsonString(json, string.concat(at, ".label"));
            assertEq(got[n].ok, vm.parseJsonBool(json, string.concat(at, ".ok")), string.concat("ok flag: ", label));
            assertEq(got[n].ret, vm.parseJsonBytes(json, string.concat(at, ".ret")), string.concat("bytes: ", label));
        }
    }

    /// @notice The recording itself says the token is a precompile: no bytecode, only a marker.
    function test_recordingShowsAPrecompileMarker() public view {
        string memory json = vm.readFile("data/tslac_live_probe.json");
        assertEq(vm.parseJsonBytes(json, ".eth_getCode"), hex"ef");
        assertEq(vm.parseJsonUint(json, ".chain_id"), 8453);
    }
}
