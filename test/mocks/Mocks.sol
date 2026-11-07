// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReadConsumer} from "../../src/interfaces/IReadConsumer.sol";
import {ReadClient} from "../../src/ReadClient.sol";

/// @dev Minimal token exposing `balanceOf`, the read target in the tests.
contract MockToken {
    mapping(address => uint256) internal balances;

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }
}

/// @dev Read targets that misbehave.
contract BadTarget {
    error Nope(uint256 code);

    function boom() external pure returns (uint256) {
        revert Nope(42);
    }

    function huge(uint256 size) external pure returns (bytes memory) {
        return new bytes(size);
    }
}

/// @dev Generic consumer that records the last result and can be told to fail in its callback.
contract RecordingConsumer is IReadConsumer {
    enum Mode {
        Ok,
        Revert,
        BurnGas
    }

    ReadClient public immutable client;
    Mode public mode;

    bytes32 public lastRequestId;
    bool public lastSuccess;
    bytes public lastResult;
    uint256 public callbacks;

    constructor(ReadClient client_) {
        client = client_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function doRead(uint64 dst, address target, bytes calldata callData) external payable returns (bytes32) {
        return client.read{value: msg.value}(dst, target, callData);
    }

    function onReadResult(bytes32 requestId, bool success, bytes calldata result) external {
        require(msg.sender == address(client), "only client");
        if (mode == Mode.Revert) revert("consumer says no");
        if (mode == Mode.BurnGas) {
            while (true) {}
        }
        lastRequestId = requestId;
        lastSuccess = success;
        lastResult = result;
        callbacks++;
    }

    receive() external payable {}
}
