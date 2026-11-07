// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts@5.3.0/access/Ownable.sol";

import {IReadConsumer} from "./interfaces/IReadConsumer.sol";
import {ReadCodec} from "./libraries/ReadCodec.sol";

/// @title ReadClient
/// @notice Source-chain entry point for cross-chain reads over CCIP (an lzRead-style pull).
/// @dev Flow: `read` sends a request to the `Reader` on the target chain. The Reader staticcalls the target and sends
///      the result back here, and `_ccipReceive` hands it to the consumer that asked.
///      The caller pays the CCIP fee for the request leg plus `responseFee`, a flat surcharge that covers the response
///      leg the Reader prepays from its own balance. The owner withdraws collected surcharges and tops up Readers.
contract ReadClient is CCIPReceiver, Ownable {
    struct Lane {
        address reader; // trusted Reader on the target chain
        uint32 requestGasLimit; // gas for Reader._ccipReceive on the target chain (staticcall + response ccipSend)
        uint256 responseFee; // native surcharge covering the response leg
    }

    struct PendingRequest {
        address consumer;
        uint64 dstChainSelector;
    }

    /// @dev Gas kept back after the consumer callback so the rest of `_ccipReceive` can finish.
    uint256 internal constant CALLBACK_RESERVE_GAS = 10_000;

    mapping(uint64 chainSelector => Lane) public lanes;
    mapping(bytes32 requestId => PendingRequest) public pending;
    uint32 public callbackGasLimit;
    uint256 public nonce;

    event LaneSet(uint64 indexed chainSelector, address reader, uint32 requestGasLimit, uint256 responseFee);
    event CallbackGasLimitSet(uint32 callbackGasLimit);
    event ReadRequested(
        bytes32 indexed requestId,
        address indexed consumer,
        uint64 indexed dstChainSelector,
        address target,
        bytes callData,
        bytes32 ccipMessageId
    );
    event ReadFulfilled(bytes32 indexed requestId, address indexed consumer, bool success, bytes result);
    event CallbackFailed(bytes32 indexed requestId, address indexed consumer, bytes reason);

    error UnsupportedLane(uint64 chainSelector);
    error InsufficientFee(uint256 required, uint256 provided);
    error UnauthorizedReader(uint64 sourceChainSelector, address sender);
    error UnknownRequest(bytes32 requestId);
    error InsufficientGasForCallback();
    error TransferFailed();

    constructor(address router, uint32 callbackGasLimit_) CCIPReceiver(router) Ownable(msg.sender) {
        callbackGasLimit = callbackGasLimit_;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------------

    function setLane(uint64 chainSelector, address reader, uint32 requestGasLimit, uint256 responseFee)
        external
        onlyOwner
    {
        lanes[chainSelector] = Lane({reader: reader, requestGasLimit: requestGasLimit, responseFee: responseFee});
        emit LaneSet(chainSelector, reader, requestGasLimit, responseFee);
    }

    function setCallbackGasLimit(uint32 callbackGasLimit_) external onlyOwner {
        callbackGasLimit = callbackGasLimit_;
        emit CallbackGasLimitSet(callbackGasLimit_);
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Total native fee for a read: the request leg's CCIP fee plus the lane's response surcharge.
    function quote(uint64 dstChainSelector, address target, bytes calldata callData)
        external
        view
        returns (uint256)
    {
        Lane memory lane = _lane(dstChainSelector);
        Client.EVM2AnyMessage memory message = _buildRequest(lane, bytes32(0), target, callData);
        return IRouterClient(getRouter()).getFee(dstChainSelector, message) + lane.responseFee;
    }

    /// @notice Request `target.staticcall(callData)` on `dstChainSelector`. The result is delivered to
    ///         `IReadConsumer(msg.sender).onReadResult` if the caller is a contract, and is always emitted in
    ///         `ReadFulfilled`. Any excess `msg.value` is refunded.
    function read(uint64 dstChainSelector, address target, bytes calldata callData)
        external
        payable
        returns (bytes32 requestId)
    {
        Lane memory lane = _lane(dstChainSelector);

        // Our own id, not the CCIP messageId: on some setups (e.g. the local simulator) the response can be delivered
        // before ccipSend returns, so the request must be recorded first.
        requestId = keccak256(abi.encode(block.chainid, address(this), nonce++));
        pending[requestId] = PendingRequest({consumer: msg.sender, dstChainSelector: dstChainSelector});

        Client.EVM2AnyMessage memory message = _buildRequest(lane, requestId, target, callData);
        IRouterClient router = IRouterClient(getRouter());
        uint256 ccipFee = router.getFee(dstChainSelector, message);
        uint256 total = ccipFee + lane.responseFee;
        if (msg.value < total) revert InsufficientFee(total, msg.value);

        bytes32 messageId = router.ccipSend{value: ccipFee}(dstChainSelector, message);
        emit ReadRequested(requestId, msg.sender, dstChainSelector, target, callData, messageId);

        uint256 refund = msg.value - total;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Response leg
    // ---------------------------------------------------------------------------------------------------------------

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        Lane memory lane = lanes[message.sourceChainSelector];
        if (lane.reader == address(0) || sender != lane.reader) {
            revert UnauthorizedReader(message.sourceChainSelector, sender);
        }

        (bytes32 requestId, bool success, bytes memory result) = ReadCodec.decodeResponse(message.data);
        PendingRequest memory req = pending[requestId];
        if (req.consumer == address(0) || req.dstChainSelector != message.sourceChainSelector) {
            revert UnknownRequest(requestId);
        }
        delete pending[requestId];

        emit ReadFulfilled(requestId, req.consumer, success, result);

        if (req.consumer.code.length == 0) return; // EOA callers read the result from the event

        // Make sure the consumer really gets `callbackGasLimit` (EIP-150 forwards at most 63/64 of what is left).
        // If not, revert so the CCIP message can be manually re-executed with more gas instead of silently
        // failing the callback.
        if (gasleft() < (uint256(callbackGasLimit) * 64) / 63 + CALLBACK_RESERVE_GAS) {
            revert InsufficientGasForCallback();
        }
        try IReadConsumer(req.consumer).onReadResult{gas: callbackGasLimit}(requestId, success, result) {}
        catch (bytes memory reason) {
            emit CallbackFailed(requestId, req.consumer, reason);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _lane(uint64 chainSelector) internal view returns (Lane memory lane) {
        lane = lanes[chainSelector];
        if (lane.reader == address(0)) revert UnsupportedLane(chainSelector);
    }

    function _buildRequest(Lane memory lane, bytes32 requestId, address target, bytes calldata callData)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(lane.reader),
            data: ReadCodec.encodeRequest(requestId, target, callData),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: lane.requestGasLimit, allowOutOfOrderExecution: true})
            )
        });
    }

    /// @dev Accepts refunds and owner top-ups.
    receive() external payable {}
}
