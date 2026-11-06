# Chainlink CCIP 2.0 in Nidhi

CCIP is Nidhi's **cross-chain settlement layer**. The hook captures the swap output on the source chain. CCIP carries that
exact amount, together with the grant data, to a receiver on the grantee's chain, which pays them. A second CCIP message
travels back as a **receipt**, so the source ledger knows the grant was paid and marks it `SETTLED`. A relay pays chains
that have no direct lane.

Contents: [1 system view](#1-system-view) · [2 the round trip](#2-the-full-round-trip) · [3 the messages](#3-what-goes-in-each-message) ·
[4 the ledger](#4-the-source-ledger-only-moves-forward) · [5 the receiver never loses money](#5-the-receiver-never-loses-money) ·
[6 multi-hop](#6-multi-hop-paying-a-chain-with-no-direct-lane) · [7 lanes and routing](#7-lanes-and-add-only-routing) ·
[8 safety checks](#8-safety-checks-around-every-message) · [9 CCIP 2.0 specifics](#9-ccip-20-specifics-and-lessons-from-live-runs) ·
[10 costs and timing](#10-costs-and-timing) · [11 live proof](#11-live-proof) · [12 code](#12-code)

---

## 1. System view

```mermaid
flowchart LR
  subgraph SRC["Source chain"]
    HK["NidhiHook<br/>captures the output"]
    DS["NidhiDispatcher<br/>grant ledger, CCIP sender,<br/>receipt receiver"]
    R1["CCIP Router"]
  end
  subgraph DST["Grantee's chain"]
    R2["CCIP Router"]
    RX["DestinationReceiver<br/>pays, or holds and retries"]
    AUTO["Automation queue<br/>checkUpkeep / performUpkeep"]
    G(["Grantee"])
  end
  HK -->|"take + dispatch"| DS
  DS -->|"1 tokens + grant data,<br/>fee in native"| R1
  R1 ==>|"CCIP lane"| R2
  R2 -->|"2 deliver"| RX
  RX -->|"3 pay"| G
  RX -->|"4 receipt (no tokens)"| R2
  R2 ==>|"reverse lane"| R1
  R1 -->|"5 SETTLED"| DS
  AUTO -.-> RX
```

Every chain runs both halves (a dispatcher and a receiver), so any lane works in both directions and every receipt returns
on the reverse lane.

---

## 2. The full round trip

```mermaid
sequenceDiagram
  autonumber
  participant HK as NidhiHook
  participant DS as NidhiDispatcher (source)
  participant R1 as CCIP Router (source)
  participant NET as CCIP network
  participant R2 as CCIP Router (destination)
  participant RX as DestinationReceiver
  actor G as Grantee

  HK->>DS: dispatch(mandate, amount), after take(amount)
  DS->>DS: only the hook, route exists and matches the mandate, grant is new, balance covers it
  DS->>R1: getFee(destination, message)
  DS->>DS: record the grant as DISPATCHED (state before the external call)
  DS->>R1: ccipSend{value: fee}(destination, message)
  R1-->>DS: messageId
  R1->>NET: tokens + data
  NET->>NET: wait for source finality, verify, execute
  NET->>R2: deliver, the token pool releases to the receiver
  R2->>RX: ccipReceive(message)
  RX->>RX: sender is the known dispatcher, one allowed token, amount matches
  alt the transfer works
    RX->>G: pay
  else it reverts (paused, blocked address)
    Note over RX: HELD: funds stay in the receiver, nothing reverts
  end
  RX->>R2: ccipSend receipt(grantId, messageId, amount, PAID or HELD)
  R2->>NET: receipt
  NET->>R1: deliver
  R1->>DS: ccipReceive(receipt)
  DS->>DS: sender is the known receiver, amount and chain match, move forward only
```

---

## 3. What goes in each message

```mermaid
flowchart TB
  subgraph FWD["Grant message: source to destination"]
    F1["receiver = the destination's DestinationReceiver"]
    F2["data = (grantId, recipient, amount)"]
    F3["tokenAmounts = [ (payout token, amount) ]<br/>a programmable token transfer"]
    F4["feeToken = native"]
    F5["extraArgs = GenericExtraArgsV2<br/>(gas limit, allowOutOfOrderExecution = true)"]
  end
  subgraph ACK["Receipt: destination to source"]
    A1["receiver = the source's NidhiDispatcher"]
    A2["data = (grantId, source messageId, amount, outcome)"]
    A3["tokenAmounts = [] (data only)"]
    A4["extraArgs = the receipt's gas limit"]
  end
```

Receipt outcomes: `PAID`, `HELD`, `RECOVERED`.

---

## 4. The source ledger only moves forward

```mermaid
stateDiagram-v2
  direction LR
  [*] --> NONE
  NONE --> DISPATCHED: dispatch (hook only)
  DISPATCHED --> SETTLED: receipt PAID
  DISPATCHED --> HELD: receipt HELD
  HELD --> SETTLED: receipt PAID or RECOVERED
  SETTLED --> [*]
```

A receipt that would move a grant backwards, arrives twice, comes from an unknown sender, or names the wrong amount or chain
is rejected. The receipt can even arrive in the same transaction as the send (local simulator); the message id is reconciled
from whichever side lands first.

---

## 5. The receiver never loses money

A reverted CCIP delivery would need manual execution, and the tokens would sit in limbo. So the receiver never reverts a
delivery: it records a failure and heals later.

```mermaid
stateDiagram-v2
  direction TB
  [*] --> RECEIVED: ccipReceive
  RECEIVED --> PAID: transfer works
  RECEIVED --> HELD: transfer fails, or payouts paused
  HELD --> PAID: retryPayout (anyone, once the cause clears)
  HELD --> RECOVERED: recover (DAO owner)
  PAID --> RECEIPT_SENT
  HELD --> RECEIPT_SENT
  RECOVERED --> RECEIPT_SENT
  RECEIVED --> RECEIPT_PENDING: receipt fails (low fee balance)
  RECEIPT_PENDING --> RECEIPT_SENT: retryAck, or Automation
  RECEIPT_SENT --> [*]
```

Held payouts and unsent receipts go into a queue that Chainlink Automation can drain through `checkUpkeep` and
`performUpkeep` (up to 10 per run). The owner can never sweep grant tokens: `withdrawFees` refuses them.

---

## 6. Multi-hop: paying a chain with no direct lane

Chainlink's track description asks for exactly this: *send from chain A to chain B without worrying whether the lane
exists*. Base Sepolia and Unichain Sepolia share no CCIP lane. `NidhiHopRelay` on Arbitrum Sepolia joins them.

```mermaid
flowchart LR
  subgraph A["Base Sepolia"]
    DS["hop stack dispatcher"]
  end
  subgraph V["Arbitrum Sepolia"]
    RL["NidhiHopRelay"]
  end
  subgraph B["Unichain Sepolia"]
    RX["DestinationReceiver"]
    G(["grantee"])
  end
  DS ==>|"1 grant: tokens + data"| RL
  RL ==>|"2 forward over the next lane"| RX
  RX -->|"3 pay"| G
  RX ==>|"4 receipt"| RL
  RL ==>|"5 receipt, rewritten to the source's messageId"| DS
```

- **No existing contract changes.** To the source dispatcher, the relay *is* the destination receiver. To the final
  receiver, the relay *is* the source dispatcher.
- **The receipt still settles the source.** The relay rewrites the receipt to carry the source's own message id, which is
  what the dispatcher matches.
- **Nothing is lost if a hop fails.** A forward or a receipt that cannot be sent is parked; anyone can call `retryForward`
  or `retryAck`.
- **Hardened by the live run.** The relay forwards inside CCIP's delivery, so the source must give it enough gas (2,000,000
  on CCIP 2.0 testnet on-ramps); the first live hop ran out at the default 600,000, parked safely, and was retried. The hop
  script now sets the limits for every route.

```mermaid
sequenceDiagram
  autonumber
  participant DS as Dispatcher (Base Sepolia)
  participant RL as NidhiHopRelay (Arbitrum Sepolia)
  participant RX as Receiver (Unichain Sepolia)
  DS->>RL: CCIP grant, messageId M1
  RL->>RL: sender is the known upstream, one allowed token, record (M1, amount)
  RL->>RX: CCIP forward, messageId M2
  RX->>RX: pay the grantee
  RX->>RL: receipt (grantId, M2, PAID)
  RL->>RL: M2 matches what it sent
  RL->>DS: receipt (grantId, M1, PAID)
  DS->>DS: SETTLED
```

---

## 7. Lanes and add-only routing

A grant can only go where Chainlink runs a lane, and a route, once added, can never be redirected.

```mermaid
flowchart TB
  REG[("chains/registry.json, chains/testnets.json<br/>generated from Chainlink's chains, tokens and lanes API,<br/>checked on-chain: router, selector, RMN, lanes")] --> D1
  D1["Deploy, per chain<br/>refuses a chain whose RMN is cursed<br/>funds a fee reserve = 3 x the live fee"] --> D2
  D2["Wire<br/>dispatcher.addDestination(chain, receiver)<br/>receiver.addSource(chain, dispatcher)<br/>only where a lane exists"] --> D3
  D3["Handover<br/>Ownable2Step to the DAO admin"]
```

```mermaid
flowchart LR
  SEP["Sepolia"] <--> BAS["Base Sepolia"]
  SEP <--> ARB["Arbitrum Sepolia"]
  SEP <--> UNI["Unichain Sepolia"]
  BAS <--> ARB
  ARB <--> UNI
  BAS -.->|"no lane: through the relay on Arbitrum"| UNI
```

On mainnets the payout token is USDC through CCIP's USDC pools: 10 source-capable chains and 50 directed lanes, rehearsed on
forks.

---

## 8. Safety checks around every message

```mermaid
flowchart TD
  subgraph S["Dispatcher, before sending"]
    S1["caller is the hook"] --> S2["route exists and matches the mandate"]
    S2 --> S3["grant is new"] --> S4["token balance covers the amount"]
    S4 --> S5["native balance covers the live fee"] --> S6["state written before the external call"]
  end
  subgraph D["Receiver, on delivery"]
    D1["sender is the known source dispatcher"] --> D2["exactly one allowed token"]
    D2 --> D3["data amount equals the delivered amount"] --> D4["grantId never seen"]
    D4 --> D5["payout inside try/catch: a failure becomes HELD"]
  end
  subgraph R["Dispatcher, on a receipt"]
    R1["sender is the known receiver"] --> R2["no tokens attached"]
    R2 --> R3["amount and chain match the grant"] --> R4["forward transitions only"]
  end
  S ==> D ==> R
```

The RMN curse status is checked before deploying and shown live in the app.

---

## 9. CCIP 2.0 specifics, and lessons from live runs

- **CCIP 2.0 contracts.** The contracts build on Chainlink's current CCIP library, which includes the cross-chain verifier
  configuration (`getCCVsAndFinalityConfig`). On the live testnet lanes, the token pools call `getRequiredCCVs` during fee
  quoting, visible in our deployment traces.
- **`GenericExtraArgsV2`** with `allowOutOfOrderExecution`, isolated in one library (`ExtraArgsLib`).
- **Faster-Than-Finality (FTF), CCIP 2.0.** By default a message waits for full source finality. CCIP 2.0 lets the
  sender ask for a block depth instead (`GenericExtraArgsV3`, `FinalityCodec`), but only if the receiver opts in.
  Otherwise the message is accepted at send time and then fails on execution. Nidhi does both halves:
  - `NidhiDispatcher.setRequestedFinality(destSelector, depth)` is per lane and owner-only. With nothing set it sends the
    old V2 bytes, unchanged.
  - `DestinationReceiver.setAllowedFinality(depth)` controls what `getCCVsAndFinalityConfig` returns. It allows the
    shallower depth **only for its own known source dispatcher**. Every other sender, and every unknown chain, still gets
    full finality.
  - Each lane sets its own minimum depth. Live checks: Sepolia → Base and Sepolia → Arbitrum require at least 32 blocks;
    Unichain → Arbitrum accepts 20. Lanes sourced from Base or Arbitrum are finality-only. The v5 ENS stack therefore
    asks for 32 blocks on its Sepolia lanes (about 6.4 min instead of about 15 min for finality), and its receivers accept 20 or more.
  - Tests: `test/unit/FasterThanFinality.t.sol`.
- **Gas limits matter more than they look.** A receiver pays and sends a receipt inside its delivery; a relay sends a whole
  new CCIP message inside its delivery. Destination gas limits are set per route (2,000,000 for hops, 1,500,000 for a final
  receiver's receipt).
- **Gas estimation and try/catch.** An estimator picks the lowest gas at which the outer call succeeds, and a failing send
  inside try/catch still "succeeds". Manual retries need an explicit gas limit.
- **Local simulator.** It delivers every hop in one transaction, so a two-hop test needs the whole route's gas in the first
  hop, and a receipt can arrive before the send returns. The relay reconciles that order.

---

## 10. Costs and timing

| | Who pays | How |
|---|---|---|
| Grant message | the source dispatcher | native token, quoted live with `getFee` |
| Receipt | the destination receiver | native token, from its own reserve |
| Hop forward and relayed receipt | the relay | native token, from its reserve |
| Reserve sizing | the deployer | 3 messages' worth of the live fee per side |

A direct grant costs two CCIP messages; a two-hop grant costs four. On testnets a grant takes about 15–25 minutes to reach
the grantee and 30–40 minutes to settle, mostly waiting for source-chain finality. With Faster-Than-Finality (the v5 ENS
stack, 32 blocks on Sepolia) the outbound leg waits 32 blocks instead of finality. Measured live on 6 Nov 2026:

| Grant | Lane | Sent | Paid to grantee | Time |
|---|---|---|---|---|
| `0xfd54…586d` | Sepolia → Base Sepolia | 08:31:00 UTC | 08:37:36 UTC | **6 min 36 s** |
| `0x7828…6a79` | Sepolia → Arbitrum Sepolia | 08:39:36 UTC | 08:46:51 UTC | **7 min 15 s** |

Before FTF the same lanes took 15–25 minutes. The receipt leg from
Base or Arbitrum still waits for finality, because those lanes allow nothing else.

---

## 11. Live proof

| Route | Evidence |
|---|---|
| Base Sepolia → Arbitrum Sepolia, settled | [CCIP](https://ccip.chain.link/msg/0x60433b4f9215063950bde9736f3618766fdbbdde7f43e895dba724fc3d2faf7e) · [payout](https://sepolia.arbiscan.io/tx/0x74c5f98f165389683c3201ce3b283e63e9965eaed03c5faed8d389e8f6d3c21c) |
| Sepolia → Base Sepolia, settled | [CCIP](https://ccip.chain.link/msg/0x9c3ddac23e4af71f197c9b71b36b36f11fdbc8068e25c8c6d36468d65ff1fdfa) · [payout](https://sepolia.basescan.org/tx/0xf3e05ffddcbd9e86ca12ae3c84783a1f1482824613f4ed6cbdf9449e1d628294) |
| ENS-gated Sepolia → Base Sepolia, settled | [CCIP](https://ccip.chain.link/msg/0xe5721859a03a43697d7ce3b2c5fcd8a73a5d5c9ed881ab34db33edb4ccba17a2) |
| **Multi-hop** Base Sepolia → Arbitrum Sepolia → Unichain Sepolia, settled | [swap](https://sepolia.basescan.org/tx/0x47c75cf9e20812733516d2a5642f39111a476efc2b8af1f569dbb6480cc14168) · [relay forward](https://sepolia.arbiscan.io/tx/0xeab38417c58e402c2d7e9c5f3491d0adbb1217bb44ebef1aa2e4ed11c1c8977f) |
| Agent milestone payout, Sepolia → Base Sepolia | [payout swap](https://sepolia.etherscan.io/tx/0xb8f24e16f4fe2bfa71d205e3ac48d13541a7a42ff0d35abbd8b5a9119408cfaf) |

---

## 12. Code

| What | Where |
|---|---|
| Send | [`NidhiDispatcher.dispatch`](../../src/NidhiDispatcher.sol#L120) |
| Receipt in | [`NidhiDispatcher._ccipReceive`](../../src/NidhiDispatcher.sol#L182) |
| Delivery, hold, retry, recover | [`DestinationReceiver._ccipReceive`](../../src/DestinationReceiver.sol#L119) · [`retryPayout`](../../src/DestinationReceiver.sol#L165) · [`recover`](../../src/DestinationReceiver.sol#L180) · [`sendAck`](../../src/DestinationReceiver.sol#L211) |
| Automation | [`checkUpkeep`](../../src/DestinationReceiver.sol#L263) · [`performUpkeep`](../../src/DestinationReceiver.sol#L277) |
| Multi-hop | [`NidhiHopRelay`](../../src/NidhiHopRelay.sol): [`_onGrant`](../../src/NidhiHopRelay.sol#L134) · [`_onAck`](../../src/NidhiHopRelay.sol#L152) · [`retryForward`](../../src/NidhiHopRelay.sol#L235) |
| Message encoding | [`AckLib`](../../src/libraries/AckLib.sol) · [`ExtraArgsLib`](../../src/libraries/ExtraArgsLib.sol) |
| Routes | [`script/mainnet/Wire.s.sol`](../../script/mainnet/Wire.s.sol) · [`script/hop/HopRoute.s.sol`](../../script/hop/HopRoute.s.sol) |
| Tests | [`NidhiFlow.t.sol`](../../test/unit/NidhiFlow.t.sol) · [`EdgeCases.t.sol`](../../test/unit/EdgeCases.t.sol) · [`HopRelay.t.sol`](../../test/unit/HopRelay.t.sol) · [`NidhiInvariant.t.sol`](../../test/invariant/NidhiInvariant.t.sol) |
