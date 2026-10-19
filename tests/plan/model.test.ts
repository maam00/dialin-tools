// The model transports with mocks: the SDK request body, the timeout + fallback loop, error mapping, the claude -p
// result parser and transport selection. The SDK path is the production path; it has only ever met these mocks
// (untested against the live API until a key exists).
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import Anthropic from "@anthropic-ai/sdk";
import { X100VI } from "../../lib/cameras.js";
import {
  type AskRequest, type Attempt, cliArgv, costUsd, makeAsk, ModelError, parseCliResult, sdkAttempt, sdkParams,
  SERVER_FALLBACK_BETA, type SdkLike, toModelError, transportMode,
} from "../../lib/plan/model.js";
import { planSchema, planSystem } from "../../lib/plan/prompts.js";
import { answer } from "./fixtures.js";

const req = (o: Partial<AskRequest> = {}): AskRequest => ({
  task: "plan", system: planSystem(X100VI), text: "They said: \"beach\"", schema: planSchema(X100VI),
  model: "claude-sonnet-5-5", fallback: "claude-haiku-5-5", effort: "medium", fallbackEffort: "low", timeoutMs: 100_000, ...o,
});

function message(text: string, o: Record<string, unknown> = {}) {
  return {
    id: "msg_1", type: "message", role: "assistant", model: "claude-sonnet-5-5", stop_reason: "end_turn", stop_details: null,
    content: [{ type: "thinking", thinking: "", signature: "x" }, { type: "text", text }],
    usage: { input_tokens: 3000, output_tokens: 4000, cache_read_input_tokens: 2500, cache_creation_input_tokens: 0 },
    ...o,
  } as unknown as Anthropic.Beta.Messages.BetaMessage;
}

class MockClient implements SdkLike {
  calls: { params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming; options?: { timeout?: number; maxRetries?: number } }[] = [];
  constructor(private replies: (Anthropic.Beta.Messages.BetaMessage | Error)[]) {}
  beta = {
    messages: {
      create: async (params: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming, options?: { timeout?: number; maxRetries?: number }) => {
        this.calls.push({ params, options });
        const r = this.replies.shift();
        if (!r) throw new Error("no reply queued");
        if (r instanceof Error) throw r;
        return r;
      },
    },
  };
}

describe("SDK request body", () => {
  test("structured output, cached system prompt, effort, server fallback on Sonnet", () => {
    const p = sdkParams(req({ imageBase64: "/9j/AAAA" }), "claude-sonnet-5-5", "medium") as unknown as Record<string, unknown>;
    assert.equal(p.model, "claude-sonnet-5-5");
    assert.equal(p.max_tokens, 16_000);
    assert.deepEqual((p.system as { cache_control: unknown }[])[0].cache_control, { type: "ephemeral" });
    const oc = p.output_config as { effort: string; format: { type: string; schema: unknown } };
    assert.equal(oc.effort, "medium");
    assert.equal(oc.format.type, "json_schema");
    assert.deepEqual(oc.format.schema, planSchema(X100VI));
    assert.deepEqual([p.betas, p.fallbacks], [[SERVER_FALLBACK_BETA], "default"]);
    assert.ok(!("thinking" in p)); // adaptive by default; budget_tokens / disabled would 400 on these models
    assert.ok(!("temperature" in p));
    const content = (p.messages as { content: { type: string; source?: { media_type: string } }[] }[])[0].content;
    assert.deepEqual(content.map((c) => c.type), ["image", "text"]); // the image before the words
    assert.equal(content[0].source?.media_type, "image/jpeg");
  });

  test("no server fallback on Haiku (it has none) or when switched off", () => {
    const h = sdkParams(req(), "claude-haiku-5-5", "low") as unknown as Record<string, unknown>;
    assert.ok(!("fallbacks" in h) && !("betas" in h));
    process.env.DIALIN_SERVER_FALLBACK = "off";
    try {
      assert.ok(!("fallbacks" in (sdkParams(req(), "claude-opus-5-5", "medium") as unknown as Record<string, unknown>)));
    } finally {
      delete process.env.DIALIN_SERVER_FALLBACK;
    }
    const noImage = sdkParams(req(), "claude-sonnet-5-5", "medium") as unknown as { messages: { content: { type: string }[] }[] };
    assert.deepEqual(noImage.messages[0].content.map((c) => c.type), ["text"]);
  });
});

