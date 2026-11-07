// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {CCIPLocalSimulator} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {CCIPLocalRouter} from "@chainlink/local/src/ccip/CCIPLocalRouter.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {ReadClient} from "../src/ReadClient.sol";
import {Reader} from "../src/Reader.sol";
import {ReadCodec} from "../src/libraries/ReadCodec.sol";
import {ExampleConsumer} from "../src/examples/ExampleConsumer.sol";
import {MockToken, BadTarget, RecordingConsumer} from "./mocks/Mocks.sol";

/// @dev The local simulator has one router and one chain selector, and it delivers messages synchronously. So a whole
///      read (request leg, staticcall, response leg, callback) completes inside the `read` call.
contract ReadRoundTripTest is Test {
    uint32 constant REQUEST_GAS = 1_000_000; // must cover the nested response delivery in the simulator
    uint32 constant RESPONSE_GAS = 400_000;
    uint32 constant CALLBACK_GAS = 200_000;
    uint32 constant READ_GAS_CAP = 100_000;
    uint32 constant MAX_RESULT = 256;

    CCIPLocalSimulator sim;
    CCIPLocalRouter router;
    uint64 selector;

    ReadClient client;
    Reader reader;
    MockToken token;
    BadTarget bad;
    ExampleConsumer example;
    RecordingConsumer consumer;

    address alice = makeAddr("alice");
    address holder = makeAddr("holder");

    function setUp() public {
        sim = new CCIPLocalSimulator();
        (uint64 chainSelector, IRouterClient sourceRouter,,,,,) = sim.configuration();
        selector = chainSelector;
        router = CCIPLocalRouter(address(sourceRouter));

        client = new ReadClient(address(router), CALLBACK_GAS);
        reader = new Reader(address(router), RESPONSE_GAS, READ_GAS_CAP, MAX_RESULT);
        client.setLane(selector, address(reader), REQUEST_GAS, 0);
        reader.setClient(selector, address(client));

        token = new MockToken();
        token.mint(holder, 1234e18);
        bad = new BadTarget();
        example = new ExampleConsumer(client);
        consumer = new RecordingConsumer(client);

        vm.deal(address(reader), 1 ether);
        vm.deal(alice, 10 ether);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------------------------------------------------

    function test_exampleConsumer_readsRemoteBalance() public {
        vm.prank(alice);
        bytes32 id = example.requestBalance(selector, address(token), holder);

        (address t, address account, bool fulfilled, bool success, uint256 balance,) = example.reads(id);
        assertEq(t, address(token));
        assertEq(account, holder);
        assertTrue(fulfilled);
        assertTrue(success);
        assertEq(balance, 1234e18);

        (address pendingConsumer,) = client.pending(id);
        assertEq(pendingConsumer, address(0), "request should be cleared");
    }

    function test_read_emitsLifecycleEvents() public {
        bytes memory callData = abi.encodeCall(MockToken.balanceOf, (holder));

        vm.recordLogs();
        bytes32 id = consumer.doRead(selector, address(token), callData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawRequested;
        bool sawExecuted;
        bool sawFulfilled;
        for (uint256 i; i < logs.length; i++) {
            bytes32 sig = logs[i].topics[0];
            if (sig == ReadClient.ReadRequested.selector) sawRequested = logs[i].topics[1] == id;
            if (sig == Reader.ReadExecuted.selector) sawExecuted = logs[i].topics[1] == id;
            if (sig == ReadClient.ReadFulfilled.selector) sawFulfilled = logs[i].topics[1] == id;
        }
        assertTrue(sawRequested && sawExecuted && sawFulfilled, "missing lifecycle event");

        assertEq(consumer.lastRequestId(), id);
        assertTrue(consumer.lastSuccess());
        assertEq(abi.decode(consumer.lastResult(), (uint256)), 1234e18);
    }

    function test_read_fromEOA_resultInEvent() public {
        bytes memory callData = abi.encodeCall(MockToken.balanceOf, (holder));
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(client), client.nonce()));

        vm.expectEmit(true, true, false, true, address(client));
        emit ReadClient.ReadFulfilled(expectedId, alice, true, abi.encode(uint256(1234e18)));
        vm.prank(alice);
        bytes32 id = client.read(selector, address(token), callData);
        assertEq(id, expectedId);
    }

    function test_requestIds_unique() public {
        bytes memory callData = abi.encodeCall(MockToken.balanceOf, (holder));
        bytes32 a = consumer.doRead(selector, address(token), callData);
        bytes32 b = consumer.doRead(selector, address(token), callData);
        assertTrue(a != b);
        assertEq(consumer.callbacks(), 2);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Target failures are reported, not reverted
    // ---------------------------------------------------------------------------------------------------------------

    function test_targetRevert_deliveredAsFailure() public {
        consumer.doRead(selector, address(bad), abi.encodeCall(BadTarget.boom, ()));
        assertFalse(consumer.lastSuccess());
        assertEq(consumer.lastResult(), abi.encodeWithSelector(BadTarget.Nope.selector, 42));
    }

    function test_targetNotContract_deliveredAsFailure() public {
        address nobody = makeAddr("nobody");
        consumer.doRead(selector, nobody, abi.encodeCall(MockToken.balanceOf, (holder)));
        assertFalse(consumer.lastSuccess());
        assertEq(consumer.lastResult(), abi.encodeWithSelector(Reader.TargetNotContract.selector, nobody));
    }

    function test_resultTooLarge_deliveredAsFailure() public {
        consumer.doRead(selector, address(bad), abi.encodeCall(BadTarget.huge, (1000)));
        assertFalse(consumer.lastSuccess());
        // abi-encoded `bytes` of length 1000: 32 offset + 32 length + 1024 padded data
        assertEq(consumer.lastResult(), abi.encodeWithSelector(Reader.ResultTooLarge.selector, 1088, MAX_RESULT));
    }

    function test_resultAtLimit_delivered() public {
        // Storing a 1 KB result costs ~800k gas in the consumer, so every gas budget on the path goes up.
        client.setCallbackGasLimit(1_500_000);
        reader.setConfig(2_000_000, READ_GAS_CAP, 1088);
        client.setLane(selector, address(reader), 3_000_000, 0);
        consumer.doRead(selector, address(bad), abi.encodeCall(BadTarget.huge, (1000)));
        assertTrue(consumer.lastSuccess());
        assertEq(abi.decode(consumer.lastResult(), (bytes)).length, 1000);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Consumer callback failures never block CCIP delivery
    // ---------------------------------------------------------------------------------------------------------------

    function test_consumerRevert_emitsCallbackFailed() public {
        consumer.setMode(RecordingConsumer.Mode.Revert);
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(client), client.nonce()));

        vm.expectEmit(true, true, false, true, address(client));
        emit ReadClient.CallbackFailed(
            expectedId, address(consumer), abi.encodeWithSignature("Error(string)", "consumer says no")
        );
        consumer.doRead(selector, address(token), abi.encodeCall(MockToken.balanceOf, (holder)));

        (address pendingConsumer,) = client.pending(expectedId);
        assertEq(pendingConsumer, address(0));
    }

    function test_consumerOutOfGas_emitsCallbackFailed() public {
        consumer.setMode(RecordingConsumer.Mode.BurnGas);
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(client), client.nonce()));

        vm.expectEmit(true, true, false, true, address(client));
        emit ReadClient.CallbackFailed(expectedId, address(consumer), "");
        consumer.doRead(selector, address(token), abi.encodeCall(MockToken.balanceOf, (holder)));
    }

    function test_responseGasTooLowForCallback_reverts() public {
        // The response leg can't guarantee CALLBACK_GAS to the consumer, so delivery reverts (and could be retried
        // with more gas on a real network) instead of being marked as a failed callback.
        reader.setConfig(150_000, READ_GAS_CAP, MAX_RESULT);
        vm.expectRevert();
        consumer.doRead(selector, address(token), abi.encodeCall(MockToken.balanceOf, (holder)));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fees
    // ---------------------------------------------------------------------------------------------------------------

    function test_fees_quoteChargeAndRefund() public {
        router.setFee(0.01 ether);
        client.setLane(selector, address(reader), REQUEST_GAS, 0.02 ether);
        bytes memory callData = abi.encodeCall(MockToken.balanceOf, (holder));

        uint256 q = client.quote(selector, address(token), callData);
        assertEq(q, 0.03 ether);

        uint256 aliceBefore = alice.balance;
        uint256 readerBefore = address(reader).balance;
        vm.prank(alice);
        client.read{value: 1 ether}(selector, address(token), callData);

        assertEq(alice.balance, aliceBefore - q, "excess refunded");
        assertEq(address(client).balance, 0.02 ether, "surcharge kept for the response leg");
        assertEq(address(reader).balance, readerBefore - 0.01 ether, "reader paid the response fee");
    }

    function test_fees_underpaymentReverts() public {
        router.setFee(0.01 ether);
        bytes memory callData = abi.encodeCall(MockToken.balanceOf, (holder));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReadClient.InsufficientFee.selector, 0.01 ether, 0.005 ether));
        client.read{value: 0.005 ether}(selector, address(token), callData);
    }

    function test_unfundedReader_reverts() public {
        router.setFee(0.01 ether);
        vm.deal(address(reader), 0);
        vm.prank(alice);
        vm.expectRevert(); // InsufficientBalance on the target, bubbled up by the simulator
        client.read{value: 0.01 ether}(selector, address(token), abi.encodeCall(MockToken.balanceOf, (holder)));
    }

    function test_exampleConsumer_refundsExcess() public {
        router.setFee(0.01 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        example.requestBalance{value: 0.5 ether}(selector, address(token), holder);
        assertEq(alice.balance, before - 0.01 ether);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------------------------

    function test_read_unsupportedLane_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReadClient.UnsupportedLane.selector, uint64(999)));
        client.read(999, address(token), "");
    }

    function test_reader_rejectsUnknownClient() public {
        address impostor = makeAddr("impostor");
        Client.Any2EVMMessage memory m =
            _message(selector, impostor, ReadCodec.encodeRequest(bytes32(0), address(token), ""));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(Reader.UnauthorizedClient.selector, selector, impostor));
        reader.ccipReceive(m);
    }

    function test_reader_rejectsWrongChain() public {
        Client.Any2EVMMessage memory m =
            _message(777, address(client), ReadCodec.encodeRequest(bytes32(0), address(token), ""));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(Reader.UnauthorizedClient.selector, uint64(777), address(client)));
        reader.ccipReceive(m);
    }

    function test_client_rejectsUnknownReader() public {
        address impostor = makeAddr("impostor");
        Client.Any2EVMMessage memory m = _message(selector, impostor, ReadCodec.encodeResponse(bytes32(0), true, ""));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(ReadClient.UnauthorizedReader.selector, selector, impostor));
        client.ccipReceive(m);
    }

    function test_client_rejectsUnknownRequest() public {
        bytes32 id = keccak256("nope");
        Client.Any2EVMMessage memory m = _message(selector, address(reader), ReadCodec.encodeResponse(id, true, ""));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(ReadClient.UnknownRequest.selector, id));
        client.ccipReceive(m);
    }

    function test_client_rejectsReplay() public {
        bytes32 id = consumer.doRead(selector, address(token), abi.encodeCall(MockToken.balanceOf, (holder)));
        Client.Any2EVMMessage memory m = _message(selector, address(reader), ReadCodec.encodeResponse(id, true, ""));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(ReadClient.UnknownRequest.selector, id));
        client.ccipReceive(m);
    }

    function test_ccipReceive_onlyRouter() public {
        Client.Any2EVMMessage memory m = _message(selector, address(reader), "");
        vm.expectRevert();
        client.ccipReceive(m);
        vm.expectRevert();
        reader.ccipReceive(m);
    }

    function test_admin_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        client.setLane(selector, alice, 1, 0);
        vm.expectRevert();
        reader.setClient(selector, alice);
        vm.expectRevert();
        reader.withdraw(payable(alice), 1);
        vm.stopPrank();
    }

    function _message(uint64 sourceSelector, address sender, bytes memory data)
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: sourceSelector,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }
}
