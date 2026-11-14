#!/usr/bin/env python3
"""
When the regular "Coinbase <TICKER>" Chainlink feeds on Base are expected to print, as a small
calendar model. Python 3.9+, standard library only. The same model is in `src/StockFeedGuard.sol`
(for contracts) and behind https://kerne.fi/quotes/api/feed-status (for anything else).

INFORMATIONAL ONLY. The model is a schedule. It cannot see a trading halt, a corporate-action
pause, an unscheduled market closure or a feed outage. Always check `updatedAt` as well.

The model, in New York time:
  - A trading day runs from 20:00 the evening before to 20:00 on the day (overnight, pre-market,
    regular and post-market sessions). The feed can print at any time inside it.
  - Trading days are Monday to Friday, minus the full-day holidays of the New York Stock Exchange.
  - So the weekly closure is Friday 20:00 to Sunday 20:00, and a holiday closes the feed from 20:00
    the evening before to 20:00 on the holiday.
  - On an early-close day (13:00 close) the late session ends at 17:00, so the day ends 3 hours early.

What was measured and what was not is in data/METHOD.md. Short version: every one of the 13 feeds
followed the weekend rule on every recorded weekend, and the one holiday in the data (Labor Day,
2026-09-07) followed the holiday rule. Early closes have not been observed yet; that rule is taken
from the exchange's published hours.

  python scripts/market_calendar.py                  # state now, next close, next open
  python scripts/market_calendar.py 1795726800       # state at a unix time
  python scripts/market_calendar.py --table          # the holiday table as day numbers (for Solidity)
  python scripts/market_calendar.py --selftest       # rebuild the holiday table from the rules and compare
  python scripts/market_calendar.py --vectors        # data/calendar_vectors.csv, checked by the Solidity tests
"""
import datetime as dt
import sys

UTC = dt.timezone.utc
EPOCH_ORDINAL = dt.date(1970, 1, 1).toordinal()

# Full-day closures, New York Stock Exchange, 2026 to 2028 (nyse.com/markets/hours-calendars,
# read 2026-11-14). No New Year's Day closure in 2028: it falls on a Saturday.
HOLIDAYS = {
    "2026-01-01": "New Year's Day", "2026-01-19": "Martin Luther King Jr. Day", "2026-02-16": "Washington's Birthday",
    "2026-04-03": "Good Friday", "2026-05-25": "Memorial Day", "2026-06-19": "Juneteenth",
    "2026-07-03": "Independence Day (observed)", "2026-09-07": "Labor Day", "2026-11-26": "Thanksgiving Day",
    "2026-12-25": "Christmas Day",
    "2027-01-01": "New Year's Day", "2027-01-18": "Martin Luther King Jr. Day", "2027-02-15": "Washington's Birthday",
    "2027-03-26": "Good Friday", "2027-05-31": "Memorial Day", "2027-06-18": "Juneteenth (observed)",
    "2027-07-05": "Independence Day (observed)", "2027-09-06": "Labor Day", "2027-11-25": "Thanksgiving Day",
    "2027-12-24": "Christmas Day (observed)",
    "2028-01-17": "Martin Luther King Jr. Day", "2028-02-21": "Washington's Birthday", "2028-04-14": "Good Friday",
    "2028-05-29": "Memorial Day", "2028-06-19": "Juneteenth", "2028-07-04": "Independence Day",
    "2028-09-04": "Labor Day", "2028-11-23": "Thanksgiving Day", "2028-12-25": "Christmas Day",
}
# 13:00 New York close; the late session ends at 17:00.
EARLY_CLOSES = {
    "2026-11-27": "day after Thanksgiving", "2026-12-24": "Christmas Eve", "2027-11-26": "day after Thanksgiving",
    "2028-07-03": "day before Independence Day", "2028-11-24": "day after Thanksgiving",
}
CALENDAR_FIRST = "2026-01-01"
CALENDAR_LAST = "2028-12-31"  # after this day only weekends are modelled

EARLY_CLOSE_CUT = 3 * 3600  # an early-close day ends at 17:00 New York, not 20:00


def day_number(iso):
    """Days since 1970-01-01 for an ISO date."""
    return dt.date.fromisoformat(iso).toordinal() - EPOCH_ORDINAL


def iso_day(day):
    return dt.date.fromordinal(day + EPOCH_ORDINAL).isoformat()


HOLIDAY_DAYS = {day_number(k): v for k, v in HOLIDAYS.items()}
EARLY_CLOSE_DAYS = {day_number(k): v for k, v in EARLY_CLOSES.items()}
CALENDAR_LAST_DAY = day_number(CALENDAR_LAST)


