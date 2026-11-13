// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {SimExec} from "./SimExec.sol";

interface IERC20Probe {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice A fixed script of ERC-20 calls whose every result (return data or revert data) is recorded.
///
///         Run it twice and compare:
///           1. against the REAL token on a live node (`scripts/sim_live.py`, one `eth_call` with a
///              state override), which writes `data/tslac_live_probe.json`;
///           2. against `MockB20` in a forge test (`test/Conformance.t.sol`), which must reproduce
///              that file byte for byte.
///         That is how the mock is kept honest about the behaviour it claims to copy.
///
///         `holder`, `alice`, `bob` and `carol` must all carry `SimExec` code. `holder` must own at
///         least `amount` of the token. `alice`, `bob` and `carol` must start with a zero balance.
contract B20Probe {
    struct Result {
        bool ok;
        bytes ret; // return data on success, revert data on failure
    }

    struct In {
        address token;
        address holder;
        address alice;
        address bob;
        address carol;
        uint256 amount; // at least 1000 base units
    }

    uint256 public constant STEPS = 41;

    Result[] private _r;

    function run(In calldata i) external returns (Result[] memory) {
        require(i.amount >= 1000, "amount too small");
        IERC20Probe t = IERC20Probe(i.token);
        address tok = i.token;

        _read(tok, abi.encodeCall(t.decimals, ())); //                                           0
        _read(tok, abi.encodeCall(t.totalSupply, ())); //                                        1
        _read(tok, abi.encodeCall(t.balanceOf, (i.alice))); //                                   2  expect 0

        // plain transfers
        _as(i.holder, tok, abi.encodeCall(t.transfer, (i.alice, i.amount))); //                  3
        _read(tok, abi.encodeCall(t.balanceOf, (i.alice))); //                                   4  amount
        _as(i.alice, tok, abi.encodeCall(t.transfer, (i.bob, 0))); //                            5  zero amount
        _as(i.alice, tok, abi.encodeCall(t.transfer, (i.alice, 1))); //                          6  to self
        _read(tok, abi.encodeCall(t.balanceOf, (i.alice))); //                                   7  amount
        _as(i.alice, tok, abi.encodeCall(t.transfer, (i.bob, i.amount + 1))); //                 8  over balance
        _as(i.alice, tok, abi.encodeCall(t.transfer, (address(0), 1))); //                       9  to zero
        _as(i.alice, tok, abi.encodeCall(t.transfer, (address(0), i.amount + 1))); //            10 to zero, over balance
        _as(i.alice, tok, abi.encodeCall(t.transfer, (tok, 1))); //                              11 to the token

        // allowances
        _as(i.alice, tok, abi.encodeCall(t.approve, (i.bob, 100))); //                           12
        _read(tok, abi.encodeCall(t.allowance, (i.alice, i.bob))); //                            13 100
        _as(i.bob, tok, abi.encodeCall(t.transferFrom, (i.alice, i.carol, 40))); //              14
        _read(tok, abi.encodeCall(t.allowance, (i.alice, i.bob))); //                            15 60
        _read(tok, abi.encodeCall(t.balanceOf, (i.carol))); //                                   16 40
        _as(i.bob, tok, abi.encodeCall(t.transferFrom, (i.alice, i.carol, 61))); //              17 over allowance
        _as(i.carol, tok, abi.encodeCall(t.transferFrom, (i.alice, i.carol, 1))); //             18 no allowance
        _as(i.alice, tok, abi.encodeCall(t.transferFrom, (i.alice, i.bob, 1))); //               19 owner as spender
        _as(i.bob, tok, abi.encodeCall(t.transferFrom, (i.alice, address(0), 1))); //            20 to zero
        _as(i.bob, tok, abi.encodeCall(t.transferFrom, (i.alice, tok, 1))); //                   21 to the token
        _as(i.carol, tok, abi.encodeCall(t.transferFrom, (i.alice, address(0), 1))); //          22 to zero, no allowance
        _as(i.carol, tok, abi.encodeCall(t.transferFrom, (i.alice, i.carol, i.amount * 2))); //  23 no allowance, over balance
        _read(tok, abi.encodeCall(t.allowance, (i.alice, i.bob))); //                            24 still 60

        // unlimited allowance
        _as(i.alice, tok, abi.encodeCall(t.approve, (i.bob, type(uint256).max))); //             25
        _as(i.bob, tok, abi.encodeCall(t.transferFrom, (i.alice, i.carol, 10))); //              26
        _read(tok, abi.encodeCall(t.allowance, (i.alice, i.bob))); //                            27 is max spent?
        _as(i.bob, tok, abi.encodeCall(t.transferFrom, (i.alice, i.carol, i.amount))); //        28 over balance
        _as(i.alice, tok, abi.encodeCall(t.approve, (i.bob, 0))); //                             29
        _read(tok, abi.encodeCall(t.allowance, (i.alice, i.bob))); //                            30 0
        _as(i.alice, tok, abi.encodeCall(t.approve, (address(0), 1))); //                        31 zero spender

        // edges
        _as(i.alice, tok, abi.encodeCall(t.transferFrom, (address(0), i.bob, 0))); //            32 from zero, amount 0
        _as(i.alice, tok, abi.encodeCall(t.transferFrom, (address(0), i.bob, 1))); //            33 from zero, amount 1
        _as(i.alice, tok, abi.encodeCall(t.transferFrom, (address(0), address(0), 1))); //       34 from zero, to zero
        _as(i.alice, tok, hex"deadbeef"); //                                                     35 unknown selector
        _as(i.alice, tok, ""); //                                                                36 empty calldata
        _as(i.alice, tok, hex"de"); //                                                           37 one byte of calldata

        // end state
        _read(tok, abi.encodeCall(t.balanceOf, (i.alice))); //                                   38 amount - 50
        _read(tok, abi.encodeCall(t.balanceOf, (i.carol))); //                                   39 50
        _read(tok, abi.encodeCall(t.totalSupply, ())); //                                        40 unchanged

        Result[] memory out = _r;
        require(out.length == STEPS, "step count");
        return out;
    }

    function _as(address who, address target, bytes memory data) private {
        try SimExec(who).exec(target, data) returns (bytes memory ret) {
            _r.push(Result({ok: true, ret: ret}));
        } catch (bytes memory err) {
            _r.push(Result({ok: false, ret: err}));
        }
    }

    function _read(address target, bytes memory data) private {
        (bool ok, bytes memory ret) = target.staticcall(data);
        _r.push(Result({ok: ok, ret: ret}));
    }
}
