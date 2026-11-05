// Groq and Cerebras both expose OpenAI-compatible /chat/completions and /models endpoints.
import { parseReview, type Juror, type JurorOutcome } from "./types.ts";

interface Config {
  provider: string;
  baseUrl: string; // e.g. https://api.groq.com/openai/v1
  apiKeyEnv: string;
  modelEnv: string;
  preferred: RegExp[]; // model-id preferences, best first
}

export function openAiCompatibleJuror(cfg: Config): Juror {
  const key = () => process.env[cfg.apiKeyEnv];

  async function pickModel(): Promise<string> {
    const pinned = process.env[cfg.modelEnv];
    if (pinned) return pinned;
    const res = await fetch(`${cfg.baseUrl}/models`, { headers: { Authorization: `Bearer ${key()}` } });
    if (!res.ok) throw new Error(`${cfg.provider} /models ${res.status}`);
    const ids: string[] = ((await res.json()).data ?? []).map((m: any) => m.id).sort();
    for (const re of cfg.preferred) {
      const hit = ids.find((id) => re.test(id));
      if (hit) return hit;
    }
    if (!ids.length) throw new Error(`${cfg.provider}: no models listed`);
    return ids[0];
  }

  return {
    provider: cfg.provider,
    available: () => Boolean(key()),
    async review(system: string, user: string): Promise<JurorOutcome> {
      try {
        const model = await pickModel();
        const res = await fetch(`${cfg.baseUrl}/chat/completions`, {
          method: "POST",
          headers: { Authorization: `Bearer ${key()}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            model,
            messages: [
              { role: "system", content: system },
              { role: "user", content: user },
            ],
            response_format: { type: "json_object" },
            max_tokens: 4000,
          }),
        });
        if (!res.ok) return { provider: cfg.provider, status: "unavailable", reason: `HTTP ${res.status}: ${(await res.text()).slice(0, 160)}` };
        const body = await res.json();
        const review = parseReview(body.choices?.[0]?.message?.content ?? "");
        if (!review) return { provider: cfg.provider, status: "unavailable", reason: "response did not match the review schema" };
        return { provider: cfg.provider, status: "reviewed", model: body.model ?? model, review };
      } catch (e) {
        return { provider: cfg.provider, status: "unavailable", reason: e instanceof Error ? e.message : String(e) };
      }
    },
  };
}

export const groqJuror = () =>
  openAiCompatibleJuror({
    provider: "groq",
    baseUrl: "https://api.groq.com/openai/v1",
    apiKeyEnv: "GROQ_API_KEY",
    modelEnv: "GROQ_MODEL",
    preferred: [/llama-?4.*maverick/i, /llama-?3\.3-70b/i, /gpt-oss-120b/i, /70b/i],
  });

export const cerebrasJuror = () =>
  openAiCompatibleJuror({
    provider: "cerebras",
    baseUrl: "https://api.cerebras.ai/v1",
    apiKeyEnv: "CEREBRAS_API_KEY",
    modelEnv: "CEREBRAS_MODEL",
    preferred: [/gpt-oss-120b/i, /qwen-?3.*235b/i, /llama-?3\.3-70b/i, /70b/i],
  });