def weekday(day):
    """0 = Sunday ... 6 = Saturday. 1970-01-01 was a Thursday."""
    return (day + 4) % 7


def _nth_sunday(year, month, n):
    first = dt.date(year, month, 1).toordinal() - EPOCH_ORDINAL
    return first + (7 - weekday(first)) % 7 + 7 * (n - 1)


def is_dst(day):
    """US daylight time on UTC day `day`: from the 2nd Sunday of March to the 1st Sunday of November.
    The real switch is at 02:00 local on those Sundays, inside the weekend closure, so using whole
    UTC days changes no open or close time."""
    year = dt.date.fromordinal(day + EPOCH_ORDINAL).year
    return _nth_sunday(year, 3, 2) <= day < _nth_sunday(year, 11, 1)


def day_start(day):
    """Unix time at which trading day `day` starts: 20:00 New York on the evening before."""
    return day * 86400 + (0 if is_dst(day) else 3600)


def trading_day(t):
    """The day whose 20:00-to-20:00 New York window holds unix time t."""
    u = t // 86400
    return u if t >= day_start(u) else u - 1


def is_trading_day(day):
    return 1 <= weekday(day) <= 5 and day not in HOLIDAY_DAYS


def day_end(day):
    return day_start(day + 1) - (EARLY_CLOSE_CUT if day in EARLY_CLOSE_DAYS else 0)


def is_open(t):
    d = trading_day(t)
    return is_trading_day(d) and t < day_end(d)


def next_open(t):
    """t if the feed is expected to be printing at t, else the next expected reopen."""
    if is_open(t):
        return t
    d = trading_day(t) + 1
    while not is_trading_day(d):
        d += 1
    return day_start(d)


def next_close(t):
    """The end of the open window that holds t, or of the next one if t is in a closure."""
    d = trading_day(next_open(t))
    while True:
        if d in EARLY_CLOSE_DAYS or not is_trading_day(d + 1):
            return day_end(d)
        d += 1


def last_open(t):
    """The start of the open window that holds t, or of the latest one before t if t is in a closure."""
    d = trading_day(t)
    while not is_trading_day(d):
        d -= 1
    while is_trading_day(d - 1) and (d - 1) not in EARLY_CLOSE_DAYS:
        d -= 1
    return day_start(d)


def closed_reason(t):
    """None when open, else 'weekend', 'holiday: <name>' or 'early close: <name>'."""
    if is_open(t):
        return None
    d = trading_day(t)
    if d in HOLIDAY_DAYS:
        return "holiday: " + HOLIDAY_DAYS[d]
    if is_trading_day(d):
        return "early close: " + EARLY_CLOSE_DAYS[d]
    return "weekend"


def closures(t0, t1):
    """Every scheduled closure [close, reopen) that starts in [t0, t1), in order, with what causes it."""
    out = []
    t = t0 if is_open(t0) else next_open(t0)
    while True:
        close = next_close(t)
        if close >= t1:
            return out
        reopen = next_open(close)
        days = range(trading_day(close), trading_day(reopen))
        names = [HOLIDAY_DAYS[d] for d in days if d in HOLIDAY_DAYS]
        early = EARLY_CLOSE_DAYS.get(trading_day(close - 1))
        kind = "weekend" if any(weekday(d) in (0, 6) for d in days) else "holiday"
        if names and kind == "weekend":
            kind = "weekend+holiday"
        out.append({"close": close, "reopen": reopen, "kind": kind, "holidays": names, "early_close": early})
        t = reopen


def covered(t):
    """True while the holiday table reaches t. After it, holidays are not modelled."""
    return day_number(CALENDAR_FIRST) <= trading_day(t) <= CALENDAR_LAST_DAY


def fmt(t):
    return dt.datetime.fromtimestamp(t, UTC).strftime("%a %Y-%m-%d %H:%M:%S UTC")


# ---------------------------------------------------------------- self test: the table from the rules
def _easter(year):
    """Gregorian Easter Sunday (anonymous algorithm)."""
    a, b, c = year % 19, year // 100, year % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    m = (32 + 2 * e + 2 * i - h - k) % 7
    n = (a + 11 * h + 22 * m) // 451
    month = (h + m - 7 * n + 114) // 31
    return dt.date(year, month, (h + m - 7 * n + 114) % 31 + 1)


