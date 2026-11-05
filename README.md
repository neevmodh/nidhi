# Nidhi: atomic, mandate-gated cross-chain grant payouts

**ETHGlobal Mumbai.** A Uniswap v4 hook turns one pool into a DAO payout rail. A grant moves only if:
- a DAO **approver** and an **AI auditor** have signed for it (EIP-712), and
- both hold roles delegated through the DAO's **ENSv2** name.

The swap output then goes straight into **Chainlink CCIP** and on to the grantee on another chain. The destination's **acknowledgement** closes the loop on-chain.

> **The problem: "blind send."** Today a DAO payout is several separate multisig transactions: swap, then hold, then bridge. Nothing cryptographically links the approved mandate, the conversion and the settlement.
> **Nidhi's answer:** authorization, conversion and dispatch happen in **one source-chain transaction or not at all**, and every state change is accounted for until the grant is `SETTLED`.

```
 grants.json ─▶ AI auditor ──signs Attestation──┐
 (amounts)     (rubric decides, LLM may veto)   │
                                                ▼
 approver ──signs Mandate──▶ NidhiSwapRouter ─▶ PoolManager ─▶ NidhiHook.beforeSwap
                                                                  ├─ EIP-712 x2 (ECDSA / 7702 / ERC-1271)
                                                                  ├─ ENSv2: name → resolver → EAC role
                                                                  └─ bound to pool, direction, exact input, executor, deadline, one-use
                                                              swap (flash accounting)
                                                              NidhiHook.afterSwap
                                                                  ├─ output must sit in [minOut, maxOut]
                                                                  ├─ afterSwapReturnDelta claims 100% of output
                                                                  └─ take() → NidhiDispatcher → CCIP ccipSend (token + payload)
 Base Sepolia: DestinationReceiver ─ pays grantee (or HOLDS, recoverable) ─ ACK via CCIP ─▶ dispatcher: SETTLED
```

## Live deployment (testnet)

