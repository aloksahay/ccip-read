// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ReadCodec
/// @notice Wire format for the two CCIP legs of a cross-chain read.
library ReadCodec {
    /// @dev Source -> target: "staticcall `target` with `callData` and send me the result".
    function encodeRequest(bytes32 requestId, address target, bytes memory callData)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(requestId, target, callData);
    }

    function decodeRequest(bytes memory data)
        internal
        pure
        returns (bytes32 requestId, address target, bytes memory callData)
    {
        return abi.decode(data, (bytes32, address, bytes));
    }

    /// @dev Target -> source: the outcome of the staticcall. On failure `result` holds the revert data.
    function encodeResponse(bytes32 requestId, bool success, bytes memory result)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(requestId, success, result);
    }

    function decodeResponse(bytes memory data)
        internal
        pure
        returns (bytes32 requestId, bool success, bytes memory result)
    {
        return abi.decode(data, (bytes32, bool, bytes));
    }
}
