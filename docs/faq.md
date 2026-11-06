# Nidhi FAQ: how fast is a grant?

## How long does a grant take to reach the grantee?

About **7 minutes** on the testnet lanes from Sepolia. Measured on 6 Nov 2026:

| Lane | Sent | Grantee paid | Time |
|---|---|---|---|
| Sepolia → Base Sepolia | 08:31:00 UTC | 08:37:36 UTC | 6 min 36 s |
| Sepolia → Arbitrum Sepolia | 08:39:36 UTC | 08:46:51 UTC | 7 min 15 s |

Before the upgrade the same lanes took 15–25 minutes.

## Why is it that fast?

Chainlink CCIP normally waits until the source block is **final** before it delivers a message. On Sepolia that takes
about 15 minutes. CCIP 2.0 adds **Faster-Than-Finality (FTF)**: the sender may ask CCIP to wait a fixed number of
blocks instead.

- The dispatcher asks for **32 blocks** (about 6.4 minutes on Sepolia), using `GenericExtraArgsV3`. That is the
  minimum the Sepolia → Base and Sepolia → Arbitrum lanes accept.
- The receiver has to agree, through `getCCVsAndFinalityConfig`. Nidhi's receivers accept 20 blocks or more, and only
  from their own dispatcher. Every other sender still waits for full finality.
- Without the receiver's agreement the message would be accepted at send time and then fail on delivery, so both sides
  are configured together.

Details: [architecture/03-chainlink-ccip.md](architecture/03-chainlink-ccip.md), section 9.

## Why does "Settled" take longer than "paid"?

A grant is **paid** when the receiver on the destination chain sends the tokens to the grantee. It is **Settled** when the
receipt (ACK) travels back to Sepolia and the dispatcher records it.

The receipt starts on Base or Arbitrum. Those lanes accept **full finality only**: a Base or Arbitrum block is final once
it is posted to Ethereum and Ethereum finalizes it. So the receipt leg still takes roughly 20–40 minutes. The first FTF
grant was paid after 6 min 36 s and settled after 28 min.

The grantee already has the money at "paid". "Settled" is the DAO's proof.

## What can make a grant slower or stop it?

- **Fee reserves.** The dispatcher pays the CCIP fee for each grant, about 0.00025 ETH on Sepolia. Each receiver pays
  for its receipt, about 0.001 ETH from Base. If a reserve runs low:
  - a grant cannot be sent, and the swap reverts;
  - a receipt fails and is kept as pending. The payout itself is never undone. Anyone can call `retryAck` once the
    receiver is topped up.
- **Lane minimums.** If a lane raises its minimum block depth above what the dispatcher asks for, the owner raises the
  requested depth with `setRequestedFinality`.
- **Source finality on L2s.** Grants sent *from* Base or Arbitrum still wait for full finality, because those lanes
  do not offer FTF.
