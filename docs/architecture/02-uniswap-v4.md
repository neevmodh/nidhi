# 2. Uniswap v4 architecture in Nidhi

Uniswap v4 is Nidhi's **execution and enforcement layer**. A grant is not "send money": it is a **swap that cannot happen
unless a signed mandate is attached**, whose output never reaches the caller. The hook enforces the rules inside the swap.

## 2.1 System view: Uniswap contracts and Nidhi's additions

```mermaid
flowchart TB
  subgraph UNI["Uniswap v4 - the real deployments, not forks"]
    PM["PoolManager\nsingleton, flash accounting, EIP-1153"]
    POSM["PositionManager\nLP positions as NFTs"]
    P2["Permit2"]
    Q["V4Quoter\nexact quotes"]
    SV["StateView\ngetSlot0 reference price"]
    TAPI["Trading API\nindicative USD value, treasury funding"]
  end

  subgraph NIDHI["Nidhi"]
    RT["NidhiSwapRouter\nunlock, swap, settle\nexposes msgSender()"]
    HK["NidhiHook\nflags 0xC4 mined into the address\nbeforeSwap, afterSwap, afterSwapReturnDelta"]
    DS["NidhiDispatcher\nholds captured output, sends CCIP"]
    AU["IGrantAuthority\nENS or RoleAuthority"]
  end

  EXEC(["Executor wallet\nholds WETH, carries signed hookData"]) -->|"swap(key, params, hookData)"| RT
  RT -->|"unlock then swap"| PM
  PM -->|"beforeSwap / afterSwap callbacks"| HK
  HK -->|"roles and payee"| AU
  HK -->|"take(output) to dispatcher"| DS
  Q -.->|"quote only: sender == quoter, hook allows, nothing persists"| HK
  HK -.->|"getSlot0 of the canonical deep pool"| SV
  DS -->|"CCIP"| NEXT(["next chain"])

  LP["DAO treasury"] -->|"MINT_POSITION, SETTLE_PAIR"| POSM
  POSM --> PM
  LP -->|"approve"| P2
  P2 --> POSM
  AUD["Auditor service"] -.->|"value of the grant"| TAPI
```

## 2.2 The pool

| Property | Value |
|---|---|
| Pair | wrapped native (WETH or equivalent) / payout token (USDC on mainnets, CCIP-BnM on testnets) |
| Fee, tick spacing | 3000 (0.30%), 60 |
| Hook | `NidhiHook`, address mined so its low bits equal `0xC4` = `BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA` |
| Hook deployment | CREATE2 through the canonical deployer `0x4e59...956C`, salt found by `HookMiner` per chain (PoolManager differs per chain) |
| Initial price | mainnets: the canonical deep pool's price; testnets: about 1 WETH = 1000 payout tokens |
| Liquidity | one **payout-token-only** position through PositionManager (an NFT). Base-to-payout grant swaps pull the payout token out of it |
| Why not a test router | `PoolModifyLiquidityTest` positions can be drained by anyone. A PositionManager NFT is owned by the DAO |

## 2.3 One grant swap, call by call

```mermaid
sequenceDiagram
  autonumber
  actor EX as Executor
  participant RT as NidhiSwapRouter
  participant PM as PoolManager
  participant HK as NidhiHook
  participant AU as IGrantAuthority
  participant SV as StateView
  participant DS as NidhiDispatcher

  EX->>RT: swap(key, exactInput amountIn, hookData = GrantAuth)
  RT->>RT: record initiator = msg.sender (transient)
  RT->>PM: unlock(...)
  PM->>RT: unlockCallback
  RT->>PM: swap(key, params, hookData)
  PM->>HK: beforeSwap(sender = router, key, params, hookData)
  Note over HK: 1 pool == mandate.poolId, not paused, sender == trustedRouter
  Note over HK: 2 deadline, exact input, direction tokenIn to tokenOut
  Note over HK: 3 router.msgSender() == mandate.executor
  Note over HK: 4 grantId unused, EIP-712 sigs, approver != auditor
  HK->>AU: isAuthorized(APPROVER / AUDITOR)
  HK->>AU: resolveGrantee(label, destSelector) == mandate.recipient
  Note over HK: 5 amountIn within the remaining daily cap, mark grantUsed, spentPerDay += amountIn
  HK->>HK: tstore(ACTIVE_GRANT_SLOT, grantId)
  HK-->>PM: ok
  PM->>PM: execute the swap in the pool
  PM->>HK: afterSwap(sender, key, params, delta, hookData)
  Note over HK: tload active grant, must equal mandate.grantId, then clear it
  Note over HK: output must be within [minOut, maxOut]
  HK->>SV: getSlot0(reference pool)
  Note over HK: achieved rate within maxDeviationBps of reference, else PriceDeviation
  HK->>PM: take(output currency, to dispatcher, out)
  HK->>DS: dispatch(mandate, out)
  HK-->>PM: return +out as afterSwap delta
  Note over PM: hook nets to zero, the swapper's output side becomes 0
  RT->>PM: settle amountIn from executor (needs ERC-20 approval)
  PM-->>RT: nothing owed back on the output side
  RT-->>EX: swap done, output is already in flight via CCIP
```

