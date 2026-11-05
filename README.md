# Nidhi: mandate-gated, ENS-native, cross-chain grant payouts

**ETHGlobal Mumbai.** A Uniswap v4 hook turns one pool into a DAO payout rail. A grant moves only if:
- a DAO **approver** and an **AI auditor** have signed for it (EIP-712), and both hold roles delegated through the DAO's **ENSv2** name;
- the recipient is exactly what the grantee's **ENS subname** resolves to on the payout chain;
- the grant fits the **daily cap**, the **ENS guardian** has not paused payouts, and nobody has cancelled the grant.

The swap output goes straight into **Chainlink CCIP** to the grantee on Base. The destination's **acknowledgement** closes the loop on-chain, and **Chainlink Automation** retries anything that gets stuck.

> **The problem: "blind send."** A DAO payout today is several separate multisig transactions: swap, then hold, then bridge. Nothing cryptographically links the approved mandate, the conversion and the settlement.
> **Nidhi's answer:** authorization, conversion and dispatch happen in **one source-chain transaction or not at all**, and every grant is tracked until it is `SETTLED`.

**Live dashboard:** https://neevmodh.github.io/nidhi/ discovers every contract from `nidhi-dao.eth` and hard-codes nothing.

```
 grants.json ─▶ AI auditor (rubric decides; Groq/Gemini/Cerebras jury may veto) ─signs Attestation─┐
                                                                                                    ▼
 approver ─signs Mandate─▶ NidhiSwapRouter ─▶ PoolManager ─▶ NidhiHook.beforeSwap
                                                              ├─ not paused (ENS guardian), within daily cap, not cancelled
                                                              ├─ EIP-712 x2: ECDSA / EIP-7702 / ERC-1271
                                                              ├─ ENSv2: nidhi-dao.eth → resolver → EAC roles (approver, auditor)
                                                              ├─ ENSv2: alice.nidhi-dao.eth → addr(Base) == mandate.recipient
                                                              └─ bound to pool, direction, exact input, executor, deadline, one use
                                                          swap (flash accounting)
                                                          NidhiHook.afterSwap: output ∈ [minOut,maxOut] → take() → CCIP
 Base Sepolia: DestinationReceiver ─ pays grantee (or HOLDS) ─ ACK ─▶ SETTLED      Automation ─ retries ACKs / held payouts
```

## Live deployment (v3, testnet)

Every address below is also published as an ENS text record on `nidhi-dao.eth` (`nidhi.contract.*`).

