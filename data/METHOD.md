# Data and method

Everything in this folder was read from Base mainnet with public RPCs and can be read again with the
scripts in `scripts/`. Nothing was edited by hand.

## Files

| File | What it is | Written by |
| - | - | - |
| `tsla_feed_rounds.csv` | Every round of the Coinbase TSLA Chainlink feed readable through its proxy: 1,554 rounds, 2026-08-03 15:46:43 to 2026-11-13 16:56:49 UTC | `python scripts/feed_rounds.py` |
| `tsla_feed_rounds.csv.meta.json` | The feed address, the block the read was pinned to, the RPC host and the round count per phase | same |
| `tsla_feed_weekends.csv` | One row per weekend | `python scripts/feed_gaps.py` |
| `tsla_feed_summary.json` | The numbers quoted in the README | same |
| `tslac_live_probe.json` | What the real TSLAc precompile answered to the 41 calls of `src/sim/B20Probe.sol` | `python scripts/sim_live.py probe --write-fixture` |

## The feed read

- Feed: `0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4`, description `Coinbase TSLA`, 8 decimals.
- Pinned to Base block 57036280 (2026-11-13 19:20:31 UTC), read from `mainnet.base.org`.
- A Chainlink proxy numbers rounds as `(phase << 64) | aggregatorRound`. The script reads
  `latestRoundData`, then every phase from 1 to the current one. For the current phase it reads rounds
  1 to the latest. For an older phase it finds the last round by doubling and then bisecting on
  `getRoundData`. Rounds are read through Multicall3 in chunks of 300, all at the pinned block.
- This feed has two phases: phase 1 with 147 rounds (2026-08-03 to 2026-08-14) and phase 2 with 1,407
  rounds (2026-08-05 to 2026-11-13). They overlap in time, because the second aggregator has its own
  history from before the proxy switched to it. The CSV keeps both. The `seconds_since_prev` column is
  the gap to the row above, so ignore it on the first row of phase 2.
- `getRoundData` for a round that does not exist inside an existing phase returned all zeros and did not
  revert. For a phase that does not exist it reverted with no data. The script treats `updatedAt == 0`
  as "no round".

## The gap report

`feed_gaps.py` uses ONE phase (the newest, phase 2) so no round is counted twice: 1,407 rounds over
99.8 days. Every number comes from the `updated_at` timestamps.

- **Weekend.** For each Saturday 12:00 UTC inside the data, the last round before it and the first
  round after it. A weekend still in progress at the end of the file is left out. There are 14.
- **Friday close.** 16:00 New York time on the Friday, converted to UTC with the US daylight rule
  (second Sunday of March to first Sunday of November): 20:00 UTC until 2026-10-30, 21:00 UTC from
  2026-11-06. "Round after the close" asks whether the last round before the weekend is at or after
  that time.
- **Reopen.** 20:00 New York time on the Sunday. The first round after the weekend was within 2
  minutes of it on 13 of 14 weekends. The exception is 2026-09-04: Monday 2026-09-07 was Labor Day
  and the first round came on Tuesday 00:00:51 UTC, which is Monday 8 PM in New York.
- **Staleness share.** For a bound T, the time during which the newest round was older than T is the
  sum over all gaps of `max(0, gap - T)`. It is given as a share of the whole span and, separately, of
  the span without the 14 weekend gaps.
- **Step size.** `abs(p[i] / p[i-1] - 1)` between consecutive rounds, the plain percentage change, in
  basis points.

## The weekends

