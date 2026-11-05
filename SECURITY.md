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
| AI hallucinating amounts | Amounts come only from `grants.json`; the LLM can only veto | `offchain/src/audit.ts` design, re-checked by `verify.ts` |

## Admin surface (all one-time or bounded)

- **Hook:** `setPool` can be called once by the owner.
- **Dispatcher:** `setHook` and `setDestReceiver` once each; `setDestGasLimit`; `withdrawFees` for the fee token only. Grant tokens never rest in the dispatcher.
- **Receiver:** `setSourceDispatcher` once; `setPayoutsPaused`, a circuit breaker that holds funds rather than paying them out; `recover`, which works only on HELD grants; `withdrawFees`, which can never touch the bridged token.
- Ownership uses `Ownable2Step`.

## Slither (0.11.4) triage

28 findings after hardening: 0 open High or Medium issues. Each one is listed below.

| Finding | Location | Disposition |
|---|---|---|
| High: reentrancy-eth | `NidhiDispatcher.dispatch`: `messageId` written after `ccipSend` | **By design.** The callee is the immutable CCIP router. `dispatch` is hook-only and `nonReentrant`, and status and amount are written *before* the call. The only re-entry is the ACK arriving synchronously (local simulator, or out-of-order delivery), which `messageId` reconciliation handles explicitly in both directions (tested). |
| Medium: incorrect-equality | `g.messageId == bytes32(0)` | Intentional sentinel for "not yet recorded". |
| Medium: reentrancy-no-eth (x3) | `DestinationReceiver._ccipReceive` / `_ack` | Calls go to `this` (self-only functions), the immutable bridged token and the router. Optimistic state is now written **before** the call. What remains is the `catch` branch, which by construction writes after the call. Every re-entrant entry point checks `outcome` first. |
| Medium: unused-return | `ECDSA.tryRecover` third value | The error argument is intentionally unused. |
| Low: reentrancy-events (x4) | events after external calls | Accepted. Events mirror state that is already written. |
| Low: timestamp (x4) | deadline, stuck-flag, expiry checks | Minute-scale windows; validator skew is irrelevant. |
| Low: missing-zero-check (x2) | `NidhiSwapRouter`/`ENSv2Authority` constructor | Checked by the deploy scripts; the hook constructor checks for zero addresses. |
| Info: assembly | EIP-1153 `tload`/`tstore` | Constant keccak-1 slots, `memory-safe`. |
| Info: other | naming, low-level calls (native fee withdrawal), unindexed addresses | Accepted. |

## Known limitations (stated, not hidden)

- **CCIP delivery is asynchronous.** Atomicity holds only on the source chain. Destination failures are recoverable and visible but cannot be unwound.
- **The pool is gated:** every swap requires a mandate, so it is a dedicated payout pool, not a public market. Liquidity providers are not gated.
- **The LLM review is not reproducible** and is advisory only. Its output is bound by hash, not trusted.
- **The ENSv2 contracts are a Sepolia beta.** The resource derivation matches the deployed implementation, which is a different version from the unreleased `main` branch.
