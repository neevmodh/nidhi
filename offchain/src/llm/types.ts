// Shared contract for every advisory LLM juror. A juror can only VETO; it never sets amounts or recipients.
import { z } from "zod/v4";

export const Review = z.object({
  verdict: z.enum(["consistent", "inconsistent", "insufficient_evidence"]),
  summary: z.string(),
  concerns: z.array(z.string()),
});
export type ReviewT = z.infer<typeof Review>;

export type JurorOutcome =
  | { provider: string; status: "reviewed"; model: string; review: ReviewT }
  | { provider: string; status: "unavailable"; reason: string };

export interface Juror {
  provider: string;
  available(): boolean;
  review(system: string, user: string): Promise<JurorOutcome>;
}

export const SYSTEM_PROMPT = `You are an independent auditor for a DAO grant program.
You receive a request for proposals (RFP) and the full diff of a merged pull request submitted as the deliverable.
Decide whether the diff plausibly fulfils the RFP's stated deliverable and acceptance criteria.
You do not decide payment amounts or recipients and must not comment on them.
Report every concrete concern you notice; downstream rules filter them.
Answer "inconsistent" only when the diff clearly does not deliver what the RFP asks for.
Answer "insufficient_evidence" when the diff alone cannot show it either way.
Respond with ONLY a JSON object: {"verdict": "consistent" | "inconsistent" | "insufficient_evidence", "summary": string, "concerns": string[]}.`;

/** Parse a model's JSON text into a validated Review, tolerating ```json fences. */
export function parseReview(text: string): ReviewT | null {
  const cleaned = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    const parsed = Review.safeParse(JSON.parse(cleaned));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}