describe("SDK attempt (mocked client)", () => {
  test("parses the JSON text block, reads usage, passes the time budget and no SDK retries", async () => {
    const client = new MockClient([message(JSON.stringify(answer()))]);
    const ask = makeAsk(sdkAttempt(client), "api");
    const a = await ask(req());
    assert.equal(a.ok, true);
    assert.equal((a.data as { looks: unknown[] }).looks.length, 4);
    assert.deepEqual(a.usage, { input_tokens: 3000, output_tokens: 4000, cache_read_input_tokens: 2500, cache_creation_input_tokens: 0 });
    assert.equal(a.usd, costUsd("claude-sonnet-5-5", a.usage));
    assert.equal(client.calls[0].options?.maxRetries, 0);
    assert.equal(client.calls[0].options?.timeout, 72_000); // 72% of the budget for the primary model
    const timing = a.tries[0].timing;
    assert.equal(timing?.transport, "sdk_nonstreaming");
    assert.ok(typeof timing?.transportMs === "number" && timing.transportMs >= 0);
    assert.equal(timing.firstTokenMs, null);
    assert.equal(timing.firstTokenUnavailableReason, "sdk_nonstreaming");
    assert.equal(timing.cliReportedApiMs, null, "the SDK does not report a provider phase duration");
  });

  test("a timeout falls back to Haiku inside the same budget", async () => {
    const client = new MockClient([new Anthropic.APIConnectionTimeoutError(), message(JSON.stringify(answer()), { model: "claude-haiku-5-5" })]);
    const a = await makeAsk(sdkAttempt(client), "api")(req());
    assert.equal(a.ok, true);
    assert.equal(a.model, "claude-haiku-5-5");
    assert.deepEqual(a.tries.map((t) => [t.model, t.ok, t.code]), [["claude-sonnet-5-5", false, "timeout"], ["claude-haiku-5-5", true, null]]);
    assert.equal(client.calls[1].params.model, "claude-haiku-5-5");
    assert.equal((client.calls[1].params.output_config as { effort: string }).effort, "low");
    assert.ok((client.calls[1].options?.timeout ?? 0) <= 100_000 - 0);
    assert.equal(a.tries[0].timing?.transport, "sdk_nonstreaming", "failed attempts retain their elapsed time");
    assert.ok(typeof a.tries[0].timing?.transportMs === "number");
  });

  test("refusal, max_tokens and bad JSON fall back; a bad key does not", async () => {
    for (const first of [message("{}", { stop_reason: "refusal" }), message("{", { stop_reason: "max_tokens" }), message("not json")]) {
      const client = new MockClient([first, message(JSON.stringify(answer()))]);
      const a = await makeAsk(sdkAttempt(client), "api")(req());
      assert.equal(a.ok, true);
      assert.equal(client.calls.length, 2);
    }
    const auth = new Anthropic.AuthenticationError(401, { type: "error" }, "invalid x-api-key", new Headers());
    const client = new MockClient([auth, message(JSON.stringify(answer()))]);
    const a = await makeAsk(sdkAttempt(client), "api")(req());
    assert.deepEqual([a.ok, a.code, client.calls.length], [false, "auth", 1]);
    assert.doesNotMatch(a.error ?? "", /x-api-key/);
  });

  test("both models failing is a plain failure, never a throw", async () => {
    const client = new MockClient([
      new Anthropic.InternalServerError(529, { type: "error" }, "overloaded", new Headers()),
      new Anthropic.RateLimitError(429, { type: "error" }, "slow down", new Headers()),
    ]);
    const a = await makeAsk(sdkAttempt(client), "api")(req());
    assert.deepEqual([a.ok, a.code, a.tries.length], [false, "rate_limited", 2]);
  });
});

describe("the budget", () => {
  test("a slow primary leaves the fallback the rest; no try starts with under 6 s", async () => {
    const seen: [string, number][] = [];
    const slow: Attempt = async (_r, model, _e, budget) => {
      seen.push([model, budget]);
      throw new ModelError("Claude took too long", "timeout");
    };
    const a = await makeAsk(slow, "test")(req({ timeoutMs: 20_000 }));
    assert.equal(a.ok, false);
    assert.equal(seen[0][1], 14_400);
    assert.equal(seen[1][0], "claude-haiku-5-5");
    const b = await makeAsk(slow, "test")(req({ timeoutMs: 5_000 }));
    assert.deepEqual([b.ok, b.tries.length, b.code], [false, 0, "timeout"]);
  });
});

