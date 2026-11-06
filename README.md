# Nidhi: mandate-gated, cross-chain grant payouts

**ETHGlobal Mumbai.** A Uniswap v4 hook turns one pool into a DAO payout rail. A grant moves only if:
- a DAO **approver** and an **AI auditor** have each signed it (EIP-712), and both hold their role in the DAO's authority
  (**ENSv2** on Sepolia, or the DAO-owned `RoleAuthority` on every other chain);
- the recipient is exactly what the grantee's **name** resolves to on the payout chain;
- the grant fits the **daily cap**, the **guardian** has not paused payouts, and nobody has cancelled the grant.

The swap output goes straight into **Chainlink CCIP** to the grantee on another chain. The destination's
**acknowledgement** closes the loop on-chain, and **Chainlink Automation** can retry anything that gets stuck.

> **The problem: "blind send."** A DAO payout today is several separate multisig transactions: swap, then hold, then bridge. Nothing cryptographically links the approved mandate, the conversion and the settlement.
> **Nidhi's answer:** authorization, conversion and dispatch happen in **one source-chain transaction or not at all**, and every grant is tracked until it is `SETTLED`.

**App:** https://neevmodh.github.io/nidhi/ (live chain data, no hard-coded numbers). **Architecture diagrams:**
[ENS](docs/architecture/01-ens.md) · [Uniswap v4](docs/architecture/02-uniswap-v4.md) · [Chainlink CCIP](docs/architecture/03-chainlink-ccip.md).

```
 grants.json ─▶ AI auditor (rubric decides; Groq/Gemini/Cerebras jury may veto) ─signs Attestation─┐
                                                                                                    ▼
 approver ─signs Mandate─▶ NidhiSwapRouter ─▶ PoolManager ─▶ NidhiHook.beforeSwap
                                                              ├─ not paused (guardian), within daily cap, not cancelled
                                                              ├─ EIP-712 x2: ECDSA / EIP-7702 / ERC-1271
                                                              ├─ authority: APPROVER + AUDITOR roles (ENSv2 or RoleAuthority)
                                                              ├─ authority: resolveGrantee(label, destChain) == mandate.recipient
                                                              └─ bound to pool, direction, exact input, executor, deadline, one use
                                                          swap (flash accounting)
                                                          NidhiHook.afterSwap: output in band, price guard → take() → CCIP
 any lane:  DestinationReceiver ─ pays grantee (or HOLDS) ─ ACK ─▶ SETTLED      Automation ─ retries ACKs / held payouts
```

## Live deployment (v4, four testnets)

Every chain runs both sides (dispatcher and receiver), wired along real CCIP lanes. The payout token is CCIP-BnM.
Ownership is handed to the DAO admin `0x9f75…b9C7` (Ownable2Step).

