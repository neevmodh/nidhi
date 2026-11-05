# RFP nidhi-003: Keep the Uniswap v4 hook template's toolchain current

Deliverable: a merged pull request to Uniswap/v4-template that updates the template's build configuration and
its pinned dependencies so new hook projects start from a current, working toolchain.

Acceptance:
1. The change touches the Foundry configuration (`foundry.toml`) and the vendored libraries under `lib/`.
2. The pull request is merged into the default branch with at least one approving review.
3. No CI check on the merged head reports a failure.