| Component | Chain | Address |
|---|---|---|
| `nidhi-dao.eth` resolver (roles + contract records) | Sepolia | [`0x0D919208…aBbF`](https://sepolia.etherscan.io/address/0x0D919208f68a4156E7580B9101171fa72dECaBbF) |
| `NidhiHook` (flags `0xC4`, daily cap 0.001 WETH) | Sepolia | [`0x77099032…00c4`](https://sepolia.etherscan.io/address/0x7709903218297e3cB9bCbb61fee8cEC8514000c4) |
| `NidhiDispatcher` | Sepolia | [`0x5C35D156…2bE1`](https://sepolia.etherscan.io/address/0x5C35D15630af501bf73506eE6cBa37A24cC42bE1) |
| `NidhiSwapRouter` | Sepolia | [`0x8d0b4e8d…58A3`](https://sepolia.etherscan.io/address/0x8d0b4e8d05736e09627F18EE2761F37fd9B558A3) |
| `ENSv2Authority` | Sepolia | [`0x439549E7…4B28`](https://sepolia.etherscan.io/address/0x439549E7A153b43E8c307E1Ab8543Aa28D524B28) |
| ENSv2 subregistry for `*.nidhi-dao.eth` | Sepolia | [`0x562FB95c…C656`](https://sepolia.etherscan.io/address/0x562FB95c17272B850c99496e565bA5eCEDA6C656) |
| Grants resolver (`alice.`, `auditor.` records) | Sepolia | [`0x0195E12d…bd4A`](https://sepolia.etherscan.io/address/0x0195E12dD817F97e7CF7226858F64B8a6BC9bd4A) |
| Pool liquidity: PositionManager NFT **#41398**, owned by the DAO | Sepolia | [PositionManager](https://sepolia.etherscan.io/address/0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4) |
| `DestinationReceiver` (Automation-compatible) | Base Sepolia | [`0x11252C99…0216`](https://sepolia.basescan.org/address/0x11252C994ccba7BE458D78C8901dAD6B5D1F0216) |

### Live proof (real transactions)

| What happened | Evidence |
|---|---|
| **Grant `nidhi-003`, paid to `alice.nidhi-dao.eth`:** audited and signed by the AI auditor key; ENS roles and the ENS recipient checked; swapped; bridged; paid on Base; ACK received → `SETTLED` | [swap tx `0x1a511bb2…`](https://sepolia.etherscan.io/tx/0x1a511bb2c3314dc630cd491970577b0c3e53376b101ed897d7a83b9c8e823648) · [CCIP `0x6c382c72…`](https://ccip.chain.link/msg/0x6c382c7228f29aa035573ffff8f3f7ba62da4361abd23f83f0399008c47b13a5) |
| Guardian (ENS role) **paused** all payouts; a grant attempt then failed with `Paused` | [`0x9d90b420…`](https://sepolia.etherscan.io/tx/0x9d90b420432ea96357bc9797dcfeb5227ca1c6bfee6d38924ccdcf502b021a63) |
| Guardian unpaused | [`0xd1506f51…`](https://sepolia.etherscan.io/tx/0xd1506f512e0ef1902c64a387b61f0e6c78184e582358f32241ef7cc52afabc78) |
| DAO **revoked the approver's ENS role**; the next grant failed with `NotAuthorized` | [`0x0c667850…`](https://sepolia.etherscan.io/tx/0x0c667850e6d9f4c292d07beb30f7a1770fdab8dc6b2583866c504f62178e0a25) |
| Role restored; grants allowed again | [`0xf2c8215c…`](https://sepolia.etherscan.io/tx/0xf2c8215ca89917b9bcce48c6d579a03347604ac9094f8b8da56f35f3e133af29) |
| Approver **cancelled** a signed mandate; executing it failed with `GrantAlreadyUsed` | [`0x0753ee02…`](https://sepolia.etherscan.io/tx/0x0753ee0289831f1b3f00dd2577a72cebaa99d2bd9c3f785076c60beb9097e535) |
| **Batch**: two grants in one transaction (all or nothing) | [`0x79ffe1e4…`](https://sepolia.etherscan.io/tx/0x79ffe1e465629d551db0361e45caea158e5a17506e6d5216eacd1ee66804a003) · CCIP [`0xe15be099…`](https://ccip.chain.link/msg/0xe15be099f5c976d8119afa4f5cc9271cefa30df22cbff145d265f26801def9a6), [`0xec3f761f…`](https://ccip.chain.link/msg/0xec3f761f677075800fc537f29eed83fa541d3444d17e58eb24c4333f52757958) |
| Recipient swapped after signing failed with `BadSignature` | simulated against live state with [`07_LiveScenarios`](script/07_LiveScenarios.s.sol) `tamper()` (nothing sent) |
| v1/v2 grant `nidhi-001`: the first full round trip, `SETTLED` | [swap tx `0xeef72833…`](https://sepolia.etherscan.io/tx/0xeef72833d24991172178bef1100955f8f45a54bbfcd93a08d511733c9ac03948) · [CCIP `0xdeaaa58f…`](https://ccip.chain.link/msg/0xdeaaa58fba42a708914c5bb4ea16f418808c7c26aa6834db5436c6da643f621b) |

## Sponsor integrations (with exact code)

### Uniswap v4: custom hook (`beforeSwap`, `afterSwap`, `afterSwapReturnDelta`)
| What | Where |
|---|---|
| Minimal permissions `0xC4`, mined with `HookMiner` (CREATE2) | [`getHookPermissions` L120](src/NidhiHook.sol#L120), [`02_DeploySource`](script/02_DeploySource.s.sol) |
| Firewall: pause, cap, router, executor, replay, signatures, roles, ENS recipient | [`_beforeSwap` L190](src/NidhiHook.sol#L190), [`_checkBinding` L221](src/NidhiHook.sol#L221), [`_checkSignatures` L234](src/NidhiHook.sol#L234), [`_checkRecipient` L266](src/NidhiHook.sol#L266) |
| Capture: output band, `take()` into the dispatcher, return delta | [`_afterSwap` L286](src/NidhiHook.sol#L286), [`take` L307](src/NidhiHook.sol#L307) |
| EIP-1153 transient grant handoff between the two callbacks | [`ACTIVE_GRANT_SLOT` L72](src/NidhiHook.sol#L72) |
| Trusted router with `msgSender()`; batch payouts in one unlock | [`msgSender` L39](src/NidhiSwapRouter.sol#L39), [`swapBatch` L74](src/NidhiSwapRouter.sol#L74), [`unlockCallback` L88](src/NidhiSwapRouter.sol#L88) |
| Liquidity as a DAO-owned **PositionManager NFT** (Permit2, `MINT_POSITION` + `SETTLE_PAIR`) | [`_createPool`](script/02_DeploySource.s.sol), [`PosmSpike.t.sol`](test/fork/PosmSpike.t.sol) |

### Chainlink: CCIP 2.0 in both directions + Automation
| What | Where |
|---|---|
| Programmable token transfer (token + grant payload), LINK or native fees | [`dispatch` L122](src/NidhiDispatcher.sol#L122), [`ccipSend` L147](src/NidhiDispatcher.sol#L147) |
| ACK receipt changes on-chain state: monotonic ledger, then `SETTLED` | [`NidhiDispatcher._ccipReceive` L178](src/NidhiDispatcher.sol#L178) |
| Defensive receiver: failed payouts are HELD, not reverted; DAO `recover`; decoupled ACK | [`_ccipReceive` L113](src/DestinationReceiver.sol#L113), [`recover` L173](src/DestinationReceiver.sol#L173), [`_ack` L191](src/DestinationReceiver.sol#L191) |
| **Automation**: queue of grants needing work; `checkUpkeep` and `performUpkeep` retry ACKs and held payouts | [`checkUpkeep` L256](src/DestinationReceiver.sol#L256), [`performUpkeep` L270](src/DestinationReceiver.sol#L270), [`09_RegisterUpkeep`](script/09_RegisterUpkeep.s.sol) (registrar 2.3) |
| `extraArgs` encoding isolated in one place | [`ExtraArgsLib.encode` L10](src/libraries/ExtraArgsLib.sol#L10) |

### ENSv2: identities, permissions and discovery (Sepolia, live contracts)
| What | Where |
|---|---|
| **Roles:** approver, auditor and guardian are EAC `ROLE_SET_TEXT` on `keccak256(key)`, read through the DAO name's current resolver | [`isAuthorized` L84](src/ENSv2Authority.sol#L84), [`resourceOf` L76](src/ENSv2Authority.sol#L76) |
| **Pay a name, not an address:** `alice.nidhi-dao.eth` resolves through registry → subregistry → resolver → `addr(node, ENSIP-11 Base coin type)` | [`resolveGrantee` L95](src/ENSv2Authority.sol#L95), [`06_EnsSubnames`](script/06_EnsSubnames.s.sol) |
| **Guardian kill-switch** and **approver cancellation**, gated by ENS roles | [`setPaused` L152](src/NidhiHook.sol#L152), [`cancelGrant` L160](src/NidhiHook.sol#L160) |
| **AI agent identity:** `auditor.nidhi-dao.eth`, which may write only its `nidhi.attestation` text record | [`06_EnsSubnames`](script/06_EnsSubnames.s.sol), [`audit.ts --publish`](offchain/src/audit.ts) |
| **No hard-coded addresses:** contract records on `nidhi-dao.eth` power the dashboard | [`_ensRecords`](script/02_DeploySource.s.sol), [`docs/index.html`](docs/index.html) |
| Fails closed: an expired DAO name, an expired subname or a broken resolver means no payout | [`V3Features.t.sol`](test/unit/V3Features.t.sol), [`LiveSepolia.t.sol`](test/fork/LiveSepolia.t.sol) |

## What makes it hold up
- **No single key can move funds.** Two distinct ENS-role signers are required, and both roles can be revoked instantly in ENS.
- **Bounded blast radius.** Even a leaked approver plus auditor pair can move at most the **daily cap**. The **ENS guardian** stops everything in one transaction, and approvers can **cancel** a mandate before it executes.
- **Each mandate is bound to exactly one swap:** pool, direction, exact input, executor (stops front-running), deadline, destination, ENS recipient, and a one-time `grantId`.
- **Funds never rest anywhere.** Invariants assert that the hook, router and dispatcher always hold zero tokens, and that value is conserved end to end.
- **Liquidity can't be drained.** The v2 seed position, held by v4's test router, was removable by anyone, which [`DrainCheck.t.sol`](test/fork/DrainCheck.t.sol) proves. v3 holds it as a DAO-owned PositionManager NFT.
- **Self-healing destination.** Held payouts and failed ACKs enter a queue that Chainlink Automation drains, and an invariant proves the queue is always exact.
- **Modern signers.** It accepts EOAs, **EIP-7702-delegated EOAs** (OpenZeppelin `SignatureChecker` alone rejects them; found by the live-fork tests) and ERC-1271 smart wallets.
- **The AI is accountable but not trusted.** A deterministic rubric over SHA-pinned GitHub evidence decides, and a **multi-model jury** (Groq, Gemini, Cerebras, optional Claude) can only veto. Amounts come from the DAO's pre-committed grant table. CI re-verifies a committed audit from scratch. `nidhi-002` (merged without an approving review) was correctly **rejected**.

## Tests: 97 passing
```
forge test                        # unit + fuzz + invariant + live Sepolia fork (fork suites need SEPOLIA_RPC_URL)
forge coverage --no-match-contract "LiveSepolia|Spike|DrainCheck"
```
| Suite | What it proves |
|---|---|
| `NidhiFlow.t.sol` (39) | Happy path with the ACK loop; every firewall rejection; 7702 and ERC-1271 signers; HELD, recover and retry; ACK failure never reverts a payout; 512-run fuzz |
| `V3Features.t.sol` (16) + fail-closed (6) | Daily cap and day rollover; guardian pause; cancellation; ENS recipient check, label binding, expiry, re-pointing; batch atomicity; Automation queue |
| `EdgeCases.t.sol` (15) | Native-fee lanes, forged/malformed ACKs, all admin guards |
| `NidhiInvariant.t.sol` (8,192 calls) | No funds rest; value conserved; ledgers agree; **cap never exceeded**; **Automation queue exact**; valid grants always pass, defective ones always fail |
| `LiveSepolia.t.sol` (5) | **Real ENSv2** name, roles, revocation, expiry and **subname resolution**; full grant on the **real v4 PoolManager** |
| Spikes / `DrainCheck` (3) | Live subname resolution, PositionManager NFT mint, proof that the v2 position was drainable |
| `CrossLangEIP712.t.sol` (2) | viem (TypeScript) and Solidity EIP-712 agree; a viem-signed attestation pays out |
| `ENSv2Authority.t.sol` (9) | Resource derivation matches `PermissionedResolverLib`; root/admin/expiry/resolver-switch semantics |

Line coverage: ENSv2Authority 100%, NidhiDispatcher 98.8%, NidhiSwapRouter 97.7%, NidhiHook 97.1%, DestinationReceiver 95.5%. A gas snapshot is in `.gas-snapshot`. CI runs format, build, tests, snapshot check and auditor re-verification ([`.github/workflows/test.yml`](.github/workflows/test.yml)). Slither triage is in [SECURITY.md](SECURITY.md).

## Run it
```bash
# prerequisites: Foundry, Node >= 22.18; copy .env.example to .env and fill in keys
git clone --recursive https://github.com/neevmodh/nidhi && cd nidhi
forge build && forge test

cd offchain && npm ci
node src/audit.ts nidhi-003 --publish   # rubric + LLM jury → signed attestation (+ ENS record)
node src/verify.ts                      # anyone can re-verify
cd ..

forge script script/00_EnsCommit.s.sol    --rpc-url sepolia      --broadcast   # ENSv2 resolver + roles + commit
forge script script/01_EnsRegister.s.sol  --rpc-url sepolia      --broadcast   # register nidhi-dao.eth (after 60s)
forge script script/02_DeploySource.s.sol --rpc-url sepolia      --broadcast   # hook, router, dispatcher, pool NFT, ENS records
forge script script/06_EnsSubnames.s.sol  --rpc-url sepolia      --broadcast   # alice.nidhi-dao.eth, auditor.nidhi-dao.eth
forge script script/03_DeployDest.s.sol   --rpc-url base_sepolia --broadcast   # receiver + ACK fee reserve
forge script script/04_WireSource.s.sol   --rpc-url sepolia      --broadcast   # dispatcher → receiver (+ ENS record)
forge script script/09_RegisterUpkeep.s.sol --rpc-url base_sepolia --broadcast # Chainlink Automation upkeep
forge script script/05_Demo.s.sol         --rpc-url sepolia      --broadcast   # pay an audited grant
forge script script/07_LiveScenarios.s.sol --rpc-url sepolia --broadcast --sig "pause()"   # | unpause revoke regrant tamper cancel batch
```
The full pipeline was rehearsed on local forks of both chains before every live deployment. `08_Migrate` retired v2 and recovered all of its liquidity, LINK and ETH.

More detail: [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](SECURITY.md), [DEMO.md](DEMO.md), [FEEDBACK.md](FEEDBACK.md).
