// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts@5.3.0/access/Ownable.sol";

import {ReadCodec} from "./libraries/ReadCodec.sol";

/// @title Reader
/// @notice Target-chain half of a cross-chain read. It receives a request from an allowlisted `ReadClient`, runs the
///         staticcall, and sends the result back over CCIP, paying the fee in native gas from its own balance.
/// @dev If the balance cannot cover the response fee, `_ccipReceive` reverts. The request message then shows as
///      failed in CCIP and can be manually re-executed once the Reader has been topped up.
contract Reader is CCIPReceiver, Ownable {
    mapping(uint64 chainSelector => address client) public clients;
    uint32 public responseGasLimit; // gas for ReadClient._ccipReceive on the source chain
    uint32 public readGasCap; // gas forwarded to the target staticcall
    uint32 public maxResultBytes; // larger results are reported as ResultTooLarge

    event ClientSet(uint64 indexed chainSelector, address client);
    event ConfigSet(uint32 responseGasLimit, uint32 readGasCap, uint32 maxResultBytes);
    event ReadExecuted(
        bytes32 indexed requestId, uint64 indexed sourceChainSelector, bool success, bytes32 ccipMessageId
    );

    error UnauthorizedClient(uint64 sourceChainSelector, address sender);
    error InsufficientBalance(uint256 required, uint256 available);
    error TransferFailed();

    /// @notice Revert data returned to the consumer when the target is not a contract.
    error TargetNotContract(address target);
    /// @notice Revert data returned to the consumer when the result exceeds `maxResultBytes`.
    error ResultTooLarge(uint256 size, uint256 max);

    constructor(address router, uint32 responseGasLimit_, uint32 readGasCap_, uint32 maxResultBytes_)
        CCIPReceiver(router)
        Ownable(msg.sender)
    {
        _setConfig(responseGasLimit_, readGasCap_, maxResultBytes_);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    function setClient(uint64 chainSelector, address client) external onlyOwner {
        clients[chainSelector] = client;
        emit ClientSet(chainSelector, client);
    }

    function setConfig(uint32 responseGasLimit_, uint32 readGasCap_, uint32 maxResultBytes_) external onlyOwner {
        _setConfig(responseGasLimit_, readGasCap_, maxResultBytes_);
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Native fee to send `response` back to `sourceChainSelector`. Useful for sizing `responseFee`.
    function quoteResponse(uint64 sourceChainSelector, uint256 resultLength) external view returns (uint256) {
        Client.EVM2AnyMessage memory message =
            _buildResponse(clients[sourceChainSelector], bytes32(0), true, new bytes(resultLength));
        return IRouterClient(getRouter()).getFee(sourceChainSelector, message);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Request leg
    // ---------------------------------------------------------------------------------------------------------------

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        address client = clients[message.sourceChainSelector];
        if (client == address(0) || sender != client) {
            revert UnauthorizedClient(message.sourceChainSelector, sender);
        }

        (bytes32 requestId, address target, bytes memory callData) = ReadCodec.decodeRequest(message.data);
        (bool success, bytes memory result) = _boundedStaticCall(target, callData);

        Client.EVM2AnyMessage memory response = _buildResponse(client, requestId, success, result);
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(message.sourceChainSelector, response);
        if (address(this).balance < fee) revert InsufficientBalance(fee, address(this).balance);

        bytes32 messageId = router.ccipSend{value: fee}(message.sourceChainSelector, response);
        emit ReadExecuted(requestId, message.sourceChainSelector, success, messageId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Staticcall that copies at most `maxResultBytes` of return data, so a target cannot burn the Reader's gas
    ///      with a huge return payload.
    function _boundedStaticCall(address target, bytes memory callData)
        internal
        view
        returns (bool success, bytes memory result)
    {
        if (target.code.length == 0) {
            return (false, abi.encodeWithSelector(TargetNotContract.selector, target));
        }

        uint256 gasCap = readGasCap;
        uint256 size;
        assembly ("memory-safe") {
            success := staticcall(gasCap, target, add(callData, 0x20), mload(callData), 0, 0)
            size := returndatasize()
        }

        uint256 max = maxResultBytes;
        if (size > max) {
            return (false, abi.encodeWithSelector(ResultTooLarge.selector, size, max));
        }

        result = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(result, 0x20), 0, size)
        }
    }

    function _buildResponse(address client, bytes32 requestId, bool success, bytes memory result)
        internal
        view
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(client),
            data: ReadCodec.encodeResponse(requestId, success, result),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: responseGasLimit, allowOutOfOrderExecution: true})
            )
        });
    }

    function _setConfig(uint32 responseGasLimit_, uint32 readGasCap_, uint32 maxResultBytes_) internal {
        responseGasLimit = responseGasLimit_;
        readGasCap = readGasCap_;
        maxResultBytes = maxResultBytes_;
        emit ConfigSet(responseGasLimit_, readGasCap_, maxResultBytes_);
    }

    /// @dev Operator top-ups for response fees.
    receive() external payable {}
}