| Chain | `NidhiHook` (flags `0xC4`) | `NidhiDispatcher` | `DestinationReceiver` | `RoleAuthority` |
|---|---|---|---|---|
| Ethereum Sepolia | [`0xa020A751…c0c4`](https://sepolia.etherscan.io/address/0xa020A75106A7a5094Fb0530692Ee8aaADe7fc0c4) | [`0x438E5Db9…5115`](https://sepolia.etherscan.io/address/0x438E5Db9667Ada9B2b892aC2bcAC4E3a5a725115) | [`0x4E5A6ce8…C690`](https://sepolia.etherscan.io/address/0x4E5A6ce89eaDE86be64f1Bb095aA3b45C371C690) | [`0xeBA6566B…15b9`](https://sepolia.etherscan.io/address/0xeBA6566Bee077966F9d28D6d230102e6D43D15b9) |
| Base Sepolia | [`0xB703D879…80c4`](https://sepolia.basescan.org/address/0xB703D879B1F3fE33184841B42bc61097133A80c4) | [`0xc7Bfda6A…31A2`](https://sepolia.basescan.org/address/0xc7Bfda6AC241f12fb21E491866d919A1B03431A2) | [`0x0c892F69…7958`](https://sepolia.basescan.org/address/0x0c892F6905C3C9b4Fb5dA628B3F8048e09107958) | [`0x8C507e44…13BE`](https://sepolia.basescan.org/address/0x8C507e4407466A2550E16EAe3a6BE8ABAa5C13BE) |
| Arbitrum Sepolia | [`0x56d56254…80c4`](https://sepolia.arbiscan.io/address/0x56d56254A518142375E9eA9a69f310aB8D7b80c4) | [`0xB2ab0955…D36A`](https://sepolia.arbiscan.io/address/0xB2ab0955a101802Bc9e2F1ec099Bd74Aed9bD36A) | [`0xd52365cA…D6B9`](https://sepolia.arbiscan.io/address/0xd52365cA8Fa5Cf07f3Bd9dFd64c024E455F4D6B9) | [`0x11252C99…0216`](https://sepolia.arbiscan.io/address/0x11252C994ccba7BE458D78C8901dAD6B5D1F0216) |
| Unichain Sepolia | [`0x2835f2af…C0c4`](https://unichain-sepolia.blockscout.com/address/0x2835f2af22486B547EE2E3F94805160b380bC0c4) | [`0xB2ab0955…D36A`](https://unichain-sepolia.blockscout.com/address/0xB2ab0955a101802Bc9e2F1ec099Bd74Aed9bD36A) | [`0xd52365cA…D6B9`](https://unichain-sepolia.blockscout.com/address/0xd52365cA8Fa5Cf07f3Bd9dFd64c024E455F4D6B9) | [`0x11252C99…0216`](https://unichain-sepolia.blockscout.com/address/0x11252C994ccba7BE458D78C8901dAD6B5D1F0216) |

**ENSv2-gated stack (Sepolia):** [`ENSv2Authority` 0x92ceAa59…5600](https://sepolia.etherscan.io/address/0x92ceAa59dfB8Ce4A85dCECFd26e50Ba58e375600) on `nidhi-dao.eth` · hook [`0x88257DA3…80c4`](https://sepolia.etherscan.io/address/0x88257DA3a88Aaaf8b3EEF52112Bfb9C3596580c4) · dispatcher [`0x2bE281A8…A07b`](https://sepolia.etherscan.io/address/0x2bE281A806d754c2a7b5899a7effb649Fb72A07b), with its own receivers on [Base Sepolia](https://sepolia.basescan.org/address/0x9197993f0c9fc1B9920e9f1b81b4852334B2Cc83) and [Arbitrum Sepolia](https://sepolia.arbiscan.io/address/0xa08D0621872539A8b5c0DB986BDb7367833aA6cA).

Lanes wired: Sepolia ⇄ Base, Sepolia ⇄ Arbitrum, Sepolia ⇄ Unichain, Base ⇄ Arbitrum, Arbitrum ⇄ Unichain. All addresses
are in `deployments/<chainId>.json`; chain data comes from `chains/testnets.json`, generated and checked on-chain by
`offchain/src/testnets.ts`.

### Live proof (v4, real transactions)

| What happened | Evidence |
|---|---|
| **Base Sepolia → Arbitrum Sepolia:** signed, swapped in the hook, bridged, 0.2934 BnM paid to the grantee, ACK back → `SETTLED` | [swap](https://sepolia.basescan.org/tx/0xdd2b11a77fa318b95c812589f07211ad71e0fbc0e174fc6b78487a1bc1b328a0) · [CCIP](https://ccip.chain.link/msg/0x60433b4f9215063950bde9736f3618766fdbbdde7f43e895dba724fc3d2faf7e) · [payout](https://sepolia.arbiscan.io/tx/0x74c5f98f165389683c3201ce3b283e63e9965eaed03c5faed8d389e8f6d3c21c) |
| **Sepolia → Base Sepolia:** same loop, 0.2917 BnM paid → `SETTLED` | [swap](https://sepolia.etherscan.io/tx/0xf2d1a270524c098410037c03720714fbe049fba9ba880b1463c0b3fd53f9207a) · [CCIP](https://ccip.chain.link/msg/0x9c3ddac23e4af71f197c9b71b36b36f11fdbc8068e25c8c6d36468d65ff1fdfa) · [payout](https://sepolia.basescan.org/tx/0xf3e05ffddcbd9e86ca12ae3c84783a1f1482824613f4ed6cbdf9449e1d628294) |
| **The app's own signing code, on-chain:** a grant built, quoted (V4Quoter) and signed with `ui/src/lib/mandate.ts`, carrying the real audit evidence of `nidhi-001` | [swap](https://sepolia.basescan.org/tx/0x23c79346238efea4b006f4a6a9533d26a393609630783a38fb89c84170f76c74) ([`ui/scripts/e2e-grant.ts`](ui/scripts/e2e-grant.ts)) |

| **ENSv2-gated grant to `alice.nidhi-dao.eth`:** roles read from the DAO's ENS name, payee resolved through the ENSv2 subregistry for Base Sepolia, swapped and sent by CCIP | [swap](https://sepolia.etherscan.io/tx/0x696887ae1880740414a2746ad6c2e764f248781ecf26eaaaabcda723088fe3e0) · [CCIP](https://ccip.chain.link/msg/0xe5721859a03a43697d7ce3b2c5fcd8a73a5d5c9ed881ab34db33edb4ccba17a2) |
| **The AI auditor, as the ENS agent `auditor.nidhi-dao.eth`, published its attestation** to the one text record it may write | [`setText`](https://sepolia.etherscan.io/tx/0x9956a77cc937c7c33839c7882fa8de598bf8f5c296e1ad88d44ade924586c85c) |
| **`bob.nidhi-dao.eth` got his own Permissioned Resolver**; the DAO key then gave up its setter role, so only bob controls where he is paid | [resolver](https://sepolia.etherscan.io/tx/0x4fa99ec2271f4622b63b77186131c70612912f524517d6c2ca81bb5fc01be10d) · [renounce](https://sepolia.etherscan.io/tx/0xe39eb0a174890df7e9771519cf1c9e619a58128a792a5f2cbf05c779bc570e73) |
| **`carol.nidhi-dao.eth` registered with an expiry = her grant period**; after it, ENS stops resolving her and the hook refuses to pay | [register](https://sepolia.etherscan.io/tx/0x5de4f4a47b52aad6088d5ad189ff0911caf60106f91fbf3905c7223998a50953) |
| An **unregistered name (`mallory`) is refused** by the ENS-gated hook with `RecipientMismatch` | simulated against live state (`script/ens/`, nothing sent) |

The first two grants carried a fixed evidence hash; the third carries the auditor's real one.

### Mainnet: rehearsed, not deployed

`chains/registry.json` covers the 21 Uniswap v4 mainnets. Ten can send USDC by CCIP (50 lanes). The same Deploy / Wire /
Handover scripts were run on forks of each against the real PoolManager, PositionManager, V4Quoter, StateView, CCIP router
and USDC: Ethereum, Base, Arbitrum, Polygon, Avalanche, HyperEVM and Monad pass; Optimism, Unichain and Ink were skipped
because their CCIP RMN was cursed when checked. Deploying needs a funded deployer (`node offchain/src/preflight.ts`).

### Earlier live proof (v3, Sepolia → Base Sepolia, ENSv2, retired)

| What happened | Evidence |
|---|---|
| **Grant `nidhi-003`, paid to `alice.nidhi-dao.eth`:** ENS roles and the ENS recipient checked; swapped; bridged; paid on Base; ACK → `SETTLED` | [swap tx](https://sepolia.etherscan.io/tx/0x1a511bb2c3314dc630cd491970577b0c3e53376b101ed897d7a83b9c8e823648) · [CCIP](https://ccip.chain.link/msg/0x6c382c7228f29aa035573ffff8f3f7ba62da4361abd23f83f0399008c47b13a5) |
| Guardian (ENS role) **paused** all payouts; a grant attempt then failed with `Paused` | [`0x9d90b420…`](https://sepolia.etherscan.io/tx/0x9d90b420432ea96357bc9797dcfeb5227ca1c6bfee6d38924ccdcf502b021a63) |
| DAO **revoked the approver's ENS role**; the next grant failed with `NotAuthorized` | [`0x0c667850…`](https://sepolia.etherscan.io/tx/0x0c667850e6d9f4c292d07beb30f7a1770fdab8dc6b2583866c504f62178e0a25) |
| Approver **cancelled** a signed mandate; executing it failed with `GrantAlreadyUsed` | [`0x0753ee02…`](https://sepolia.etherscan.io/tx/0x0753ee0289831f1b3f00dd2577a72cebaa99d2bd9c3f785076c60beb9097e535) |
| **Batch**: two grants in one transaction (all or nothing) | [`0x79ffe1e4…`](https://sepolia.etherscan.io/tx/0x79ffe1e465629d551db0361e45caea158e5a17506e6d5216eacd1ee66804a003) |

The v3 scripts are archived in [`legacy/sepolia-v3/`](legacy/sepolia-v3/).

## Prize tracks: what each asks for, and where it is

### Build with Uniswap
| They ask for | Nidhi |
|---|---|
| A new v4 hook | `NidhiHook`: mandate-gated, captures its own output with `afterSwapReturnDelta`, live on 4 testnets ([`_beforeSwap` L238](src/NidhiHook.sol#L238), [`_afterSwap` L351](src/NidhiHook.sol#L351)) |
| Uniswap AMM v4 | Real PoolManagers; DAO liquidity as a PositionManager NFT via Permit2 ([`_mintUsdcOnly`](script/mainnet/Deploy.s.sol)); exact quotes from V4Quoter, which the hook lets through ([L245](src/NidhiHook.sol#L245)); an on-chain price guard from StateView ([`_checkReferencePrice` L317](src/NidhiHook.sol#L317)) |
| The Uniswap API | Trading API for the auditor's USD valuation and treasury funding ([`tradingApi.ts`](offchain/src/uniswap/tradingApi.ts), [`treasury.ts`](offchain/src/treasury.ts)) |
| Tooling for the ecosystem | A generated, on-chain-checked registry of every v4 chain ([`registry.ts`](offchain/src/registry.ts), [`testnets.ts`](offchain/src/testnets.ts)) and fork rehearsals ([`rehearse-all.sh`](offchain/rehearse-all.sh)) |
| `FEEDBACK.md` | [FEEDBACK.md](FEEDBACK.md) |

### Best Use of ENSv2
| They ask for | Nidhi |
|---|---|
| ENSv2 central, not cosmetic | On the Sepolia ENS stack the DAO's name **is** the authority: no ENS role, no grant; no ENS name, no payee ([`ENSv2Authority`](src/ENSv2Authority.sol): [`isAuthorized` L94](src/ENSv2Authority.sol#L94), [`resolveGrantee` L105](src/ENSv2Authority.sol#L105)) |
| Enhanced Access Control to delegate specific rights | Each role is permission to set one text record on `nidhi-dao.eth`; the auditor agent may set only `nidhi.attestation` |
| Your own subname registry | A UserRegistry for `*.nidhi-dao.eth`; grantees are subnames ([`EnsSetup.s.sol`](script/ens/EnsSetup.s.sol)) |
| Subnames with their own Permissioned Resolver | `bob.nidhi-dao.eth` owns his resolver; the DAO renounced its setter role |
| Expiring / revocable subnames | `carol.nidhi-dao.eth` expires with her grant period; a revoked role stops a signer on the next swap (proven live in v3) |
| Bonus: AI agents as namespaces | `auditor.nidhi-dao.eth`, the AI auditor, publishes each signed verdict to its own record |
| Functional demo, no hard-coded values | The app's ENS page reads roles, resolvers, per-chain addresses, expiry and the agent's record live from ENSv2 ([`Ens.tsx`](ui/src/pages/Ens.tsx)) |

### Best use of Chainlink CCIP 2.0
| They ask for | Nidhi |
|---|---|
| CCIP inside smart contracts, changing state | A programmable token transfer pays the grantee; a second message (the ACK) moves the source ledger to `SETTLED` ([`dispatch` L120](src/NidhiDispatcher.sol#L120), [`NidhiDispatcher._ccipReceive` L182](src/NidhiDispatcher.sol#L182)) |
| Token transfers and arbitrary messaging | Both, in both directions, over 5 live lanes between 4 testnets |
| Liquidity across multiple chains | A hooked v4 pool on every chain, each able to pay any chain it has a lane to |
| CCIP Local Simulator | Used across the Foundry tests (`test/`) |
| Encouraged: Automation, Data Feeds, CRE, VRF | Automation-compatible receiver queue ([`checkUpkeep` L263](src/DestinationReceiver.sol#L263)); not registered on testnet (needs LINK). Data Feeds, CRE and VRF are not used |

## Sponsor integrations (with exact code)

### Uniswap v4: custom hook (`beforeSwap`, `afterSwap`, `afterSwapReturnDelta`)
| What | Where |
|---|---|
| Minimal permissions `0xC4`, mined with `HookMiner` (CREATE2) | [`getHookPermissions` L168](src/NidhiHook.sol#L168), [`Deploy.s.sol`](script/mainnet/Deploy.s.sol) |
| Firewall: pause, cap, router, executor, replay, signatures, roles, ENS recipient | [`_beforeSwap` L238](src/NidhiHook.sol#L238), [`_checkBinding` L273](src/NidhiHook.sol#L273), [`_checkSignatures` L286](src/NidhiHook.sol#L286), [`_checkRecipient` L331](src/NidhiHook.sol#L331) |
| Capture: output band, `take()` into the dispatcher, return delta | [`_afterSwap` L351](src/NidhiHook.sol#L351), [`take` L374](src/NidhiHook.sol#L374) |
| EIP-1153 transient grant handoff between the two callbacks | [`ACTIVE_GRANT_SLOT` L105](src/NidhiHook.sol#L105) |
| Trusted router with `msgSender()`; batch payouts in one unlock | [`msgSender` L39](src/NidhiSwapRouter.sol#L39), [`swapBatch` L74](src/NidhiSwapRouter.sol#L74), [`unlockCallback` L88](src/NidhiSwapRouter.sol#L88) |
| Liquidity as a DAO-owned **PositionManager NFT** (Permit2, `MINT_POSITION` + `SETTLE_PAIR`) | [`_mintUsdcOnly`](script/mainnet/Deploy.s.sol), [`PosmSpike.t.sol`](test/fork/PosmSpike.t.sol) |

### Chainlink: CCIP 2.0 in both directions + Automation
| What | Where |
|---|---|
| Programmable token transfer (token + grant payload), LINK or native fees | [`dispatch` L120](src/NidhiDispatcher.sol#L120), [`ccipSend` L147](src/NidhiDispatcher.sol#L147) |
| ACK receipt changes on-chain state: monotonic ledger, then `SETTLED` | [`NidhiDispatcher._ccipReceive` L182](src/NidhiDispatcher.sol#L182) |
| Defensive receiver: failed payouts are HELD, not reverted; DAO `recover`; decoupled ACK | [`_ccipReceive` L119](src/DestinationReceiver.sol#L119), [`recover` L180](src/DestinationReceiver.sol#L180), [`_ack` L198](src/DestinationReceiver.sol#L198) |
| **Automation**: queue of grants needing work; `checkUpkeep` and `performUpkeep` retry ACKs and held payouts | [`checkUpkeep` L263](src/DestinationReceiver.sol#L263), [`performUpkeep` L277](src/DestinationReceiver.sol#L277), [`09_RegisterUpkeep`](legacy/sepolia-v3/09_RegisterUpkeep.s.sol) (registrar 2.3) |
| `extraArgs` encoding isolated in one place | [`ExtraArgsLib.encode` L10](src/libraries/ExtraArgsLib.sol#L10) |

### ENSv2: identities, permissions and discovery (Sepolia, live contracts)
| What | Where |
|---|---|
| **Roles:** approver, auditor and guardian are EAC `ROLE_SET_TEXT` on `keccak256(key)`, read through the DAO name's current resolver | [`isAuthorized` L94](src/ENSv2Authority.sol#L94), [`resourceOf` L86](src/ENSv2Authority.sol#L86) |
| **Pay a name, not an address:** `alice.nidhi-dao.eth` resolves through registry → subregistry → resolver → `addr(node, ENSIP-11 Base coin type)` | [`resolveGrantee` L105](src/ENSv2Authority.sol#L105), [`06_EnsSubnames`](legacy/sepolia-v3/06_EnsSubnames.s.sol) |
| **Guardian kill-switch** and **approver cancellation**, gated by ENS roles | [`setPaused` L200](src/NidhiHook.sol#L200), [`cancelGrant` L208](src/NidhiHook.sol#L208) |
| **AI agent identity:** `auditor.nidhi-dao.eth`, which may write only its `nidhi.attestation` text record | [`06_EnsSubnames`](legacy/sepolia-v3/06_EnsSubnames.s.sol), [`audit.ts --publish`](offchain/src/audit.ts) |
| **No hard-coded addresses:** contract records on `nidhi-dao.eth` powered the v3 dashboard | [`_ensRecords`](legacy/sepolia-v3/02_DeploySource.s.sol), [`docs/legacy/index.html`](docs/legacy/index.html) |
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

## Tests: 114 passing (unit, fuzz, invariant) plus fork suites
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
node src/audit.ts nidhi-001            # rubric + LLM jury → signed attestation
node src/verify.ts                     # anyone can re-verify
node src/testnets.ts                   # regenerate chains/testnets.json (on-chain checks)
cd ..

# deploy, per chain (REGISTRY=chains/testnets.json for testnets; mainnets use chains/registry.json)
forge script script/mainnet/Deploy.s.sol   --rpc-url <chain> --broadcast --slow   # stack, mined hook, pool, LP NFT
forge script script/mainnet/Wire.s.sol     --rpc-url <chain> --broadcast --slow   # add-only CCIP routes
forge script script/mainnet/Handover.s.sol --rpc-url <chain> --broadcast --slow   # Ownable2Step to the DAO admin
DEST_CHAIN=421614 forge script script/mainnet/LiveGrant.s.sol --rpc-url <chain> --broadcast   # send one grant

cd ui && npm ci && npm run dev           # the app, reading the live deployment
```
Every deploy was rehearsed on anvil forks first (`offchain/rehearse-all.sh` for mainnets).

More detail: [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](SECURITY.md), [DEMO.md](DEMO.md), [FEEDBACK.md](FEEDBACK.md).
