# Uniswap developer feedback

This is feedback from building `NidhiHook`, a v4 hook using `beforeSwap`, `afterSwap` and `afterSwapReturnDelta` that redirects 100% of swap output into a CCIP transfer, then taking it to four testnets (Sepolia, Base Sepolia, Arbitrum Sepolia, Unichain Sepolia) and rehearsing it on forks of the v4 mainnets. Each item is something that cost real time during the build.

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
5. **Quoting through a gating hook.** The `V4Quoter` simulates the swap, so a hook that reverts on unauthorized swaps also reverts the quote. In v3 of Nidhi we quoted off-chain with `SqrtPriceMath`. In v4 we pass the chain's canonical `V4Quoter` address into the hook and let `sender == quoter` through with a zero delta (the quoter always reverts its own swap, so nothing persists): see `_beforeSwap` in `src/NidhiHook.sol`. The app now quotes every grant with the real `V4Quoter`. *Suggestion:* document this pattern for gated hooks, since without it a gated pool cannot be quoted at all.
6. **`PoolModifyLiquidityTest` positions can be removed by anyone.** Many tutorials and scripts seed liquidity through the
   test router. The position is owned by the router contract, so **any address** can call it with a negative delta and
   withdraw the liquidity; we proved this against our own live pool (`test/fork/DrainCheck.t.sol`). *Suggestion:* a loud
   warning in the template/docs, and a PositionManager seeding example (Permit2 + `MINT_POSITION` + `SETTLE_PAIR`) as the default.
7. **Deployments are not machine-readable, and the testnet tables have gaps.** We generate a registry of all 21 v4 mainnets
   and 4 testnets from the deployments page (`offchain/src/registry.ts`, `offchain/src/testnets.ts`). That meant parsing
   HTML, and some testnet rows were missing (for example Base Sepolia's PositionManager and StateView, and Unichain
   Sepolia's StateView). We identified each contract on-chain instead, by calling `poolManager()` and `WETH9()` on every
   address on the page. *Suggestion:* publish a `deployments.json` keyed by chain id, covering the testnets in full.
8. **The PoolManager address differs per chain, so the hook address does too.** Hook permissions live in the address
   bits, and the CREATE2 address depends on the constructor arguments, which include the PoolManager. Every chain needs its
   own mined salt, and the same hook has a different address on each of the four testnets. *Suggestion:* where possible,
   deploy the PoolManager at one deterministic address across chains (as Permit2 is), so a hook can share an address too.
9. **`modifyLiquidities(MINT_POSITION)` does not return the token id.** Scripts read `nextTokenId()` before minting. On a
   busy PositionManager (Sepolia) another user minted between our read and our mint, so we recorded the wrong position and
   a later ownership transfer failed with `WRONG_FROM`. We now confirm ownership after minting (`_mintUsdcOnly` in
   `script/mainnet/Deploy.s.sol`). *Suggestion:* document the race and recommend reading the ERC-721 `Transfer` event, or
   offer a mint helper that returns the id.
10. **Trading API coverage.** The API powers the auditor's USD valuation and treasury funding (`offchain/src/uniswap/tradingApi.ts`).
    It covers 20 of the 21 v4 mainnets (HyperEVM is missing) and three testnets, but not Arbitrum Sepolia, one of the four
    testnets we deployed on. *Suggestion:* add Arbitrum Sepolia, and state per endpoint which chains support v4 routing.
11. **StateView made an on-chain price guard easy.** `getSlot0` on the canonical deep pool gives the hook a reference
    price with no oracle, so a thin hooked pool cannot be skewed far (`_checkReferencePrice`). A worked example of using
    StateView from inside a hook would help others do the same.

## Testing note
EIP-7702 is live: several well-known test keys on Sepolia now have delegation code. OpenZeppelin `SignatureChecker` routes any address with code to ERC-1271 only, which rejects valid ECDSA signatures from 7702 accounts. That's not a Uniswap issue, but any hook doing signature-gated swaps will hit it.
