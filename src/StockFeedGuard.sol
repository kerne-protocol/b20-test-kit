// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

/// @notice The one function this library needs from a Chainlink price feed.
interface IStockFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title  StockFeedGuard
/// @notice "Is this stock feed frozen right now, and when does it resume?" for the regular
///         "Coinbase <TICKER>" Chainlink feeds on Base (the 24/5 ones, not the "(24/7)" variants).
///
///         Those feeds stop printing when the US market is closed and hold the last value, while
///         `latestRoundData()` keeps answering. Base's docs tell integrators never to settle or
///         liquidate against a frozen feed. This library gives a contract two things:
///           1. the schedule: `isOpen`, `nextOpen`, `nextClose`, `lastOpen` (pure functions of a
///              timestamp, so they also work for a future expiry), and
///           2. guarded reads: `read` reverts during a scheduled closure, on a stale round and on a
///              non-positive answer; `readSinceReopen` also reverts until the feed has printed
///              since the last closure ended, and is the one to use if a price from before a
///              closure must never be accepted.
///
///         The schedule, in New York time: a trading day runs from 20:00 the evening before to 20:00
///         on the day; trading days are Monday to Friday minus the full-day holidays of the New York
///         Stock Exchange; an early-close day ends at 17:00. So the feed is expected to be silent from
///         Friday 20:00 to Sunday 20:00, and from 20:00 before a holiday to 20:00 on it.
///
///         What is behind it: 28,887 rounds of the 13 feeds, 2026-08-05 to 2026-11-14. That is 14
///         weekends, one of them the Labor Day long weekend and one the November clock change, seen
///         on 13 feeds that move together. Counted per feed, 181 of 182 closures had no round inside
///         (one round came 5 seconds after a Friday 20:00), and every one ended with a round within
///         99 seconds of the modelled reopen. The data and the scripts are in `data/all_feeds`.
///
/// @dev    INFORMATIONAL. READ THIS BEFORE RELYING ON IT.
///         - A schedule cannot see a trading halt, a corporate-action pause (the feed freezes until
///           Coinbase confirms the new price and multiplier), an unscheduled market closure or a feed
///           outage. `isOpen` can be true while the price is frozen. That is what `maxAge` is for:
///           the feed's heartbeat is 24 hours, so a round older than about 25 hours while the
///           schedule says open means something is wrong.
///         - The holiday table ends on 2028-12-31 (`HOLIDAYS_THROUGH_DAY`). After that only weekends
///           are modelled, so on a 2029 holiday `isOpen` is true and `read` falls back to `maxAge`
///           alone. Nothing reverts for you: check `holidaysKnown(block.timestamp)` if you would
///           rather stop than run on weekends only, and redeploy with a new table before then.
///         - One holiday and one clock change are in the data. A one-day midweek holiday is not:
///           Thanksgiving, 2026-11-26, will be the first.
///         - The early-close rule (17:00 instead of 20:00 on five listed days) comes from the
///           exchange's published hours. It has not been observed on these feeds yet.
///         - Add a check of Base's sequencer uptime feed if your protocol needs one. A sequencer
///           outage also stops rounds, and this library does not look at it.
///         - Timestamps below 1970-01-02 revert (arithmetic underflow). `block.timestamp` never is.
///         - Not audited. MIT licence, no warranty.
library StockFeedGuard {
    /// @notice The schedule says the feed is not printing now. `reopensAt` is the expected reopen.
    error FeedClosed(uint256 reopensAt);
    /// @notice The newest round is older than `maxAge`, or carries a timestamp in the future.
    error FeedStale(uint256 updatedAt, uint256 maxAge);
    /// @notice The newest round was written before the current open window began.
    error FeedNotResumed(uint256 updatedAt, uint256 openedAt);
    /// @notice The newest round's answer is zero or negative.
    error FeedAnswerNotPositive(int256 answer);

    enum Status {
        Ok,
        Closed, // scheduled closure: weekend, holiday, or the tail of an early-close day
        Stale, // the schedule says open, but the newest round is older than maxAge
        BadAnswer // zero or negative answer
    }

    /// @notice Last day (days since 1970-01-01) covered by the holiday table: 2028-12-31.
    uint256 internal constant HOLIDAYS_THROUGH_DAY = 21549;

    // Full-day closures of the New York Stock Exchange, 2026 to 2028, as big-endian uint16 day
    // numbers in ascending order (nyse.com/markets/hours-calendars, read 2026-11-14). Printed by
    // `python scripts/market_calendar.py --table`, which also rebuilds the list from the holiday rules.
    bytes private constant HOLIDAYS =
        hex"4fe64ff8501450425076508f509d50df512f514c51535164518051a751e951fb520c524b529b52b852d052f353285355536a537953b754075427";
    // 13:00 closes; the late session ends at 17:00 New York on these days.
    bytes private constant EARLY_CLOSES = hex"5130514b529c53785408";
    uint256 private constant EARLY_CLOSE_CUT = 3 hours;

    // ------------------------------------------------------------------ guarded reads

    /// @notice The feed's newest price, or a revert if it should not be used right now.
    /// @dev    This does NOT require a round since the last closure. After a ONE-day holiday the
    ///         schedule reopens 24 hours after it closed, so a round written in the last hour before
    ///         the holiday is still under a 25 hour `maxAge` for up to an hour after the reopen, and
    ///         `read` returns it. That price is from before the holiday. If the market has moved
    ///         less than 0.5% since, the feed may not have printed and the price is still close;
    ///         if the feed has simply not resumed, it is not. `read` cannot tell the two apart.
    ///         Use `readSinceReopen` to refuse it in both cases. After a weekend this cannot happen
    ///         with a `maxAge` under 48 hours.
    /// @param feed   a regular "Coinbase <TICKER>" Chainlink proxy on Base
    /// @param maxAge the oldest round you accept, in seconds. The heartbeat is 24 hours, so 25 hours
    ///               accepts every healthy round while the market is open; pick less if your
    ///               protocol needs a fresher price and can wait for one.
    function read(address feed, uint256 maxAge) internal view returns (uint256 price, uint256 updatedAt) {
        if (!isOpen(block.timestamp)) revert FeedClosed(nextOpen(block.timestamp));
        int256 answer;
        (, answer,, updatedAt,) = IStockFeed(feed).latestRoundData();
        if (answer <= 0) revert FeedAnswerNotPositive(answer);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) revert FeedStale(updatedAt, maxAge);
        price = uint256(answer);
    }

    /// @notice Like `read`, and the round must also have been written since the current open window
    ///         began, so a price from before the last closure is never returned. Stricter: after a
    ///         reopen this reverts until the feed's first round (19 to 99 seconds on the 182
    ///         recorded closures, all of them two days or longer; a one-day holiday has not been
    ///         recorded yet and may take longer).
    function readSinceReopen(address feed, uint256 maxAge) internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = read(feed, maxAge);
        uint256 openedAt = lastOpen(block.timestamp);
        if (updatedAt < openedAt) revert FeedNotResumed(updatedAt, openedAt);
    }

    /// @notice The same checks as `read` without reverting, for keepers and views.
    /// @return status    Ok, Closed, Stale or BadAnswer
    /// @return price     the newest answer (0 when it is not positive); set even when status is not Ok
    /// @return updatedAt the newest round's timestamp
    /// @return reopensAt the expected reopen when status is Closed, otherwise 0
    function check(address feed, uint256 maxAge)
        internal
        view
        returns (Status status, uint256 price, uint256 updatedAt, uint256 reopensAt)
    {
        int256 answer;
        (, answer,, updatedAt,) = IStockFeed(feed).latestRoundData();
        price = answer > 0 ? uint256(answer) : 0;
        if (!isOpen(block.timestamp)) return (Status.Closed, price, updatedAt, nextOpen(block.timestamp));
        if (answer <= 0) return (Status.BadAnswer, 0, updatedAt, 0);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) return (Status.Stale, price, updatedAt, 0);
        return (Status.Ok, price, updatedAt, 0);
    }

    // ------------------------------------------------------------------ the schedule

    /// @notice True when the schedule says the feed can print at unix time `ts`.
    function isOpen(uint256 ts) internal pure returns (bool) {
        uint256 day = tradingDay(ts);
        return isTradingDay(day) && ts < _dayEnd(day);
    }

    /// @notice `ts` if the feed is open then, otherwise the next expected reopen.
    function nextOpen(uint256 ts) internal pure returns (uint256) {
        if (isOpen(ts)) return ts;
        uint256 day = tradingDay(ts) + 1;
        while (!isTradingDay(day)) day++; // at most a long weekend: every 7 days hold a weekday that is not a holiday
        return _dayStart(day);
    }

    /// @notice The end of the open window that holds `ts`, or of the next one if `ts` is in a closure.
    function nextClose(uint256 ts) internal pure returns (uint256) {
        uint256 day = tradingDay(nextOpen(ts));
        while (!_isEarlyClose(day) && isTradingDay(day + 1)) day++; // at most Monday to Friday
        return _dayEnd(day);
    }

    /// @notice The start of the open window that holds `ts`, or of the latest one before `ts` if
    ///         `ts` is in a closure.
    function lastOpen(uint256 ts) internal pure returns (uint256) {
        uint256 day = tradingDay(ts);
        while (!isTradingDay(day)) day--;
        while (isTradingDay(day - 1) && !_isEarlyClose(day - 1)) day--; // at most Friday back to Monday
        return _dayStart(day);
    }

    /// @notice True while the holiday table covers `ts`. After 2028-12-31 only weekends are modelled.
    function holidaysKnown(uint256 ts) internal pure returns (bool) {
        return tradingDay(ts) <= HOLIDAYS_THROUGH_DAY;
    }

    /// @notice The trading day (days since 1970-01-01) whose 20:00-to-20:00 New York window holds `ts`.
    function tradingDay(uint256 ts) internal pure returns (uint256 day) {
        day = ts / 1 days;
        if (ts < _dayStart(day)) day--;
    }

    /// @notice Monday to Friday and not a full-day holiday.
    function isTradingDay(uint256 day) internal pure returns (bool) {
        uint256 weekday = (day + 4) % 7; // 0 = Sunday; 1970-01-01 was a Thursday
        return weekday >= 1 && weekday <= 5 && !_listed(HOLIDAYS, day);
    }

    // ------------------------------------------------------------------ internals

    /// @dev 20:00 New York on the evening before `day`, as unix time: 00:00 UTC in daylight time,
    ///      01:00 UTC in standard time.
    function _dayStart(uint256 day) private pure returns (uint256) {
        return day * 1 days + (_isDaylightTime(day) ? 0 : 1 hours);
    }

    function _dayEnd(uint256 day) private pure returns (uint256) {
        return _dayStart(day + 1) - (_isEarlyClose(day) ? EARLY_CLOSE_CUT : 0);
    }

    function _isEarlyClose(uint256 day) private pure returns (bool) {
        return _listed(EARLY_CLOSES, day);
    }

    /// @dev `list` is ascending big-endian uint16 day numbers.
    function _listed(bytes memory list, uint256 day) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i += 2) {
            uint256 d = (uint256(uint8(list[i])) << 8) | uint256(uint8(list[i + 1]));
            if (d == day) return true;
            if (d > day) return false;
        }
        return false;
    }

    /// @dev US daylight time on UTC day `day`: from the second Sunday of March to the first Sunday of
    ///      November. The real switch is at 02:00 local on those Sundays, inside the weekend closure,
    ///      so working in whole UTC days changes no open or close time.
    function _isDaylightTime(uint256 day) private pure returns (bool) {
        uint256 year = _yearOf(day);
        uint256 march1 = _dayOf(year, 3);
        uint256 nov1 = _dayOf(year, 11);
        uint256 start = march1 + ((7 - (march1 + 4) % 7) % 7) + 7;
        uint256 end = nov1 + ((7 - (nov1 + 4) % 7) % 7);
        return day >= start && day < end;
    }

    /// @dev Civil year of a day number (Howard Hinnant's civil_from_days).
    function _yearOf(uint256 day) private pure returns (uint256 year) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        year = yoe + era * 400;
        if ((5 * doy + 2) / 153 >= 10) year++; // January and February belong to the next civil year
    }

    /// @dev Day number of the first day of `month` (3 to 12) in `year` (days_from_civil).
    function _dayOf(uint256 year, uint256 month) private pure returns (uint256) {
        uint256 era = year / 400;
        uint256 yoe = year - era * 400;
        uint256 doy = (153 * (month - 3) + 2) / 5;
        return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
    }
}
