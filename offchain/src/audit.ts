// Nidhi AI auditor (v3).
//
//   node src/audit.ts <grantLabel> [--publish]
//
// 1. Loads the DAO's pre-committed grant entry (repo, PR, grantee ENS label, amount) from grants.json.
//    Recipients are ENS subnames (<label>.nidhi-dao.eth), never raw addresses; the hook resolves them on-chain.
// 2. Fetches evidence pinned to immutable SHAs (merge commit, head, per-file blob SHAs) from GitHub.
// 3. Applies the deterministic rubric (rubric.json). This alone decides pass/fail.
// 4. Runs a multi-model jury (Groq, Gemini, Cerebras, optional Claude). Jurors can only VETO.
// 5. Binds everything into evidenceHash and, if the grant passes, signs the EIP-712 Attestation with the AUDITOR
//    key (which must hold the ENS role "nidhi.role.auditor").
// 6. --publish: mirrors "<grant>:<evidenceHash>" to the text record "nidhi.attestation" on auditor.nidhi-dao.eth.
//
// Outputs out/evidence-bundle.json and out/attestation.json. Re-check with `node src/verify.ts`.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, http, parseAbi, toHex, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { canonical, evaluateRubric, evidenceHashOf, fetchEvidence, grantIdOf, hashJson, hashText, modelIdentity } from "./lib.ts";
import { runJury } from "./llm/jury.ts";
import { SYSTEM_PROMPT } from "./llm/types.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const repoRoot = path.resolve(root, "..");
const envFile = path.join(repoRoot, ".env");
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

async function publishAttestation(label: string, evidenceHash: Hex) {
  const subnames = path.join(repoRoot, "deployments", "sepolia-subnames.json");
  const ens = path.join(repoRoot, "deployments", "sepolia-ens.json");
  const key = process.env.AUDITOR_PRIVATE_KEY as Hex | undefined;
  if (!key || !process.env.SEPOLIA_RPC_URL || !fs.existsSync(subnames) || !fs.existsSync(ens)) {
    console.log("[nidhi-auditor] --publish skipped (needs AUDITOR key, SEPOLIA_RPC_URL and deployed subnames)");
    return;
  }
  const { grantsResolver } = JSON.parse(fs.readFileSync(subnames, "utf8"));
  const { label: dao } = JSON.parse(fs.readFileSync(ens, "utf8"));
  const enc = new TextEncoder();
  const name = new Uint8Array([7, ...enc.encode("auditor"), dao.length, ...enc.encode(dao), 3, ...enc.encode("eth"), 0]);
  const account = privateKeyToAccount(key);
  const transport = http(process.env.SEPOLIA_RPC_URL);
  const pub = createPublicClient({ chain: sepolia, transport });
  if ((await pub.getBalance({ address: account.address })) === 0n) {
    console.log(`[nidhi-auditor] --publish skipped: auditor ${account.address} has no Sepolia ETH for gas`);
    return;
  }
  const wallet = createWalletClient({ chain: sepolia, transport, account });
  const hash = await wallet.writeContract({
    address: grantsResolver,
    abi: parseAbi(["function setText(bytes name, string key, string value)"]),
    functionName: "setText",
    args: [toHex(name), "nidhi.attestation", `${label}:${evidenceHash}`],
  });
  await pub.waitForTransactionReceipt({ hash });
  console.log(`[nidhi-auditor] attestation published to auditor.${dao}.eth (tx ${hash})`);
}

async function main() {
  const label = process.argv[2] ?? "nidhi-002";
  const publish = process.argv.includes("--publish");
  const grants = JSON.parse(fs.readFileSync(path.join(root, "grants.json"), "utf8")).grants;
  const grant = grants[label];
  if (!grant) throw new Error(`unknown grant "${label}" in grants.json`);
  const rubric = JSON.parse(fs.readFileSync(path.join(root, "rubric.json"), "utf8"));
  const rfp = fs.readFileSync(path.join(root, grant.rfp), "utf8");

  console.log(`[nidhi-auditor] grant ${label}: ${grant.repo}#${grant.pr} -> ${grant.grantee}.<dao>.eth`);
  const { evidence, diff } = await fetchEvidence(grant.repo, grant.pr);
  const results = evaluateRubric(evidence, rubric.rules, grant.requiredPathGlobs ?? []);
  for (const r of results) console.log(`  ${r.pass ? "PASS" : "FAIL"}  ${r.rule.padEnd(26)} ${r.detail}`);

  const jury = await runJury(rfp, diff);
  for (const j of jury.jurors) {
    if (j.status === "reviewed") console.log(`  JURY  ${`${j.provider}:${j.model}`.padEnd(40)} ${j.review.verdict}`);
    else console.log(`  JURY  ${j.provider.padEnd(40)} unavailable (${j.reason})`);
  }
  console.log(`  JURY  ${jury.reviewed} reviewed, ${jury.inconsistentVotes} inconsistent, veto at ${jury.vetoThreshold} -> ${jury.veto ? "VETO" : "no veto"}`);

  const rulesPass = results.every((r) => r.pass);
  const pass = rulesPass && !jury.veto;

  const inputs = { repo: evidence.repo, pr: evidence.pr, evidence, diffHash: hashText(diff), rfpHash: hashText(rfp) };
  const inputsHash = hashJson(inputs);
  const rubricHash = hashJson(rubric);
  const promptHash = hashText(SYSTEM_PROMPT);
  const modelHash = hashText(modelIdentity(jury.jurors));
  const output = { results, jury, pass };
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
    fs.rmSync(path.join(root, "out", "attestation.json"), { force: true }); // never leave a stale attestation behind
    console.error(`[nidhi-auditor] grant ${label} REJECTED (${rulesPass ? "jury veto" : "rubric failed"}); no attestation signed.`);
    process.exit(2);
  }

  const attestation: Record<string, unknown> = {
    grantLabel: label,
    grantId,
    evidenceHash,
    inputsHash,
    rubricHash,
    issuedAt,
    granteeLabel: grant.grantee,
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
  if (publish) await publishAttestation(label, evidenceHash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
