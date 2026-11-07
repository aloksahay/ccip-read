// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReadConsumer} from "../interfaces/IReadConsumer.sol";
import {ReadClient} from "../ReadClient.sol";

interface IERC20BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title ExampleConsumer
/// @notice Reads an ERC20 balance on another chain through ccip-read.
contract ExampleConsumer is IReadConsumer {
    struct BalanceRead {
        address token;
        address account;
        bool fulfilled;
        bool success;
        uint256 balance;
        bytes error;
    }

    ReadClient public immutable client;
    mapping(bytes32 requestId => BalanceRead) public reads;
    bytes32 public lastRequestId;

    event BalanceReceived(bytes32 indexed requestId, address token, address account, uint256 balance);
    event BalanceReadFailed(bytes32 indexed requestId, bytes error);

    error OnlyClient();
    error TransferFailed();
    error InsufficientFee(uint256 required, uint256 provided);

    constructor(ReadClient client_) {
        client = client_;
    }

    /// @notice Native fee to pass to `requestBalance`.
    function quoteBalance(uint64 dstChainSelector, address token, address account) external view returns (uint256) {
        return client.quote(dstChainSelector, token, abi.encodeCall(IERC20BalanceOf.balanceOf, (account)));
    }

    /// @notice Ask for `token.balanceOf(account)` on `dstChainSelector`. Send at least `quoteBalance(...)`. Any excess
    ///         is refunded to the caller.
    function requestBalance(uint64 dstChainSelector, address token, address account)
        external
        payable
        returns (bytes32 requestId)
    {
        bytes memory callData = abi.encodeCall(IERC20BalanceOf.balanceOf, (account));
        uint256 fee = client.quote(dstChainSelector, token, callData);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        requestId = client.read{value: fee}(dstChainSelector, token, callData);
        // Note: with the local simulator the result has already been delivered at this point, so only the result
        // fields of `reads[requestId]` are set by the callback, and these two are filled in here.
        BalanceRead storage r = reads[requestId];
        r.token = token;
        r.account = account;
        lastRequestId = requestId;

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
    }

    function onReadResult(bytes32 requestId, bool success, bytes calldata result) external override {
        if (msg.sender != address(client)) revert OnlyClient();
        BalanceRead storage r = reads[requestId];
        r.fulfilled = true;
        r.success = success;
        if (success) {
            r.balance = abi.decode(result, (uint256));
            emit BalanceReceived(requestId, r.token, r.account, r.balance);
        } else {
            r.error = result;
            emit BalanceReadFailed(requestId, result);
        }
    }
}