| Component | Chain | Address |
|---|---|---|
| DAO name `nidhi-dao.eth` (ENSv2) → resolver | Sepolia | [`0x0D919208f68a4156E7580B9101171fa72dECaBbF`](https://sepolia.etherscan.io/address/0x0D919208f68a4156E7580B9101171fa72dECaBbF) |
| `NidhiHook` (flags `0xC4`) | Sepolia | [`0xA400E9c24EFf13D9E3AdDa47301Ed875E3dBc0C4`](https://sepolia.etherscan.io/address/0xA400E9c24EFf13D9E3AdDa47301Ed875E3dBc0C4) |
| `NidhiDispatcher` | Sepolia | [`0x825742ff3b49e16E6872A3B0eE89e1883AcDaca3`](https://sepolia.etherscan.io/address/0x825742ff3b49e16E6872A3B0eE89e1883AcDaca3) |
| `NidhiSwapRouter` | Sepolia | [`0xF528F71AececB5eE86e58EcFa7Ca26f46A357c10`](https://sepolia.etherscan.io/address/0xF528F71AececB5eE86e58EcFa7Ca26f46A357c10) |
| `ENSv2Authority` | Sepolia | [`0x5afE82AE1f2311C4E9BAF235990953Ce5C7C6d76`](https://sepolia.etherscan.io/address/0x5afE82AE1f2311C4E9BAF235990953Ce5C7C6d76) |
| `DestinationReceiver` | Base Sepolia | [`0xc4df9D78f3A1031e331235678758020b493A58f9`](https://sepolia.basescan.org/address/0xc4df9D78f3A1031e331235678758020b493A58f9) |

**Grant `nidhi-001`** (deliverable: Uniswap/v4-template#90, audited by `offchain/src/audit.ts`, which signed the attestation itself):
- **One Sepolia transaction** ([`0xeef72833…3948`](https://sepolia.etherscan.io/tx/0xeef72833d24991172178bef1100955f8f45a54bbfcd93a08d511733c9ac03948)) did all of this:
  - verified the approver and auditor signatures;
  - checked both ENS roles through `nidhi-dao.eth`;
  - swapped 0.0001 WETH;
  - passed the full 0.0947 CCIP-BnM output to CCIP.
- **CCIP message:** [`0xdeaaa58f…621b`](https://ccip.chain.link/msg/0xdeaaa58fba42a708914c5bb4ea16f418808c7c26aa6834db5436c6da643f621b)

## Sponsor integrations (with exact code)

### Uniswap v4: custom hook with `beforeSwap`, `afterSwap` and `afterSwapReturnDelta`
| What | Where |
|---|---|
| Minimal permissions (`0xC4`: beforeSwap, afterSwap, afterSwapReturnDelta) | [`src/NidhiHook.sol:105`](src/NidhiHook.sol#L105) |
| Firewall: router, executor, replay, signatures, roles | [`_beforeSwap` L150](src/NidhiHook.sol#L150), [`_checkBinding` L175](src/NidhiHook.sol#L175), [`_checkSignatures` L188](src/NidhiHook.sol#L188) |
| Capture: output band, `take()` into the dispatcher, return delta | [`_afterSwap` L229](src/NidhiHook.sol#L229), [`take` L250](src/NidhiHook.sol#L250), [`return delta` L254](src/NidhiHook.sol#L254) |
| EIP-1153 transient grant handoff between the two callbacks | [`ACTIVE_GRANT_SLOT` L64](src/NidhiHook.sol#L64) |
| Trusted router exposing the real initiator (`msgSender()`) | [`src/NidhiSwapRouter.sol:38`](src/NidhiSwapRouter.sol#L38), [`unlockCallback` L68](src/NidhiSwapRouter.sol#L68) |
| CREATE2 hook-address mining with `HookMiner` | [`script/02_DeploySource.s.sol`](script/02_DeploySource.s.sol) |

### Chainlink CCIP 2.0: programmable token transfer plus a return ACK that changes on-chain state
| What | Where |
|---|---|
| Token and grant payload in one message; LINK or native fees; `getFee` | [`dispatch` L117](src/NidhiDispatcher.sol#L117), [`ccipSend` L142](src/NidhiDispatcher.sol#L142), [`_buildMessage` L159](src/NidhiDispatcher.sol#L159) |
| ACK receipt with router, chain and sender allowlist; monotonic ledger; `SETTLED` | [`NidhiDispatcher._ccipReceive` L173](src/NidhiDispatcher.sol#L173) |
| Defensive receiver: a failed payout is HELD instead of reverting, plus retry and recovery | [`DestinationReceiver._ccipReceive` L100](src/DestinationReceiver.sol#L100), [`retryPayout` L146](src/DestinationReceiver.sol#L146), [`recover` L157](src/DestinationReceiver.sol#L157) |
| Decoupled ACK (can never roll back a payout) with `retryAck` | [`_ack` L175](src/DestinationReceiver.sol#L175), [`sendAck` L187](src/DestinationReceiver.sol#L187) |
| `extraArgs` encoding isolated in one place | [`src/libraries/ExtraArgsLib.sol:10`](src/libraries/ExtraArgsLib.sol#L10) |

### ENSv2: Enhanced Access Control as an on-chain transaction firewall (Sepolia)
| What | Where |
|---|---|
| Name → resolver looked up from the **ENSv2 registry on every check**, nothing hard-coded | [`currentResolver` L57](src/ENSv2Authority.sol#L57) |
| Role = `ROLE_SET_TEXT` on resource `keccak256(key)`, exactly as the deployed `PermissionedResolver` checks it | [`resourceOf` L62](src/ENSv2Authority.sol#L62), [`isAuthorized` L69](src/ENSv2Authority.sol#L69) |
| DAO name, resolver proxy (`VerifiableFactory`) and delegation (`grantSetterRoles`); the admin holds only the *admin* bit | [`script/00_EnsCommit.s.sol`](script/00_EnsCommit.s.sol), [`script/01_EnsRegister.s.sol`](script/01_EnsRegister.s.sol) |
| Revoking a role in ENS stops the very next payout. An expired name **freezes all payouts** (fails closed) | [`test/fork/LiveSepolia.t.sol`](test/fork/LiveSepolia.t.sol) runs against the live ENSv2 contracts |

## What makes it hold up
- **No single key can move funds.** Two distinct signers are required (approver and auditor). Both roles live in ENS, and each can be revoked instantly.
- **Each mandate is bound to exactly one swap:** pool, direction, exact input, executor (stops front-running with a leaked mandate), deadline, destination, and a one-time `grantId`.
- **Slippage is part of the authorization.** Output outside `[minOut, maxOut]` reverts the entire payout.
- **Funds never rest anywhere.** Invariant tests assert the hook, router and dispatcher end every transaction holding zero tokens.
- **Honest guarantees.** The source side is atomic. Delivery on the destination is eventually consistent, but it is never silently lost: it is HELD and recoverable, ACKed on-chain, and flaggable if stuck.
- **Modern signers.** It accepts EOAs, **EIP-7702-delegated EOAs** (OpenZeppelin `SignatureChecker` alone rejects them, a bug that the live-fork tests caught), and ERC-1271 smart wallets such as Safe.
- **The AI is accountable but not trusted.** A deterministic rubric over SHA-pinned GitHub evidence decides; the LLM can only veto. Amounts come from the DAO's pre-committed grant table. Anyone can re-run [`offchain/src/verify.ts`](offchain/src/verify.ts).

## Tests: 71 passing
```
forge test                                   # unit + invariant + live Sepolia fork (fork suite needs SEPOLIA_RPC_URL)
forge coverage --no-match-contract LiveSepolia
```
| Suite | What it proves |
|---|---|
| `NidhiFlow.t.sol` (39) | Happy path with the full ACK loop; every firewall rejection; 7702 and ERC-1271 signers; HELD, recover and retry; ACK failure never reverts a payout; 512-run fuzz conserving value |
| `EdgeCases.t.sol` (15) | Native-fee lanes, forged and malformed ACKs, receiver/dispatcher/router guards |
| `NidhiInvariant.t.sol` (8,192 calls) | No funds rest in intermediaries; value conserved; source and destination ledgers agree; valid grants always pass and defective ones always fail |
| `LiveSepolia.t.sol` (4) | **Real ENSv2** registration, roles, revocation and expiry; a full grant on the **real v4 PoolManager** |
| `CrossLangEIP712.t.sol` (2) | The viem (TypeScript) and Solidity EIP-712 encodings agree; a viem-signed attestation pays out |
| `ENSv2Authority.t.sol` (9) | Resource derivation matches `PermissionedResolverLib`; root/admin/expiry/resolver-switch semantics |

Line coverage: ENSv2Authority 100%, NidhiDispatcher 98.8%, NidhiHook 97.4%, NidhiSwapRouter 96.4%, DestinationReceiver 95.7%. Slither triage is in [SECURITY.md](SECURITY.md).

## Run it
```bash
# prerequisites: Foundry, Node >= 22.18. Fill .env from .env.example (deployer, approver and auditor keys; RPCs)
forge build && forge test

# AI audit of grant nidhi-001 (Uniswap/v4-template#90) → offchain/out/attestation.json
cd offchain && npm install && node src/audit.ts nidhi-001 && node src/verify.ts && cd ..

forge script script/00_EnsCommit.s.sol   --rpc-url sepolia      --broadcast   # ENSv2 resolver + roles + commit
# wait 60s
forge script script/01_EnsRegister.s.sol --rpc-url sepolia      --broadcast   # register nidhi-dao.eth
forge script script/02_DeploySource.s.sol --rpc-url sepolia     --broadcast   # hook (mined), router, dispatcher, pool
forge script script/03_DeployDest.s.sol  --rpc-url base_sepolia --broadcast   # receiver + ACK fee reserve
forge script script/04_WireSource.s.sol  --rpc-url sepolia      --broadcast   # dispatcher → receiver
forge script script/05_Demo.s.sol        --rpc-url sepolia      --broadcast   # pay grant; prints CCIP explorer link
```
The whole pipeline was rehearsed against local forks of Sepolia and Base Sepolia, including real ENSv2 registration and a real CCIP 2.0 `ccipSend`.

More detail: [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](SECURITY.md), [FEEDBACK.md](FEEDBACK.md).
