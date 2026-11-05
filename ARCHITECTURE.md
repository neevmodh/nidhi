# Architecture

## Components

| Contract | Chain | Role |
|---|---|---|
| `NidhiHook` | Sepolia | v4 hook. `beforeSwap` is the firewall; `afterSwap` captures the output and dispatches it atomically. Bound to one pool, one router and minimal permissions (`0xC4`). |
| `NidhiSwapRouter` | Sepolia | Minimal unlock-callback router. The caller pays the exact input via allowance, and `msgSender()` exposes the initiator to the hook. |
| `NidhiDispatcher` | Sepolia | Grant ledger and CCIP endpoint. Sends the programmable token transfer and accepts the ACK. |
| `ENSv2Authority` | Sepolia | Resolves the DAO name to its resolver through the ENSv2 registry, then checks EAC roles. |
| `DestinationReceiver` | Base Sepolia | Defensive CCIP receiver: pays out or holds, recovers, and sends a decoupled ACK. |

## Grant lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant DAO as grants.json (DAO)
    participant AI as AI auditor (offchain)
    participant AP as Approver
    participant EX as Executor
    participant R as NidhiSwapRouter
    participant PM as v4 PoolManager
    participant H as NidhiHook
    participant ENS as ENSv2 registry + resolver
    participant D as NidhiDispatcher
    participant C as CCIP
    participant DR as DestinationReceiver (Base)

    DAO->>AI: grant (repo, PR, recipient, amount)
    AI->>AI: SHA-pinned evidence, deterministic rubric, LLM may veto
    AI-->>EX: Attestation{grantId, evidenceHash, ...} signed by AUDITOR key
    AP-->>EX: Mandate{grantId, executor, recipient, amountIn, band, dest, deadline, poolId} signed
    EX->>R: swap(key, exact-input params, hookData, deadline)
    R->>PM: unlock → swap
    PM->>H: beforeSwap(sender=router, hookData)
    H->>ENS: getResolver(label) → hasRoles(keccak(key), ROLE_SET_TEXT, signer) x2
    H->>H: bind (pool, direction, exact input, executor, deadline), one-use grantId, tstore(grant)
    PM->>PM: swap (flash accounting deltas)
    PM->>H: afterSwap(delta)
    H->>H: out ∈ [minOut, maxOut]
    H->>PM: take(tokenOut, dispatcher, out)
    H->>D: dispatch(mandate, out)
    D->>C: ccipSend(token + {grantId, recipient, amount})
    H-->>PM: return +out (afterSwapReturnDelta) → swapper receives 0
    R->>PM: settle exact input from executor
    C->>DR: ccipReceive (router/source/sender/token/amount checked)
    DR->>DR: pay recipient, or HOLD (pause/failure)
    DR->>C: ACK{grantId, sourceMessageId, amount, outcome}
    C->>D: ccipReceive(ACK) → SETTLED (or HELD → SETTLED after retry/recover)
```

Steps 5 to 17 happen in **one transaction on Sepolia**. If any check fails, nothing moves.

## Accounting detail (afterSwapReturnDelta)

For an exact-input swap, the unspecified currency is the output. The hook returns `+out` as its unspecified delta, so the PoolManager credits the hook with `out` and reduces the swapper's output by `out`, to zero. Inside `afterSwap`, the hook calls `take(tokenOut, dispatcher, out)`, which debits the hook by `out`. Its net delta is therefore 0 when the unlock closes. The router settles only the negative input delta. This mechanism is what makes "funds never rest in a human wallet" literally true.

## Ledger (source) and payout state (destination)

```
NidhiDispatcher:  NONE ─dispatch─▶ DISPATCHED ─ACK PAID─▶ SETTLED
                                       │                    ▲
                                       └─ACK HELD─▶ HELD ─ACK PAID / RECOVERED
DestinationReceiver: (unseen) ─receive─▶ PAID | HELD ─retryPayout─▶ PAID
                                                  └──recover(DAO)─▶ RECOVERED
```

Transitions only move forward; the invariant tests enforce this. A grant still `DISPATCHED` after `STUCK_AFTER` (6h) can be flagged with `flagStuck`. CCIP cannot be unwound, so recovery always happens on the destination: anyone can run CCIP manual execution, and the DAO can call `recover`.

## ENSv2 role model

- **The DAO owns `nidhi-dao.eth`.** Its resolver is a `PermissionedResolver` proxy created through the `VerifiableFactory`.
- **The DAO admin holds only `ROLE_SET_TEXT_ADMIN`.** It can delegate and revoke roles, but it cannot approve grants itself.
- **Approver role:** `grantSetterRoles(setText(name, "nidhi.role.approver", ""), approver)`, which writes `ROLE_SET_TEXT` on resource `keccak256("nidhi.role.approver")`.
- **Auditor role:** the same call with key `"nidhi.role.auditor"`.
- **The hook asks the registry for the resolver on every swap.** If the DAO moves its name to a new resolver, permissions follow automatically. If the name expires, every check fails closed.

The adapter matches the `PermissionedResolver` implementation deployed on Sepolia at `0x115eb53F…2b2C` (Sourcify exact match). The unreleased `main` branch of `ensdomains/contracts-v2` scopes resources by namehash instead. `ENSv2Authority` is the single place to change if the deployment is upgraded.

## AI auditor (off-chain, accountable but not trusted)

1. **Inputs are pinned:** repo, PR, merge commit SHA, head SHA, per-file blob SHAs, the full diff hash and the RFP hash.
2. **A deterministic rubric (`rubric.json`) decides pass/fail:** merged, approvals, no failed checks, path globs, size.
3. **The LLM review is advisory** (model `claude-opus-5-5`, structured JSON output). It can only veto, and it never sees or sets amounts. Current models reject `temperature`, so reproducibility comes from the rubric, not from sampling settings.
4. **`evidenceHash`** = `keccak256(abi.encode(inputsHash, rubricHash, promptHash, modelHash, outputHash))`. The approver signs this value inside the Mandate.
5. **`verify.ts`** recomputes everything reproducible from scratch, checks the auditor's signature, and checks the auditor's ENS role on-chain.
