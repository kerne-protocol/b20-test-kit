#!/usr/bin/env python3
"""
Dump every round of a Chainlink feed on Base to CSV. Python 3.9+, standard library only, read only.

A Chainlink proxy numbers rounds as (phase << 64) | aggregatorRound. This script reads the latest
round, walks every phase from 1 to the current one, and reads each round with `getRoundData` through
Multicall3. All reads are pinned to ONE block, so the file is a consistent snapshot.

  python scripts/feed_rounds.py                      # Coinbase TSLA feed -> data/tsla_feed_rounds.csv
  python scripts/feed_rounds.py --feed 0x... --out data/aapl_feed_rounds.csv
  BASE_RPC=https://your-node python scripts/feed_rounds.py

Columns: round_id, phase, agg_round, answer (raw integer), price (answer / 10^decimals),
started_at, updated_at (unix seconds), updated_at_utc, seconds_since_prev (gap to the round before).
A sidecar <out>.meta.json records the feed, the block, the RPC host and the read time.
"""
import argparse
import csv
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import b20kit as K  # noqa: E402

CHUNK = 300
MASK64 = (1 << 64) - 1


def get_rounds(url, feed, ids, block):
    """[(round_id, answer, started_at, updated_at) or None when the round does not exist]."""
    out = []
    for i in range(0, len(ids), CHUNK):
        part = ids[i:i + CHUNK]
        calls = [(feed, K.SEL["getRoundData(uint80)"] + K.enc_uint(r)) for r in part]
        last = None
        for attempt in range(4):
            try:
                res = K.multicall(url, calls, block)
                break
            except K.RpcError as exc:
                last = exc
                time.sleep(1.5 * (attempt + 1))
        else:
            raise SystemExit(f"X reading rounds failed: {last}")
        for rid, (ok, data) in zip(part, res):
            if not ok or len(data) < 320:
                out.append(None)
                continue
            w = K.words(data)
            if w[3] == 0:  # updatedAt == 0 means "no data" on aggregators that do not revert
                out.append(None)
                continue
            out.append((rid, K.to_int256(w[1]), w[2], w[3]))
    return out


def phase_length(url, feed, phase, block):
    """Highest aggregator round that exists in a phase (rounds run 1..N). 0 if the phase is empty."""
    def exists(n):
        return get_rounds(url, feed, [(phase << 64) | n], block)[0] is not None

    if not exists(1):
        return 0
    lo, hi = 1, 2
    while exists(hi):
        lo, hi = hi, hi * 2
        if hi > 1 << 40:
            raise SystemExit("X phase length search ran away")
    while hi - lo > 1:  # invariant: lo exists, hi does not
        mid = (lo + hi) // 2
        if exists(mid):
            lo = mid
        else:
            hi = mid
    return lo


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--feed", default=K.TSLA_FEED, help="Chainlink proxy address (default: Coinbase TSLA)")
    ap.add_argument("--out", default=os.path.join("data", "tsla_feed_rounds.csv"))
    ap.add_argument("--rpc", default=None, help="RPC URL (default: first public Base RPC that answers)")
    a = ap.parse_args()

    url = K.pick_rpc([a.rpc] if a.rpc else None)
    blk = K.rpc(url, "eth_getBlockByNumber", ["latest", False])
    block = blk["number"]
    head = K.multicall(url, [
        (a.feed, K.SEL["latestRoundData()"]),
        (a.feed, K.SEL["decimals()"]),
        (a.feed, K.SEL["description()"]),
    ], block)
    if not all(ok for ok, _ in head):
        raise SystemExit("X this address did not answer as a Chainlink feed")
    lw = K.words(head[0][1])
    latest_id, decimals = lw[0], K.words(head[1][1])[0]
    description = K.dec_string("0x" + head[2][1])
    cur_phase, cur_round = latest_id >> 64, latest_id & MASK64
    print(f"feed {a.feed} \"{description}\", {decimals} decimals, block {int(block, 16)} on {K.host(url)}")
    print(f"latest round: phase {cur_phase}, aggregator round {cur_round}, updated {K.utc(lw[3])} UTC")

    rows, phases = [], {}
    for phase in range(1, cur_phase + 1):
        n = cur_round if phase == cur_phase else phase_length(url, a.feed, phase, block)
        phases[phase] = n
        if n == 0:
            print(f"   phase {phase}: no rounds readable through the proxy")
            continue
        got = get_rounds(url, a.feed, [(phase << 64) | r for r in range(1, n + 1)], block)
        missing = sum(1 for g in got if g is None)
        rows += [g for g in got if g is not None]
        print(f"   phase {phase}: {n - missing} rounds" + (f" ({missing} not readable)" if missing else ""))

    if not rows:
        raise SystemExit("X no rounds read")
    # File order is round order (phase, then aggregator round). The gap column is against the row above.
    non_monotonic = sum(1 for p, q in zip(rows, rows[1:]) if q[3] < p[3])
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", newline="", encoding="utf-8") as f:
        wr = csv.writer(f, lineterminator="\n")
        wr.writerow(["round_id", "phase", "agg_round", "answer", "price", "started_at", "updated_at",
                     "updated_at_utc", "seconds_since_prev"])
        prev = None
        for rid, ans, started, updated in rows:
            price = f"{ans / 10 ** decimals:.{decimals}f}"
            if "." in price:
                price = price.rstrip("0").rstrip(".")
            wr.writerow([rid, rid >> 64, rid & MASK64, ans, price, started, updated, K.utc(updated),
                         "" if prev is None else updated - prev])
            prev = updated
    meta = {
        "feed": a.feed, "description": description, "decimals": decimals, "chain_id": K.CHAIN_ID,
        "block_number": int(block, 16), "block_hash": blk["hash"], "block_time_utc": K.utc(int(blk["timestamp"], 16)),
        "rpc_host": K.host(url), "latest_round_id": str(latest_id), "rounds_per_phase": phases,
        "rows": len(rows), "first_round_utc": K.utc(rows[0][3]), "last_round_utc": K.utc(rows[-1][3]),
        "rounds_with_timestamp_before_previous": non_monotonic,
    }
    with open(a.out + ".meta.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print(f"wrote {len(rows)} rounds, {K.utc(rows[0][3])} to {K.utc(rows[-1][3])} UTC -> {a.out}")
    if non_monotonic:
        print(f"   note: {non_monotonic} round(s) carry a timestamp earlier than the round before")
    return 0


if __name__ == "__main__":
    sys.exit(main())
