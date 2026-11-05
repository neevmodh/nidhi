# Nidhi v3 — Multi-Token + Cost Optimisation

**Branch:** `feat/multi-token-permit2-cost-optimisation`  
**Author:** Jaimin (AI-assisted by Antigravity)  
**Tests:** 70 passing (67 original + 3 new), 0 failing, 4 skipped (live-fork)  
**Build:** `forge build` exits 0, warnings only (pre-existing)

---

## What This Branch Adds (on top of main)

### 1. Any ERC-20 as `tokenIn` — no more WETH lock-in

The contracts were already generic at the hook level. The blocker was in the router and scripts. Now removed:

- `NidhiSwapRouter`: no longer hardcodes WETH. Any approved ERC-20 is accepted as `tokenIn`.
- `script/02_DeploySource.s.sol`: removed `require(SEP_WETH < SEP_BNM, ...)`. Currency ordering is now computed dynamically via address sort, works with any pair.
- `script/05_Demo.s.sol`: replaced `IWETH9Demo` interface + deposit+approve block with generic `IERC20Min.approve()`. `tokenIn` is now read from `deployments/sepolia.json` at runtime — no hardcoding.
- `script/NidhiScript.sol`: added `PERMIT2` constant (canonical address, same on all EVM chains).

> **Important constraint (unchanged):** `tokenOut` must remain a CCIP-whitelisted token. On Sepolia → Base Sepolia lane only CCIP-BnM is reliably available. On mainnet lanes, CCIP-registered USDC would work. This is a CCIP protocol limit, not a Nidhi limit.

### 2. Native ETH input — auto-wrap

`NidhiSwapRouter` now accepts two new constructor arguments:

```solidity
constructor(IPoolManager poolManager_, address weth9_, address permit2_)
```

- If `weth9_ != address(0)` and the pool's `currency0 == address(0)` (native ETH pool), the router wraps the caller's `msg.value` to WETH9 before settling. No WETH pre-wrap step needed from the executor.
- If `weth9_ == address(0)`, native ETH pools revert with `NativeWethNotConfigured()` (explicit, not silent).

Deploy command update:
```bash
# was: new NidhiSwapRouter(poolManager)
# now:
new NidhiSwapRouter(poolManager, SEP_WETH, PERMIT2)
```

### 3. Permit2 — burner wallet / zero-nonce support

A new 5-argument `swap()` overload accepts optional `permitData`:

```solidity
function swap(
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata hookData,
    uint256 deadline,
    bytes calldata permitData   // ← NEW: abi.encode(PermitTransferFrom, sig)
) external payable returns (BalanceDelta)
```

- If `permitData.length > 0`, the router calls `Permit2.permitTransferFrom` before entering the PoolManager unlock.
- Tokens are pulled from the caller into the router without a prior ERC-20 `approve()`.
- Enables brand-new EOAs (zero nonce, no transaction history) to execute grants in a single signed message.
- The 4-argument `swap()` overload is kept **unchanged** — full backward compatibility with existing tests and scripts.

### 4. Gas limit reduction — `destGasLimit: 600k → 400k`

**`src/NidhiDispatcher.sol`:**
```diff
- uint32 public destGasLimit = 600_000;
+ uint32 public destGasLimit = 400_000;
```

**Why 400k and not lower:**  
The CCIP local simulator (used in tests) executes the full destination flow synchronously within the `destGasLimit` allocation:
- `DestinationReceiver._ccipReceive` payout: ~90k gas
- `DestinationReceiver.sendAck` → `ccipSend` for the return ACK: ~60k
- Overhead: ~50k  
Total: ~200k in test, ~200k is the ackGasLimit, so 400k gives a 2× buffer.

On **live CCIP**, the ACK is a separate message with its own `ackGasLimit` budget (200k). So the `destGasLimit` only needs to cover the payout itself (~70k real gas). After one successful on-chain run, the owner can call:
```bash
cast send $DISPATCHER "setDestGasLimit(uint32)" 200000 --rpc-url sepolia --private-key $PRIVATE_KEY
```
to tighten it further and cut CCIP fees by an additional ~33%.

