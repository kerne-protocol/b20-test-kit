// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MockAggregator} from "../src/MockAggregator.sol";
import {StockFeedGuard} from "../src/StockFeedGuard.sol";
import {FeedReplay} from "./utils/FeedReplay.sol";

/// @dev The library's functions are internal, so the tests call them through this contract.
contract GuardHarness {
    function read(address feed, uint256 maxAge) external view returns (uint256, uint256) {
        return StockFeedGuard.read(feed, maxAge);
    }

    function readSinceReopen(address feed, uint256 maxAge) external view returns (uint256, uint256) {
        return StockFeedGuard.readSinceReopen(feed, maxAge);
    }

    function check(address feed, uint256 maxAge) external view returns (StockFeedGuard.Status, uint256, uint256, uint256) {
        return StockFeedGuard.check(feed, maxAge);
    }

    function isOpen(uint256 ts) external pure returns (bool) {
        return StockFeedGuard.isOpen(ts);
    }

    function nextOpen(uint256 ts) external pure returns (uint256) {
        return StockFeedGuard.nextOpen(ts);
    }

    function nextClose(uint256 ts) external pure returns (uint256) {
        return StockFeedGuard.nextClose(ts);
    }

    function lastOpen(uint256 ts) external pure returns (uint256) {
        return StockFeedGuard.lastOpen(ts);
    }

    function holidaysKnown(uint256 ts) external pure returns (bool) {
        return StockFeedGuard.holidaysKnown(ts);
    }
}

