#!/usr/bin/env bash
# Rehearse the full Nidhi stack on a fork of every deployable chain (one forge process per chain: fork switching inside a
# single process shares the test contract's state across chains). Opt-in, read-only: it only forks.
#   ./offchain/rehearse-all.sh            all source-capable chains in chains/registry.json, 3 in parallel
#   ./offchain/rehearse-all.sh 8453 1     chosen chains
set -euo pipefail
cd "$(dirname "$0")/.."
IDS=("$@")
if [ ${#IDS[@]} -eq 0 ]; then IDS=($(node -p 'require("./chains/registry.json").sourceChains.join(" ")')); fi
mkdir -p offchain/out/rehearsal
run() {
  id="$1"
  net=""; [ "$id" = "143" ] && net="--network monad"   # Foundry needs the Monad EVM family for Monad forks
  MAINNET_FORK=1 FORK_CHAINS="$id" forge test $net --match-contract MainnetForkTest -vv > "offchain/out/rehearsal/$id.log" 2>&1 || true
  if grep -q "PASS chain" "offchain/out/rehearsal/$id.log"; then echo "PASS  $id"
  elif grep -q "SKIP chain" "offchain/out/rehearsal/$id.log"; then echo "SKIP  $id (CCIP RMN cursed right now)"
  else echo "FAIL  $id  (see offchain/out/rehearsal/$id.log)"; fi
}
export -f run
printf '%s\n' "${IDS[@]}" | xargs -P 3 -I{} bash -c 'run {}'
