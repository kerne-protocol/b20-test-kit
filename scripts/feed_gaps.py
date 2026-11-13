#!/usr/bin/env python3
"""
Measure the quiet periods in a feed CSV written by feed_rounds.py. Python 3.9+, standard library only.

  python scripts/feed_gaps.py                                   # data/tsla_feed_rounds.csv
  python scripts/feed_gaps.py data/aapl_feed_rounds.csv --phase 1

What it reports, all from the round timestamps (`updated_at`):
  1. One row per weekend: the last round before Saturday 12:00 UTC, the first round after it, the
     length of the gap, and whether any round landed between the Friday 4 PM New York close and
     the reopen. Written to <csv stem>_weekends.csv.
  2. How long a consumer with a staleness bound would have been locked out: the share of time the
     latest round was older than 1, 4, 12 and 24 hours.
  3. The size of the price steps between rounds.
  A JSON copy of the summary goes to <csv stem>_summary.json.

Only ONE phase is analysed (default: the newest in the file). Two phases can overlap in time, since a
new aggregator has its own history from before the proxy switched to it, so mixing them would double
count rounds.
"""
import argparse
import csv
import datetime as dt
import json
import os
import statistics
import sys

UTC = dt.timezone.utc


def ny_offset_hours(day):
    """UTC offset of New York on a date: -4 from the 2nd Sunday of March to the 1st Sunday of November."""
    def nth_sunday(year, month, n):
        d = dt.date(year, month, 1)
        d += dt.timedelta(days=(6 - d.weekday()) % 7)
        return d + dt.timedelta(weeks=n - 1)

    return -4 if nth_sunday(day.year, 3, 2) <= day < nth_sunday(day.year, 11, 1) else -5


def ny_time_utc(day, hour):
    """Unix time of `hour`:00 New York local time on `day`."""
    return int(dt.datetime(day.year, day.month, day.day, hour, tzinfo=UTC).timestamp()) - ny_offset_hours(day) * 3600


