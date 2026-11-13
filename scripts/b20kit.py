"""
Shared helpers for the b20-test-kit scripts. Python 3.9+, standard library only.

Nothing here signs or sends a transaction. Every call is a read (`eth_call`, `eth_getCode`, ...).
"""
import http.client
import json
import os
import time
import urllib.error
import urllib.request

# Public Base mainnet RPCs, tried in order. All three accept `eth_call` with a state override
# (checked 2026-11-13). publicnode refuses old blocks, so pin to a recent block or use "latest".
BASE_RPCS = [
    "https://mainnet.base.org",
    "https://base-rpc.publicnode.com",
    "https://base.drpc.org",
]
CHAIN_ID = 8453

# Coinbase tokenized Tesla on Base (a B20 asset token, 8 decimals) and its Chainlink feed.
TSLAC = "0xb2000000000000000000001e800a7f5189430cD0"
TSLA_FEED = "0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"

# 4-byte selectors (keccak256 of the signature; `cast sig "<signature>"` prints the same value).
SEL = {
    "latestRoundData()": "0xfeaf968c",
    "getRoundData(uint80)": "0x9a6fc8f5",
    "decimals()": "0x313ce567",
    "description()": "0x7284e416",
    "name()": "0x06fdde03",
    "symbol()": "0x95d89b41",
    "totalSupply()": "0x18160ddd",
    "balanceOf(address)": "0x70a08231",
    "aggregate3((address,bool,bytes)[])": "0x82ad56cb",
}

# Custom errors of the real B20 token, from the Base docs (specifications/b20/reference/errors).
B20_ERRORS = {
    "0xdb42144d": "InsufficientBalance(address,uint256,uint256)",
    "0x192b9e4e": "InsufficientAllowance(address,uint256,uint256)",
    "0x4c14f64c": "InvalidSender(address)",
    "0x9cfea583": "InvalidReceiver(address)",
    "0x8bc146c4": "InvalidApprover(address)",
    "0x4e15efda": "InvalidSpender(address)",
    "0xfd8c4245": "ContractPaused(uint8)",
    "0xa43fec12": "PolicyForbids(bytes32,uint64)",
    "0xcccad523": "PolicyNotFound(uint64)",
    "0x6fb1b0e9": "NonPayable()",
    "0x82b42900": "Unauthorized()",
    "0x08c379a0": "Error(string)",
    "0x4e487b71": "Panic(uint256)",
}


class RpcError(Exception):
    def __init__(self, message, data=None):
        super().__init__(message)
        self.data = data  # revert data as a 0x string when the node returned it


