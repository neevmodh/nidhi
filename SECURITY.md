# Security

## Threat model

| Threat | Mitigation | Test |
|---|---|---|
| Unauthorized payout | Two EIP-712 signatures from distinct accounts, each holding an ENSv2 role | `test_revert_approverWithoutEnsRole`, `test_revert_signatureFromNonApprover`, `test_revert_sameKeyForBothRoles` |
| Compromised or removed signer | Roles revocable in ENS, effective on the next swap; name expiry freezes everything | `test_ensRevocationBlocksNextPayout`, `test_ensNameExpiryFreezesPayouts`, `test_live_ensRevocationIsImmediate` |
| Tampered mandate (recipient, amount, destination) | Every field is covered by the approver's EIP-712 signature | `test_revert_tamperedMandate` |
| Replay | `grantId` is single-use in the hook and mirrored in the dispatcher | `test_revert_replaySameGrant`, `test_revert_duplicateDispatch` |
| Front-running with a leaked mandate | Mandate bound to `executor`, read from the trusted router's `msgSender()` | `test_revert_wrongExecutor_frontRunWithLeakedMandate` |
| Hook called through another router | `sender == trustedRouter` | `test_revert_untrustedRouter` |
| Direct hook call | `onlyPoolManager` (BaseHook) | `test_revert_directHookCall` |
| Sandwich or slippage | Output must sit in the signed `[minOut, maxOut]`, or the payout reverts | `test_revert_outputBelowMin/AboveMax` |
| Wrong pool, direction or amount | Bound to `poolId`, `tokenIn`/`tokenOut` and exact `amountIn` | `test_revert_wrongDirection`, `test_revert_amountDiffersFromMandate`, `test_revert_exactOutputSwap`, `test_revert_mandateForOtherPool` |
| Funds stuck in intermediaries | `afterSwapReturnDelta` + `take` → dispatcher → router in one transaction | invariant `noFundsRestInIntermediaries` |
| Forged CCIP messages | Router-only plus source chain, source sender, token and amount checks on both ends | `test_revert_forgedAckFromUnknownSender`, `test_revert_forgedGrantAtDestination`, `test_revert_receiverRejectsWrongTokenOrAmount` |
| ACK manipulation | Amount and messageId must match; transitions are monotonic | `test_revert_ackWrongAmount`, `test_revert_ackWrongMessageId`, `test_revert_ackCannotRegressSettled` |
| Payout failure at destination | Funds HELD (not reverted), then retry to the recipient or DAO `recover` | `test_pausedPayoutIsHeldThenRecovered`, `test_heldPayoutRetriedToRecipient` |
| ACK failure rolling back a payout | ACK decoupled with try/catch; `retryAck` | `test_ackFailureNeverRollsBackPayout_thenRetryAck` |
| EIP-7702 / smart-wallet signers rejected | ECDSA first, then ERC-1271 fallback | `test_eip7702DelegatedApproverAccepted`, `test_erc1271SmartWalletApproverAccepted` |
| Off-chain and on-chain EIP-712 drift | viem test vector asserted in Solidity | `CrossLangEIP712.t.sol` |
| AI hallucinating amounts | Amounts come only from `grants.json`; the LLM jury can only veto | `offchain/src/audit.ts` design, re-checked by `verify.ts` (and in CI) |
| **v3:** both signer keys leak | Rolling **daily cap** on `amountIn`; ENS **guardian** pause; approver **cancel** | `test_dailyCapAccumulatesAndBlocks`, `test_guardianPauseBlocksAllGrants`, `test_approverCancelsBeforeExecution`, invariant `dailyCapNeverExceeded` |
| **v3:** paying the wrong address | Mandate recipient must equal what `<grantee>.<dao>.eth` resolves to on the payout chain (ENSIP-11) | `test_revert_recipientMustMatchEnsSubname`, `test_revert_labelMustMatchSignedHash`, `test_live_granteeSubnameResolvesOnChain` |
| **v3:** stale or expired grantee identity | Expired or unset subname, or any broken resolver link, resolves to `address(0)` and the payout reverts | `test_revert_expiredSubnameBlocksPayout`, `ResolveGranteeFailClosedTest` (5 adversarial resolvers) |
| **v3:** grantee rotates their wallet | Re-pointing the subname redirects future grants; old mandates to the old address fail | `test_repointingSubnameRedirectsFutureGrants` |
| **v3:** pause/cancel abuse | `setPaused` needs the ENS guardian role; `cancelGrant` needs the ENS approver role; both are revocable | `test_revert_onlyEnsGuardianCanPause`, `test_revert_cancelGuards` |
| **v3:** partial batch payouts | `swapBatch` runs every grant in one unlock: all succeed or all revert | `test_batchIsAllOrNothing`, `test_batchPaysSeveralGrantsInOneTx` |
| **v3:** stuck ACKs or held funds need a human | Exact work queue drained by Chainlink Automation; `performUpkeep` is permissionless, idempotent, recipient-bound | `test_automationPaysHeldGrantAfterUnpause`, `test_automationRetriesFailedAck`, `test_performUpkeepSkipsStaleIds`, invariant `automationQueueIsExact` |
| **v3:** pool liquidity drained | v2 seed was held by v4's test router (removable by anyone); v3 mints a **PositionManager NFT owned by the DAO** | `DrainCheck.t.sol` (proves the v2 issue), `PosmSpike.t.sol` |

