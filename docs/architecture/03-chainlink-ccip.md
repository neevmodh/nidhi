# 3. Chainlink CCIP architecture in Nidhi

CCIP is Nidhi's **cross-chain settlement layer**. The hook captures the swap output on the source chain. CCIP carries that
exact token amount, plus the grant data, to a receiver on the destination chain that pays the grantee. A second CCIP message
travels back as a **receipt (ACK)** so the source ledger knows the grant is `SETTLED`.

## 3.1 System view

```mermaid
flowchart LR
  subgraph SRC["Source chain (e.g. Base)"]
    HK["NidhiHook\nafterSwap capture"]
    DS["NidhiDispatcher\nCCIPReceiver, owner = DAO admin\ndestReceivers[selector] add-only\nledger: grantId to status"]
    RS["CCIP Router + RMN"]
  end

  subgraph DST["Destination chain (e.g. Arbitrum)"]
    RD["CCIP Router + RMN"]
    RX["DestinationReceiver\nCCIPReceiver, defensive\nsourceDispatchers[selector] add-only\nallowedToken allowlist"]
    AUTO["Chainlink Automation\ncheckUpkeep / performUpkeep"]
    GR(["Grantee wallet"])
  end

  HK -->|"take(out) + dispatch(mandate, out)"| DS
  DS -->|"1 ccipSend: token + grant data, fee in native"| RS
  RS ==>|"CCIP lane: DON commit and execute, RMN verifies"| RD
  RD -->|"2 ccipReceive: token already delivered to receiver"| RX
  RX -->|"3 safeTransfer(token, recipient, amount)"| GR
  RX -->|"4 ccipSend ACK: no tokens, outcome"| RD
  RD ==>|"CCIP lane back"| RS
  RS -->|"5 ccipReceive ACK"| DS
  AUTO -->|"drains the queue of held payouts and unsent ACKs"| RX
```

Every chain deploys **both** sides (a dispatcher and a receiver), so any lane works in either direction, and the ACK always
returns on the reverse lane.

## 3.2 The full round trip

```mermaid
sequenceDiagram
  autonumber
  participant HK as NidhiHook
  participant DS as NidhiDispatcher (source)
  participant RT as CCIP Router (source)
  participant NET as CCIP network (DON + RMN)
  participant RR as CCIP Router (destination)
  participant RX as DestinationReceiver
  actor G as Grantee

  HK->>DS: dispatch(mandate, out) after take(out)
  DS->>DS: checks: only hook, destReceivers[sel] set, m.destReceiver matches, grant status NONE, balance at least out
  DS->>RT: getFee(destSelector, message)
  DS->>DS: effects first: status = DISPATCHED, amount, token, recipient
  DS->>RT: approve token, ccipSend{value: fee}(destSelector, message)
  RT-->>DS: messageId
  Note over DS: emits GrantDispatched(grantId, messageId, token, amount, recipient, fee)
  RT->>NET: message + tokens (burn/lock in the token pool)
  NET->>NET: commit, RMN blessing, execute
  NET->>RR: deliver, token pool releases to the receiver
  RR->>RX: ccipReceive(message)
  RX->>RX: source == sourceDispatchers[sel], exactly 1 token, token allowlisted, amount == received
  RX->>RX: duplicate guard, record payout, optimistic outcome = PAID
  alt payout succeeds
    RX->>G: token.safeTransfer(recipient, amount) via try this.executePayout
    Note over RX: outcome stays PAID
  else transfer reverts (blacklisted recipient, paused...)
    Note over RX: outcome = HELD, tokens stay in the receiver, nothing reverts
  end
  RX->>RR: ccipSend ACK(grantId, messageId, amount, outcome), no tokens, native fee
  RR->>NET: ACK message
  NET->>RT: deliver ACK
  RT->>DS: ccipReceive(ACK)
  DS->>DS: sender == destReceivers[sourceSelector], amount and destSelector match, monotonic transition
  Note over DS: PAID or RECOVERED gives SETTLED, HELD gives HELD
```

## 3.3 What goes in the CCIP message

```mermaid
flowchart TB
  subgraph FWD["Forward message: source to destination"]
    F1["receiver = abi.encode(destReceivers[destSelector])"]
    F2["data = AckLib.encodeGrant(grantId, recipient, amount)"]
    F3["tokenAmounts = [ {tokenOut, amount} ]\nprogrammable token transfer"]
    F4["feeToken = address(0)  native\nor an ERC-20 fee token"]
    F5["extraArgs = GenericExtraArgsV2 tag 0x181dcf10\ngasLimit = destGasLimit, allowOutOfOrderExecution = true"]
  end
  subgraph ACKM["Return message: destination to source"]
    A1["receiver = abi.encode(sourceDispatchers[srcSelector])"]
    A2["data = AckLib.encodeAck(grantId, sourceMessageId, amount, outcome)"]
    A3["tokenAmounts = []  data only"]
    A4["extraArgs gasLimit = ackGasLimit"]
  end
```

Outcome codes carried in the ACK: `PAID`, `HELD`, `RECOVERED`.

## 3.4 The grant ledger is monotonic

