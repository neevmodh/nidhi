// Build-time GitHub snapshot: for every PR whose title carries a milestone tag ("[m1]", "[b2]"), its state, author,
// approvals and CI. The Milestones page starts from this, so visitors see PR status without spending their own
// GitHub quota (60 unauthenticated requests per hour per IP). CI passes GITHUB_TOKEN; locally it works without one.
// Best-effort: any failure keeps the previous snapshot and the build continues.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ui = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = path.join(ui, "src", "data", "prs.json");
const prev = fs.existsSync(out) ? JSON.parse(fs.readFileSync(out, "utf8")) : { fetchedAt: null, prs: {} };
const milestones = JSON.parse(fs.readFileSync(path.join(ui, "src", "data", "milestones.json"), "utf8"));

const repos = new Set(Object.values(milestones.milestones ?? {}).map((m) => m.repo).filter(Boolean));
repos.add("neevmodh/nidhi"); // the board's on-chain milestones point here too

const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
const gh = async (p) => {
  const r = await fetch(`https://api.github.com${p}`, {
    headers: { Accept: "application/vnd.github+json", "User-Agent": "nidhi-ui-build", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
  if (!r.ok) throw new Error(`GitHub ${r.status} on ${p}`);
  return r.json();
};

const TAG = /\[([a-z]+\d+)\]/i;
try {
  const prs = {};
  for (const repo of repos) {
    const list = await gh(`/repos/${repo}/pulls?state=all&sort=updated&direction=desc&per_page=100`);
    const newest = new Map(); // tag -> newest PR carrying it (the list is newest-updated first)
    for (const p of list) {
      const t = String(p.title).match(TAG)?.[1]?.toLowerCase();
      if (t && !newest.has(t)) newest.set(t, p);
    }
    for (const [t, p] of newest) {
      const [reviews, checks] = await Promise.all([
        gh(`/repos/${repo}/pulls/${p.number}/reviews?per_page=100`),
        gh(`/repos/${repo}/commits/${p.head.sha}/check-runs?per_page=100`),
      ]);
      const runs = (checks.check_runs ?? []).filter((c) => c.name !== "agent"); // the agent's own run is not CI
      prs[`${repo}#${t}`] = {
        number: p.number, title: p.title, url: p.html_url, author: p.user?.login,
        state: p.merged_at ? "merged" : p.state === "open" ? "open" : "closed",
        approvals: reviews.filter((r) => r.state === "APPROVED").length,
        checks: {
          total: runs.length,
          failed: runs.filter((c) => c.conclusion && !["success", "neutral", "skipped"].includes(c.conclusion)).length,
          pending: runs.filter((c) => !c.conclusion).length,
        },
      };
    }
  }
  fs.writeFileSync(out, JSON.stringify({ fetchedAt: new Date().toISOString(), prs }, null, 1) + "\n");
  console.log(`[prs] ${Object.keys(prs).length} tagged PRs from ${repos.size} repo(s)${token ? " (token)" : " (no token)"}`);
} catch (e) {
  fs.writeFileSync(out, JSON.stringify(prev, null, 1) + "\n");
  console.warn(`[prs] kept the previous snapshot: ${e.message}`);
}
