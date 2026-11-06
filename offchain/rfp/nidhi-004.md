# RFP nidhi-004: Fix audit finding H-02 in OpenZeppelin's ReHypothecationHook

Deliverable: a merged pull request to OpenZeppelin/uniswap-hooks that resolves audit finding H-02 ("bound the amounts of
liquidity additions and removals") in `ReHypothecationHook`, with tests demonstrating the fix.

Acceptance:
1. The change modifies the hook source under `src/` and adds or updates tests under `test/`.
2. The pull request is merged with at least one approving review.
3. No CI check on the merged head reports a failure.
