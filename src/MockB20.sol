// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

/// @title  MockB20
/// @notice Test stand-in for the ERC-20 surface of a Base B20 token, such as a Coinbase tokenized
///         stock. TEST ONLY: anyone can mint, burn, block and pause. Never deploy it to a live network.
///
///         Real B20 tokens are precompiles inside the Base node. They have no bytecode
///         (`eth_getCode` returns the marker `0xef`), so a stock Foundry fork cannot execute them.
///         Etch this contract at the token's address and a fork or a unit test can.
///
///         What is copied from the real token, and how it was checked:
///           - CHECKED LIVE. `test/Conformance.t.sol` replays `data/tslac_live_probe.json`, the recorded
///             results of 41 calls against the real TSLAc precompile, and requires this mock to return
///             the same bytes: return values, the custom errors with their arguments, the order of
///             the checks, an unlimited allowance that is never spent down, and the 4-byte revert
///             for an unknown selector.
///           - FROM THE DOCS, NOT CHECKED LIVE. The pause switch and the policy block
///             (`ContractPaused`, `PolicyForbids`) and where they sit in the order of checks follow
///             the natspec of Base's `IB20.sol`. Nobody outside the issuer can pause or block on the
///             real token, so these two paths could not be observed.
///
///         What is NOT here: memo transfers, permit, roles, mint and burn with roles, seizure, the
///         UI multiplier (`uiMultiplier`, `balanceOfUI`, ...), the policy registry, and events other
///         than `Transfer` and `Approval`. For the full reference implementation use Base's own
///         `base-std` mocks or `base-anvil`.
///
///         Known differences from the real token, all on malformed or unusual calls:
///           - a known selector with truncated arguments reverts with empty data here, and with the
///             4-byte selector on the real token;
///           - `isPaused` with a value above 3 returns false here and reverts on the real token;
///           - `policyId` with an unknown scope returns the mock's id here and reverts on the real token;
///           - a call that carries ETH reverts with empty data here (the docs list `NonPayable()`).
///
///         Storage sits in one namespaced struct, so the mock starts empty wherever it is etched,
///         including at a real token address on a fork.
contract MockB20 {
    // Same names, arguments and selectors as the real token (Base docs, B20 reference, errors).
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error InvalidSender(address sender);
    error InvalidReceiver(address receiver);
    error InvalidSpender(address spender);
    error ContractPaused(uint8 feature);
    error PolicyForbids(bytes32 policyScope, uint64 policyId);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // keccak256 of the scope names, as listed in the Base docs (B20 reference, constants).
    bytes32 public constant TRANSFER_SENDER_POLICY = 0xb81736c875ab819dd97f59f2a6542cfb731ad52b4ae15a6f24df2fb02b0327f5;
    bytes32 public constant TRANSFER_RECEIVER_POLICY =
        0x8a4b3fa2d8b921852bc0089c6ef0958aa6961897be36fd731330fe2cd23f8363;
    bytes32 public constant TRANSFER_EXECUTOR_POLICY =
        0x10be5173aff2a44e748bd9acd8b19fe34689581398a9db7ba2fb671e786ff7d8;
    uint8 internal constant FEATURE_TRANSFER = 0; // PausableFeature.TRANSFER in IB20.sol

    struct Layout {
        uint256 totalSupply;
        mapping(address => uint256) balanceOf;
        mapping(address => mapping(address => uint256)) allowance;
        mapping(address => bool) blocked;
        bool transfersPaused;
        uint64 policyId;
        uint16 decimalsPlusOne; // 0 means "not set", which reads as 8
        string name;
        string symbol;
    }

    // keccak256("b20-test-kit.MockB20.storage")
    bytes32 private constant SLOT = 0x62bb631ff7525c5884df16daed70f3da91debc502ce0c8f50a222fd3dac0abfc;

    function _s() private pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }

    // ------------------------------------------------------------------ ERC-20 reads

    function name() external view returns (string memory) {
        Layout storage l = _s();
        return bytes(l.name).length == 0 ? "Mock B20" : l.name;
    }

    function symbol() external view returns (string memory) {
        Layout storage l = _s();
        return bytes(l.symbol).length == 0 ? "mB20" : l.symbol;
    }

    /// @notice 8 unless set. Every Coinbase tokenized stock read so far reports 8.
    function decimals() external view returns (uint8) {
        uint16 d = _s().decimalsPlusOne;
        return d == 0 ? 8 : uint8(d - 1);
    }

    function totalSupply() external view returns (uint256) {
        return _s().totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _s().balanceOf[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _s().allowance[owner][spender];
    }

    // ------------------------------------------------------------------ ERC-20 writes

    /// @notice Not gated by pause or by policy, as on the real token.
    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender(spender);
        _s().allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        Layout storage l = _s();
        if (l.transfersPaused) revert ContractPaused(FEATURE_TRANSFER);
        if (to == address(0) || to == address(this)) revert InvalidReceiver(to);
        if (msg.sender == address(0)) revert InvalidSender(msg.sender); // only reachable in a simulation
        _policy(l, msg.sender, msg.sender, to);
        _move(l, msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        Layout storage l = _s();
        if (l.transfersPaused) revert ContractPaused(FEATURE_TRANSFER);
        if (to == address(0) || to == address(this)) revert InvalidReceiver(to);
        if (from == address(0)) revert InvalidSender(from);
        uint256 allowed = l.allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
        _policy(l, msg.sender, from, to);
        uint256 bal = l.balanceOf[from];
        if (bal < amount) revert InsufficientBalance(from, bal, amount);
        // An unlimited allowance is never spent down (checked live).
        if (allowed != type(uint256).max) l.allowance[from][msg.sender] = allowed - amount;
        _move(l, from, to, amount);
        return true;
    }

    function _policy(Layout storage l, address executor, address from, address to) private view {
        if (l.blocked[executor]) revert PolicyForbids(TRANSFER_EXECUTOR_POLICY, l.policyId);
        if (l.blocked[from]) revert PolicyForbids(TRANSFER_SENDER_POLICY, l.policyId);
        if (l.blocked[to]) revert PolicyForbids(TRANSFER_RECEIVER_POLICY, l.policyId);
    }

    function _move(Layout storage l, address from, address to, uint256 amount) private {
        uint256 bal = l.balanceOf[from];
        if (bal < amount) revert InsufficientBalance(from, bal, amount);
        unchecked {
            l.balanceOf[from] = bal - amount;
        }
        l.balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    // ------------------------------------------------------------------ B20 reads a consumer may use

    /// @notice `feature` 0 is TRANSFER. The mock only models the transfer pause.
    function isPaused(uint8 feature) external view returns (bool) {
        return feature == FEATURE_TRANSFER && _s().transfersPaused;
    }

    /// @notice The policy id reported in `PolicyForbids`. The real TSLAc reported 5 for all three
    ///         transfer scopes on 2026-11-13. The mock keeps one id for every scope.
    function policyId(bytes32) external view returns (uint64) {
        return _s().policyId;
    }

    // ------------------------------------------------------------------ test controls (open to anyone)

    function mockMint(address to, uint256 amount) external {
        Layout storage l = _s();
        l.totalSupply += amount;
        l.balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function mockBurn(address from, uint256 amount) external {
        Layout storage l = _s();
        uint256 bal = l.balanceOf[from];
        if (bal < amount) revert InsufficientBalance(from, bal, amount);
        unchecked {
            l.balanceOf[from] = bal - amount;
            l.totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /// @notice A blocked account cannot send, receive or execute a transfer (a blocklist policy).
    function mockSetBlocked(address account, bool isBlocked) external {
        _s().blocked[account] = isBlocked;
    }

    function mockIsBlocked(address account) external view returns (bool) {
        return _s().blocked[account];
    }

    function mockSetPolicyId(uint64 id) external {
        _s().policyId = id;
    }

    /// @notice Pauses `transfer` and `transferFrom`. `approve` keeps working, as on the real token.
    function mockSetPaused(bool paused) external {
        _s().transfersPaused = paused;
    }

    function mockSetMetadata(string calldata name_, string calldata symbol_, uint8 decimals_) external {
        Layout storage l = _s();
        l.name = name_;
        l.symbol = symbol_;
        l.decimalsPlusOne = uint16(decimals_) + 1;
    }

    // ------------------------------------------------------------------ unknown calls

    /// @dev The real token answers an unknown selector by reverting with that selector as the
    ///      revert data (4 bytes), and with 0x00000000 when the calldata is shorter than 4 bytes.
    fallback() external {
        assembly {
            mstore(0, 0)
            if iszero(lt(calldatasize(), 4)) { mstore(0, calldataload(0)) }
            revert(0, 4)
        }
    }
}