## Admin surface (all one-time or bounded)

- **Hook:** `setPool` can be called once by the owner. The daily cap is immutable. Pause and cancel are **not** owner powers: they belong to ENS role holders (guardian and approver) and can be revoked in ENS.
- **Dispatcher:** `setHook` and `setDestReceiver` once each; `setDestGasLimit`; `withdrawFees` for the fee token only. Grant tokens never rest in the dispatcher.
- **Receiver:** `setSourceDispatcher` once; `setPayoutsPaused`, a circuit breaker that holds funds rather than paying them out; `recover`, which works only on HELD grants; `withdrawFees`, which can never touch the bridged token.
- Ownership uses `Ownable2Step`.

## Slither (0.11.4) triage

38 findings on v3: 0 open High or Medium issues. The v3 additions (Automation queue, ENS resolution, batch) add only informational/low findings plus the same documented reentrancy pattern on `performUpkeep`. Each one is listed below.

| Finding | Location | Disposition |
|---|---|---|
| High: reentrancy-eth | `NidhiDispatcher.dispatch`: `messageId` written after `ccipSend` | **By design.** The callee is the immutable CCIP router. `dispatch` is hook-only and `nonReentrant`, and status and amount are written *before* the call. The only re-entry is the ACK arriving synchronously (local simulator, or out-of-order delivery), which `messageId` reconciliation handles explicitly in both directions (tested). |
| Medium: incorrect-equality | `g.messageId == bytes32(0)` | Intentional sentinel for "not yet recorded". |
| Medium: reentrancy-no-eth (x4) | `DestinationReceiver._ccipReceive` / `_ack` / `performUpkeep` | Calls go to `this` (self-only functions), the immutable bridged token and the router. Optimistic state is now written **before** the call. What remains is the `catch` branch, which by construction writes after the call. Every re-entrant entry point checks `outcome` first. |
| Medium: unused-return | `ECDSA.tryRecover` third value | The error argument is intentionally unused. |
| Low: reentrancy-events (x5) / reentrancy-benign (x1) | events or queue bookkeeping after external calls | Accepted. Events mirror state that is already written; the queue sync runs after the guarded call by design. |
| Low: calls-loop (x2) / Info: costly-loop (x2) | `performUpkeep`, `checkUpkeep`, `swapBatch` | Bounded: `MAX_BATCH = 10` per upkeep; batch size is chosen by the executor. |
| Low: timestamp (x5) | deadline, stuck-flag, expiry, daily-cap day index | Minute- to day-scale windows; validator skew is irrelevant. |
| Low: missing-zero-check (x2) | `NidhiSwapRouter`/`ENSv2Authority` constructor | Checked by the deploy scripts; the hook constructor checks for zero addresses. |
| Info: assembly | EIP-1153 `tload`/`tstore` | Constant keccak-1 slots, `memory-safe`. |
| Info: other | naming, low-level calls (native fee withdrawal), unindexed addresses | Accepted. |

## Known limitations (stated, not hidden)

- **CCIP delivery is asynchronous.** Atomicity holds only on the source chain. Destination failures are recoverable and visible but cannot be unwound.
- **The daily cap is per UTC day, not a sliding 24h window**, so up to 2× the cap can move across a day boundary. That is still bounded, and documented.
- **The pool is gated:** every swap requires a mandate, so it is a dedicated payout pool, not a public market. Liquidity providers are not gated.
- **The LLM review is not reproducible** and is advisory only. Its output is bound by hash, not trusted.
- **The ENSv2 contracts are a Sepolia beta.** The resource derivation matches the deployed implementation, which is a different version from the unreleased `main` branch.