describe("errors and costs", () => {
  test("SDK errors map to codes, most specific first", () => {
    const h = new Headers();
    assert.equal(toModelError(new Anthropic.APIConnectionTimeoutError()).code, "timeout");
    assert.equal(toModelError(new Anthropic.APIConnectionError({ message: "x" })).code, "connection");
    assert.equal(toModelError(new Anthropic.BadRequestError(400, {}, "bad", h)).code, "bad_request");
    assert.equal(toModelError(new Anthropic.PermissionDeniedError(403, {}, "no", h)).fatal, true);
    assert.equal(toModelError(new Anthropic.APIError(402, {}, "billing", h)).code, "billing");
    assert.equal(toModelError(new Error("boom")).code, "unknown");
  });

  test("cost per call from list prices", () => {
    const u = { input_tokens: 1_000_000, output_tokens: 1_000_000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
    assert.equal(costUsd("claude-sonnet-5-5", u), 12);
    assert.equal(costUsd("claude-opus-5-5", u), 24);
    assert.equal(costUsd("claude-haiku-5-5", u), 3); // over 100K input tokens uses the long-context rate
    assert.equal(costUsd("claude-sonnet-5-5", { ...u, input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 1_000_000 }), 0.1);
    assert.equal(costUsd("other", u), null);
  });
});

describe("claude -p (dev mode)", () => {
  test("argv mirrors studio/ai.py, with effort and the schema", () => {
    const argv = cliArgv("SYS", { type: "object" }, "claude-sonnet-5-5", "medium");
    assert.deepEqual(argv.slice(0, 7), ["-p", "--model", "claude-sonnet-5-5", "--effort", "medium", "--output-format", "json"]);
    assert.equal(argv[argv.indexOf("--json-schema") + 1], "{\"type\":\"object\"}");
    assert.equal(argv[argv.indexOf("--system-prompt") + 1], "SYS");
    assert.ok(argv.includes("--no-session-persistence") && argv.includes("--strict-mcp-config"));
    assert.ok(!argv.some((a) => /dangerously|bypass/i.test(a)));
    assert.equal(argv[argv.indexOf("--tools") + 1], "", "text planning cannot read arbitrary local files");
    assert.ok(!argv.includes("Read") && !argv.includes("--allowedTools"));
    const imageArgv = cliArgv("SYS", { type: "object" }, "claude-sonnet-5-5", "medium", true);
    assert.equal(imageArgv[imageArgv.indexOf("--tools") + 1], "Read", "attached images keep the required reader");
    assert.equal(imageArgv[imageArgv.indexOf("--allowedTools") + 1], "Read");
  });

  test("the result parser reads structured_output and usage, and says why it failed", () => {
    const out = JSON.stringify({ type: "result", is_error: false, result: "", structured_output: { a: 1 }, total_cost_usd: 0.05,
      usage: { input_tokens: 10, output_tokens: 20, cache_read_input_tokens: 30, cache_creation_input_tokens: 40 } });
    const r = parseCliResult(`noise\n${out}\n`);
    assert.deepEqual(r.data, { a: 1 });
    assert.equal(r.usage?.cache_creation_input_tokens, 40);
    assert.deepEqual(parseCliResult(JSON.stringify({ is_error: false, result: "{\"b\":2}" })).data, { b: 2 });
    assert.throws(() => parseCliResult(JSON.stringify({ is_error: true, result: "Claude usage limit reached" })),
      (e: unknown) => e instanceof ModelError && e.code === "rate_limited");
    assert.throws(() => parseCliResult("nothing"), ModelError);
  });

  test("CLI timing retains reported aggregates without inventing first-token or local durations", () => {
    const fields = { duration_ms: 82_000, duration_api_ms: 79_000, num_turns: 2 };
    const expected = { transport: "cli_process", transportMs: null, cliReportedDurationMs: 82_000,
      cliReportedApiMs: 79_000, cliReportedTurns: 2, firstTokenMs: null, firstTokenUnavailableReason: "cli_single_result" };
    assert.deepEqual(parseCliResult(JSON.stringify({ structured_output: { ok: true }, ...fields })).timing, expected);
    assert.throws(() => parseCliResult(JSON.stringify({ is_error: true, result: "synthetic failure", ...fields })), (error) => {
      assert.ok(error instanceof ModelError);
      assert.deepEqual(error.observations.timing, expected);
      return true;
    });
    for (const invalid of [undefined, null, -1, "100", "private response text"]) {
      const timing = parseCliResult(JSON.stringify({ structured_output: {},
        duration_ms: invalid, duration_api_ms: invalid, num_turns: invalid })).timing;
      assert.equal(timing.cliReportedDurationMs, null);
      assert.equal(timing.cliReportedApiMs, null);
      assert.equal(timing.cliReportedTurns, null);
    }
    assert.equal(parseCliResult('{"structured_output":{},"duration_ms":1e999,"duration_api_ms":1e999,"num_turns":1.5}').timing.cliReportedDurationMs, null);
    assert.equal(parseCliResult('{"structured_output":{},"duration_ms":0,"duration_api_ms":0,"num_turns":0}').timing.cliReportedTurns, 0);
    assert.equal(parseCliResult('{"structured_output":{},"num_turns":1.5}').timing.cliReportedTurns, null);
  });

  test("transport selection: a key means the API; deployed without a key means none, never the CLI", () => {
    assert.equal(transportMode({ ANTHROPIC_API_KEY: "k" }), "api");
    assert.equal(transportMode({}), "none");
    assert.equal(transportMode({ DIALIN_MODEL_TRANSPORT: "cli" }), "cli");
    assert.equal(transportMode({ VERCEL: "1" }), "none");
    assert.equal(transportMode({ VERCEL: "1", DIALIN_MODEL_TRANSPORT: "cli" }), "none");
    assert.equal(transportMode({ NODE_ENV: "production" }), "none");
    assert.equal(transportMode({ ANTHROPIC_API_KEY: "k", DIALIN_MODEL_TRANSPORT: "cli" }), "cli");
  });
});