def fmt(ts):
    return dt.datetime.fromtimestamp(ts, UTC).strftime("%a %Y-%m-%d %H:%M:%S")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="?", default=os.path.join("data", "tsla_feed_rounds.csv"))
    ap.add_argument("--phase", type=int, default=None)
    a = ap.parse_args()

    with open(a.csv, encoding="utf-8") as f:
        allrows = list(csv.DictReader(f))
    phase = a.phase or max(int(r["phase"]) for r in allrows)
    rows = [(int(r["updated_at"]), int(r["answer"]), r["price"]) for r in allrows if int(r["phase"]) == phase]
    if len(rows) < 10:
        sys.exit("X not enough rounds in that phase")
    if any(b[0] < a_[0] for a_, b in zip(rows, rows[1:])):
        sys.exit("X timestamps are not in order inside the phase")
    t0, t1 = rows[0][0], rows[-1][0]
    print(f"phase {phase}: {len(rows)} rounds, {fmt(t0)} to {fmt(t1)} UTC ({(t1 - t0) / 86400:.1f} days)")

    # ---- 1. weekends ----
    weekends = []
    day = dt.datetime.fromtimestamp(t0, UTC).date()
    while True:
        if day.weekday() == 5:  # Saturday
            noon = int(dt.datetime(day.year, day.month, day.day, 12, tzinfo=UTC).timestamp())
            if noon > t1:
                break
            if noon > t0:
                before = max(r for r in rows if r[0] <= noon)
                after = [r for r in rows if r[0] > noon]
                if after:  # a weekend still in progress at the end of the file is left out
                    nxt = after[0]
                    friday = day - dt.timedelta(days=1)
                    close = ny_time_utc(friday, 16)
                    sunday = day + dt.timedelta(days=1)
                    reopen = ny_time_utc(sunday, 20)
                    at_or_after_close = [r for r in rows if r[0] >= close][0]
                    weekends.append({
                        "friday": friday.isoformat(),
                        "friday_close_utc": fmt(close),
                        "last_round_before_weekend_utc": fmt(before[0]),
                        "first_round_after_weekend_utc": fmt(nxt[0]),
                        "gap_hours": round((nxt[0] - before[0]) / 3600, 2),
                        "round_between_close_and_weekend": "yes" if before[0] >= close else "no",
                        "first_round_at_or_after_close_utc": fmt(at_or_after_close[0]),
                        "wait_after_close_hours": round((at_or_after_close[0] - close) / 3600, 2),
                        "sunday_8pm_new_york_utc": fmt(reopen),
                        "first_round_minus_sunday_8pm_seconds": nxt[0] - reopen,
                        "price_before": before[2],
                        "price_after": nxt[2],
                        "move_bps": round((nxt[1] / before[1] - 1) * 1e4, 1),
                        "_span": (before[0], nxt[0]),
                    })
        day += dt.timedelta(days=1)

    stem = a.csv[:-4] if a.csv.endswith(".csv") else a.csv
    stem = stem[:-len("_rounds")] if stem.endswith("_rounds") else stem
    cols = [k for k in weekends[0] if not k.startswith("_")] if weekends else []
    with open(stem + "_weekends.csv", "w", newline="", encoding="utf-8") as f:
        wr = csv.writer(f, lineterminator="\n")
        wr.writerow(cols)
        for w in weekends:
            wr.writerow([w[c] for c in cols])

    print(f"\nweekends in the data: {len(weekends)}")
    print("   Friday      last round before         first round after         gap h   round after close?  move")
    for w in weekends:
        print(f"   {w['friday']}  {w['last_round_before_weekend_utc']}  {w['first_round_after_weekend_utc']}"
              f"  {w['gap_hours']:6.1f}   {w['round_between_close_and_weekend']:<3}                 {w['move_bps']:+.1f} bps")
    gaps_h = [w["gap_hours"] for w in weekends]
    silent = sum(1 for w in weekends if w["gap_hours"] >= 48)
    no_round_after_close = sum(1 for w in weekends if w["round_between_close_and_weekend"] == "no")
    on_reopen = sum(1 for w in weekends if 0 <= w["first_round_minus_sunday_8pm_seconds"] <= 120)

    # ---- 2. staleness ----
    weekend_spans = {w["_span"] for w in weekends}
    pairs = list(zip(rows, rows[1:]))
    all_gaps = [(b[0] - a_[0], (a_[0], b[0]) in weekend_spans) for a_, b in pairs]
    total = t1 - t0
    weekday_total = sum(g for g, wk in all_gaps if not wk)
    stale = {}
    for hours in (1, 4, 12, 24):
        lim = hours * 3600
        every = sum(max(0, g - lim) for g, _ in all_gaps)
        weekday = sum(max(0, g - lim) for g, wk in all_gaps if not wk)
        stale[hours] = {"all_time_pct": round(100 * every / total, 1),
                        "outside_weekend_gaps_pct": round(100 * weekday / weekday_total, 1)}
    longest_weekday = max((g, a_[0], b[0]) for (a_, b), (g, wk) in zip(pairs, all_gaps) if not wk)

    print("\nshare of time the latest round was older than a bound:")
    print("   bound    all time   outside the weekend gaps")
    for hours, s in stale.items():
        print(f"   {hours:>3} h    {s['all_time_pct']:5.1f} %    {s['outside_weekend_gaps_pct']:5.1f} %")
    print(f"longest gap that is not a weekend: {longest_weekday[0] / 3600:.1f} h, "
          f"{fmt(longest_weekday[1])} to {fmt(longest_weekday[2])} UTC")

    # ---- 3. step sizes ----
    steps = sorted(abs(b[1] / a_[1] - 1) * 1e4 for a_, b in pairs)  # plain percentage change, in bps

    def q(f):
        return round(steps[int(f * (len(steps) - 1))], 1)

    print(f"\nprice step between rounds, bps: p5 {q(.05)}, median {q(.5)}, p95 {q(.95)}, max {round(steps[-1], 1)}; "
          f"{100 * sum(s >= 50 for s in steps) / len(steps):.1f} % of steps are 50 bps or more")

    summary = {
        "source_csv": os.path.basename(a.csv), "phase": phase, "rounds": len(rows),
        "first_round_utc": fmt(t0), "last_round_utc": fmt(t1), "days": round(total / 86400, 1),
        "weekends": len(weekends),
        "weekends_with_gap_of_48h_or_more": silent,
        "weekends_with_no_round_between_friday_close_and_reopen": no_round_after_close,
        "weekends_where_first_round_is_within_2_min_of_sunday_8pm_new_york": on_reopen,
        "weekend_gap_hours_min": min(gaps_h) if gaps_h else None,
        "weekend_gap_hours_max": max(gaps_h) if gaps_h else None,
        "weekend_gap_hours_median": round(statistics.median(gaps_h), 2) if gaps_h else None,
        "largest_weekend_move_bps": max((abs(w["move_bps"]) for w in weekends), default=None),
        "stale_share": stale,
        "longest_non_weekend_gap_hours": round(longest_weekday[0] / 3600, 1),
        "longest_non_weekend_gap_from_utc": fmt(longest_weekday[1]),
        "longest_non_weekend_gap_to_utc": fmt(longest_weekday[2]),
        "step_bps": {"p5": q(.05), "median": q(.5), "p95": q(.95), "max": round(steps[-1], 1),
                     "share_50bps_or_more_pct": round(100 * sum(s >= 50 for s in steps) / len(steps), 1)},
    }
    with open(stem + "_summary.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")

    print(f"\n{silent} of {len(weekends)} weekends had no round for 48 hours or more "
          f"(gap {min(gaps_h):.1f} to {max(gaps_h):.1f} h).")
    print(f"{no_round_after_close} of {len(weekends)} had no round between the Friday 4 PM New York close and the reopen.")
    print(f"{on_reopen} of {len(weekends)} resumed within 2 minutes of Sunday 8 PM New York.")
    print(f"wrote {stem}_weekends.csv and {stem}_summary.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
