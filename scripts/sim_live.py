#!/usr/bin/env python3
"""
Run contracts against the REAL B20 precompile on Base mainnet, in ONE read-only `eth_call`.

Why: a B20 token (every Coinbase tokenized stock) is a precompile inside the Base node. It has no
bytecode, so a stock Foundry fork cannot execute it. A live node can. `eth_call` takes a state
override that swaps the code at chosen addresses for that one call, so a script of many steps, each
made AS a different address, runs against the real token and the real chain state. Nothing is signed,
nothing is sent, nothing changes on chain.

  python scripts/sim_live.py probe                    # ERC-20 behaviour probe on TSLAc, 41 steps
  python scripts/sim_live.py probe --write-fixture    # also rewrite data/tslac_live_probe.json
  python scripts/sim_live.py escrow                   # example: deploy a contract INSIDE the call and use it
  python scripts/sim_live.py probe --token 0x... --holder 0x...   # another B20 token

Needs: Python 3.9+ (standard library only) and `forge` on PATH (any version; it only compiles).
Set BASE_RPC to use your own node.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import b20kit as K  # noqa: E402

# Addresses the simulation acts as. They only need to be unused on mainnet.
ORCH = "0x00000000000000000000000000000000b20c0de0"   # the orchestrator contract is placed here
ALICE = "0x00000000000000000000000000000000b20a11ce"
BOB = "0x00000000000000000000000000000000b20b0b00"
CAROL = "0x00000000000000000000000000000000b20ca401"
# Any current holder works: its code is swapped for the length of the call so it can "send" tokens.
# This is the USDC/TSLAc pool that held the most TSLAc on 2026-11-13.
DEFAULT_HOLDER = "0x7a33000372f3f028f074182ccb9d16cbeefbf920"

PROBE_LABELS = [
    "decimals()",
    "totalSupply() before",
    "balanceOf(alice) before",
    "holder: transfer(alice, amount)",
    "balanceOf(alice)",
    "alice: transfer(bob, 0)",
    "alice: transfer(alice, 1)  to self",
    "balanceOf(alice)",
    "alice: transfer(bob, amount + 1)  over balance",
    "alice: transfer(address(0), 1)",
    "alice: transfer(address(0), amount + 1)  over balance too",
    "alice: transfer(token, 1)",
    "alice: approve(bob, 100)",
    "allowance(alice, bob)",
    "bob: transferFrom(alice, carol, 40)",
    "allowance(alice, bob)",
    "balanceOf(carol)",
    "bob: transferFrom(alice, carol, 61)  over allowance",
    "carol: transferFrom(alice, carol, 1)  no allowance",
    "alice: transferFrom(alice, bob, 1)  owner as spender",
    "bob: transferFrom(alice, address(0), 1)",
    "bob: transferFrom(alice, token, 1)",
    "carol: transferFrom(alice, address(0), 1)  no allowance too",
    "carol: transferFrom(alice, carol, 2 x amount)  no allowance, over balance",
    "allowance(alice, bob)  unchanged by the failures",
    "alice: approve(bob, max)",
    "bob: transferFrom(alice, carol, 10)",
    "allowance(alice, bob)  after spending from max",
    "bob: transferFrom(alice, carol, amount)  max allowance, over balance",
    "alice: approve(bob, 0)",
    "allowance(alice, bob)",
    "alice: approve(address(0), 1)",
    "alice: transferFrom(address(0), bob, 0)",
    "alice: transferFrom(address(0), bob, 1)",
    "alice: transferFrom(address(0), address(0), 1)",
    "alice: call with unknown selector 0xdeadbeef",
    "alice: call with empty calldata",
    "alice: call with one byte of calldata 0xde",
    "balanceOf(alice) at the end",
    "balanceOf(carol) at the end",
    "totalSupply() at the end",
]
LAST = len(PROBE_LABELS) - 1


def artifact(sol, name):
    path = os.path.join(ROOT, "out", sol, f"{name}.json")
    if not os.path.exists(path):
        sys.exit(f"X {path} is missing. Run `forge build` in {ROOT} first.")
    with open(path, encoding="utf-8") as f:
        art = json.load(f)
    return art["deployedBytecode"]["object"], art["methodIdentifiers"]


def build():
    try:
        subprocess.run(["forge", "build"], cwd=ROOT, check=True, capture_output=True)
    except FileNotFoundError:
        sys.exit("X `forge` is not on PATH. Install Foundry, or run `forge build` yourself first.")
    except subprocess.CalledProcessError as exc:
        sys.exit("X forge build failed:\n" + exc.stderr.decode("utf-8", "replace")[-2000:])


def describe(ok, ret):
    if not ok:
        return "REVERT  " + K.explain_revert("0x" + ret)
    if len(ret) == 64:
        return f"ok      {int(ret, 16)}"
    return "ok      0x" + (ret if len(ret) <= 72 else ret[:72] + "...")


def setup(a):
    if not a.no_build:
        build()
    url = K.pick_rpc([a.rpc] if a.rpc else None, need_override=True)
    token = a.token
    code = K.rpc(url, "eth_getCode", [token, "latest"])
    sym = K.dec_string(K.rpc(url, "eth_call", [{"to": token, "data": K.SEL["symbol()"]}, "latest"]))
    dec = int(K.rpc(url, "eth_call", [{"to": token, "data": K.SEL["decimals()"]}, "latest"]), 16)
    blk = K.rpc(url, "eth_getBlockByNumber", ["latest", False])
    block = blk["number"]

    def bal(who):
        return int(K.rpc(url, "eth_call", [{"to": token, "data": K.SEL["balanceOf(address)"] + K.enc_addr(who)},
                                           block]), 16)

    if bal(a.holder) < a.amount:
        sys.exit(f"X holder {a.holder} has {bal(a.holder)} base units, fewer than --amount {a.amount}. "
                 "Pick another holder with --holder.")
    for name, who in (("alice", ALICE), ("bob", BOB), ("carol", CAROL)):
        if bal(who) != 0:
            sys.exit(f"X the stand-in address for {name} already holds the token; edit the constants")
    print(f"node {K.host(url)}, block {int(block, 16)} ({K.utc(int(blk['timestamp'], 16))} UTC)")
    print(f"token {token} {sym}, {dec} decimals, eth_getCode = {code} "
          f"({'a precompile marker, not contract bytecode' if len(code) <= 6 else 'contract bytecode'})")
    return url, block, blk, sym, dec, code


def cmd_probe(a):
    url, block, blk, sym, dec, code = setup(a)
    exec_code, _ = artifact("SimExec.sol", "SimExec")
    probe_code, ids = artifact("B20Probe.sol", "B20Probe")
    selector = next(v for k, v in ids.items() if k.startswith("run("))
    data = "0x" + selector + "".join([K.enc_addr(a.token), K.enc_addr(a.holder), K.enc_addr(ALICE),
                                      K.enc_addr(BOB), K.enc_addr(CAROL), K.enc_uint(a.amount)])
    override = {ORCH: {"code": probe_code}}
    for who in (a.holder, ALICE, BOB, CAROL):
        override[who] = {"code": exec_code}
    try:
        raw = K.rpc(url, "eth_call", [{"from": ALICE, "to": ORCH, "data": data, "gas": hex(8_000_000)},
                                      block, override])
    except K.RpcError as exc:
        sys.exit(f"X the simulation reverted: {exc} {K.explain_revert(exc.data) if exc.data else ''}")
    res = K.decode_aggregate3(raw, len(PROBE_LABELS))
    print(f"\nprobe on the live token, amount {a.amount} base units, holder {a.holder}\n")
    for i, (label, (ok, ret)) in enumerate(zip(PROBE_LABELS, res)):
        print(f"  {i:>2}  {label:<62} {describe(ok, ret)}")

    fixture = {
        "note": "Written by scripts/sim_live.py probe --write-fixture. Results of src/sim/B20Probe.sol "
                "run against the live token in one eth_call. test/Conformance.t.sol replays the same "
                "probe on MockB20 and requires identical bytes.",
        "chain_id": K.CHAIN_ID, "block_number": int(block, 16), "block_hash": blk["hash"],
        "block_time_utc": K.utc(int(blk["timestamp"], 16)), "rpc_host": K.host(url),
        "token": a.token, "symbol": sym, "decimals": dec, "eth_getCode": code,
        "holder": a.holder, "alice": ALICE, "bob": BOB, "carol": CAROL, "amount": str(a.amount),
        "steps": [{"i": i, "label": label, "ok": ok, "ret": "0x" + ret}
                  for i, (label, (ok, ret)) in enumerate(zip(PROBE_LABELS, res))],
    }
    path = os.path.join(ROOT, "data", "tslac_live_probe.json") if a.fixture is None else a.fixture
    if a.write_fixture:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(fixture, f, indent=2)
            f.write("\n")
        print(f"\nwrote {path}")
    elif os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            old = json.load(f)
        same_inputs = all(str(old.get(k)).lower() == str(fixture[k]).lower()
                          for k in ("token", "holder", "alice", "bob", "carol", "amount"))
        if same_inputs:
            # totalSupply moves as shares are minted and redeemed, so the two totalSupply steps are compared to each other.
            skip = {1, LAST}
            diff = [s["i"] for s, o in zip(fixture["steps"], old["steps"])
                    if s["i"] not in skip and (s["ok"], s["ret"]) != (o["ok"], o["ret"])]
            if diff:
                print(f"\nDIFFERENT from the checked-in fixture at steps {diff}. The live token may have "
                      "changed behaviour. Re-run with --write-fixture and re-run `forge test`.")
                return 1
            print(f"\nidentical to the checked-in fixture (block {old['block_number']}) on every step "
                  "except totalSupply, which moves with mints and redemptions.")
    if fixture["steps"][1]["ret"] != fixture["steps"][LAST]["ret"]:
        print("X totalSupply changed during the probe")
        return 1
    print("Nothing was signed or sent.")
    return 0


def cmd_escrow(a):
    url, block, blk, sym, dec, code = setup(a)
    exec_code, _ = artifact("SimExec.sol", "SimExec")
    sim_code, ids = artifact("EscrowSim.sol", "EscrowSim")
    selector = next(v for k, v in ids.items() if k.startswith("run("))
    data = "0x" + selector + "".join([K.enc_addr(a.token), K.enc_addr(a.holder), K.enc_addr(ALICE),
                                      K.enc_uint(a.amount)])
    override = {ORCH: {"code": sim_code}, a.holder: {"code": exec_code}, ALICE: {"code": exec_code}}
    try:
        raw = K.rpc(url, "eth_call", [{"from": ALICE, "to": ORCH, "data": data, "gas": hex(8_000_000)},
                                      block, override])
    except K.RpcError as exc:
        sys.exit(f"X the simulation reverted: {exc} {K.explain_revert(exc.data) if exc.data else ''}")
    w = K.words(raw)
    keys = ["escrow deployed inside the call (address as a number)", "alice balance after funding",
            "escrow balance after deposit", "alice deposit recorded", "second withdraw reverted (1 = yes)",
            "alice balance after withdraw", "escrow balance after withdraw"]
    want = [None, a.amount, a.amount, a.amount, 1, a.amount, 0]
    fails = 0
    print(f"\nexample: ExampleEscrow deployed and used inside one eth_call against live {sym}\n")
    for k, got, exp in zip(keys, w, want):
        if exp is None:
            print(f"   [ok ] {k}: 0x{got:040x}")
            continue
        ok = got == exp
        fails += not ok
        print(f"   [{'ok ' if ok else 'FAIL'}] {k}: {got}" + ("" if ok else f"  (expected {exp})"))
    if fails:
        print(f"\n{fails} check(s) failed")
        return 1
    print("\nAll checks passed against the live precompile. Nothing was signed or sent.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["probe", "escrow"])
    ap.add_argument("--token", default=K.TSLAC)
    ap.add_argument("--holder", default=DEFAULT_HOLDER)
    ap.add_argument("--amount", type=int, default=1_000_000, help="base units to move (default 0.01 TSLAc)")
    ap.add_argument("--rpc", default=None)
    ap.add_argument("--write-fixture", action="store_true")
    ap.add_argument("--fixture", default=None, help="fixture path (default data/tslac_live_probe.json)")
    ap.add_argument("--no-build", action="store_true", help="skip `forge build`")
    a = ap.parse_args()
    return cmd_probe(a) if a.cmd == "probe" else cmd_escrow(a)


if __name__ == "__main__":
    sys.exit(main())
