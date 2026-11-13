// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MockAggregator} from "../src/MockAggregator.sol";
import {FeedReplay} from "./utils/FeedReplay.sol";

/// @notice Replays the recorded Coinbase TSLA rounds (data/tsla_feed_rounds.csv) and shows what the
///         weekend silence does to two things most vaults do with a price feed.
contract FeedReplayTest is Test {
    string constant CSV = "data/tsla_feed_rounds.csv";
    uint256 constant PHASE = 2;

    // Friday 2026-10-30. New York was on daylight time, so the 4 PM close was 20:00 UTC.
    uint256 constant FRIDAY_CLOSE = 1793390400; // 2026-10-30 20:00:00 UTC
    uint256 constant SATURDAY_NOON = 1793448000; // 2026-10-31 12:00:00 UTC
    uint256 constant LAST_ROUND_BEFORE_WEEKEND = 1793387335; // 2026-10-30 19:08:55 UTC
    uint256 constant FIRST_ROUND_AFTER_WEEKEND = 1793581233; // 2026-11-02 01:00:33 UTC

    MockAggregator feed;

    function setUp() public {
        feed = new MockAggregator();
        feed.mockSetMetadata("Coinbase TSLA", 8);
    }

    function test_loadsEveryRecordedRound() public {
        uint256 n = FeedReplay.load(feed, CSV, PHASE, type(uint256).max);
        assertGe(n, 1407); // the file had 1,407 rounds of this phase when it was first recorded
        // First recorded round of the phase, with its real id.
        (uint80 id, int256 answer,, uint256 updatedAt,) = feed.getRoundData(uint80((PHASE << 64) | 1));
        assertEq(id, 36893488147419103233);
        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        // Round 1,407 of the phase: history never changes, so these values are fixed.
        (id, answer,, updatedAt,) = feed.getRoundData(uint80((PHASE << 64) | 1407));
        assertEq(id, 36893488147419104639);
        assertEq(answer, 39045550000); // 390.4555
        assertEq(updatedAt, 1794589009); // 2026-11-13 16:56:49 UTC
        (uint80 latest,,, uint256 latestAt,) = feed.latestRoundData();
        assertGe(latest, id);
        assertGe(latestAt, updatedAt);
        // A round that was never published returns zeros and does not revert, like the live feed.
        (, int256 none,, uint256 noneAt,) = feed.getRoundData(uint80((PHASE << 64) | 9_999_999));
        assertEq(none, 0);
        assertEq(noneAt, 0);
    }

    /// @notice On Saturday noon the newest price is 16.9 hours old, so a 4 hour staleness bound has
    ///         already rejected the feed for most of a day. Any bound under 49 hours was breached on
    ///         every recorded weekend.
    function test_stalenessBoundLocksOutTheWeekend() public {
        FeedReplay.load(feed, CSV, PHASE, SATURDAY_NOON);
        vm.warp(SATURDAY_NOON);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, LAST_ROUND_BEFORE_WEEKEND);
        assertEq(answer, 39945170000); // 399.4517
        uint256 age = block.timestamp - updatedAt;
        assertEq(age, 60665); // 16 h 51 min
        assertGt(age, 4 hours);

        // It stays that way until Sunday 8 PM New York (01:00 UTC on Monday after the clock change).
        // A second feed, loaded right up to one second before the reopen, still ends on Friday's round.
        MockAggregator later = new MockAggregator();
        FeedReplay.load(later, CSV, PHASE, FIRST_ROUND_AFTER_WEEKEND - 1);
        vm.warp(FIRST_ROUND_AFTER_WEEKEND - 1);
        (,,, updatedAt,) = later.latestRoundData();
        assertEq(updatedAt, LAST_ROUND_BEFORE_WEEKEND);
        assertEq(block.timestamp - updatedAt, 193897); // 53.86 hours without a round
    }

    /// @notice A contract that settles on "the first round at or after expiry" with an expiry at the
    ///         Friday close does not get Friday's price. No round followed the close that day, so the
    ///         first round at or after it is the Sunday-night reopen, 53 hours later.
    function test_expiryAtTheFridayCloseSettlesOnTheReopen() public {
        FeedReplay.load(feed, CSV, PHASE, type(uint256).max);
        (uint80 id,,,,) = feed.latestRoundData();
        // Walk back to the first round with updatedAt >= expiry.
        while (true) {
            (,,, uint256 prevAt,) = feed.getRoundData(id - 1);
            if (prevAt < FRIDAY_CLOSE) break;
            id--;
        }
        (, int256 settle,, uint256 settleAt,) = feed.getRoundData(id);
        assertEq(settleAt, FIRST_ROUND_AFTER_WEEKEND);
        assertEq(settle, 40139682163); // 401.39682163
        assertEq(settleAt - FRIDAY_CLOSE, 190833); // 53.01 hours after the expiry

        // The last price before the weekend was published 51 minutes BEFORE the close.
        (, int256 friday,, uint256 fridayAt,) = feed.getRoundData(id - 1);
        assertEq(fridayAt, LAST_ROUND_BEFORE_WEEKEND);
        assertEq(friday, 39945170000);
        assertLt(fridayAt, FRIDAY_CLOSE);
    }

    function test_pushRoundRejectsOldIdsAndOldTimes() public {
        feed.pushRound(10, 100e8, 1000, 1000);
        vm.expectRevert(abi.encodeWithSelector(MockAggregator.RoundNotAfterLatest.selector, uint80(10), uint80(10)));
        feed.pushRound(10, 101e8, 1001, 1001);
        vm.expectRevert(abi.encodeWithSelector(MockAggregator.TimestampBeforeLatest.selector, 999, 1000));
        feed.pushRound(11, 101e8, 999, 999);
        assertEq(feed.push(102e8, 2000), 11);
        (uint80 id, int256 answer,, uint256 at, uint80 answeredIn) = feed.latestRoundData();
        assertEq(id, 11);
        assertEq(answer, 102e8);
        assertEq(at, 2000);
        assertEq(answeredIn, 11);
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "Coinbase TSLA");
        assertEq(feed.version(), 6);
    }

    function test_timestampsMustFitAndLoaderRefusesAnEmptyLoad() public {
        uint256 tooBig = uint256(type(uint64).max) + 1000;
        vm.expectRevert(abi.encodeWithSelector(MockAggregator.TimestampTooLarge.selector, tooBig));
        feed.push(1e8, tooBig);
        vm.expectRevert(abi.encodeWithSelector(MockAggregator.TimestampTooLarge.selector, tooBig));
        feed.pushRound(1, 1e8, tooBig, 5);
        feed.mockSetMetadata("Wide", 255);
        assertEq(feed.decimals(), 255);
    }

    /// @dev External so the revert inside the library call can be expected.
    function loadPhase(uint256 phase) external returns (uint256) {
        return FeedReplay.load(new MockAggregator(), CSV, phase, type(uint256).max);
    }

    function test_loaderRevertsWhenNothingMatches() public {
        vm.expectRevert(bytes("FeedReplay: no rounds loaded (wrong path, phase or cut-off?)"));
        this.loadPhase(77);
    }
}
