# b20-test-kit

Small test tools for contracts that hold Coinbase tokenized stocks on Base, plus three months of
recorded Chainlink rounds for the TSLA feed and what they show about weekends.

It works with stock Foundry and a public RPC. No API key, no private key, nothing to sign.

## The two things that cost us time

**1. The stock tokens are precompiles, so a normal fork cannot run them.**
Coinbase tokenized stocks are B20 tokens. A B20 token is implemented inside the Base node, not as a
deployed contract. `eth_getCode` at the TSLAc address returns one byte, `0xef`. On a stock Foundry
fork that byte is all there is: a call to the token fails (`OpcodeNotFound` on anvil 1.5.1, and inside
`forge test` the call burns all the gas it is given).

**2. The price feed stops for the weekend, and the last price before it is often not the close.**
Base's docs describe the feeds as 24/5 and say the value is held off-hours. In the recorded rounds of
the Coinbase TSLA feed that means: on 14 of 14 weekends there was no round for 49 to 76 hours, and on
9 of the 14 the last round came before the 4 PM New York close. Details and the data are below.

## What Base already ships, and where this kit fits

Use Base's own tools when you need the full B20 behaviour:

- [`base/base-std`](https://github.com/base/base-std): the interfaces, constants and Solidity reference
  mocks of the precompiles.
- [`base/base-anvil`](https://github.com/base/base-anvil): a fork of Foundry that hosts the precompiles
  locally (`base-forge`, `base-anvil`).
- [Tokenized stocks on Base](https://docs.base.org/specifications/b20/tokenized-stocks-on-base) and the
  [B20 reference](https://docs.base.org/specifications/b20/reference/interfaces/ib20) in the docs.

This kit is the smaller set of things we wanted on top of those while building a vault on TSLAc:

| Piece | What it gives you |
| - | - |
| `src/MockB20.sol` | One file, no imports. The ERC-20 surface of a B20 token, to etch at the REAL token address on a mainnet fork with stock Foundry. Kept in step with the real token by a recorded live probe. |
| `scripts/sim_live.py` | Runs a multi-step script, your contract included, against the REAL precompile and live state in one read-only `eth_call`. |
| `data/` + `src/MockAggregator.sol` | 1,554 recorded rounds of the Coinbase TSLA feed, the script that reads them, a weekend and staleness report, and a loader that replays them in a forge test. |
| `scripts/fork_setup.py` | Puts both mocks in place on a local anvil fork and lets you mint, move time and push prices. |

## Quick start

```bash
git clone https://github.com/kerne-protocol/b20-test-kit
cd b20-test-kit
forge test                                  # 25 tests, no network needed
python scripts/sim_live.py probe            # 41 calls against the real TSLAc, read only
python scripts/sim_live.py escrow           # deploy a contract inside the call and use it
python scripts/feed_gaps.py                 # the weekend report, from the checked-in CSV
FORK_TESTS=1 forge test --match-contract ForkTest -vv     # fork tests against Base mainnet
```

On PowerShell set the variable first: `$env:FORK_TESTS=1; forge test --match-contract ForkTest -vv`.

Needs Foundry and Python 3.9 or newer (`python3` where that is the command). The scripts use the
Python standard library only. `forge-std` is vendored in `lib/`, so there is no install step. Set
`BASE_RPC` to use your own node.

To use the mocks from your own project, either copy `src/MockB20.sol` (it has no imports), or install
the kit and add one remapping so the import paths below resolve:

```bash
forge install kerne-protocol/b20-test-kit
```

```toml
# foundry.toml of your project
remappings = ["b20-test-kit/=lib/b20-test-kit/"]
```

## 1. The mock token

```solidity
import {MockB20} from "b20-test-kit/src/MockB20.sol";

address constant TSLAC = 0xb2000000000000000000001e800a7f5189430cD0;

vm.etch(TSLAC, type(MockB20).runtimeCode);       // on a fork or in a plain unit test
MockB20(TSLAC).mockMint(alice, 5e8);             // 5.0 TSLAc, 8 decimals
MockB20(TSLAC).mockSetBlocked(address(vault), true);   // what a policy block does to your contract
MockB20(TSLAC).mockSetPaused(true);              // what a transfer pause does
```

The mock keeps its state in one namespaced storage slot, so it starts empty wherever you etch it.

What it copies, and how each part was checked:

| Behaviour | Source |
| - | - |
| `transfer`, `transferFrom`, `approve` return `true`; zero amounts and self-transfers succeed | checked live |
| `InsufficientBalance(sender, balance, needed)`, `InsufficientAllowance(spender, allowance, needed)` with these exact arguments | checked live |
| `InvalidReceiver` for `address(0)` and for the token's own address; `InvalidSender` for a zero `from`; `InvalidSpender` for a zero spender | checked live |
| Order of checks in `transferFrom`: receiver, then sender, then allowance, then balance | checked live |
| `transfer` called from the zero address reverts `InvalidSender`, after the receiver check | seen in a one-off `eth_call`, not in the recording |
| An allowance of `type(uint256).max` is never spent down | checked live |
| An unknown selector reverts with that selector as the 4 bytes of revert data; calldata under 4 bytes reverts with `0x00000000` | checked live |
| 8 decimals | checked live (TSLAc) |
| `ContractPaused(0)` when transfers are paused; `approve` still works | Base docs and `IB20.sol`, not checked live |
| `PolicyForbids(scope, policyId)` for a blocked executor, sender or receiver, checked after the allowance and before the balance | Base docs and `IB20.sol`, not checked live |

"Checked live" means `test/Conformance.t.sol` replays `data/tslac_live_probe.json`. That file holds
what the real TSLAc precompile answered to the 41 calls of `src/sim/B20Probe.sol`, and the test requires
the mock to return the same success flag and the same bytes at every step. The pause and policy paths
cannot be seen from outside, since only the issuer can pause or block, so they follow the docs.

Not in the mock: memo transfers, permit, roles, seizure, the UI multiplier (`uiMultiplier`,
`balanceOfUI` and friends), the policy registry, and any event other than `Transfer` and `Approval`.
If your contract uses those, use `base-std` or `base-anvil`.

Known differences, all on malformed or unusual calls: a known selector with truncated arguments reverts
with empty data here and with the selector on the real token; `isPaused` with a value above 3 and
`policyId` with an unknown scope revert on the real token and return a value here; a call that carries
ETH reverts with empty data here.

## 2. Running against the real precompile

`eth_call` accepts a third argument, a state override, that swaps the code at any address for the
length of that one call. That is enough to run a whole scenario on the live chain state:

1. Put `SimExec` (ten lines, `src/sim/SimExec.sol`) at a current token holder and at a few unused
   addresses. Each of them can now be told to call anything, and the target sees it as `msg.sender`.
2. Put an orchestrator contract at one more unused address. It drives the steps and returns what it saw.
3. Send one `eth_call`. The node runs the real precompile. Nothing is signed and nothing is sent.

```
$ python scripts/sim_live.py escrow
node mainnet.base.org, block 57040694 (2026-11-13 19:35:14 UTC)
token 0xb2000000000000000000001e800a7f5189430cD0 TSLAc, 8 decimals, eth_getCode = 0xef (a precompile marker, not contract bytecode)

example: ExampleEscrow deployed and used inside one eth_call against live TSLAc

   [ok ] escrow deployed inside the call (address as a number): 0x30a5efc46f67f3254bc74e930c9548da2b45562c
   [ok ] alice balance after funding: 1000000
   [ok ] escrow balance after deposit: 1000000
   [ok ] alice deposit recorded: 1000000
   [ok ] second withdraw reverted (1 = yes): 1
   [ok ] alice balance after withdraw: 1000000
   [ok ] escrow balance after withdraw: 0

All checks passed against the live precompile. Nothing was signed or sent.
```

To test your own contract, copy `src/example/EscrowSim.sol` and swap `ExampleEscrow` for it. The same
orchestrator then runs in a forge test against the mock (`test/EscrowExample.t.sol`) and against the
real token (`sim_live.py`), so you write the scenario once.

Things to know:

- Create your contract with `new` inside the orchestrator. Code placed by an override never ran its
  constructor, so it has no immutables and no initial storage.
- The holder's code is replaced for that call. Pick a holder your scenario does not depend on. The
  default is a USDC/TSLAc pool, which is fine unless your path swaps through that pool.
- For a single call you do not need any of this. Set `from` in a plain `eth_call`.
- Events are not returned by `eth_call`. Assert on balances and return values.
- `mainnet.base.org`, `base-rpc.publicnode.com` and `base.drpc.org` all accepted the override and gave
  identical results on 2026-11-13. Other nodes may ignore it; `sim_live.py` checks the node (chain
  id and override support) before it runs, also when you pass `--rpc`.
- `python scripts/sim_live.py probe` compares the live token with the checked-in recording and tells
  you if the token's behaviour has changed. Add `--write-fixture` to record again, then run `forge test`.

## 3. The feed and the weekend

`data/tsla_feed_rounds.csv` holds every round of the Coinbase TSLA Chainlink feed
(`0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4`) readable on 2026-11-13: 1,554 rounds from 2026-08-03,
read at one pinned block. `data/METHOD.md` has the method and the full weekend table. In short, for the
current aggregator (1,407 rounds over 99.8 days, 14 complete weekends):

- **Every weekend was silent.** 14 of 14 had no round for 48 hours or more. The gap ran from 49.0 to
  56.2 hours on a normal weekend and 76.0 hours over Labor Day.
- **The feed came back at Sunday 8 PM New York**, within 2 minutes, on 13 of 14 (the other one was the
  Monday holiday). That is 00:00 UTC on Monday in summer and 01:00 UTC after the November clock change.
- **The last price before the weekend was often not the close.** On 9 of 14 Fridays no round landed
  between the 4 PM New York close and the reopen. The earliest "last round" was 15:47 UTC on a Friday,
  more than four hours before the close.
- **Rounds follow price, not the clock.** 99.1% of the price changes between rounds were 0.50% or
  larger, and the median was 0.53%. On a quiet weekday the feed went 18.6 hours without a round.
- **A short staleness bound locks you out most of the time.** The newest round was more than 1 hour old
  72.8% of the time and more than 4 hours old 45.4% of the time. Outside the weekend gaps those shares
  were 60.9% and 23.3%.

What that means for a contract:

- A staleness check sized for a crypto feed (say 1 hour) will reject this feed most of the day. A bound
  that keeps weekdays open (the longest weekday gap was 18.6 hours) still closes every weekend, which
  may be what you want. Decide it on purpose and test both sides of it.
- "Settle on the first round at or after expiry" with an expiry at the Friday close gave the
  Sunday-night reopen price on 9 of 14 weekends, 52 to 53 hours later and after the weekend's news.
  The largest price move across one of those nine gaps was 1.01%. If you want Friday's price, put the
  expiry inside the trading day, or settle on the last round before expiry.
- Even when a round lands near the close, it is the last 0.5% step and need not be the closing price.

`test/FeedReplay.t.sol` shows both effects on the recorded rounds: a 4 hour bound failing on a
Saturday, and a Friday-close expiry settling 53 hours later. To replay the rounds in your own tests:

```solidity
import {MockAggregator} from "b20-test-kit/src/MockAggregator.sol";
import {FeedReplay} from "b20-test-kit/test/utils/FeedReplay.sol";

MockAggregator feed = new MockAggregator();
string memory csv = "lib/b20-test-kit/data/tsla_feed_rounds.csv";      // "data/..." inside this repo
FeedReplay.load(feed, csv, 2, SATURDAY_NOON);                          // phase 2, rounds up to that time
vm.warp(SATURDAY_NOON);                                                // now ask your contract for a price
```

The loader reads a file, so your `foundry.toml` needs read access to the folder the CSV sits in:
`fs_permissions = [{ access = "read", path = "./lib/b20-test-kit/data" }]`. It reverts if it loads
nothing, so a wrong path or phase cannot pass silently.

For another stock, read its feed and run the report (feed addresses are in the Base docs linked above):

```bash
python scripts/feed_rounds.py --feed 0x787f13dEa48Db0897CbCDD985de77809D837F988 --out data/aapl_feed_rounds.csv
python scripts/feed_gaps.py data/aapl_feed_rounds.csv
```

We ran the same two commands on the Coinbase AAPL feed on 2026-11-13 and saw the same pattern
(14 of 14 weekends silent). Only the TSLA data is checked in.

## On a local anvil fork

```bash
anvil --fork-url https://mainnet.base.org
python scripts/fork_setup.py init                                  # mock token + mock feed with 50 real rounds
python scripts/fork_setup.py mint --to 0xYourAddress --amount 500000000
python scripts/fork_setup.py warp --seconds 86400
python scripts/fork_setup.py push --price 431.25
python scripts/fork_setup.py status
```

The script only talks to a local anvil on chain 8453 and uses anvil's impersonation, never a key.

## Limits

- This is test code. It has not been audited. The mocks let anyone mint, block and pause. Do not
  deploy them to a live network.
- The live probe ran on TSLAc only. Other B20 tokens can carry different policies and decimals.
- The pause and policy behaviour of the mock comes from the docs, as the table above says.
- The feed data is a snapshot taken at Base block 57036280. The feed can change. Re-run the two
  scripts before you rely on a number.
- Tested with Foundry 1.5.1 on Windows. CI runs the tests on a fresh install of the current stable
  Foundry on Linux at every push.
- Not affiliated with Base, Coinbase or Chainlink.

## Who made this

[Kerne](https://kerne.fi). We wrote these while building a covered-call vault for TSLAc for Base Stocks
Maxxing, and they seemed more useful shared than kept. Found a difference between the mock and the real
token? Open an issue, or write to liam@kerne.fi.

MIT licence. `lib/forge-std` is vendored under its own MIT or Apache-2.0 licence.
