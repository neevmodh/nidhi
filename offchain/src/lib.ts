// Shared helpers for the Nidhi auditor. Pure functions where possible so `verify` can recompute everything.
import { keccak256, toBytes, encodeAbiParameters, type Hex } from "viem";

/** Canonical JSON: sorted object keys, no whitespace. Hash inputs must be byte-identical across runs. */
export function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj)
    .sort()
    .filter((k) => obj[k] !== undefined)
    .map((k) => `${JSON.stringify(k)}:${canonical(obj[k])}`)
    .join(",")}}`;
}

export const hashJson = (v: unknown): Hex => keccak256(toBytes(canonical(v)));
export const hashText = (s: string): Hex => keccak256(toBytes(s));

/** grantId is assigned by the DAO's grant table label, not derived from evidence. */
export const grantIdOf = (label: string): Hex =>
  keccak256(encodeAbiParameters([{ type: "string" }, { type: "string" }], ["nidhi.grant", label]));

/** evidenceHash binds every component of the audit into the value the APPROVER signs in the Mandate. */
export function evidenceHashOf(p: {
  inputsHash: Hex;
  rubricHash: Hex;
  promptHash: Hex;
  modelHash: Hex;
  outputHash: Hex;
}): Hex {
  return keccak256(
    encodeAbiParameters(
      Array(5).fill({ type: "bytes32" }),
      [p.inputsHash, p.rubricHash, p.promptHash, p.modelHash, p.outputHash],
    ),
  );
}

// ------------------------------------------------------------------ GitHub (pinned to immutable SHAs)

const GH = "https://api.github.com";

async function gh<T>(path: string, accept = "application/vnd.github+json"): Promise<T> {
  const headers: Record<string, string> = { Accept: accept, "User-Agent": "nidhi-auditor" };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  const res = await fetch(`${GH}${path}`, { headers });
  if (!res.ok) throw new Error(`GitHub ${res.status} for ${path}: ${(await res.text()).slice(0, 200)}`);
  return (accept.includes("diff") ? await res.text() : await res.json()) as T;
}

export interface Evidence {
  repo: string;
  pr: number;
  title: string;
  author: string;
  merged: boolean;
  mergedAt: string | null;
  mergeCommitSha: string | null;
  headSha: string;
  files: { filename: string; status: string; additions: number; deletions: number; sha: string }[];
  approvals: number;
  checks: { name: string; conclusion: string | null }[];
}

export async function fetchEvidence(repo: string, pr: number): Promise<{ evidence: Evidence; diff: string }> {
  const p = await gh<any>(`/repos/${repo}/pulls/${pr}`);
  const files = await gh<any[]>(`/repos/${repo}/pulls/${pr}/files?per_page=100`);
  const reviews = await gh<any[]>(`/repos/${repo}/pulls/${pr}/reviews?per_page=100`);
  const checks = await gh<any>(`/repos/${repo}/commits/${p.head.sha}/check-runs?per_page=100`);
  const diff = await gh<string>(`/repos/${repo}/pulls/${pr}`, "application/vnd.github.diff");

  const evidence: Evidence = {
    repo,
    pr,
    title: p.title,
    author: p.user.login,
    merged: Boolean(p.merged),
    mergedAt: p.merged_at,
    mergeCommitSha: p.merge_commit_sha,
    headSha: p.head.sha,
    files: files
      .map((f) => ({ filename: f.filename, status: f.status, additions: f.additions, deletions: f.deletions, sha: f.sha }))
      .sort((a, b) => a.filename.localeCompare(b.filename)),
    approvals: reviews.filter((r) => r.state === "APPROVED").length,
    checks: (checks.check_runs ?? [])
      .map((c: any) => ({ name: c.name, conclusion: c.conclusion }))
      .sort((a: any, b: any) => a.name.localeCompare(b.name)),
  };
  return { evidence, diff };
}

// ------------------------------------------------------------------ deterministic rubric

export interface RuleResult {
  rule: string;
  pass: boolean;
  detail: string;
}

function globToRegExp(glob: string): RegExp {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "\u0000").replace(/\*/g, "[^/]*");
  return new RegExp(`^${esc.replace(/\u0000/g, ".*")}$`);
}

export function evaluateRubric(e: Evidence, rules: any, grantGlobs: string[] = []): RuleResult[] {
  const out: RuleResult[] = [];
  if (rules.requireMerged) out.push({ rule: "requireMerged", pass: e.merged, detail: `merged=${e.merged}` });
  out.push({
    rule: "minApprovals",
    pass: e.approvals >= rules.minApprovals,
    detail: `${e.approvals} approval(s), need ${rules.minApprovals}`,
  });
  if (rules.requireNoFailedChecks) {
    const failed = e.checks.filter((c) => c.conclusion && !["success", "neutral", "skipped"].includes(c.conclusion));
    out.push({
      rule: "requireNoFailedChecks",
      pass: failed.length === 0,
      detail: failed.length ? `failed: ${failed.map((c) => c.name).join(", ")}` : `${e.checks.length} check(s), none failed`,
    });
  }
  for (const g of [...(rules.requiredPathGlobs ?? []), ...grantGlobs]) {
    const re = globToRegExp(g);
    const hits = e.files.filter((f) => re.test(f.filename)).length;
    out.push({ rule: `touches:${g}`, pass: hits > 0, detail: `${hits} file(s) match` });
  }
  if (rules.maxFilesChanged !== undefined) {
    out.push({
      rule: "maxFilesChanged",
      pass: e.files.length <= rules.maxFilesChanged,
      detail: `${e.files.length} file(s) changed, max ${rules.maxFilesChanged}`,
    });
  }
  return out;
}

/** Model identity bound into evidenceHash: sorted "provider:model" of every juror that actually reviewed. */
export function modelIdentity(jurors: any[]): string {
  const ids = jurors.filter((j) => j.status === "reviewed").map((j) => `${j.provider}:${j.model}`).sort();
  return ids.length ? ids.join(",") : "none";
}
