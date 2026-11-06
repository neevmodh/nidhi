# Uniswap v4 in Nidhi

Uniswap v4 is Nidhi's **execution and enforcement layer**. A grant is not "send money". It is a **swap that cannot happen
unless a valid mandate rides along with it**, and whose output never reaches the person who sent it. Every rule is checked
inside the swap by the hook, so there is no gap between "approved" and "paid".

Contents: [1 system view](#1-system-view) · [2 the pool](#2-the-pool) · [3 a grant swap, call by call](#3-a-grant-swap-call-by-call) ·
[4 every check and its error](#4-every-check-and-its-error) · [5 flash accounting](#5-flash-accounting-why-the-swapper-never-touches-the-output) ·
[6 the trusted router](#6-the-trusted-router-who-really-sent-the-swap) · [7 quoting through a gated hook](#7-quoting-through-a-gated-hook) ·
[8 the price guard](#8-the-reference-price-guard-stateview) · [9 contract approvers](#9-a-contract-as-approver-erc-1271) ·
[10 liquidity](#10-liquidity-a-positionmanager-nft) · [11 tools used](#11-every-uniswap-tool-and-its-job) · [12 multi-chain](#12-one-hook-every-chain) ·
[13 code](#13-code)

---

## 1. System view

```mermaid
flowchart TB
  subgraph UNI["Uniswap v4 (the canonical deployments)"]
    PM["PoolManager<br/>singleton, flash accounting"]
    POSM["PositionManager<br/>LP positions as NFTs"]
    P2["Permit2"]
    Q["V4Quoter"]
    SV["StateView"]
    TAPI["Trading API"]
  end
  subgraph NIDHI["Nidhi"]
    RT["NidhiSwapRouter<br/>exposes msgSender()"]
    HK["NidhiHook<br/>address ends in 0xC4<br/>beforeSwap · afterSwap · afterSwapReturnDelta"]
    DS["NidhiDispatcher"]
    AU["Authority<br/>ENSv2 or RoleAuthority"]
    BB["NidhiBountyBoard<br/>(ERC-1271 approver)"]
  end
  EX(["executor: the agent or a person<br/>holds WETH, carries hookData"]) -->|"swap(key, params, hookData)"| RT
  RT -->|"unlock, swap"| PM
  PM -->|"callbacks"| HK
  HK -->|"roles, payee"| AU
  HK -.->|"isValidSignature"| BB
  HK -->|"take(output) to"| DS
  Q -.->|"quote only, allowed through"| HK
  HK -.->|"getSlot0 of the deep pool"| SV
  DAO["DAO treasury"] -->|"approve"| P2 --> POSM --> PM
  AUD["AI auditor"] -.->|"USD value"| TAPI
```

---

## 2. The pool

| Property | Value |
|---|---|
| Pair | wrapped native (WETH) / payout token (USDC on mainnets, CCIP-BnM on testnets) |
| Fee, tick spacing | 3000 (0.30%), 60 |
| Hook flags | `0xC4` = `BEFORE_SWAP` + `AFTER_SWAP` + `AFTER_SWAP_RETURNS_DELTA`, mined into the hook's address |
| Hook deployment | CREATE2 through the canonical deployer, salt found by `HookMiner` for each chain (each chain's PoolManager differs, so each chain needs its own salt) |
| Opening price | mainnets: the canonical deep pool's price; testnets: about 1 WETH = 1000 payout tokens |
| Liquidity | one payout-token-only position held as a PositionManager NFT, owned by the DAO |

Grant swaps go from WETH to the payout token and pull from that single-sided position.

---

## 3. A grant swap, call by call

```mermaid
sequenceDiagram
  autonumber
  actor EX as Executor
  participant RT as NidhiSwapRouter
  participant PM as PoolManager
  participant HK as NidhiHook
  participant AU as Authority (ENSv2)
  participant SV as StateView
  participant DS as NidhiDispatcher

  EX->>RT: swap(key, exact input, hookData = GrantAuth)
  RT->>RT: remember the initiator (transient storage)
  RT->>PM: unlock(...)
  PM->>RT: unlockCallback
  RT->>PM: swap(key, params, hookData)
  PM->>HK: beforeSwap(sender = router, ...)
  Note over HK: right pool, not paused, sender is the trusted router
  Note over HK: deadline, exact input, direction tokenIn to tokenOut
  Note over HK: router.msgSender() == mandate.executor
  Note over HK: grantId unused, two EIP-712 signatures, two different signers
  HK->>AU: approver and auditor hold their roles?
  HK->>AU: resolveGrantee(label, chain) == mandate.recipient?
  Note over HK: amount within today's cap, then mark the grant used
  HK->>HK: tstore(active grant)
  PM->>PM: run the swap
  PM->>HK: afterSwap(delta)
  Note over HK: tload: same grant, clear it
  Note over HK: output within the signed band
  HK->>SV: getSlot0(reference pool) (when the guard is on)
  HK->>PM: take(output, to the dispatcher)
  HK->>DS: dispatch(mandate, output)
  HK-->>PM: return +output as the afterSwap delta
  RT->>PM: settle amountIn from the executor
  RT-->>EX: done: the output is already on its way by CCIP
```

---

## 4. Every check, and its error

```mermaid
flowchart TD
  IN(["beforeSwap"]) --> Q{"sender is the V4Quoter?"}
  Q -- yes --> QOK["allow: quote only, the quoter reverts its own swap"]
  Q -- no --> C1{"pool set and matches"} -- no --> E1["WrongPool"]
  C1 -- yes --> C2{"not paused"} -- no --> E2["Paused"]
  C2 -- yes --> C3{"sender is the trusted router"} -- no --> E3["UntrustedRouter"]
  C3 -- yes --> C4{"deadline, exact input, direction, complete mandate"} -- no --> E4["MandateExpired / NotExactInput /<br/>WrongDirection / InvalidMandate"]
  C4 -- yes --> C5{"initiator is the executor"} -- no --> E5["WrongExecutor"]
  C5 -- yes --> C6{"grant never used"} -- no --> E6["GrantAlreadyUsed"]
  C6 -- yes --> C7{"valid signatures, two signers, roles held"} -- no --> E7["BadSignature / SameSigner /<br/>NotAuthorized / AttestationMismatch"]
  C7 -- yes --> C8{"payee is what the ENS name resolves to"} -- no --> E8["RecipientMismatch"]
  C8 -- yes --> C9{"within today's cap"} -- no --> E9["CapExceeded"]
  C9 -- yes --> OK["mark used, remember the active grant"]
  OK --> AS(["afterSwap"])
  AS --> D1{"same active grant"} -- no --> F1["NoActiveGrant"]
  D1 -- yes --> D2{"output between minOut and maxOut"} -- no --> F2["OutputOutOfBounds"]
  D2 -- yes --> D3{"price near the reference pool"} -- no --> F3["PriceDeviation"]
  D3 -- yes --> CAP["take the output, dispatch by CCIP"]
```

The PoolManager wraps a hook revert as `WrappedError(hook, selector, reason, HookCallFailed)`. Tests unwrap it and assert
the exact inner error, and the app decodes it into one plain sentence.

---

## 5. Flash accounting: why the swapper never touches the output

```mermaid
flowchart LR
  S1["swap: the pool owes OUT to the swapper<br/>(delta +OUT)"] --> S2["hook take(OUT) to the dispatcher<br/>(hook delta -OUT)"]
  S2 --> S3["hook returns +OUT as its afterSwap delta<br/>hook nets to zero;<br/>swapper's output delta becomes zero"]
  S3 --> S4["router settles amountIn only"]
  S4 --> END["at the end of unlock everything balances:<br/>OUT is in the dispatcher, bound to the grant"]
```

The executor puts in WETH and receives nothing. The payout token goes from the PoolManager to the dispatcher in the same
transaction, and from there into a CCIP message. EIP-1153 transient storage carries the active grant from `beforeSwap` to
`afterSwap`.

---

## 6. The trusted router: who really sent the swap

In a v4 hook, `sender` is the contract that called the PoolManager, not the person. `NidhiSwapRouter` records the real
initiator in transient storage and exposes it through `msgSender()`. The hook accepts swaps only from this router, and
requires `msgSender()` to equal the mandate's executor, so nobody can front-run a signed mandate.

---

## 7. Quoting through a gated hook

A hook that reverts unauthorised swaps also reverts quotes, because the V4Quoter simulates a swap. Nidhi passes the chain's
canonical V4Quoter into the hook, and the hook lets `sender == quoter` through with a zero delta. The quoter always reverts
its own simulated swap, so nothing persists. The app quotes every grant and milestone this way.

---

## 8. The reference-price guard (StateView)

```mermaid
flowchart LR
  A["achieved rate<br/>payout out / WETH in"] --> CMP{"within maxDeviationBps<br/>(300 on mainnets)"}
  B["reference spot price<br/>StateView.getSlot0 of the deep pool"] --> CMP
  CMP -- inside --> PASS["capture and dispatch"]
  CMP -- outside --> REV["PriceDeviation"]
  OFF["testnets: no deep pool, guard off"] -.-> PASS
```

A hooked pool is a new, thinner pool. On mainnet the hook compares each grant's execution price with the canonical deep v4
pool, read through StateView, so a skewed or sandwiched hooked pool cannot pay out at a bad price. No external oracle is needed.

---

## 9. A contract as approver (ERC-1271)

The hook verifies signatures with ECDSA first, then ERC-1271 for contract signers. That is what lets `NidhiBountyBoard`
approve on-chain milestones: it is the mandate's `approver`, and it answers `isValidSignature` with "valid" only when the
mandate matches a posted milestone and hashes to the exact digest the hook computed (`hook.mandateDigest`). The hook itself
needed no change to support milestones or open bounties.

---

## 10. Liquidity: a PositionManager NFT

The DAO's liquidity is minted through the PositionManager (`MINT_POSITION` + `SETTLE_PAIR`, with Permit2 approval) and held
as an NFT owned by the DAO admin. An earlier version seeded liquidity through v4's test router, whose positions anyone can
remove; `test/fork/DrainCheck.t.sol` proves that, and is why production uses the PositionManager.

---

## 11. Every Uniswap tool, and its job

| Tool | Job in Nidhi |
|---|---|
| **PoolManager** | runs the swap and the hook; flash accounting settles it |
| **v4 hooks** | the policy engine: mandate, roles, payee, cap, band, guard, capture |
| **PositionManager + Permit2** | the DAO's liquidity as an NFT |
| **V4Quoter** | exact quotes for every grant and milestone, through the gated hook |
| **StateView** | the reference-price guard, and the app's live pool price |
| **Trading API** | the auditor's USD valuation and treasury funding swaps (off-chain) |
| **Universal Router** | used by the Trading API for treasury swaps; Nidhi's own swap uses its router so the hook can see the real initiator |

---

## 12. One hook, every chain

The deploy scripts are driven by `chains/registry.json`, generated from Uniswap's deployments and checked on-chain. The same
hook runs on four testnets today, and was rehearsed on forks of the v4 mainnets: Ethereum, Base, Arbitrum, Polygon,
Avalanche, HyperEVM and Monad pass.

| Chain (live) | Hook |
|---|---|
| Sepolia | [`0xa020A751…c0c4`](https://sepolia.etherscan.io/address/0xa020A75106A7a5094Fb0530692Ee8aaADe7fc0c4) and the ENS-gated [`0x88257DA3…80c4`](https://sepolia.etherscan.io/address/0x88257DA3a88Aaaf8b3EEF52112Bfb9C3596580c4) |
| Base Sepolia | [`0xB703D879…80c4`](https://sepolia.basescan.org/address/0xB703D879B1F3fE33184841B42bc61097133A80c4) and the hop stack [`0xFAc8F26e…80c4`](https://sepolia.basescan.org/address/0xFAc8F26eE3993C86001318E5D21c2D705a2A80c4) |
| Arbitrum Sepolia | [`0x56d56254…80c4`](https://sepolia.arbiscan.io/address/0x56d56254A518142375E9eA9a69f310aB8D7b80c4) |
| Unichain Sepolia | [`0x2835f2af…C0c4`](https://unichain-sepolia.blockscout.com/address/0x2835f2af22486B547EE2E3F94805160b380bC0c4) |

Every hook address ends in `c4`: the permission bits.

---

## 13. Code

| What | Where |
|---|---|
| Permissions | [`getHookPermissions`](../../src/NidhiHook.sol#L172) |
| Every pre-swap check | [`_beforeSwap`](../../src/NidhiHook.sol#L242) · [`_checkSignatures`](../../src/NidhiHook.sol#L290) · [`_checkRecipient`](../../src/NidhiHook.sol#L337) |
| Capture and dispatch | [`_afterSwap`](../../src/NidhiHook.sol#L357) |
| Price guard | [`_checkReferencePrice`](../../src/NidhiHook.sol#L321) |
| ECDSA then ERC-1271 | [`_isValidSignature`](../../src/NidhiHook.sol#L349) |
| Guardian, cancellation | [`setPaused`](../../src/NidhiHook.sol#L204) · [`cancelGrant`](../../src/NidhiHook.sol#L212) |
| Router | [`msgSender`](../../src/NidhiSwapRouter.sol#L39) · [`swap`](../../src/NidhiSwapRouter.sol#L56) · [`unlockCallback`](../../src/NidhiSwapRouter.sol#L88) |
| Deploy: mining, pool, LP NFT | [`script/mainnet/Deploy.s.sol`](../../script/mainnet/Deploy.s.sol) |
| Tests | [`NidhiFlow.t.sol`](../../test/unit/NidhiFlow.t.sol) · [`QuoterPath.t.sol`](../../test/unit/QuoterPath.t.sol) · [`MultiChain.t.sol`](../../test/unit/MultiChain.t.sol) · [`BountyBoard.t.sol`](../../test/unit/BountyBoard.t.sol) · [`LiveSepolia.t.sol`](../../test/fork/LiveSepolia.t.sol) |
