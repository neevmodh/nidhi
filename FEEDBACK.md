# Uniswap developer feedback

This is feedback from building `NidhiHook`, a v4 hook using `beforeSwap`, `afterSwap` and `afterSwapReturnDelta` that redirects 100% of swap output into a CCIP transfer. Each item is something that cost real time during the build.

## What worked well
- **`afterSwapReturnDelta` plus `take()` inside the callback** is a clean, powerful pattern. Netting the hook's delta to zero within one unlock is easy once understood, and it makes "output never touches a wallet" provable.
- **`BaseHook` from OpenZeppelin `uniswap-hooks`**, with internal `_beforeSwap`/`_afterSwap` and automatic permission validation, prevented a whole class of mistakes.
- **`HookMiner`** made CREATE2 flag mining trivial, both in scripts and in fork tests.
- **`CustomRevert.WrappedError`** gives precise, assertable hook-revert reasons in tests once you know the shape.

## Friction and suggestions
1. **Version skew between packages.** The `v4-core` `v4.0.0` tag lacks `types/PoolOperation.sol`, but `uniswap-hooks`' `BaseHook` imports it. Separately, `v4-periphery` `main` moved `HookMiner` out of `src/utils/`. We resolved it by remapping to the `v4-core` and `v4-periphery` copies bundled inside `uniswap-hooks`. *Suggestion:* publish a compatibility matrix, or tag a matching release set.
2. **`PoolManager` pins `pragma solidity =0.8.26`.** Any test that deploys the real `PoolManager` from source forces the whole compilation unit to 0.8.26, so the `transient` keyword (0.8.28+) can't be used anywhere in the project. We fell back to `tload`/`tstore` assembly. *Suggestion:* a caret pragma, or a precompiled `PoolManager` artifact for tests.
3. **`sender` in hook callbacks is the router, not the user.** The docs mention it, but it is the #1 footgun when gating swaps. *Suggestion:* a first-class "gated hook" example showing the trusted-router `msgSender()` pattern alongside signature-carrying `hookData`.
4. **Sign conventions for return deltas.** "Positive means owed to the hook" for the `afterSwap` `int128`, and how it maps onto the specified versus unspecified currency for exact-in versus exact-out swaps, took source reading (`Hooks.sol`) to confirm. *Suggestion:* a table in the docs: exact-in/exact-out × zeroForOne → which currency is unspecified, with the sign of the hook delta.
5. **Quoting through a gating hook is impossible.** The `Quoter` simulates the swap, so a hook that reverts on unauthorized swaps also reverts the quote. We compute an exact quote off-chain with `SqrtPriceMath` from `StateLibrary` state instead (`script/05_Demo.s.sol`). *Suggestion:* document this, or let hooks detect quote simulation.
6. **`PoolModifyLiquidityTest` positions can be removed by anyone.** Many tutorials and scripts seed liquidity through the
   test router. The position is owned by the router contract, so **any address** can call it with a negative delta and
   withdraw the liquidity; we proved this against our own live pool (`test/fork/DrainCheck.t.sol`). *Suggestion:* a loud
   warning in the template/docs, and a PositionManager seeding example (Permit2 + `MINT_POSITION` + `SETTLE_PAIR`) as the default.
7. **Docs moved to developers.uniswap.org** with redirects. The deployments page asks readers to confirm addresses on the explorer, which we did, and it was helpful. A machine-readable deployments JSON would help scripts.

## Testing note
EIP-7702 is live: several well-known test keys on Sepolia now have delegation code. OpenZeppelin `SignatureChecker` routes any address with code to ERC-1271 only, which rejects valid ECDSA signatures from 7702 accounts. That's not a Uniswap issue, but any hook doing signature-gated swaps will hit it.
