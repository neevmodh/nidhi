# Legacy: Sepolia v3 deployment scripts (retired)

These scripts deployed and operated the **Sepolia / Base Sepolia v3** deployment (ENSv2 identity layer, CCIP-BnM payouts).
That deployment was retired (its LP NFT burned and fees withdrawn by `10_MigrateFromV3`), and the contracts have since
changed (multi-destination dispatcher, `RoleAuthority`, reference-price guard), so these scripts **no longer compile
against `src/`** and are kept outside the build as a record of how the testnet deployment was done.

The current deployment path is `script/mainnet/` (Deploy, Wire, Handover), driven by `chains/registry.json`.
The ENSv2-gated flow is still covered by `test/` (unit, invariant and live Sepolia fork tests).