def rpc(url, method, params, timeout=40, null_ok=False):
    """One JSON-RPC request. `null_ok` is for methods that answer null on success (anvil_setCode, ...)."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        url, body, {"content-type": "application/json", "user-agent": "b20-test-kit/1"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            out = json.load(res)
    except urllib.error.HTTPError as exc:
        raise RpcError(f"HTTP {exc.code} from {host(url)}") from None
    except (urllib.error.URLError, TimeoutError, OSError, http.client.HTTPException) as exc:
        raise RpcError(f"{host(url)}: {exc}") from None
    except ValueError:
        raise RpcError(f"{host(url)} did not answer with JSON") from None
    if out.get("error"):
        err = out["error"]
        data = err.get("data")
        if isinstance(data, dict):  # some nodes nest it
            data = data.get("data")
        raise RpcError(str(err.get("message", err))[:300], data if isinstance(data, str) else None)
    if out.get("result") is None and not null_ok:
        raise RpcError(f"null result from {host(url)} for {method}")
    return out.get("result")


def host(url):
    return url.split("//", 1)[-1].split("/", 1)[0]


def pick_rpc(candidates=None, need_override=False):
    """Return the first RPC that answers on Base mainnet (and, if asked, accepts a state override)."""
    env = os.environ.get("BASE_RPC")
    urls = list(candidates) if candidates else ([env] if env else list(BASE_RPCS))
    errors = []
    for url in urls:
        try:
            if int(rpc(url, "eth_chainId", []), 16) != CHAIN_ID:
                raise RpcError("not Base mainnet (chain id is not 8453)")
            if need_override:
                # 0x60016000526001601ff3 returns the single byte 0x01. If the override is honoured the
                # call to an empty address returns 0x01, otherwise it returns 0x.
                probe = "0x00000000000000000000000000000000000b20c1"
                got = rpc(url, "eth_call", [{"to": probe, "data": "0x"}, "latest",
                                            {probe: {"code": "0x60016000526001601ff3"}}])
                if got != "0x01":
                    raise RpcError("node ignored the state override")
            return url
        except RpcError as exc:
            errors.append(f"{host(url)}: {exc}")
            time.sleep(0.5)
    raise SystemExit("X no usable Base RPC:\n   " + "\n   ".join(errors))


# ---------- minimal ABI helpers (static types only, which is all the kit needs) ----------

def pad32(hex_no_0x):
    return hex_no_0x.lower().rjust(64, "0")


def enc_uint(x):
    if not 0 <= x < 1 << 256:
        raise ValueError(f"{x} does not fit in a uint256")
    return pad32(format(x, "x"))


def enc_addr(a):
    if not (isinstance(a, str) and a.startswith("0x") and len(a) == 42):
        raise ValueError(f"{a!r} is not a 20-byte address")
    int(a, 16)
    return pad32(a[2:])


def word(data_no_0x, i):
    return int(data_no_0x[i * 64:i * 64 + 64], 16)


def words(hex_str):
    h = hex_str[2:] if hex_str.startswith("0x") else hex_str
    return [int(h[i:i + 64], 16) for i in range(0, len(h) - len(h) % 64, 64)]


def dec_string(hex_str):
    h = hex_str[2:]
    off = word(h, 0) * 2
    n = int(h[off:off + 64], 16)
    return bytes.fromhex(h[off + 64:off + 64 + n * 2]).decode("utf-8", "replace")


def to_int256(x):
    return x - (1 << 256) if x >> 255 else x


def encode_aggregate3(calls):
    """calls: [(to, data_hex)], allowFailure is always true."""
    elems = []
    for to, data in calls:
        d = data[2:]
        elems.append(enc_addr(to) + enc_uint(1) + enc_uint(0x60) + enc_uint(len(d) // 2)
                     + d.ljust(-(-len(d) // 64) * 64, "0"))
    offset = len(calls) * 32
    offsets = []
    for e in elems:
        offsets.append(enc_uint(offset))
        offset += len(e) // 2
    return SEL["aggregate3((address,bool,bytes)[])"] + enc_uint(0x20) + enc_uint(len(calls)) \
        + "".join(offsets) + "".join(elems)


def decode_aggregate3(hex_str, n):
    h = hex_str[2:]

    def w(byte_off):
        return int(h[byte_off * 2:byte_off * 2 + 64], 16)

    arr = w(0)
    if w(arr) != n:
        raise RpcError("multicall returned a different number of results")
    base = arr + 32
    out = []
    for i in range(n):
        el = base + w(base + i * 32)
        data_off = el + w(el + 32)
        ln = w(data_off)
        out.append((w(el) == 1, h[(data_off + 32) * 2:(data_off + 32 + ln) * 2]))
    return out


def multicall(url, calls, block):
    """One eth_call through Multicall3 at a pinned block. Returns [(ok, data_hex_no_0x)]."""
    raw = rpc(url, "eth_call", [{"to": MULTICALL3, "data": encode_aggregate3(calls)}, block])
    return decode_aggregate3(raw, len(calls))


def explain_revert(data):
    """Name a revert from its data, using the documented B20 error list."""
    if not data or data == "0x":
        return "reverted with no data"
    sel = data[:10].lower()
    name = B20_ERRORS.get(sel)
    if name == "Error(string)":
        try:
            return "Error: " + dec_string("0x" + data[10:])
        except Exception:
            return "Error(string), undecodable"
    return f"{name or 'unknown error'} [{sel}] args={data[10:] or '-'}"


def utc(ts):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(ts))
