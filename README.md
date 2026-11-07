# ccip-read

**Cross-chain state reads over Chainlink CCIP. A CCIP version of LayerZero's lzRead.**


## What it is

[LayerZero lzRead](https://docs.layerzero.network/v2/developers/evm/lzread/overview) lets a contract on one chain request data from another chain's state and get the result back on the origin chain. Developers use it to query balances, prices or any `view` function across chains without deploying custom messaging logic for each read.

`ccip-read` brings the same pull-based read pattern to [Chainlink CCIP](https://docs.chain.link/ccip). An app on a source chain asks for the result of a `view` call on a target chain, and the result comes back through CCIP.

> **Note:** This project is not related to [EIP-3668 "CCIP Read"](https://eips.ethereum.org/EIPS/eip-3668), the offchain lookup standard used by ENS. Here, "CCIP" means Chainlink's Cross-Chain Interoperability Protocol.

## How it works

1. **Request (source chain):** A consumer contract calls the read client with a target chain selector, a target contract address and ABI-encoded calldata for a `view` function. The client sends this request to the target chain as a CCIP message.
2. **Execute (target chain):** A reader contract on the target chain receives the CCIP message, `staticcall`s the target contract and captures the return data.
3. **Respond (target → source):** The reader sends the result back to the source chain in a second CCIP message.
4. **Deliver (source chain):** The read client matches the response to the original request ID and runs the consumer's callback with the result.

```
 Source chain                         Target chain
┌──────────────┐   CCIP request    ┌──────────────┐
│ Consumer     │ ───────────────▶  │ Reader       │
│  → ReadClient│                   │  staticcall  │──▶ Target contract
│  ← callback  │ ◀───────────────  │              │
└──────────────┘   CCIP response   └──────────────┘
```

## lzRead vs. ccip-read

| | lzRead | ccip-read |
|---|---|---|
| Transport | LayerZero DVNs read target state directly | Two CCIP messages (request and response) |
| Who runs the read | DVNs, off-chain | A reader contract, on-chain on the target chain |
| Compute hooks | `lzMap` / `lzReduce` | Callback on the source chain (planned: optional aggregation) |
| Cost and latency | One delivery | Two CCIP fees and two finality waits |

## Status

- [ ] Read client contract (source chain)
- [ ] Reader contract (target chain)
- [ ] Request/response correlation and callback
- [ ] Fee estimation for the round trip
- [ ] Testnet deployment and demo