```mermaid
stateDiagram-v2
  direction LR
  [*] --> NONE
  NONE --> DISPATCHED: dispatch (hook only)
  DISPATCHED --> SETTLED: ACK outcome PAID
  DISPATCHED --> HELD: ACK outcome HELD
  HELD --> SETTLED: ACK outcome PAID or RECOVERED
  SETTLED --> [*]
  note right of DISPATCHED
    never goes backwards
    a duplicate or out-of-order ACK reverts InvalidAck
    flagStuck(grantId) only emits an event
  end note
```

## 3.5 Destination payout states and self-healing

The receiver never reverts a CCIP delivery, because a reverted message would need manual execution and the tokens would be
stranded. It records the failure and heals later.

```mermaid
stateDiagram-v2
  direction TB
  [*] --> RECEIVED: ccipReceive
  RECEIVED --> PAID: transfer ok
  RECEIVED --> HELD: transfer failed or payouts paused
  HELD --> PAID: retryPayout(grantId) once the cause clears
  HELD --> RECOVERED: recover(grantId, to) by owner
  PAID --> ACK_SENT: ACK sent
  HELD --> ACK_SENT: ACK sent
  RECOVERED --> ACK_SENT: ACK sent
  RECEIVED --> ACK_PENDING: ACK send failed, e.g. low fee balance
  ACK_PENDING --> ACK_SENT: retryAck, sendAck or Automation
  ACK_SENT --> [*]
```

```mermaid
flowchart LR
  Q["queue of grants that need work\nheld payouts and unsent ACKs\nMAX_BATCH = 10"] --> CU["checkUpkeep()\nview: any actionable item ?"]
  CU -- "upkeepNeeded" --> PU["performUpkeep(performData)\nretryPayout then retryAck per item"]
  PU --> Q
  FUND["fee balance low"] -.->|"ACK stays pending, never lost"| Q
```

Funds safety on the receiver: `withdrawFees` refuses allowlisted payout tokens, so an owner cannot sweep grant money.

## 3.6 Lanes and routing across many chains

Nidhi is **lane-aware and add-only**. A chain can only pay a destination that has a real CCIP lane, and a route can be added
but never overwritten.

```mermaid
flowchart TB
  REG[("chains/registry.json\ngenerated from Chainlink's chains, tokens and lanes API\nselector, router, rmn, payoutLanes, cursedAtGeneration")] --> D1
  D1["Phase 1 Deploy, per chain\nrefuses if chain is not source-capable\nrefuses if the RMN is cursed right now\nfunds native fee reserve = 3 x live getFee"] --> D2
  D2["Phase 2 Wire, idempotent\noutbound: dispatcher.addDestination(selector, receiver)\ninbound: receiver.addSource(selector, dispatcher)\nonly where a payout lane exists"] --> D3
  D3["Phase 3 Handover\nOwnable2Step to the DAO admin, who calls acceptOwnership"]
```

```mermaid
flowchart LR
  subgraph TN["Testnet lanes (CCIP-BnM), wired and live"]
    SEP["Sepolia 11155111"]
    BAS["Base Sepolia 84532"]
    ARB["Arbitrum Sepolia 421614"]
    UNI["Unichain Sepolia 1301"]
    SEP <--> BAS
    SEP <--> ARB
    SEP <--> UNI
    BAS <--> ARB
    ARB <--> UNI
  end
```

On mainnets the payout token is **USDC**, bridged by CCIP's USDC pools. 10 chains are source-capable, with 50 directed USDC
lanes. The optimism, unichain and ink RMNs were **cursed at generation time**, so Deploy refuses them and rehearsals skip them.

## 3.7 Safety checks around every CCIP call

```mermaid
flowchart TD
  subgraph SOURCE["Dispatcher, before ccipSend"]
    S1["msg.sender == hook"] --> S2["destination configured and matches the mandate"]
    S2 --> S3["grant not already dispatched"] --> S4["token balance at least amount"]
    S4 --> S5["native balance at least live getFee"] --> S6["state written BEFORE the external call"]
  end
  subgraph DEST["Receiver, in ccipReceive"]
    R1["sender == sourceDispatchers[sourceSelector]"] --> R2["exactly one token, on the allowlist"]
    R2 --> R3["data amount == token amount delivered"] --> R4["no duplicate grantId"]
    R4 --> R5["payout wrapped in try/catch, failure becomes HELD"]
  end
  subgraph ACKCHK["Dispatcher, in ACK receive"]
    A1["sender == destReceivers[sourceSelector]"] --> A2["no tokens attached"]
    A2 --> A3["amount and destSelector match the grant"] --> A4["monotonic transition only"]
  end
  SOURCE ==> DEST ==> ACKCHK
```

## 3.8 Cost model

| Item | Who pays | How |
|---|---|---|
| Forward CCIP fee | the dispatcher, per grant | native token, quoted live with `getFee` before sending |
| ACK CCIP fee | the destination receiver, per grant | native token, from its own reserve |
| Reserve sizing | the deployer at Deploy | 3 messages' worth of `getFee` on each side |
| Low reserve | nothing is lost | the ACK waits in the queue and Automation or `retryAck` sends it once funded |

One grant therefore costs two CCIP messages. Fees are small on L2s and noticeably larger from Ethereum mainnet, and Monad's fee
is hundreds of MON because the unit price of MON is low.
