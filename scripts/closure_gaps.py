#!/usr/bin/env python3
"""
Every scheduled closure (weekend or market holiday) of every feed CSV in a folder, measured against
the calendar model in market_calendar.py. Python 3.9+, standard library only. Reads files, no network.

  python scripts/closure_gaps.py                      # data/all_feeds
  python scripts/closure_gaps.py some/folder

For each `<name>_feed_rounds.csv` (written by feed_rounds.py) it takes the newest phase and, for every
modelled closure that both started and ended inside the data, writes one row to
`<folder>/closure_gaps.csv`:
  the modelled close and reopen, the last round before the reopen, the first round at or after it,
  the hours between those two rounds, how many rounds landed inside the closure (the model says
  none), how many seconds before the modelled close the last round came, how many seconds after the
  modelled reopen the first round came, and the price move.
A closure still in progress at the end of a file is left out.

Two things to keep in mind when reading the result. The feeds move together, so 13 feeds over 14
weekends are 14 calendar events seen 13 times, not 182 independent ones. And the rounds of the older
phase are not in the per-closure rows; the summary counts how many of them fall inside a modelled
closure, so nothing is hidden by leaving them out.

`<folder>/closure_gaps_summary.json` holds the per-feed and overall numbers quoted in the README.
A feed whose description ends in "(24/7)" is reported separately: those feeds are built to print
through the weekend, so the model does not apply to them.
"""
import csv
import glob
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import market_calendar as cal  # noqa: E402

COLS = ["feed", "feed_address", "kind", "holidays", "early_close_before", "modelled_close_utc", "modelled_reopen_utc",
        "modelled_closure_hours", "last_round_before_reopen_utc", "first_round_after_reopen_utc", "gap_hours",
        "rounds_inside_closure", "last_round_seconds_before_close", "first_round_seconds_after_reopen", "price_before",
        "price_after", "move_bps"]