## 2.4 What the hook enforces, and the exact error when it fails

```mermaid
flowchart TD
  IN(["beforeSwap(hookData)"]) --> Q1{"sender == V4Quoter ?"}
  Q1 -- yes --> QOK["return zero delta\nquote-only, state reverts"]
  Q1 -- no --> C1{"pool set and poolId matches"} -- no --> E1["WrongPool"]
  C1 -- yes --> C2{"not paused"} -- no --> E2["Paused"]
  C2 -- yes --> C3{"sender == trustedRouter"} -- no --> E3["UntrustedRouter"]
  C3 -- yes --> C4{"deadline ok, exact input, direction ok, mandate valid"} -- no --> E4["MandateExpired / NotExactInput / WrongDirection / InvalidMandate"]
  C4 -- yes --> C5{"router.msgSender() == executor"} -- no --> E5["WrongExecutor"]
  C5 -- yes --> C6{"grantId unused"} -- no --> E6["GrantAlreadyUsed"]
  C6 -- yes --> C7{"2 valid EIP-712 sigs, 2 different signers, roles held"} -- no --> E7["BadSignature / SameSigner / NotAuthorized / AttestationMismatch"]
  C7 -- yes --> C8{"resolved payee == mandate.recipient"} -- no --> E8["RecipientMismatch"]
  C8 -- yes --> C9{"amountIn within remainingToday"} -- no --> E9["CapExceeded"]
  C9 -- yes --> OKB["mark used, set transient active grant"]
  OKB --> AS(["afterSwap"])
  AS --> D1{"active grant == mandate.grantId"} -- no --> F1["NoActiveGrant"]
  D1 -- yes --> D2{"out between minOut and maxOut"} -- no --> F2["OutputOutOfBounds"]
  D2 -- yes --> D3{"rate within band of reference pool"} -- no --> F3["PriceDeviation"]
  D3 -- yes --> CAP["take out to dispatcher, dispatch via CCIP"]
```

Any revert inside a hook is wrapped by the PoolManager as `WrappedError(hook, selector, reason, HookCallFailed)`. Tests unwrap
it and assert the exact inner selector, so a swap cannot "revert for the wrong reason" and still pass.

## 2.5 Flash accounting: why the swapper never touches the output

```mermaid
flowchart LR
  subgraph TX["one unlock, one transaction"]
    S1["swap: pool owes OUT to the swapper\ndelta(out) = +OUT"]
    S2["hook take(OUT) to dispatcher\nhook delta(out) = -OUT"]
    S3["hook returns +OUT as afterSwap delta\nbooked to the hook = +OUT, hook nets to 0\nswapper out delta reduced to 0"]
    S4["router settles amountIn only"]
  end
  S1 --> S2 --> S3 --> S4
  S4 --> END["PoolManager books balance at unlock end\nOUT sits in the dispatcher, bound to the grant"]
```

## 2.6 Uniswap tools and what each does here

| Tool | Role in Nidhi |
|---|---|
| **PoolManager** | executes the swap, runs the hook, flash accounting settles it |
| **Hooks (v4)** | the policy engine: mandate, roles, cap, bounds, guard, capture |
| **PositionManager and Permit2** | the DAO's USDC-only LP position as an NFT, with Permit2 allowance |
| **V4Quoter** | exact-input quotes for a mandate's band. The hook recognises it (`sender == quoter`) and stays side-effect-free |
| **StateView** | on-chain reference-price guard against the canonical deep pool |
| **Trading API** | off-chain: indicative USD value in the audit, and treasury funding swaps. Nidhi's own swap uses its router so the hook can read the real initiator |
| **ReservesLens** | recorded in the registry for dashboard pool state |

## 2.7 Reference-price guard

```mermaid
flowchart LR
  A["achieved rate = payout out / base in, 1e18 scaled"] --> CMP{"within maxDeviationBps\n300 bps on mainnets"}
  B["reference spot from the canonical deep pool\nStateView.getSlot0, converted to the same units"] --> CMP
  CMP -- inside --> PASS["continue to capture"]
  CMP -- outside --> REV["revert PriceDeviation(exec, ref, maxBps)"]
  OFF["testnets: no deep pool, guard disabled\nstateView = 0, maxDeviationBps = 0"] -.-> PASS
```
