// Optional Claude juror (Anthropic SDK, structured output). Used only when ANTHROPIC_API_KEY is set.
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { Review, type Juror, type JurorOutcome } from "./types.ts";

const MODEL = "claude-opus-5-5";

export const anthropicJuror = (): Juror => ({
  provider: "anthropic",
  available: () => Boolean(process.env.ANTHROPIC_API_KEY),
  async review(system: string, user: string): Promise<JurorOutcome> {
    try {
      const response = await new Anthropic().messages.parse({
        model: MODEL,
        max_tokens: 16000,
        system,
        messages: [{ role: "user", content: user }],
        output_config: { effort: "high", format: zodOutputFormat(Review) },
      });
      if (response.stop_reason === "refusal") {
        return { provider: "anthropic", status: "unavailable", reason: `declined (${response.stop_details?.category ?? "unspecified"})` };
      }
      if (!response.parsed_output) return { provider: "anthropic", status: "unavailable", reason: `no structured output (${response.stop_reason})` };
      return { provider: "anthropic", status: "reviewed", model: response.model, review: response.parsed_output };
    } catch (err) {
      if (err instanceof Anthropic.APIError) return { provider: "anthropic", status: "unavailable", reason: `API error ${err.status}` };
      return { provider: "anthropic", status: "unavailable", reason: err instanceof Error ? err.message : String(err) };
    }
  },
});
