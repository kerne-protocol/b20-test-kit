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

## What this does and does not show

- It shows when rounds were published. It does not show why. The pattern (a round on each 0.5% move
  while the market trades, none over the weekend, one at the Sunday 8 PM New York reopen) matches what
  Base's docs say about the feed being 24/5 and holding its value off-hours, but the reading of the
  cause is ours.
- It is one feed. We ran the same two scripts on the Coinbase AAPL feed
  (`0x787f13dEa48Db0897CbCDD985de77809D837F988`, block 57042108) and got the same shape: 14 of 14
  weekends with a gap of 52.2 to 76.0 hours. That data is not checked in.
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
