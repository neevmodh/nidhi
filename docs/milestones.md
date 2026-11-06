# How a Nidhi milestone gets paid

Nidhi pays contributors for milestones without anyone pressing "send". This guide is for a developer who wants to
claim one.

## 1. The DAO commits the milestone first

Each milestone lives in `offchain/milestones.json`: the repo, a short spec (`offchain/rfp/<id>.md`), who is paid
(an ENS subname such as `alice.nidhi-dao.eth`), on which chain, how much, and the acceptance rules.

The DAO's approver then pre-signs the payout:

```bash
node offchain/src/milestone.ts commit m1
```

That writes `offchain/mandates/m1.json`: an EIP-712 mandate whose `evidenceHash` is the hash of the milestone spec.
It is public on purpose. It can only ever pay that one spec, once, to that one ENS name, within a price band and
before its deadline.

## 2. You do the work and tag the pull request

Open a pull request on the milestone's repo with the milestone id in the title, for example:

```
[m1] docs: how milestone grants are paid
```

Keep it to what the spec asks. The rules for each milestone are shown in the app's **Milestones** screen.

## 3. The agent checks the merged work

When the PR is merged, the agent (`offchain/src/agent.ts`, run by the `agent` GitHub Action) checks it:

| Rule | What it looks at |
|---|---|
| Merged | the PR was merged, not just closed |
| Approvals | the number of approving reviews the milestone requires |
| CI | no check run on the merged head failed |
| Files | the PR touches the paths the milestone names (for m1: `docs/**`) |
| Size | it changes no more files than the rubric allows |

These rules decide. AI models also read the diff against the spec, but they can only veto, never approve.
The evidence is pinned to commit and file SHAs, so the check can be repeated by anyone.

## 4. The agent pays, and CCIP delivers

If the work passes, the agent:

1. signs an attestation with its ENS auditor role on `nidhi-dao.eth`;
2. publishes `<id>:pr<number>:<evidence hash>` to `auditor.nidhi-dao.eth`, the one record it may write;
3. sends the payout: a swap through the ENS-gated Uniswap v4 hook, which checks both signatures, the roles,
   the daily cap and the price band, then hands the output to Chainlink CCIP;
4. CCIP pays your ENS name's address on the payout chain and sends a receipt back, and the grant shows **Settled**.

The agent cannot pay more, to anyone else, or twice: the hook would refuse.

## 5. Where to watch it

- **The app, Milestones screen:** your PR's reviews and CI, the agent's verification and the payout, live.
- **GitHub Actions, `agent` workflow:** each run's log, rule by rule.
- **The grant timeline:** every on-chain step with explorer and CCIP links.
