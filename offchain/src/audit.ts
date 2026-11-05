// Nidhi AI auditor.
//
//   node src/audit.ts nidhi-001
//
// 1. Loads the DAO's pre-committed grant entry (repo, PR, recipient, amount) from grants.json.
// 2. Fetches the evidence pinned to immutable SHAs (merge commit, head, per-file blob SHAs) from GitHub.
// 3. Applies the deterministic rubric (rubric.json). This alone decides pass/fail.
// 4. Asks Claude for an advisory review of the diff against the RFP. It can only VETO; it never sets amounts.
// 5. Binds everything into evidenceHash and, if the grant passes, signs the EIP-712 Attestation with the
//    AUDITOR key (which must hold the ENS role "nidhi.role.auditor" on the DAO's resolver to be accepted on-chain).
//
// Outputs: out/evidence-bundle.json (everything needed to re-verify) and out/attestation.json (consumed by
// script/05_Demo.s.sol). Re-check any bundle with `node src/verify.ts`.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod/v4";
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import { canonical, evaluateRubric, evidenceHashOf, fetchEvidence, grantIdOf, hashJson, hashText } from "./lib.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const repoRoot = path.resolve(root, "..");
const envFile = path.join(repoRoot, ".env");
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

const MODEL = "claude-opus-5-5";
const MAX_DIFF_CHARS = 400_000; // far below the 1M-token window; larger diffs skip the LLM explicitly (recorded)

const SYSTEM_PROMPT = `You are an independent auditor for a DAO grant program.
You receive a request for proposals (RFP) and the full diff of a merged pull request submitted as the deliverable.
Decide whether the diff plausibly fulfils the RFP's stated deliverable and acceptance criteria.
You do not decide payment amounts or recipients and must not comment on them.
Report every concrete concern you notice; downstream rules filter them.
Answer "inconsistent" only when the diff clearly does not deliver what the RFP asks for.
Answer "insufficient_evidence" when the diff alone cannot show it either way.`;

const Review = z.object({
  verdict: z.enum(["consistent", "inconsistent", "insufficient_evidence"]),
  summary: z.string(),
  concerns: z.array(z.string()),
});
type ReviewT = z.infer<typeof Review>;

type LlmOutcome =
  | { status: "reviewed"; model: string; review: ReviewT }
  | { status: "unavailable"; reason: string };

async function llmReview(rfp: string, diff: string): Promise<LlmOutcome> {
  if (diff.length > MAX_DIFF_CHARS) {
    return { status: "unavailable", reason: `diff is ${diff.length} chars (> ${MAX_DIFF_CHARS}); not sent to the model` };
  }
  const client = new Anthropic();
  try {
    const response = await client.messages.parse({
      model: MODEL,
      max_tokens: 16000,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: `<rfp>\n${rfp}\n</rfp>\n\n<diff>\n${diff}\n</diff>` }],
      output_config: { effort: "high", format: zodOutputFormat(Review) },
    });
    if (response.stop_reason === "refusal") {
      return { status: "unavailable", reason: `model declined (${response.stop_details?.category ?? "unspecified"})` };
    }
    if (!response.parsed_output) return { status: "unavailable", reason: `no structured output (stop_reason=${response.stop_reason})` };
    return { status: "reviewed", model: response.model, review: response.parsed_output };
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) return { status: "unavailable", reason: "no Anthropic credentials configured" };
    if (err instanceof Anthropic.RateLimitError) return { status: "unavailable", reason: "rate limited" };
    if (err instanceof Anthropic.APIError) return { status: "unavailable", reason: `API error ${err.status}` };
    if (err instanceof Error && /credentials|api key|apiKey/i.test(err.message)) {
      return { status: "unavailable", reason: "no Anthropic credentials configured" };
    }
    throw err;
  }
}

