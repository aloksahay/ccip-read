// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Implemented by contracts that want the result of a cross-chain read delivered to them.
interface IReadConsumer {
    /// @param requestId The id returned by `ReadClient.read`.
    /// @param success Whether the staticcall on the target chain succeeded.
    /// @param result The return data on success, or the revert data on failure.
    function onReadResult(bytes32 requestId, bool success, bytes calldata result) external;
}
