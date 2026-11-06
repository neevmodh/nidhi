# 1. ENS architecture in Nidhi

ENS is Nidhi's **identity and permission layer**: who may approve, who may audit, who may pause, and which address a grantee
named `alice.<dao>.eth` is paid at on each chain. The hook never stores people or addresses. It asks an `IGrantAuthority`.

> **Where this runs today.** ENSv2 exists only on Sepolia, so `ENSv2Authority` is covered by the unit, invariant and live
> Sepolia fork tests and by the retired Sepolia v3 deployment. The 2026-11 testnet and mainnet deployments use the
> drop-in `RoleAuthority` (same interface, an AccessControl registry owned by the DAO admin). Same hook, different authority.

## 1.1 System view: one interface, two authorities

```mermaid
flowchart LR
  subgraph HOOK["NidhiHook - Uniswap v4 hook"]
    CS["_checkSignatures\nAPPROVER and AUDITOR must hold their role"]
    CR["_checkRecipient\nresolved payee must equal mandate.recipient"]
    GP["setPaused / cancelGrant\nGUARDIAN and APPROVER gated"]
  end

  IFACE{{"IGrantAuthority\nisAuthorized(role, account)\nresolveGrantee(label, destSelector)\nAPPROVER AUDITOR GUARDIAN"}}

  CS -->|"isAuthorized(APPROVER, approver)\nisAuthorized(AUDITOR, auditor)"| IFACE
  GP -->|"isAuthorized(GUARDIAN, caller)"| IFACE
  CR -->|"resolveGrantee(label, destSelector)"| IFACE

  IFACE -.->|"Sepolia, ENSv2"| ENSA["ENSv2Authority\nreads ENS live, fail-closed"]
  IFACE -.->|"testnets and mainnets"| ROLE["RoleAuthority\nOZ AccessControl\nGRANTEE_ADMIN sets payees"]

  subgraph ENS["ENSv2 on Sepolia"]
    REG["ETH Registry\ngetSubregistry(dao)"]
    DAO["dao.eth\nPermissionedResolver\nEAC roles per text key"]
    SUB["UserRegistry subnames\ngetResolver(grantee)"]
    GR["alice.dao.eth\nresolver addr(node, coinType)"]
  end

  ENSA --> REG --> SUB --> GR
  ENSA -->|"hasRoles(resource, ROLE_SET_TEXT, account)"| DAO

  ADMIN["DAO admin wallet or Safe"] -->|"grant / revoke role instantly"| DAO
  ADMIN -->|"DEFAULT_ADMIN, GRANTEE_ADMIN"| ROLE
```

## 1.2 How a role check works (ENSv2Authority)

A role is an **ENS Enhanced Access Control permission on a text key of the DAO's own resolver**. Granting the right to set
`nidhi.role.auditor` on `dao.eth` IS the auditor role. Revoking it in ENS revokes it in the hook with no Nidhi transaction.

```mermaid
sequenceDiagram
  autonumber
  participant H as NidhiHook
  participant A as ENSv2Authority
  participant R as ETH Registry
  participant P as dao.eth PermissionedResolver

  H->>A: isAuthorized(AUDITOR, auditorAddr)
  A->>A: resource = uint256(keccak256("nidhi.role.auditor"))
  alt unknown role (resource == 0)
    A-->>H: false
  else known role
    A->>R: getResolver("dao")
    alt name unregistered or expired
      R-->>A: address(0)
      A-->>H: false (fail closed)
    else resolver found
      A->>P: hasRoles(resource, ROLE_SET_TEXT, auditorAddr)
      P-->>A: true / false
      A-->>H: result
    end
  end
```

Role keys (resource = `keccak256(key)`, permission bit `ROLE_SET_TEXT = 1 << 4`):

| Role | Text key on the DAO resolver | Used for |
|---|---|---|
| APPROVER | `nidhi.role.approver` | signs the EIP-712 Mandate, may `cancelGrant` |
| AUDITOR | `nidhi.role.auditor` | signs the EIP-712 Attestation after the AI audit |
| GUARDIAN | `nidhi.role.guardian` | `setPaused` (global stop) |

The hook also requires `approver != auditor` (two different keys) before it looks at ENS at all.

## 1.3 How a grantee name becomes a payout address

`resolveGrantee(label, destSelector)` follows ENSv2 resolution and applies **ENSIP-11 per-chain addresses**: the CCIP
destination selector is mapped to coin type `0x80000000 | chainId`, so one name has a different address per chain.

```mermaid
flowchart TD
  S(["resolveGrantee(label, destSelector)"]) --> C{"coinTypeOf[destSelector] != 0 ?"}
  C -- no --> Z0["return address(0)"]
  C -- yes --> L{"label length 1..63 ?"}
  L -- no --> Z0
  L -- yes --> G1["registry.getSubregistry(dao)"]
  G1 --> G1C{"subregistry set ?"}
  G1C -- no --> Z0
  G1C -- yes --> G2["subregistry.getResolver(label)"]
  G2 --> G2C{"resolver set and call ok ?"}
  G2C -- no --> Z0
  G2C -- yes --> N["name = dnsEncode(label.dao.eth)"]
  N --> RES["resolver.resolve(name, addr(node, coinType))\nENSIP-10 extended resolver"]
  RES --> V{"returns exactly 20 bytes ?"}
  V -- no --> Z0
  V -- yes --> OUT["return payee address"]
  Z0 --> FAIL["hook: RecipientMismatch, swap reverts"]
  OUT --> CMP{"payee == mandate.recipient ?"}
  CMP -- no --> FAIL
  CMP -- yes --> OK["grant continues"]
```

Every branch that fails returns `address(0)`, so a missing, expired or malformed name can never pay anyone: **fail-closed**.

## 1.4 Setup and lifecycle of the ENS identity

```mermaid
sequenceDiagram
  autonumber
  actor DAO as DAO admin
  participant E as ETH Registrar (ENSv2)
  participant P as dao.eth PermissionedResolver
  participant U as UserRegistry (subnames)
  participant AU as Auditor service
  participant HK as NidhiHook

  DAO->>E: commit then register "dao.eth" (script 00 and 01)
  DAO->>P: grantSetterRoles(nidhi.role.approver, approver)
  DAO->>P: grantSetterRoles(nidhi.role.auditor, auditor)
  DAO->>P: grantSetterRoles(nidhi.role.guardian, guardian)
  DAO->>U: create alice.dao.eth, set addr(coinType per chain)
  DAO->>P: setText nidhi.contract.* (hook, dispatcher, router, poolId...)
  Note over P: clients discover the deployment from the name, nothing hard-coded
  AU->>P: setText "nidhi.attestation" on auditor.dao.eth = grant:evidenceHash
  HK->>P: hasRoles(...) on every grant (read-only)
  DAO--xP: revoke a role in ENS
  Note over HK: next grant by that signer reverts NotAuthorized, no Nidhi tx needed
```

## 1.5 What ENS controls vs. what it does not

```mermaid
flowchart LR
  subgraph ENSCTL["ENS decides"]
    A1["who may approve a grant"]
    A2["who may audit a grant"]
    A3["who may pause the hook"]
    A4["where alice is paid, per chain"]
    A5["discovery of contract addresses"]
  end
  subgraph NOTENS["ENS does not decide"]
    B1["amount, bounds, deadline - signed in the Mandate"]
    B2["daily cap - hook immutable"]
    B3["price sanity - reference-price guard"]
    B4["token transfer - CCIP"]
  end
```
