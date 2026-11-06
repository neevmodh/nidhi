// Google Gemini via the Generative Language REST API (generateContent with a JSON response schema).
import { parseReview, type Juror, type JurorOutcome } from "./types.ts";

const BASE = "https://generativelanguage.googleapis.com/v1beta";

async function pickModel(key: string): Promise<string> {
  if (process.env.GEMINI_MODEL) return process.env.GEMINI_MODEL;
  const res = await fetch(`${BASE}/models?key=${encodeURIComponent(key)}`);
  if (!res.ok) throw new Error(`gemini /models ${res.status}`);
  const models: any[] = (await res.json()).models ?? [];
  const usable = models
    .filter((m) => (m.supportedGenerationMethods ?? []).includes("generateContent"))
    .map((m) => String(m.name).replace(/^models\//, ""));
  // the listing includes models that return 404 for new keys (e.g. 2.5-pro), so prefer the generally available flash tier
  for (const re of [/^gemini-[\d.]+-flash$/, /^gemini-[\d.]+-pro$/, /flash/, /pro/]) {
    const hit = usable.filter((id) => re.test(id)).sort().reverse()[0];
    if (hit) return hit;
  }
  if (!usable.length) throw new Error("gemini: no generateContent models");
  return usable[0];
}

export const geminiJuror = (): Juror => ({
  provider: "gemini",
  available: () => Boolean(process.env.GEMINI_API_KEY),
  async review(system: string, user: string): Promise<JurorOutcome> {
    const key = process.env.GEMINI_API_KEY!;
    try {
      const model = await pickModel(key);
      const res = await fetch(`${BASE}/models/${model}:generateContent?key=${encodeURIComponent(key)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: user }] }],
          generationConfig: {
            responseMimeType: "application/json",
            responseSchema: {
              type: "OBJECT",
              properties: {
                verdict: { type: "STRING", enum: ["consistent", "inconsistent", "insufficient_evidence"] },
                summary: { type: "STRING" },
                concerns: { type: "ARRAY", items: { type: "STRING" } },
              },
              required: ["verdict", "summary", "concerns"],
            },
          },
        }),
      });
      if (!res.ok) return { provider: "gemini", status: "unavailable", reason: `HTTP ${res.status}: ${(await res.text()).slice(0, 160)}` };
      const body = await res.json();
      const text = (body.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? "").join("");
      const review = parseReview(text);
      if (!review) return { provider: "gemini", status: "unavailable", reason: "response did not match the review schema" };
      return { provider: "gemini", status: "reviewed", model, review };
    } catch (e) {
      return { provider: "gemini", status: "unavailable", reason: e instanceof Error ? e.message : String(e) };
    }
  },
});
