// Multi-model jury. Each available juror reviews independently (in parallel).
// Veto rule: the deliverable is vetoed if at least min(2, reviewed) jurors say "inconsistent".
// Jurors can never PASS a deliverable the deterministic rubric failed.
import { SYSTEM_PROMPT, type Juror, type JurorOutcome } from "./types.ts";
import { groqJuror, cerebrasJuror } from "./openaiCompatible.ts";
import { geminiJuror } from "./gemini.ts";
import { anthropicJuror } from "./anthropic.ts";

export const MAX_DIFF_CHARS = 400_000;

export interface JuryResult {
  jurors: JurorOutcome[];
  reviewed: number;
  inconsistentVotes: number;
  vetoThreshold: number;
  veto: boolean;
}

export const allJurors = (): Juror[] => [groqJuror(), geminiJuror(), cerebrasJuror(), anthropicJuror()];

export async function runJury(rfp: string, diff: string, jurors: Juror[] = allJurors()): Promise<JuryResult> {
  const user = `<rfp>\n${rfp}\n</rfp>\n\n<diff>\n${diff}\n</diff>`;
  const outcomes: JurorOutcome[] = await Promise.all(
    jurors.map(async (j) => {
      if (!j.available()) return { provider: j.provider, status: "unavailable", reason: "no API key configured" } as JurorOutcome;
      if (diff.length > MAX_DIFF_CHARS) {
        return { provider: j.provider, status: "unavailable", reason: `diff is ${diff.length} chars; not sent` } as JurorOutcome;
      }
      return j.review(SYSTEM_PROMPT, user);
    }),
  );
  const reviewed = outcomes.filter((o) => o.status === "reviewed").length;
  const inconsistentVotes = outcomes.filter((o) => o.status === "reviewed" && o.review.verdict === "inconsistent").length;
  const vetoThreshold = Math.max(1, Math.min(2, reviewed));
  return { jurors: outcomes, reviewed, inconsistentVotes, vetoThreshold, veto: reviewed > 0 && inconsistentVotes >= vetoThreshold };
}
