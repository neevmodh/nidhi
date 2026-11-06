# RFP nidhi-005: Correct burn accounting in Uniswap v4-periphery

Deliverable: a merged pull request to Uniswap/v4-periphery that removes the extra unit burned in the affected periphery
path and expands test coverage for it.

Acceptance:
1. The change modifies contract source under `src/` and tests under `test/`.
2. The pull request is merged with at least one approving review.
3. No CI check on the merged head reports a failure.