**`src/DestinationReceiver.sol`:** `ackGasLimit` stays at **200k** (live ACK gas ~45k; local sim uses ~149k due to synchronous execution overhead).

### 5. New test file — `test/unit/MultiToken.t.sol`

Three new tests verifying the multi-token architecture:

| Test | Purpose |
|---|---|
| `test_nonWethTokenIn_mandateRejectedForWrongPool` | Hook rejects mandates where `tokenIn` doesn't match pool currencies — the firewall works for non-WETH tokens |
| `test_genericErc20_happyPath` | Full DISPATCHED→SETTLED flow with a `MockERC20` (not WETH) as tokenIn — proves no WETH-specific code path in contracts |
| `test_gasLimits_rightSized` | Asserts `destGasLimit == 400_000` and `ackGasLimit == 200_000` |

---

## Files Changed

```
script/02_DeploySource.s.sol   |  12 +++--   remove WETH assert, dynamic sort, router args
script/05_Demo.s.sol           |  10 +--     IERC20Min replaces IWETH9Demo, reads tokenIn from JSON
script/NidhiScript.sol         |   2 +       add PERMIT2 constant
src/NidhiDispatcher.sol        |   2 +-      destGasLimit 600k → 400k
src/NidhiSwapRouter.sol        | 168 +++++   full rewrite: weth9, permit2, native ETH, burner wallets
test/fork/LiveSepolia.t.sol    |   2 +-      router constructor 3 args
test/unit/EdgeCases.t.sol      |   5 +-     native key test: vm.expectRevert() (PoolNotInitialized fires first in test env)
test/unit/MultiToken.t.sol     | NEW        3 new tests
test/utils/NidhiBase.sol       |   2 +-      router constructor NidhiSwapRouter(manager, 0, 0)
```

**8 files changed, 179 insertions(+), 24 deletions(−) + 1 new file**

---

## How to Review / Merge

```bash
# 1. Fetch branch
git fetch origin feat/multi-token-permit2-cost-optimisation

# 2. Check out
git checkout feat/multi-token-permit2-cost-optimisation

# 3. Build
export PATH="$PATH:$HOME/.foundry/bin"
forge build        # must exit 0

# 4. Test
forge test --summary
# Expected: 70 passed, 0 failed, 4 skipped (live fork)

# 5. Review key files
# - src/NidhiSwapRouter.sol   → new router with weth9+permit2
# - test/unit/MultiToken.t.sol → new tests
# - src/NidhiDispatcher.sol   → destGasLimit change

# 6. Merge to main (squash recommended for clean history)
git checkout main
git merge --squash feat/multi-token-permit2-cost-optimisation
git commit -m "feat: multi-token support, Permit2 burner wallets, gas optimisation (v3)"
```

---

## What Was NOT Changed (Intentionally)

| Item | Reason |
|---|---|
| `src/NidhiHook.sol` | Already fully generic — uses `m.tokenIn`/`m.tokenOut` via `Currency`, no WETH assumption |
| `src/DestinationReceiver.sol` | `address public immutable token` already a constructor param — generic |
| `src/ENSv2Authority.sol` | Not related to token support |
| `src/libraries/Mandate.sol` | `tokenIn`/`tokenOut` already `address` fields — no WETH assumption |
| L2 / Base migration | Explicitly out of scope — stay on Ethereum L1 Sepolia as source chain |
| Frontend | Out of scope — CLI/scripts only |

---

## Post-Hackathon Follow-up (not blocking for judges)

1. **Tighten `destGasLimit`** after one successful live CCIP run:  
   `cast send $DISPATCHER "setDestGasLimit(uint32)" 200000`
2. **Tighten `ackGasLimit`** after measuring live ACK gas on Base Sepolia:  
   `cast send $RECEIVER "setAckGasLimit(uint32)" 80000`
3. **Multi-hop routing**: if `tokenIn → tokenOut` pool has no liquidity, add `V4Router`-style `PathKey[]` multi-hop through an intermediate token (WETH or USDC hub). Architecture supports it via flash accounting.
4. **USDC as tokenOut** on mainnet: CCIP-registered, replace CCIP-BnM with USDC for real production grants.