contract StockFeedGuardTest is Test {
    GuardHarness g;
    MockAggregator feed;

    uint256 constant MAX_AGE = 25 hours;

    // Weekend of 2026-10-30, the one where New York went back to standard time (Coinbase TSLA feed).
    uint256 constant LAST_ROUND_BEFORE_WEEKEND = 1793387335; // Fri 2026-10-30 19:08:55 UTC
    uint256 constant FRIDAY_8PM_NEW_YORK = 1793404800; // Sat 2026-10-31 00:00:00 UTC (daylight time)
    uint256 constant SATURDAY_NOON = 1793448000; // Sat 2026-10-31 12:00:00 UTC
    uint256 constant SUNDAY_8PM_NEW_YORK = 1793581200; // Mon 2026-11-02 01:00:00 UTC (standard time)
    uint256 constant FIRST_ROUND_AFTER_WEEKEND = 1793581233; // Mon 2026-11-02 01:00:33 UTC

    function setUp() public {
        g = new GuardHarness();
        feed = new MockAggregator();
        feed.mockSetMetadata("Coinbase TSLA", 8);
    }

    // ------------------------------------------------------------------ the schedule

    /// @notice Every vector written by `python scripts/market_calendar.py --vectors`: each modelled
    ///         close and reopen from 2026 to mid 2029, plus 2,500 pseudo-random instants.
    function test_scheduleMatchesThePythonModel() public {
        string memory path = "data/calendar_vectors.csv";
        vm.closeFile(path);
        vm.readLine(path); // header
        uint256 n;
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) break;
            // ts,is_open,next_open,next_close,last_open,holidays_known
            string[] memory c = vm.split(line, ",");
            uint256 ts = vm.parseUint(c[0]);
            assertEq(g.isOpen(ts), vm.parseUint(c[1]) == 1, line);
            assertEq(g.nextOpen(ts), vm.parseUint(c[2]), line);
            assertEq(g.nextClose(ts), vm.parseUint(c[3]), line);
            assertEq(g.lastOpen(ts), vm.parseUint(c[4]), line);
            assertEq(g.holidaysKnown(ts), vm.parseUint(c[5]) == 1, line);
            n++;
        }
        vm.closeFile(path);
        assertGe(n, 3000);
    }

    function test_weekendAcrossTheClockChange() public view {
        assertTrue(g.isOpen(FRIDAY_8PM_NEW_YORK - 1));
        assertFalse(g.isOpen(FRIDAY_8PM_NEW_YORK));
        assertFalse(g.isOpen(SATURDAY_NOON));
        assertFalse(g.isOpen(SUNDAY_8PM_NEW_YORK - 1)); // 00:59:59 UTC: an hour later than the week before
        assertTrue(g.isOpen(SUNDAY_8PM_NEW_YORK));
        assertEq(g.nextOpen(SATURDAY_NOON), SUNDAY_8PM_NEW_YORK);
        assertEq(g.nextClose(SATURDAY_NOON), SUNDAY_8PM_NEW_YORK + 5 days);
        assertEq(g.lastOpen(SATURDAY_NOON), FRIDAY_8PM_NEW_YORK - 5 days);
    }

    /// @notice Thanksgiving 2026: closed from Wednesday 20:00 to Thursday 20:00 New York, then the
    ///         day after ends at 17:00 (early close) and the weekend follows.
    function test_thanksgiving2026() public view {
        uint256 wed8pm = 1795654800; // Thu 2026-11-26 01:00:00 UTC
        uint256 thu8pm = 1795741200; // Fri 2026-11-27 01:00:00 UTC
        uint256 fri5pm = 1795816800; // Fri 2026-11-27 22:00:00 UTC
        uint256 sun8pm = 1796000400; // Mon 2026-11-30 01:00:00 UTC
        assertTrue(g.isOpen(wed8pm - 1));
        assertFalse(g.isOpen(wed8pm));
        assertFalse(g.isOpen(wed8pm + 15 hours)); // Thursday 11:00 New York, a weekday
        assertEq(g.nextOpen(wed8pm + 15 hours), thu8pm);
        assertTrue(g.isOpen(thu8pm));
        assertEq(g.nextClose(thu8pm), fri5pm);
        assertTrue(g.isOpen(fri5pm - 1));
        assertFalse(g.isOpen(fri5pm));
        assertEq(g.nextOpen(fri5pm), sun8pm);
        assertEq(g.lastOpen(fri5pm + 1 hours), thu8pm);
    }

    /// @notice Christmas 2026 is a Friday: Thursday ends at 17:00 and the feed stays shut until Sunday 20:00.
    function test_christmas2026() public view {
        uint256 thu5pm = 1798149600; // Thu 2026-12-24 22:00:00 UTC
        uint256 sun8pm = 1798419600; // Mon 2026-12-28 01:00:00 UTC
        assertTrue(g.isOpen(thu5pm - 1));
        assertFalse(g.isOpen(thu5pm));
        assertFalse(g.isOpen(1798214400)); // Fri 2026-12-25 16:00:00 UTC
        assertEq(g.nextOpen(thu5pm), sun8pm);
    }

    function test_holidayTableEnds() public view {
        assertTrue(g.holidaysKnown(1861919999)); // Sun 2028-12-31 23:59:59 UTC
        assertFalse(g.holidaysKnown(1861923600)); // Mon 2029-01-01 01:00:00 UTC
        // New Year's Day 2029 is a Monday and a market holiday, but it is past the table: weekends only.
        assertTrue(g.isOpen(1861970400)); // Mon 2029-01-01 14:00:00 UTC
        assertFalse(g.isOpen(1861840800)); // Sat 2028-12-30 12:00:00 UTC is still a weekend
    }

    function testFuzz_scheduleInvariants(uint256 ts) public view {
        ts = bound(ts, 1767225600, 2082758400); // 2026-01-01 to 2036-01-01
        uint256 open = g.nextOpen(ts);
        uint256 close = g.nextClose(ts);
        uint256 started = g.lastOpen(ts);
        assertGe(open, ts);
        assertTrue(g.isOpen(open));
        assertGt(close, open);
        assertFalse(g.isOpen(close));
        assertTrue(g.isOpen(close - 1));
        assertLe(started, ts);
        assertTrue(g.isOpen(started));
        assertFalse(g.isOpen(started - 1));
        if (g.isOpen(ts)) {
            assertEq(open, ts);
            assertLe(close - started, 5 days); // an open window is never longer than Sunday evening to Friday evening
        } else {
            assertFalse(g.isOpen(open - 1));
            assertLe(open - ts, 5 days); // the longest closure in the table is a 4-day weekend
        }
    }

    // ------------------------------------------------------------------ against the recorded rounds

    /// @notice Every recorded round of the Coinbase TSLA feed was written while the schedule says open.
    function test_everyRecordedTslaRoundIsInsideAnOpenWindow() public {
        (uint256 rounds, uint256 inside) = _roundsInsideClosures("data/all_feeds/tsla_feed_rounds.csv", 2);
        assertGe(rounds, 1410);
        assertEq(inside, 0);
    }

    /// @notice The Coinbase COIN feed has the one exception in the whole data set: a round stamped
    ///         5 seconds after Friday 20:00 New York on 2026-08-21.
    function test_coinFeedHasTheOneRoundInsideAClosure() public {
        (uint256 rounds, uint256 inside) = _roundsInsideClosures("data/all_feeds/coin_feed_rounds.csv", 2);
        assertGe(rounds, 3081);
        assertEq(inside, 1);
        assertFalse(g.isOpen(1787356805)); // Sat 2026-08-22 00:00:05 UTC
        assertTrue(g.isOpen(1787356799));
    }

    function _roundsInsideClosures(string memory path, uint256 phase) internal returns (uint256 rounds, uint256 inside) {
        vm.closeFile(path);
        vm.readLine(path);
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) break;
            string[] memory c = vm.split(line, ",");
            if (vm.parseUint(c[1]) != phase) continue;
            rounds++;
            if (!g.isOpen(vm.parseUint(c[6]))) inside++;
        }
        vm.closeFile(path);
    }

    // ------------------------------------------------------------------ the guarded read

    function test_readRevertsOverTheWeekendAndNamesTheReopen() public {
        FeedReplay.load(feed, "data/tsla_feed_rounds.csv", 2, SATURDAY_NOON);
        vm.warp(SATURDAY_NOON);
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedClosed.selector, SUNDAY_8PM_NEW_YORK));
        g.read(address(feed), MAX_AGE);

        (StockFeedGuard.Status status, uint256 price, uint256 updatedAt, uint256 reopensAt) = g.check(address(feed), MAX_AGE);
        assertEq(uint256(status), uint256(StockFeedGuard.Status.Closed));
        assertEq(price, 39945170000); // the held value, 399.4517
        assertEq(updatedAt, LAST_ROUND_BEFORE_WEEKEND);
        assertEq(reopensAt, SUNDAY_8PM_NEW_YORK);
    }

    /// @notice For 33 seconds after the reopen the newest round is still Friday's. `read` rejects it
    ///         as stale; once Monday's first round lands, both reads return it.
    function test_readAfterTheReopen() public {
        FeedReplay.load(feed, "data/tsla_feed_rounds.csv", 2, SUNDAY_8PM_NEW_YORK + 10);
        vm.warp(SUNDAY_8PM_NEW_YORK + 10);
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedStale.selector, LAST_ROUND_BEFORE_WEEKEND, MAX_AGE));
        g.read(address(feed), MAX_AGE);
        // A consumer with a very long bound would get Friday's price from `read` ...
        (uint256 held,) = g.read(address(feed), 7 days);
        assertEq(held, 39945170000);
        // ... and `readSinceReopen` is the variant that refuses it.
        vm.expectRevert(
            abi.encodeWithSelector(StockFeedGuard.FeedNotResumed.selector, LAST_ROUND_BEFORE_WEEKEND, SUNDAY_8PM_NEW_YORK)
        );
        g.readSinceReopen(address(feed), 7 days);

        feed.push(40139682163, FIRST_ROUND_AFTER_WEEKEND); // Monday's first recorded round
        vm.warp(FIRST_ROUND_AFTER_WEEKEND);
        (uint256 price, uint256 updatedAt) = g.read(address(feed), MAX_AGE);
        assertEq(price, 40139682163); // 401.39682163
        assertEq(updatedAt, FIRST_ROUND_AFTER_WEEKEND);
        (price, updatedAt) = g.readSinceReopen(address(feed), MAX_AGE);
        assertEq(updatedAt, FIRST_ROUND_AFTER_WEEKEND);
    }

    /// @notice The schedule cannot see a pause. A feed that stops in the middle of a session is
    ///         caught by `maxAge`, and only by `maxAge`.
    function test_aFreezeInsideASessionIsCaughtByMaxAgeOnly() public {
        uint256 wednesday = 1794411000; // Wed 2026-11-11 15:30:00 UTC, the market is open
        feed.push(39000000000, wednesday);
        vm.warp(wednesday + 20 hours);
        assertTrue(g.isOpen(block.timestamp));
        (uint256 price,) = g.read(address(feed), MAX_AGE); // inside the 24 h heartbeat: accepted
        assertEq(price, 39000000000);
        vm.warp(wednesday + 26 hours);
        assertTrue(g.isOpen(block.timestamp)); // the schedule still says open
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedStale.selector, wednesday, MAX_AGE));
        g.read(address(feed), MAX_AGE);
        (StockFeedGuard.Status status,,,) = g.check(address(feed), MAX_AGE);
        assertEq(uint256(status), uint256(StockFeedGuard.Status.Stale));
    }

    /// @notice The one case where the two reads differ with a 25 hour bound: a ONE-day holiday.
    ///         A round written 2 minutes before the Thanksgiving closure is 24 h 3 min old three
    ///         minutes after the reopen. `read` returns it; `readSinceReopen` refuses it.
    function test_afterAOneDayHolidayOnlyReadSinceReopenRefusesThePreHolidayPrice() public {
        uint256 wed8pm = 1795654800; // Thu 2026-11-26 01:00:00 UTC, the closure starts
        uint256 thu8pm = 1795741200; // Fri 2026-11-27 01:00:00 UTC, the schedule reopens
        feed.push(39000000000, wed8pm - 2 minutes);
        vm.warp(thu8pm - 1);
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedClosed.selector, thu8pm));
        g.read(address(feed), MAX_AGE);

        vm.warp(thu8pm + 3 minutes);
        (uint256 price, uint256 updatedAt) = g.read(address(feed), MAX_AGE);
        assertEq(price, 39000000000); // Wednesday's price, 24 h 5 min old, accepted
        assertEq(updatedAt, wed8pm - 2 minutes);
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedNotResumed.selector, wed8pm - 2 minutes, thu8pm));
        g.readSinceReopen(address(feed), MAX_AGE);

        feed.push(39200000000, thu8pm + 4 minutes); // the feed prints
        vm.warp(thu8pm + 5 minutes);
        (price,) = g.readSinceReopen(address(feed), MAX_AGE);
        assertEq(price, 39200000000);
    }

    function test_readRejectsANonPositiveAnswerAndAFutureTimestamp() public {
        uint256 wednesday = 1794411000;
        vm.warp(wednesday);
        feed.push(0, wednesday);
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedAnswerNotPositive.selector, int256(0)));
        g.read(address(feed), MAX_AGE);
        (StockFeedGuard.Status status,,,) = g.check(address(feed), MAX_AGE);
        assertEq(uint256(status), uint256(StockFeedGuard.Status.BadAnswer));

        feed.push(39000000000, wednesday + 60);
        vm.expectRevert(abi.encodeWithSelector(StockFeedGuard.FeedStale.selector, wednesday + 60, MAX_AGE));
        g.read(address(feed), MAX_AGE);
    }
}
