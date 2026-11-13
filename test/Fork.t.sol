// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test, console2} from "forge-std/Test.sol";
import {MockB20} from "../src/MockB20.sol";
import {MockAggregator} from "../src/MockAggregator.sol";
import {ExampleEscrow} from "../src/example/ExampleEscrow.sol";

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

/// @notice Fork tests against Base mainnet. Off by default so `forge test` needs no network.
///
///           FORK_TESTS=1 forge test --match-contract ForkTest -vv
///           (PowerShell:  $env:FORK_TESTS=1; forge test --match-contract ForkTest -vv)
///           BASE_RPC=<url> picks the node (default https://mainnet.base.org).
contract ForkTest is Test {
    address constant TSLAC = 0xb2000000000000000000001e800a7f5189430cD0;
    IFeed constant TSLA_FEED = IFeed(0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4);

    bool enabled;

    function setUp() public {
        enabled = vm.envOr("FORK_TESTS", false);
        if (!enabled) {
            vm.skip(true); // shows as SKIPPED, not as a pass
            return;
        }
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        assertEq(block.chainid, 8453, "not Base mainnet");
    }

    /// @notice What your Foundry sees at a real tokenized-stock address. On stock Foundry the token
    ///         has one byte of code and no behaviour, so the call fails. On a build that hosts the
    ///         Base precompiles (base-anvil / base-forge) it answers 8. The test passes either way and
    ///         prints which case you are in.
    function test_whatTheRealTokenLooksLikeOnThisFork() public view {
        if (!enabled) return;
        console2.log("code at TSLAc on the fork:");
        console2.logBytes(TSLAC.code);
        assertEq(TSLAC.code, hex"ef", "the marker byte");
        // Capped gas: the marker byte is an invalid opcode, which burns everything it is given.
        (bool ok, bytes memory ret) = TSLAC.staticcall{gas: 200_000}(abi.encodeWithSignature("decimals()"));
        bool runs = ok && ret.length == 32 && abi.decode(ret, (uint256)) == 8;
        console2.log("real precompile executes on this fork:", runs);
        if (!runs) console2.log("=> etch MockB20 at the token address, or use scripts/sim_live.py for the real thing");
    }

    /// @notice The feed is an ordinary contract, so the fork reads the real one.
    function test_theRealFeedReadsFine() public view {
        if (!enabled) return;
        assertEq(TSLA_FEED.decimals(), 8);
        assertEq(TSLA_FEED.description(), "Coinbase TSLA");
        (uint80 id, int256 answer,, uint256 updatedAt,) = TSLA_FEED.latestRoundData();
        assertGt(answer, 0);
        assertLe(updatedAt, block.timestamp);
        console2.log("latest round", uint256(id));
        console2.log("price (8 decimals)", uint256(answer));
        console2.log("age in seconds", block.timestamp - updatedAt);
    }

    /// @notice The usual fork setup: the mock token at the REAL address, the real feed left alone.
    function test_mockTokenAtTheRealAddress() public {
        if (!enabled) return;
        vm.etch(TSLAC, type(MockB20).runtimeCode);
        MockB20 token = MockB20(TSLAC);
        assertEq(token.totalSupply(), 0, "the mock starts empty at the real address");
        assertEq(token.decimals(), 8);

        address alice = makeAddr("alice");
        token.mockMint(alice, 2e8);
        ExampleEscrow escrow = new ExampleEscrow(TSLAC);
        vm.startPrank(alice);
        token.approve(address(escrow), 2e8);
        escrow.deposit(2e8);
        assertEq(token.balanceOf(address(escrow)), 2e8);
        escrow.withdraw(2e8);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2e8);
    }

    /// @notice To drive prices yourself, swap the real feed for the mock, seeded with the feed's
    ///         own last rounds (same ids, prices and times), then push the next round.
    function test_mockFeedAtTheRealAddressSeededWithRealRounds() public {
        if (!enabled) return;
        (uint80 latest, int256 lastAnswer,, uint256 lastAt,) = TSLA_FEED.latestRoundData();
        uint256 n = 5;
        uint80[] memory ids = new uint80[](n);
        int256[] memory answers = new int256[](n);
        uint256[] memory started = new uint256[](n);
        uint256[] memory updated = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            (ids[k], answers[k], started[k], updated[k],) = TSLA_FEED.getRoundData(latest - uint80(n - 1 - k));
        }

        vm.etch(address(TSLA_FEED), type(MockAggregator).runtimeCode);
        MockAggregator feed = MockAggregator(address(TSLA_FEED));
        feed.mockSetMetadata("Coinbase TSLA", 8);
        for (uint256 k = 0; k < n; k++) {
            feed.pushRound(ids[k], answers[k], started[k], updated[k]);
        }

        (uint80 id, int256 answer,, uint256 at,) = TSLA_FEED.latestRoundData();
        assertEq(id, latest);
        assertEq(answer, lastAnswer);
        assertEq(at, lastAt);

        // Your scenario: one day later the stock is up 5%.
        vm.warp(block.timestamp + 1 days);
        uint80 next = feed.push(lastAnswer * 105 / 100, block.timestamp);
        (id, answer,, at,) = TSLA_FEED.latestRoundData();
        assertEq(id, next);
        assertEq(id, latest + 1);
        assertEq(answer, lastAnswer * 105 / 100);
        assertEq(at, block.timestamp);
    }
}
