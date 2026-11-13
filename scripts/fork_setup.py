#!/usr/bin/env python3
"""
Prepare a LOCAL anvil fork of Base for work with a tokenized stock. Python 3.9+, standard library only.

Stock anvil cannot execute the B20 precompile, so this puts the kit's mocks where the real things live:
  - MockB20 at the token address (starts empty; mint what you need)
  - MockAggregator at the Chainlink feed address, seeded with the feed's own last rounds (same round
    ids, prices and timestamps), so you can push the next price yourself
Everything else on the fork (your contracts, USDC, pools) is the real mainnet state.

  anvil --fork-url https://mainnet.base.org --port 8545
  python scripts/fork_setup.py init                       # etch both mocks, seed 50 real rounds
  python scripts/fork_setup.py mint --to 0xYou --amount 500000000      # 5.0 TSLAc (8 decimals)
  python scripts/fork_setup.py warp --seconds 86400
  python scripts/fork_setup.py push --price 431.25        # a new round at the fork's current time
  python scripts/fork_setup.py status

It refuses anything that is not a local anvil on chain 8453. It uses anvil's impersonation, so it
never needs a private key.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import b20kit as K  # noqa: E402

SENDER = "0x00000000000000000000000000000000b20f04c0"  # impersonated, funded on the fork only


def artifact(sol, name):
    path = os.path.join(ROOT, "out", sol, f"{name}.json")
    if not os.path.exists(path):
        try:
            subprocess.run(["forge", "build"], cwd=ROOT, check=True, capture_output=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            sys.exit(f"X {path} is missing and `forge build` did not work. Build the kit first.")
    with open(path, encoding="utf-8") as f:
        art = json.load(f)
    return art["deployedBytecode"]["object"], art["methodIdentifiers"]


def enc_string(s):
    b = s.encode()
    return K.enc_uint(len(b)) + b.hex().ljust(-(-len(b) // 32) * 64, "0")


def send(url, to, data):
    K.rpc(url, "anvil_impersonateAccount", [SENDER], null_ok=True)
    K.rpc(url, "anvil_setBalance", [SENDER, hex(10 ** 18)], null_ok=True)
    h = K.rpc(url, "eth_sendTransaction", [{"from": SENDER, "to": to, "data": data, "gas": hex(1_000_000)}])
    for _ in range(100):
        rc = K.rpc(url, "eth_getTransactionReceipt", [h], null_ok=True)
        if rc is None:
            time.sleep(0.1)
            continue
        if int(rc["status"], 16) != 1:
            sys.exit(f"X fork transaction reverted: {h}")
        return
    sys.exit(f"X no receipt for {h}; is anvil mining? (do not start it with --no-mining)")


def call(url, to, data):
    return K.rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])


def chain_now(url):
    return int(K.rpc(url, "eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def feed_latest(url, feed):
    w = K.words(call(url, feed, K.SEL["latestRoundData()"]))
    return w[0], K.to_int256(w[1]), w[3]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rpc", default="http://127.0.0.1:8545")
    ap.add_argument("--token", default=K.TSLAC)
    ap.add_argument("--feed", default=K.TSLA_FEED)
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("init")
    i.add_argument("--rounds", type=int, default=50, help="real rounds to copy into the mock feed")
    i.add_argument("--name", default="Tesla Inc.")
    i.add_argument("--symbol", default="TSLAc")
    i.add_argument("--decimals", type=int, default=8)
    m = sub.add_parser("mint")
    m.add_argument("--to", required=True)
    m.add_argument("--amount", type=int, required=True, help="base units")
    p = sub.add_parser("push")
    p.add_argument("--price", type=float, required=True)
    p.add_argument("--at", type=int, default=None, help="unix time (default: the fork's current time)")
    w = sub.add_parser("warp")
    w.add_argument("--seconds", type=int, required=True)
    sub.add_parser("status")
    a = ap.parse_args()

    url = a.rpc
    if not (url.startswith("http://127.0.0.1:") or url.startswith("http://localhost:")):
        sys.exit("X local anvil only (http://127.0.0.1:<port>)")
    try:
        client = K.rpc(url, "web3_clientVersion", [])
        chain = int(K.rpc(url, "eth_chainId", []), 16)
    except K.RpcError as exc:
        sys.exit(f"X nothing answers at {url}: {exc}")
    if "anvil" not in client.lower() or chain != K.CHAIN_ID:
        sys.exit(f"X not an anvil fork of Base mainnet: {client}, chain {chain}")

    token_code, token_ids = artifact("MockB20.sol", "MockB20")
    feed_code, feed_ids = artifact("MockAggregator.sol", "MockAggregator")
    is_mock_token = K.rpc(url, "eth_getCode", [a.token, "latest"]).lower() == token_code.lower()
    is_mock_feed = K.rpc(url, "eth_getCode", [a.feed, "latest"]).lower() == feed_code.lower()

    if a.cmd == "init":
        if is_mock_token or is_mock_feed:
            sys.exit("X this fork is already initialised (the mocks are in place)")
        if a.rounds < 1:
            sys.exit("X --rounds must be 1 or more")
        dec = int(call(url, a.feed, K.SEL["decimals()"]), 16)
        desc = K.dec_string(call(url, a.feed, K.SEL["description()"]))
        latest, _, _ = feed_latest(url, a.feed)
        n = min(a.rounds, latest & ((1 << 64) - 1))
        rounds = []
        for rid in range(latest - n + 1, latest + 1):  # the REAL feed, read through the fork
            r = K.words(call(url, a.feed, K.SEL["getRoundData(uint80)"] + K.enc_uint(rid)))
            if r[3] == 0:
                sys.exit(f"X the real feed has no round {rid}")
            rounds.append((rid, r[1], r[2], r[3]))

        K.rpc(url, "anvil_setCode", [a.token, token_code], null_ok=True)
        K.rpc(url, "anvil_setCode", [a.feed, feed_code], null_ok=True)
        send(url, a.token, "0x" + token_ids["mockSetMetadata(string,string,uint8)"]
             + K.enc_uint(0x60) + K.enc_uint(0x60 + len(enc_string(a.name)) // 2) + K.enc_uint(a.decimals)
             + enc_string(a.name) + enc_string(a.symbol))
        send(url, a.feed, "0x" + feed_ids["mockSetMetadata(string,uint8)"]
             + K.enc_uint(0x40) + K.enc_uint(dec) + enc_string(desc))
        for rid, ans, started, updated in rounds:
            send(url, a.feed, "0x" + feed_ids["pushRound(uint80,int256,uint256,uint256)"]
                 + K.enc_uint(rid) + K.enc_uint(ans) + K.enc_uint(started) + K.enc_uint(updated))
        rid, ans, upd = feed_latest(url, a.feed)
        if (rid, ans, upd) != (rounds[-1][0], K.to_int256(rounds[-1][1]), rounds[-1][3]):
            sys.exit("X the mock feed does not read back the last real round")
        if int(call(url, a.token, K.SEL["totalSupply()"]), 16) != 0:
            sys.exit("X the mock token did not start empty")
        print(f"fork ready on {url}")
        print(f"   mock token at {a.token}: {a.symbol}, {a.decimals} decimals, supply 0 (use `mint`)")
        print(f"   mock feed  at {a.feed}: \"{desc}\", {n} real rounds copied, "
              f"last {ans / 10 ** dec:.4f} at {K.utc(upd)} UTC")
        return 0

    if a.cmd == "status":
        print(f"{client}, chain {chain}, fork time {K.utc(chain_now(url))} UTC")
        print(f"   token {a.token}: {'MockB20' if is_mock_token else 'NOT the mock (run init)'}")
        print(f"   feed  {a.feed}: {'MockAggregator' if is_mock_feed else 'the real feed (run init to replace it)'}")
        if is_mock_token:
            print(f"   token supply: {int(call(url, a.token, K.SEL['totalSupply()']), 16)} base units")
        rid, ans, upd = feed_latest(url, a.feed)
        print(f"   feed latest: round {rid}, answer {ans}, updated {K.utc(upd)} UTC, "
              f"{chain_now(url) - upd} s old on the fork")
        return 0

    if a.cmd == "warp":
        K.rpc(url, "evm_increaseTime", [a.seconds], null_ok=True)
        K.rpc(url, "evm_mine", [], null_ok=True)
        print(f"fork time is now {K.utc(chain_now(url))} UTC")
        return 0

    if a.cmd == "mint":
        if not is_mock_token:
            sys.exit("X the token is not the mock yet; run `init` first")
        send(url, a.token, "0x" + token_ids["mockMint(address,uint256)"] + K.enc_addr(a.to) + K.enc_uint(a.amount))
        bal = int(call(url, a.token, K.SEL["balanceOf(address)"] + K.enc_addr(a.to)), 16)
        print(f"minted {a.amount} base units; {a.to} now holds {bal}")
        return 0

    if a.cmd == "push":
        if not is_mock_feed:
            sys.exit("X the feed is not the mock yet; run `init` first")
        if a.price <= 0:
            sys.exit("X --price must be above zero")
        dec = int(call(url, a.feed, K.SEL["decimals()"]), 16)
        at = a.at if a.at is not None else chain_now(url)
        send(url, a.feed, "0x" + feed_ids["push(int256,uint256)"]
             + K.enc_uint(int(round(a.price * 10 ** dec))) + K.enc_uint(at))
        rid, ans, upd = feed_latest(url, a.feed)
        print(f"pushed round {rid}: {ans / 10 ** dec:.4f} at {K.utc(upd)} UTC")
        return 0


if __name__ == "__main__":
    sys.exit(main())