async function main() {
  const label = process.argv[2] ?? "nidhi-001";
  const grants = JSON.parse(fs.readFileSync(path.join(root, "grants.json"), "utf8")).grants;
  const grant = grants[label];
  if (!grant) throw new Error(`unknown grant "${label}" in grants.json`);
  const rubric = JSON.parse(fs.readFileSync(path.join(root, "rubric.json"), "utf8"));
  const rfp = fs.readFileSync(path.join(root, grant.rfp), "utf8");

  console.log(`[nidhi-auditor] grant ${label}: ${grant.repo}#${grant.pr}`);
  const { evidence, diff } = await fetchEvidence(grant.repo, grant.pr);
  const results = evaluateRubric(evidence, rubric.rules);
  for (const r of results) console.log(`  ${r.pass ? "PASS" : "FAIL"}  ${r.rule.padEnd(26)} ${r.detail}`);

  const llm = await llmReview(rfp, diff);
  if (llm.status === "reviewed") console.log(`  LLM   ${llm.review.verdict.padEnd(26)} ${llm.review.summary.slice(0, 120)}`);
  else console.log(`  LLM   unavailable                ${llm.reason} (advisory only; does not block)`);

  const rulesPass = results.every((r) => r.pass);
  const vetoed = llm.status === "reviewed" && llm.review.verdict === "inconsistent";
  const pass = rulesPass && !vetoed;

  // ---- hashes (everything except the LLM output is reproducible by `verify`)
  const inputs = { repo: evidence.repo, pr: evidence.pr, evidence, diffHash: hashText(diff), rfpHash: hashText(rfp) };
  const inputsHash = hashJson(inputs);
  const rubricHash = hashJson(rubric);
  const promptHash = hashText(SYSTEM_PROMPT);
  const modelHash = hashText(llm.status === "reviewed" ? llm.model : "none");
  const output = { results, llm, pass };
  const outputHash = hashJson(output);
  const evidenceHash = evidenceHashOf({ inputsHash, rubricHash, promptHash, modelHash, outputHash });
  const grantId = grantIdOf(label);
  const issuedAt = Math.floor(Date.now() / 1000);

  const bundle = {
    grantLabel: label,
    grantId,
    grant,
    inputs,
    rubric,
    systemPrompt: SYSTEM_PROMPT,
    output,
    hashes: { inputsHash, rubricHash, promptHash, modelHash, outputHash, evidenceHash },
    issuedAt,
  };
  fs.mkdirSync(path.join(root, "out"), { recursive: true });
  fs.writeFileSync(path.join(root, "out", "evidence-bundle.json"), JSON.stringify(JSON.parse(canonical(bundle)), null, 2));

  if (!pass) {
    console.error(`[nidhi-auditor] grant ${label} REJECTED (${rulesPass ? "LLM veto" : "rubric failed"}); no attestation signed.`);
    process.exit(2);
  }

  // ---- EIP-712 Attestation, signed by the AUDITOR key when the hook is deployed
  const attestation: Record<string, unknown> = {
    grantLabel: label,
    grantId,
    evidenceHash,
    inputsHash,
    rubricHash,
    issuedAt,
    recipient: grant.recipient,
    amountInWei: grant.amountInWei,
  };
  const deployment = path.join(repoRoot, "deployments", "sepolia.json");
  const key = process.env.AUDITOR_PRIVATE_KEY as Hex | undefined;
  if (key && fs.existsSync(deployment)) {
    const { hook, chainId } = JSON.parse(fs.readFileSync(deployment, "utf8"));
    const account = privateKeyToAccount(key);
    const signature = await account.signTypedData({
      domain: { name: "Nidhi", version: "1", chainId: Number(chainId), verifyingContract: hook },
      types: {
        Attestation: [
          { name: "grantId", type: "bytes32" },
          { name: "evidenceHash", type: "bytes32" },
          { name: "inputsHash", type: "bytes32" },
          { name: "rubricHash", type: "bytes32" },
          { name: "issuedAt", type: "uint64" },
        ],
      },
      primaryType: "Attestation",
      message: { grantId, evidenceHash, inputsHash, rubricHash, issuedAt: BigInt(issuedAt) },
    });
    Object.assign(attestation, { auditor: account.address, auditorSig: signature, hook, chainId: Number(chainId) });
    console.log(`[nidhi-auditor] attestation signed by auditor ${account.address}`);
  } else {
    console.log("[nidhi-auditor] hook not deployed yet (or no AUDITOR key): attestation left unsigned; the demo script signs it.");
  }
  fs.writeFileSync(path.join(root, "out", "attestation.json"), JSON.stringify(attestation, null, 2));
  console.log(`[nidhi-auditor] grant ${label} PASSED  evidenceHash=${evidenceHash}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