| Friday | Last round before the weekend (UTC) | First round after (UTC) | Gap, hours | Round after the 4 PM New York close? | Price move across the gap |
| - | - | - | - | - | - |
| 2026-08-07 | Fri 2026-08-07 16:49:43 | Mon 2026-08-10 00:00:43 | 55.2 | no | +37.5 bps |
| 2026-08-14 | Fri 2026-08-14 18:19:01 | Mon 2026-08-17 00:00:33 | 53.7 | no | +17.5 bps |
| 2026-08-21 | Fri 2026-08-21 23:00:27 | Mon 2026-08-24 00:00:25 | 49.0 | yes | +51.9 bps |
| 2026-08-28 | Fri 2026-08-28 19:54:05 | Mon 2026-08-31 00:00:33 | 52.1 | no | -25.3 bps |
| 2026-09-04 | Fri 2026-09-04 20:02:37 | Tue 2026-09-08 00:00:51 | 76.0 | yes | +23.3 bps |
| 2026-09-11 | Fri 2026-09-11 15:47:27 | Mon 2026-09-14 00:00:53 | 56.2 | no | -101.2 bps |
| 2026-09-18 | Fri 2026-09-18 19:49:39 | Mon 2026-09-21 00:00:27 | 52.2 | no | +23.1 bps |
| 2026-09-25 | Fri 2026-09-25 18:52:13 | Mon 2026-09-28 00:00:51 | 53.1 | no | +10.0 bps |
| 2026-10-02 | Fri 2026-10-02 19:55:37 | Mon 2026-10-05 00:00:37 | 52.1 | no | +52.1 bps |
| 2026-10-09 | Fri 2026-10-09 16:05:25 | Mon 2026-10-12 00:00:23 | 55.9 | no | +16.5 bps |
| 2026-10-16 | Fri 2026-10-16 20:44:45 | Mon 2026-10-19 00:00:51 | 51.3 | yes | +123.8 bps |
| 2026-10-23 | Fri 2026-10-23 20:05:47 | Mon 2026-10-26 00:00:43 | 51.9 | yes | +39.8 bps |
| 2026-10-30 | Fri 2026-10-30 19:08:55 | Mon 2026-11-02 01:00:33 | 53.9 | no | +48.7 bps |
| 2026-11-06 | Fri 2026-11-06 21:42:54 | Mon 2026-11-09 01:00:23 | 51.3 | yes | -22.7 bps |

## The numbers

| Measure | Value |
| - | - |
| Weekends with no round for 48 hours or more | 14 of 14 |
| Weekend gap, shortest / median / longest | 49.0 / 52.7 / 76.0 hours |
| Weekends with no round between the Friday close and the reopen | 9 of 14 |
| Wait from the Friday close to the next round, on those 9 | 52.0 to 53.0 hours |
| Longest gap that is not a weekend | 18.6 hours (Wed 2026-08-26 19:01:57 to Thu 2026-08-27 13:40:33 UTC) |
| Newest round older than 1 hour | 72.8% of all time, 60.9% outside the weekend gaps |
| Newest round older than 4 hours | 45.4% of all time, 23.3% outside the weekend gaps |
| Newest round older than 12 hours | 26.2% of all time, 2.0% outside the weekend gaps |
| Newest round older than 24 hours | 17.9% of all time, 0.0% outside the weekend gaps |
| Step between rounds, 5th percentile / median / 95th percentile / largest | 50.2 / 53.4 / 74.3 / 203.1 bps |
| Steps of 50 bps or more | 99.1% |

## All 13 feeds and the calendar model

`all_feeds/` holds the same read for every regular "Coinbase <TICKER>" feed in Chainlink's Base
directory (AAPL AMZN COIN CRCL GOOGL INTC META MSFT MSTR NVDA SNDK SPCX TSLA) and for the three
"(24/7)" feeds (GOOGL, NVDA, TSLA), taken on 2026-11-14. Each `<name>_feed_rounds.csv` was written by
`python scripts/feed_rounds.py --feed <address> --out data/all_feeds/<name>_feed_rounds.csv`, and its
`.meta.json` names the block it was pinned to (57436913 to 57437588, read from `mainnet.base.org`).
Every regular feed has two phases, like TSLA, and the reports use the newest; the 24/7 feeds have one.

| File | What it is | Written by |
| - | - | - |
| `all_feeds/*_feed_rounds.csv` + `.meta.json` | Every round of 16 feeds | `python scripts/feed_rounds.py` |
| `all_feeds/closure_gaps.csv` | One row per regular feed per scheduled closure, 182 rows | `python scripts/closure_gaps.py` |
| `all_feeds/closure_gaps_summary.json` | The numbers quoted in section 4 of the README | same |
| `calendar_vectors.csv` | 3,252 instants with the model's answer for each | `python scripts/market_calendar.py --vectors` |

The model is `scripts/market_calendar.py`: a trading day runs from 20:00 New York the evening before
to 20:00 on the day; trading days are Monday to Friday minus the full-day holidays of the New York
Stock Exchange; an early-close day ends at 17:00. The holiday table (2026 to 2028) was read from
nyse.com/markets/hours-calendars on 2026-11-14, and `--selftest` rebuilds it from the holiday rules.
New York's clock change is taken per whole UTC day. The real change is at 02:00 local on a Sunday,
which is inside the weekend closure, so no open or close time moves.