def _rule_holidays(year):
    def nth(month, wd, n):  # wd: Monday = 0
        d = dt.date(year, month, 1)
        d += dt.timedelta(days=(wd - d.weekday()) % 7)
        return d + dt.timedelta(weeks=n - 1)

    def last_monday(month):
        d = dt.date(year, month + 1, 1) - dt.timedelta(days=1)
        return d - dt.timedelta(days=d.weekday())

    def observed(d):
        """Saturday -> the Friday before, Sunday -> the Monday after."""
        return d - dt.timedelta(days=1) if d.weekday() == 5 else d + dt.timedelta(days=1) if d.weekday() == 6 else d

    out = [nth(1, 0, 3), nth(2, 0, 3), _easter(year) - dt.timedelta(days=2), last_monday(5),
           observed(dt.date(year, 6, 19)), observed(dt.date(year, 7, 4)), nth(9, 0, 1), nth(11, 3, 4),
           observed(dt.date(year, 12, 25))]
    ny = dt.date(year, 1, 1)
    if ny.weekday() != 5:  # a Saturday New Year's Day is not observed (NYSE rule 7.2)
        out.append(observed(ny))
    return sorted(d.isoformat() for d in out)


def selftest():
    ok = True
    for year in (2026, 2027, 2028):
        table = sorted(k for k in HOLIDAYS if k.startswith(str(year)))
        rule = _rule_holidays(year)
        same = table == rule
        ok &= same
        print(("PASS" if same else "FAIL"), year, "holiday table == rules", "" if same else f"{table} vs {rule}")
    wd = all(1 <= weekday(d) <= 5 for d in list(HOLIDAY_DAYS) + list(EARLY_CLOSE_DAYS))
    ok &= wd
    print("PASS" if wd else "FAIL", "every holiday and early close is a weekday")
    # Sunday 20:00 New York on both sides of a clock change, and the Labor Day reopen that was measured.
    for name, t, want in (
        ("reopen Sun 2026-10-25 20:00 EDT", 1792972800, True), ("one second before it", 1792972799, False),
        ("reopen Sun 2026-11-01 20:00 EST", 1793581200, True), ("one second before it", 1793581199, False),
        ("Labor Day Mon 2026-09-07 12:00 New York", 1788796800, False),
        ("reopen Mon 2026-09-07 20:00 EDT", 1788825600, True),
    ):
        good = is_open(t) == want
        ok &= good
        print("PASS" if good else "FAIL", name, fmt(t), "open" if is_open(t) else "closed")
    return ok


def write_vectors(path):
    """Test vectors shared by the Solidity library and the TypeScript copy: every modelled close and
    reopen from 2026 to mid 2029 (one second before, and at), plus 2,500 pseudo-random instants."""
    t0, t1 = day_number("2026-01-01") * 86400, day_number("2029-07-01") * 86400
    ts = set()
    for c in closures(t0, t1):
        ts.update((c["close"] - 1, c["close"], c["reopen"] - 1, c["reopen"]))
    seed = 0x5EED2026
    for _ in range(2500):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        ts.add(t0 + seed % (t1 - t0))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("ts,is_open,next_open,next_close,last_open,holidays_known\n")
        for t in sorted(ts):
            f.write(f"{t},{int(is_open(t))},{next_open(t)},{next_close(t)},{last_open(t)},{int(trading_day(t) <= CALENDAR_LAST_DAY)}\n")
    print(f"wrote {len(ts)} vectors to {path}")


def main(argv):
    if "--selftest" in argv:
        return 0 if selftest() else 1
    if "--vectors" in argv:
        import os
        write_vectors(os.path.join("data", "calendar_vectors.csv"))
        return 0
    if "--table" in argv:
        hol = sorted(HOLIDAY_DAYS)
        ear = sorted(EARLY_CLOSE_DAYS)
        print("holidays      ", len(hol), 'hex"' + "".join(f"{d:04x}" for d in hol) + '"')
        print("early closes  ", len(ear), 'hex"' + "".join(f"{d:04x}" for d in ear) + '"')
        print("calendar last day", CALENDAR_LAST_DAY)
        return 0
    import time
    t = int(argv[0]) if argv else int(time.time())
    print("at            ", fmt(t))
    print("state         ", "OPEN (the feed is expected to print)" if is_open(t) else "CLOSED (" + closed_reason(t) + ")")
    if not is_open(t):
        print("expected reopen", fmt(next_open(t)))
    print("next close    ", fmt(next_close(t)))
    if not covered(t):
        print("note: outside the holiday table (" + CALENDAR_FIRST + " to " + CALENDAR_LAST + "); only weekends are modelled")
    print("Informational only: a schedule cannot see a halt, a corporate-action pause or an outage.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
