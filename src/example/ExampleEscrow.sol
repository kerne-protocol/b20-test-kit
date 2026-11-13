// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice The smallest contract that holds a B20 token: deposit pulls it in, withdraw sends it back.
///         It stands in for "your contract" in the examples. Not for production use.
contract ExampleEscrow {
    IERC20Min public immutable token;
    mapping(address => uint256) public deposited;

    constructor(address token_) {
        token = IERC20Min(token_);
    }

    function deposit(uint256 amount) external {
        deposited[msg.sender] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    }

    function withdraw(uint256 amount) external {
        deposited[msg.sender] -= amount; // reverts on underflow
        require(token.transfer(msg.sender, amount), "transfer failed");
    }
}