def load(path):
    with open(path, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    phase = max(int(r["phase"]) for r in rows)
    older = [int(r["updated_at"]) for r in rows if int(r["phase"]) != phase]
    return phase, [(int(r["updated_at"]), int(r["answer"]), r["price"]) for r in rows if int(r["phase"]) == phase], older


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join("data", "all_feeds")
    files = sorted(glob.glob(os.path.join(folder, "*_feed_rounds.csv")))
    if not files:
        sys.exit("X no *_feed_rounds.csv in " + folder)
    out_rows, feeds, feeds_247 = [], {}, {}
    for path in files:
        with open(path + ".meta.json", encoding="utf-8") as f:
            meta = json.load(f)
        name = meta["description"]
        phase, rows, older = load(path)
        if any(b[0] < a[0] for a, b in zip(rows, rows[1:])):
            sys.exit("X timestamps are not in order inside the phase: " + path)
        ts = [r[0] for r in rows]
        t0, t1 = ts[0], ts[-1]
        inside_any = sum(1 for t in ts if not cal.is_open(t))
        base = {"feed_address": meta["feed"], "phase": phase, "rounds": len(rows),
                "first_round_utc": cal.fmt(t0), "last_round_utc": cal.fmt(t1), "read_at_block": meta["block_number"],
                "days": round((t1 - t0) / 86400, 1),
                "older_phase_rounds": len(older),
                "older_phase_rounds_inside_any_modelled_closure": sum(1 for t in older if not cal.is_open(t))}
        if name.endswith("(24/7)"):
            feeds_247[name] = {**base, "rounds_inside_modelled_closures": inside_any,
                               "note": "a 24/7 feed: it prints through the weekend, the calendar model does not apply"}
            continue
        mine = []
        for c in cal.closures(t0, t1):
            after = [r for r in rows if r[0] >= c["reopen"]]
            if not after:  # still in progress at the end of the file
                continue
            before = [r for r in rows if r[0] < c["reopen"]][-1]
            nxt = after[0]
            mine.append({
                "feed": name, "feed_address": meta["feed"], "kind": c["kind"], "holidays": "; ".join(c["holidays"]),
                "early_close_before": c["early_close"] or "",
                "modelled_close_utc": cal.fmt(c["close"]), "modelled_reopen_utc": cal.fmt(c["reopen"]),
                "modelled_closure_hours": round((c["reopen"] - c["close"]) / 3600, 2),
                "last_round_before_reopen_utc": cal.fmt(before[0]), "first_round_after_reopen_utc": cal.fmt(nxt[0]),
                "gap_hours": round((nxt[0] - before[0]) / 3600, 2),
                "rounds_inside_closure": sum(1 for t in ts if c["close"] <= t < c["reopen"]),
                # negative when the last round before the reopen is itself inside the closure
                "last_round_seconds_before_close": c["close"] - before[0],
                "first_round_seconds_after_reopen": nxt[0] - c["reopen"],
                "price_before": before[2], "price_after": nxt[2], "move_bps": round((nxt[1] / before[1] - 1) * 1e4, 1),
                "_span": (before[0], nxt[0]),
            })
        out_rows += mine
        spans = {m["_span"] for m in mine}
        open_gaps = [b[0] - a[0] for a, b in zip(rows, rows[1:]) if (a[0], b[0]) not in spans]
        gaps = [m["gap_hours"] for m in mine]
        late = [m["first_round_seconds_after_reopen"] for m in mine]
        early = [m["last_round_seconds_before_close"] for m in mine]
        feeds[name] = {
            **base, "closures": len(mine),
            "weekends": sum(1 for m in mine if m["kind"].startswith("weekend")),
            "holiday_closures": sum(1 for m in mine if "holiday" in m["kind"]),
            "closures_with_a_round_inside": sum(1 for m in mine if m["rounds_inside_closure"]),
            "rounds_inside_any_modelled_closure": inside_any,
            "gap_hours_min": min(gaps), "gap_hours_median": round(statistics.median(gaps), 2), "gap_hours_max": max(gaps),
            "first_round_after_reopen_seconds_median": statistics.median(late),
            "first_round_after_reopen_seconds_max": max(late),
            "closures_resumed_within_2_minutes": sum(1 for s in late if s <= 120),
            "last_round_before_close_seconds_min": min(early),
            "last_round_before_close_seconds_median": statistics.median(early),
            "longest_gap_while_open_hours": round(max(open_gaps) / 3600, 1),
            "largest_move_across_a_closure_bps": max(abs(m["move_bps"]) for m in mine),
        }
        print(f"{name:<16} phase {phase}: {len(rows):>5} rounds, {len(mine):>2} closures, gap {min(gaps):.1f} to {max(gaps):.1f} h, "
              f"{feeds[name]['closures_with_a_round_inside']} with a round inside, first round {min(late)} to {max(late)} s after the reopen")

    with open(os.path.join(folder, "closure_gaps.csv"), "w", newline="", encoding="utf-8") as f:
        wr = csv.writer(f, lineterminator="\n")
        wr.writerow(COLS)
        for r in out_rows:
            wr.writerow([r[c] for c in COLS])

    allgaps = [r["gap_hours"] for r in out_rows]
    late = [r["first_round_seconds_after_reopen"] for r in out_rows]
    early = sorted(r["last_round_seconds_before_close"] for r in out_rows)
    weekend = [r for r in out_rows if r["kind"].startswith("weekend")]
    events = sorted({(r["modelled_close_utc"], r["modelled_reopen_utc"]) for r in out_rows})
    summary = {
        "model": "scripts/market_calendar.py (the same rule as src/StockFeedGuard.sol)",
        "feeds": len(feeds),
        "rounds": sum(f["rounds"] for f in feeds.values()),
        "closures_measured": len(out_rows),
        "distinct_calendar_closures": len(events),
        "note_on_independence": "the feeds move together: these are the distinct calendar closures seen on every feed, not independent events",
        "weekend_closures_measured": len(weekend),
        "holiday_closures_measured": sum(1 for r in out_rows if "holiday" in r["kind"]),
        "closures_with_no_round_inside": sum(1 for r in out_rows if r["rounds_inside_closure"] == 0),
        "rounds_inside_any_modelled_closure": sum(f["rounds_inside_any_modelled_closure"] for f in feeds.values()),
        "gap_hours_min": min(allgaps), "gap_hours_median": round(statistics.median(allgaps), 2), "gap_hours_max": max(allgaps),
        "weekend_gap_hours_min": min(r["gap_hours"] for r in weekend),
        "weekend_gap_hours_max": max(r["gap_hours"] for r in weekend),
        "closures_resumed_within_2_minutes_of_the_modelled_reopen": sum(1 for s in late if s <= 120),
        "first_round_after_reopen_seconds_max": max(late),
        "last_round_before_close_seconds_min": early[0],
        "last_round_before_close_seconds_median": statistics.median(early),
        "closures_with_a_round_in_the_last_10_minutes_before_the_close": sum(1 for s in early if 0 <= s <= 600),
        "older_phase_rounds_not_in_these_numbers": sum(f["older_phase_rounds"] for f in feeds.values()),
        "older_phase_rounds_inside_any_modelled_closure": sum(f["older_phase_rounds_inside_any_modelled_closure"] for f in feeds.values()),
        "longest_gap_while_open_hours": max(f["longest_gap_while_open_hours"] for f in feeds.values()),
        "largest_move_across_a_closure_bps": max(abs(r["move_bps"]) for r in out_rows),
        "per_feed": feeds,
        "feeds_24_7": feeds_247,
    }
    with open(os.path.join(folder, "closure_gaps_summary.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    print(f"\n{summary['feeds']} feeds, {summary['rounds']} rounds, {len(out_rows)} closures measured "
          f"({summary['weekend_closures_measured']} weekends, {summary['holiday_closures_measured']} with a holiday).")
    print(f"{summary['closures_with_no_round_inside']} of {len(out_rows)} closures had no round inside; "
          f"{summary['rounds_inside_any_modelled_closure']} round(s) in total landed inside a modelled closure.")
    print(f"gap between the last round before and the first round after: {min(allgaps):.1f} to {max(allgaps):.1f} h, median {summary['gap_hours_median']} h.")
    print(f"{summary['closures_resumed_within_2_minutes_of_the_modelled_reopen']} of {len(out_rows)} resumed within 2 minutes of the modelled reopen "
          f"(slowest {max(late)} s).")
    print(f"those are {len(events)} distinct calendar closures seen on {len(feeds)} feeds that move together.")
    print(f"last round before the modelled close: median {summary['last_round_before_close_seconds_median'] / 3600:.1f} h before it, "
          f"closest {min(s for s in early if s >= 0)} s before it; "
          f"{summary['closures_with_a_round_in_the_last_10_minutes_before_the_close']} closures had a round in the last 10 minutes.")
    print(f"older phase (not in the numbers above): {summary['older_phase_rounds_not_in_these_numbers']} rounds, "
          f"{summary['older_phase_rounds_inside_any_modelled_closure']} inside a modelled closure.")
    for name, f in feeds_247.items():
        print(f"{name}: {f['rounds_inside_modelled_closures']} of {f['rounds']} rounds landed inside a modelled closure (expected for a 24/7 feed)")
    print(f"wrote {os.path.join(folder, 'closure_gaps.csv')} and closure_gaps_summary.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
