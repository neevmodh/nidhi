# Nidhi: demo script (about 4 minutes)

**Before recording, open:**
- **The app:** https://neevmodh.github.io/nidhi/ (or `cd ui && npm run dev`). Use the evening grade.
- **MetaMask** with the admin wallet, and CCIP-BnM imported on Base Sepolia (`0x88A2d74F47a237a62e7A51cdDa67270CE381555e`).
- **CCIP Explorer:** https://ccip.chain.link
- **This repo on GitHub**, with `README.md` open at "Prize tracks".

Every number on screen is read live from the chains. If an RPC is slow, wait a second; nothing is pre-recorded.

---

### 0:00 – 0:25 · The problem (landing page)
> "A DAO paying a grant today signs a swap, holds the tokens, then signs a bridge: three separate steps and three chances to
> pay the wrong amount to the wrong place. Nidhi does all of it in one transaction, and only after two signatures."

Point at the hero card: it is the newest real grant, live, with its five steps.

### 0:25 – 1:10 · Uniswap v4: the hook is the gate (Overview, then a grant timeline)
> "The grant is a swap through our Uniswap v4 hook. The hook checks two EIP-712 signatures, the daily cap and the price band,
> then takes the output straight into the CCIP dispatcher, so the caller never holds it."

- **Overview:** cap left today, fee reserve, routes and health, all read live from the hook and the dispatcher.
- **Pool:** the pool price comes from Uniswap's StateView, and the DAO's liquidity is a PositionManager NFT.
- **New grant:** type `alice`. The name check and the V4Quoter quote run as you type.

### 1:10 – 2:00 · Chainlink CCIP: paid on another chain, with a receipt (Grants → a settled grant)
> "CCIP carries the exact amount and the grant data to the grantee's chain. The receiver pays, then sends a receipt back, and
> the source ledger moves to Settled. Every step links to the real transaction."

Click **CCIP explorer** on the timeline to show the message. Then open the **multi-hop** grant (Base Sepolia → Unichain Sepolia):
> "Base and Unichain share no CCIP lane. Our relay on Arbitrum forwards the grant and returns the receipt, so the DAO can pay a
> chain without worrying whether a lane exists."

Show the relay step in its timeline.

### 2:00 – 3:10 · ENSv2: the DAO's name decides (ENS page)
> "On Sepolia the authority is the DAO's ENSv2 name. A role is Enhanced Access Control permission to set one text record on
> nidhi-dao.eth. Revoke it in ENS, and that signer is stopped on the next swap."

- **Roles:** the approver and auditor hold their roles; paste any address to check it live.
- **Grantees are subnames:** alice on the shared resolver, bob with **his own resolver** (only his wallet can change it), carol
  with an **expiring** name as her grant period. After it expires she shows "grants refused".
- **The AI auditor is an ENS agent:** `auditor.nidhi-dao.eth` holds its signed verdict, and that is the only record it may write.
- Open the ENS-gated grant to `alice.nidhi-dao.eth` in **Grants**: "Decided by ENSv2".

### 3:10 – 3:40 · Safety (landing page, Security section)
> "Two different signers, a daily cap, a guardian pause, routes that can only be added, a receiver that never reverts, and on
> mainnet a price band against the deep Uniswap pool."

Optional: on **Network**, switch to **Mainnets, ready**: rehearsed on forks of each chain, not deployed.

### 3:40 – 4:00 · Close
> "Nidhi: Uniswap v4 enforces the grant, Chainlink CCIP settles it across chains, ENSv2 says who is allowed. It's all open
> source, with every claim linked to code and transactions in the README."

---

## If something goes wrong live
- **A screen shows "Could not reach…":** a public RPC is slow. Reload, or switch chains and back.
- **A grant is "In flight":** testnet CCIP takes 10 to 25 minutes per leg. Show a settled grant instead.
- **The wallet says "does not hold the approver role":** that is the role check working. Signing needs the role keys.
