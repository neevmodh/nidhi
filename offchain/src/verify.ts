// Independent re-verification of a Nidhi audit.
//
//   node src/verify.ts [out/evidence-bundle.json] [out/attestation.json]
//
// Recomputes from scratch everything that is reproducible - GitHub evidence pinned to SHAs, the rubric verdict,
// inputsHash, rubricHash, promptHash and evidenceHash - and checks the recorded LLM output still hashes to the
// committed value. The LLM's text itself is not reproducible (and is advisory only). If an attestation is signed,
// recovers the signer and, given SEPOLIA_RPC_URL + deployments, checks on-chain that it holds the ENS auditor role.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, recoverTypedDataAddress, parseAbi, type Hex } from "viem";
import { sepolia } from "viem/chains";
import { canonical, evaluateRubric, evidenceHashOf, fetchEvidence, grantIdOf, hashJson, hashText } from "./lib.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const repoRoot = path.resolve(root, "..");
const envFile = path.join(repoRoot, ".env");
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`  ${ok ? "OK  " : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
  if (!ok) failures++;
}

async function main() {
  const bundlePath = process.argv[2] ?? path.join(root, "out", "evidence-bundle.json");
  const attPath = process.argv[3] ?? path.join(root, "out", "attestation.json");
  const b = JSON.parse(fs.readFileSync(bundlePath, "utf8"));
  console.log(`[nidhi-verify] ${b.grantLabel}: ${b.inputs.repo}#${b.inputs.pr}`);

  // 1. Evidence is re-fetched, not trusted.
  const { evidence, diff } = await fetchEvidence(b.inputs.repo, b.inputs.pr);
  check("merge commit unchanged", evidence.mergeCommitSha === b.inputs.evidence.mergeCommitSha, evidence.mergeCommitSha ?? "");
  check("diff unchanged", hashText(diff) === b.inputs.diffHash);
  const inputs = { ...b.inputs, evidence, diffHash: hashText(diff) };
  check("inputsHash reproduces", hashJson(inputs) === b.hashes.inputsHash);

  // 2. Rubric and its verdict are deterministic.
  check("rubricHash reproduces", hashJson(b.rubric) === b.hashes.rubricHash);
  const results = evaluateRubric(evidence, b.rubric.rules);
  check("rubric verdict reproduces", canonical(results) === canonical(b.output.results));
  check("promptHash reproduces", hashText(b.systemPrompt) === b.hashes.promptHash);

  // 3. Recorded (non-reproducible) LLM output is bound by its hash.
  check("outputHash binds recorded output", hashJson(b.output) === b.hashes.outputHash);
  const modelHash = hashText(b.output.llm.status === "reviewed" ? b.output.llm.model : "none");
  check("modelHash binds model id", modelHash === b.hashes.modelHash);
  const evidenceHash = evidenceHashOf({ ...b.hashes, modelHash });
  check("evidenceHash reproduces", evidenceHash === b.hashes.evidenceHash, evidenceHash);
  check("grantId = DAO label", grantIdOf(b.grantLabel) === b.grantId);

  // 4. Signature and on-chain role.
  if (fs.existsSync(attPath)) {
    const a = JSON.parse(fs.readFileSync(attPath, "utf8"));
    check("attestation matches bundle", a.evidenceHash === b.hashes.evidenceHash && a.grantId === b.grantId);
    if (a.auditorSig) {
      const signer = await recoverTypedDataAddress({
        domain: { name: "Nidhi", version: "1", chainId: a.chainId, verifyingContract: a.hook },
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
        message: {
          grantId: a.grantId,
          evidenceHash: a.evidenceHash,
          inputsHash: a.inputsHash,
          rubricHash: a.rubricHash,
          issuedAt: BigInt(a.issuedAt),
        },
        signature: a.auditorSig as Hex,
      });
      check("auditor signature recovers", signer.toLowerCase() === String(a.auditor).toLowerCase(), signer);

      const deployment = path.join(repoRoot, "deployments", "sepolia.json");
      if (process.env.SEPOLIA_RPC_URL && fs.existsSync(deployment)) {
        const { authority } = JSON.parse(fs.readFileSync(deployment, "utf8"));
        const client = createPublicClient({ chain: sepolia, transport: http(process.env.SEPOLIA_RPC_URL) });
        const abi = parseAbi([
          "function AUDITOR() view returns (bytes32)",
          "function isAuthorized(bytes32 role, address account) view returns (bool)",
          "function currentResolver() view returns (address)",
        ]);
        const role = await client.readContract({ address: authority, abi, functionName: "AUDITOR" });
        const ok = await client.readContract({ address: authority, abi, functionName: "isAuthorized", args: [role, signer] });
        const resolver = await client.readContract({ address: authority, abi, functionName: "currentResolver" });
        check("signer holds ENS auditor role (live)", ok, `resolver ${resolver}`);
      }
    } else {
      console.log("  --    attestation unsigned (demo script signs it)");
    }
  }

  console.log(failures === 0 ? "[nidhi-verify] ALL CHECKS PASSED" : `[nidhi-verify] ${failures} CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
