// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

/// @title  MockAggregator
/// @notice Chainlink-style price feed with a full round history. TEST ONLY: anyone can push rounds.
///
///         It answers `latestRoundData`, `getRoundData`, `decimals` and `description` like the proxy
///         of the Coinbase TSLA feed on Base, including two details that are easy to get wrong:
///           - a round that does not exist returns all zeros and does NOT revert (checked on the live
///             feed inside an existing phase), so a consumer walking rounds must test `updatedAt != 0`;
///           - round ids can carry a phase in the top bits, `(phase << 64) | aggregatorRound`. Use
///             `pushRound` with the real ids to replay recorded rounds exactly.
///         One difference: the mock has no notion of phases, so it returns zeros for ANY unknown id.
///         The live proxy reverts, with no data, for an id whose phase does not exist.
///
///         Storage sits in one namespaced struct, so the mock starts empty wherever it is etched,
///         including at a real feed address on a fork (the real proxy keeps data in slot 0).
contract MockAggregator {
    struct Round {
        int256 answer;
        uint64 startedAt;
        uint64 updatedAt;
    }

    struct Layout {
        uint80 latest;
        uint16 decimalsPlusOne; // 0 means "not set", which reads as 8
        mapping(uint80 => Round) rounds;
        string description;
    }

    // keccak256("b20-test-kit.MockAggregator.storage")
    bytes32 private constant SLOT = 0x44a15b562ebc54e822e11efc43ec6ddb51733bd0ebbba755920149d7f7ef9688;

    error RoundNotAfterLatest(uint80 roundId, uint80 latest);
    error TimestampBeforeLatest(uint256 updatedAt, uint256 latestUpdatedAt);
    error TimestampTooLarge(uint256 timestamp);

    function _s() private pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------ AggregatorV3Interface

    function decimals() external view returns (uint8) {
        uint16 d = _s().decimalsPlusOne;
        return d == 0 ? 8 : uint8(d - 1);
    }

    function description() external view returns (string memory) {
        Layout storage l = _s();
        return bytes(l.description).length == 0 ? "Mock feed" : l.description;
    }

    /// @notice 6, as the live Coinbase TSLA proxy reported on 2026-11-13.
    function version() external pure returns (uint256) {
        return 6;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Layout storage l = _s();
        Round storage r = l.rounds[l.latest];
        return (l.latest, r.answer, r.startedAt, r.updatedAt, l.latest);
    }

    /// @notice All zeros (apart from the id) for a round that was never pushed. No revert.
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round storage r = _s().rounds[roundId];
        return (roundId, r.answer, r.startedAt, r.updatedAt, roundId);
    }

    // ------------------------------------------------------------------ test controls (open to anyone)

    /// @notice Append a round with the next id (latest + 1) and `startedAt == updatedAt`.
    function push(int256 answer, uint256 updatedAt) external returns (uint80 roundId) {
        roundId = _s().latest + 1;
        _push(roundId, answer, updatedAt, updatedAt);
    }

    /// @notice Append a round with an explicit id, for replaying recorded rounds with their real ids.
    ///         The id must be above the latest one and the timestamp must not go backwards.
    function pushRound(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) external {
        _push(roundId, answer, startedAt, updatedAt);
    }

    function _push(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) private {
        Layout storage l = _s();
        if (updatedAt > type(uint64).max) revert TimestampTooLarge(updatedAt);
        if (startedAt > type(uint64).max) revert TimestampTooLarge(startedAt);
        if (roundId <= l.latest) revert RoundNotAfterLatest(roundId, l.latest);
        uint256 last = l.rounds[l.latest].updatedAt;
        if (updatedAt < last) revert TimestampBeforeLatest(updatedAt, last);
        l.rounds[roundId] = Round({answer: answer, startedAt: uint64(startedAt), updatedAt: uint64(updatedAt)});
        l.latest = roundId;
    }

    function mockSetMetadata(string calldata description_, uint8 decimals_) external {
        Layout storage l = _s();
        l.description = description_;
        l.decimalsPlusOne = uint16(decimals_) + 1;
    }

    function latestRound() external view returns (uint80) {
        return _s().latest;
    }
}
