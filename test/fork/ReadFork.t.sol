// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

import {ReadClient} from "../../src/ReadClient.sol";
import {Reader} from "../../src/Reader.sol";
import {ExampleConsumer} from "../../src/examples/ExampleConsumer.sol";
import {MockToken} from "../mocks/Mocks.sol";

/// @notice Full round trip on forks of the real CCIP lane: Sepolia (source) <-> Arbitrum Sepolia (target).
/// @dev Needs ETHEREUM_SEPOLIA_RPC_URL and ARBITRUM_SEPOLIA_RPC_URL. Skipped when either is unset.
contract ReadForkTest is Test {
    uint32 constant REQUEST_GAS = 500_000;
    uint32 constant RESPONSE_GAS = 300_000;
    uint32 constant CALLBACK_GAS = 150_000;

    CCIPLocalSimulatorFork sim;
    uint256 sepoliaFork;
    uint256 arbFork;
    Register.NetworkDetails sepolia;
    Register.NetworkDetails arb;

    ReadClient client; // on Sepolia
    ExampleConsumer consumer; // on Sepolia
    Reader reader; // on Arbitrum Sepolia
    MockToken token; // on Arbitrum Sepolia

    address alice = makeAddr("alice");
    address holder = makeAddr("holder");

    function setUp() public {
        string memory sepoliaRpc = vm.envOr("ETHEREUM_SEPOLIA_RPC_URL", string(""));
        string memory arbRpc = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(sepoliaRpc).length == 0 || bytes(arbRpc).length == 0) {
            vm.skip(true);
            return;
        }

        sepoliaFork = vm.createSelectFork(sepoliaRpc);
        arbFork = vm.createFork(arbRpc);

        sim = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(sim));
        sepolia = sim.getNetworkDetails(block.chainid);

        // Target chain: Reader + something to read.
        vm.selectFork(arbFork);
        arb = sim.getNetworkDetails(block.chainid);
        reader = new Reader(arb.routerAddress, RESPONSE_GAS, 100_000, 1024);
        token = new MockToken();
        token.mint(holder, 777e18);
        vm.deal(address(reader), 1 ether); // prefunded response fees

        // Source chain: ReadClient + consumer.
        vm.selectFork(sepoliaFork);
        client = new ReadClient(sepolia.routerAddress, CALLBACK_GAS);
        consumer = new ExampleConsumer(client);
        vm.deal(alice, 1 ether);

        // Wire the lane both ways.
        vm.selectFork(arbFork);
        reader.setClient(sepolia.chainSelector, address(client));
        uint256 responseFee = reader.quoteResponse(sepolia.chainSelector, 32);

        vm.selectFork(sepoliaFork);
        client.setLane(arb.chainSelector, address(reader), REQUEST_GAS, responseFee * 2); // 2x buffer
    }

    function test_fork_readBalanceAcrossChains() public {
        vm.selectFork(sepoliaFork);
        uint256 fee = consumer.quoteBalance(arb.chainSelector, address(token), holder);
        vm.prank(alice);
        bytes32 id = consumer.requestBalance{value: fee}(arb.chainSelector, address(token), holder);

        // Leg 1: Sepolia -> Arbitrum Sepolia. The Reader runs the staticcall and sends the response.
        sim.switchChainAndRouteMessage(arbFork);
        // Leg 2: Arbitrum Sepolia -> Sepolia. The ReadClient delivers to the consumer.
        sim.switchChainAndRouteMessage(sepoliaFork);

        vm.selectFork(sepoliaFork);
        (,, bool fulfilled, bool success, uint256 balance,) = consumer.reads(id);
        assertTrue(fulfilled, "not fulfilled");
        assertTrue(success, "read failed");
        assertEq(balance, 777e18);
    }
}