`closure_gaps.py` asks the model for every closure between a feed's first and last round and, for each
one that had a round after it, takes the last round before the modelled reopen and the first round at
or after it. A closure still in progress at the end of the file (the weekend of 2026-11-14) is left out.

- **Closures.** 14 calendar closures, all weekends: one is the Labor Day long weekend (Monday
  2026-09-07) and one holds the November clock change. Each is seen on all 13 feeds, which gives the
  182 rows. The feeds move together, so these are 14 events seen 13 times, not 182 independent ones.
- **Rounds inside a closure.** 181 of 182 closures had none. One round, on the Coinbase COIN feed,
  is stamped Sat 2026-08-22 00:00:05 UTC, 5 seconds after the modelled Friday 20:00 New York close.
  It is the only one of 28,887 rounds that falls inside a modelled closure.
- **Reopen.** On all 182 the first round came 19 to 99 seconds after the modelled reopen, Labor Day
  included (all 13 feeds stayed silent on the Monday and printed at Monday 20:00 New York).
- **Close.** The last round before a modelled close came a median of 4.1 hours before it, because a
  round needs a 0.5% move. The closest was 22 seconds before the close, and 5 of the 182 had a round
  in the last 10 minutes. So the data shows rounds right up to Friday 20:00 New York and (with the
  one exception above) none after it, but it cannot place the close more finely than that.
- **Older phase.** Each regular feed also has an older aggregator with rounds from 2026-08-03 to
  2026-08-14, 4,087 in all. They overlap the newer phase in time, so they are left out of the rows
  and counted separately: none of them falls inside a modelled closure.
- **Held time.** From the last round before a closure to the first after it: 48.0 to 81.6 hours,
  median 52.3. The longest are Labor Day weekend on feeds whose last round came early on the Friday.
- **Open sessions.** The longest gap between two rounds with no closure between them was 24.0 hours,
  which matches the 24 hour heartbeat in Chainlink's directory.
- **The 24/7 feeds.** They started on 2026-11-04 and 2026-11-05. In the one and a half weekends
  recorded, GOOGL printed 6 rounds inside a modelled closure, NVDA 12 and TSLA 4. The model is not for
  them and the guard library should not be pointed at them.

Not in the data: an early-close day and a one-day midweek holiday. Neither has happened since the
feeds launched. The 17:00 rule for early-close days comes from the exchange's published late-session
hours, and the rule that a holiday closes the feed from 20:00 the evening before is extended from
the one Monday holiday that was recorded.

`calendar_vectors.csv` holds every modelled close and reopen from 2026 to mid 2029 (one second before
each, and at each) plus 2,500 pseudo-random instants. `test/StockFeedGuard.t.sol` requires the
Solidity library to give the same five answers on every line, and the TypeScript copy behind
`kerne.fi/quotes/api/feed-status` is checked against the same file.

## What this does and does not show

- It shows when rounds were published. It does not show why. The pattern (a round on each 0.5% move
  while the market trades, none over the weekend, one at the Sunday 8 PM New York reopen) matches what
  Base's docs say about the feed being 24/5 and holding its value off-hours, but the reading of the
  cause is ours.
- The tables above this section are one feed, TSLA. The other 12 regular feeds are in `all_feeds/`
  and show the same shape.
- It is a snapshot. A feed's deviation threshold, heartbeat and schedule can change. Read it again.
- Phase 1 and phase 2 disagree slightly on the weekend of 2026-08-07 (last round 19:58 UTC in phase 1,
  16:49 UTC in phase 2), which is in the overlap. The report uses phase 2 throughout.

## The live probe

`tslac_live_probe.json` was recorded at Base block 57048991 (2026-11-13) with one `eth_call` carrying a
state override: `B20Probe` code at an unused address, `SimExec` code at a current TSLAc holder (the
USDC/TSLAc pool `0x7a33000372f3f028f074182ccb9d16cbeefbf920`) and at three unused addresses. The call
moved 0.01 TSLAc inside the simulation only. Nothing was signed or sent, and the chain did not change.
The same probe gave identical bytes on `mainnet.base.org`, `base-rpc.publicnode.com` and
`base.drpc.org`. `totalSupply` is the one value that moves between runs, since shares are minted and
redeemed, so the script compares it with itself (before and after the probe) and not with the recording.
