# Nidhi: demo script (3–4 minutes)

Before recording, open these tabs:
- **Dashboard:** https://neevmodh.github.io/nidhi/
- **Terminal** in the repo, with `.env` filled in.
- **MetaMask on Base Sepolia**, with the CCIP-BnM token imported (`0x88A2d74F47a237a62e7A51cdDa67270CE381555e`).
- **CCIP Explorer:** https://ccip.chain.link

---

### 0:00 – 0:25: The problem
> "A DAO paying a grant today signs a swap, holds the tokens, then signs a bridge. Three disconnected steps, three chances
> to send the wrong amount to the wrong place. We call it the blind send."

Show the one-line flow at the top of the dashboard.

### 0:25 – 0:55: Identity lives in ENS
> "Nidhi's permissions are not in our contracts. They live in the DAO's ENSv2 name."

On the dashboard, show the panel **Discovered from nidhi-dao.eth**. Every contract address comes from the name's text records. Then show **ENS identities**: `alice.nidhi-dao.eth` resolves to the grantee's Base wallet, and `auditor.nidhi-dao.eth` is the AI agent.

### 0:55 – 1:35: The AI auditor
```bash
cd offchain && node src/audit.ts nidhi-003 && node src/verify.ts
```
> "The rubric decides: merged, approved, CI green, right files. A jury of models (Groq, Gemini, Cerebras) can only veto.
> Amounts come from the DAO's grant table, never from an LLM. Anyone can re-verify."

Then show the rejection:
```bash
node src/audit.ts nidhi-002
```
> "This PR was merged without review, so it is rejected and nothing is signed."

### 1:35 – 2:25: One transaction pays the grant
```bash
cd .. && forge script script/05_Demo.s.sol --rpc-url sepolia --broadcast
```
> "In one Sepolia transaction the hook checks both signatures, both ENS roles, that the recipient is exactly what
> alice.nidhi-dao.eth resolves to on Base, the daily cap, and the guardian switch. Then it swaps, captures the whole output,
> and hands it to Chainlink CCIP. The executor receives nothing; funds never rest in a wallet."

Open the printed CCIP Explorer link. When the message lands, show the CCIP-BnM balance in MetaMask on Base, then the dashboard row turning **SETTLED** once the ACK returns.

### 2:25 – 3:20: Try to break it (live)
```bash
forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --broadcast --sig "revoke()"   # ENS role revoked → NotAuthorized
forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --broadcast --sig "regrant()"
forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --broadcast --sig "pause()"    # guardian → Paused
forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --broadcast --sig "unpause()"
forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --sig "tamper()"               # recipient swapped → BadSignature
```
> "Revoke a role in ENS and the very next payout fails. The guardian stops everything in one transaction. Change one byte of a
> signed mandate and it fails. And even if both keys leaked, the daily cap bounds the damage."

### 3:20 – 3:45: It heals itself
> "If a payout can't complete on Base, the funds are held, never lost. Chainlink Automation retries stuck acknowledgements
> and held payouts, and the DAO can recover to a safe address."

Show the **Self-healing queue** on the dashboard and `checkUpkeep` / `performUpkeep` in [`DestinationReceiver.sol`](src/DestinationReceiver.sol).

### 3:45 – 4:00: Close
> "97 tests including live-fork tests against the real ENSv2 and Uniswap contracts, invariants, Slither triage, and every claim
> backed by a transaction hash in the README. Nidhi: pay a name, under a mandate, in one transaction."

---

**If something is slow live:** CCIP testnet delivery waits for Sepolia finality (15–25 minutes). Record the payout and the `SETTLED` state from the earlier grant `nidhi-003` (links in the README) instead of waiting on camera.
