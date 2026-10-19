import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type Anthropic from "@anthropic-ai/sdk";
import { dayConditions, geocode, clearCaches, setGetJson } from "../../lib/plan/conditions.js";
import { cliAttempt, costUsd, makeAsk, MODELS, parseCliResult, sdkAttempt, type AskRequest, type SdkLike } from "../../lib/plan/model.js";
import { nodeRequestOwner } from "../../lib/plan/node-http.js";

const req = (signal?: AbortSignal): AskRequest => ({ task: "test", system: "Stable knowledge", text: "Synthetic scene",
  schema: { type: "object", additionalProperties: false, properties: {} }, model: MODELS.sonnet,
  fallback: MODELS.haiku, effort: "medium", fallbackEffort: "low", timeoutMs: 10_000, signal });
const usage = (input: number, output: number) => ({ input_tokens: input, output_tokens: output,
  cache_read_input_tokens: 0, cache_creation_input_tokens: 0 });
const message = (overrides: Record<string, unknown> = {}) => ({ model: MODELS.sonnet, stop_reason: "end_turn",
  content: [{ type: "text", text: "{}" }], usage: usage(100, 200), _request_id: "req_safe",
  ...overrides } as unknown as Anthropic.Beta.Messages.BetaMessage);

test("SDK owner cancellation passes its signal and cannot trigger a fallback", async () => {
  const controller = new AbortController();
  let calls = 0;
  const client: SdkLike = { beta: { messages: { create: async (_params, options) => {
    calls += 1;
    assert.ok(options?.signal);
    controller.abort();
    // Simulates an adapter that returns despite cancellation; the result must still be discarded.
    return message();
  } } } };
  await assert.rejects(makeAsk(sdkAttempt(client), "api")(req(controller.signal)), { name: "AbortError" });
  assert.equal(calls, 1);
  await assert.rejects(makeAsk(sdkAttempt(client), "api")(req(controller.signal)), { name: "AbortError" });
  assert.equal(calls, 1);
});

test("known usage survives refused/truncated attempts and unknown failures cannot imply complete cost", async () => {
  let calls = 0;
  const client: SdkLike = { beta: { messages: { create: async () => {
    calls += 1;
    return calls === 1 ? message({ stop_reason: "max_tokens", usage: usage(10, 20) })
      : message({ model: MODELS.haiku, usage: usage(30, 40) });
  } } } };
  const result = await makeAsk(sdkAttempt(client), "api")(req());
  assert.deepEqual(result.usage, usage(40, 60));
  assert.equal(result.usageComplete, true);
  assert.equal(result.servedModel, MODELS.haiku);
  assert.equal(result.requestedModel, MODELS.sonnet);
  assert.equal(result.tries[0].stopReason, "max_tokens");
  assert.equal(result.tries[0].providerRequestID, "req_safe");
  assert.equal(result.usd, Number((costUsd(MODELS.sonnet, usage(10, 20))! + costUsd(MODELS.haiku, usage(30, 40))!).toFixed(6)));
  const unknown = await makeAsk(async () => { throw new Error("no provider receipt"); }, "test")(req());
  assert.equal(unknown.usageComplete, false);
  assert.equal(unknown.usd, null);
  assert.equal(unknown.usage, null);
});

test("server-side fallback usage is summed by iteration and exact served identity stays separate", async () => {
  const iterations = [{ type: "message", model: MODELS.sonnet, ...usage(100, 10) },
    { type: "fallback_message", model: MODELS.haiku, ...usage(200, 20) }];
  const client: SdkLike = { beta: { messages: { create: async () => message({ model: MODELS.haiku,
    usage: { ...usage(200, 20), iterations, output_tokens_details: { thinking_tokens: 4 },
      cache_creation: { ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 0 } } }) } } };
  const result = await makeAsk(sdkAttempt(client), "api")(req());
  assert.deepEqual(result.usage, usage(300, 30));
  assert.deepEqual(result.tries[0].providerUsage, usage(200, 20));
  assert.equal(result.tries[0].usageIterations?.length, 2);
  assert.equal(result.tries[0].outputTokenDetails?.thinking_tokens, 4);
  assert.equal(result.servedModel, MODELS.haiku);
  assert.equal(result.usageComplete, true);
});

test("CLI aggregates preserve reported cost without inventing the final serving model", () => {
  const parsed = parseCliResult(JSON.stringify({ structured_output: { ok: true }, model: "sonnet",
    usage: usage(10, 20), total_cost_usd: 0.012,
    modelUsage: { [MODELS.sonnet]: { inputTokens: 10, outputTokens: 20, cacheReadInputTokens: 3, cacheCreationInputTokens: 4, costUSD: 0.012 } } }));
  assert.equal(parsed.servedModel, null);
  assert.equal(parsed.costUsd, 0.012);
  assert.equal(parsed.usageIterations[0].model, MODELS.sonnet);
  assert.equal(parsed.usageIterations[0].usage.cache_creation_input_tokens, 4);
  for (const failure of [{ is_error: true, result: "Safe refusal" }, { result: "incomplete structured result" }]) {
    assert.throws(() => parseCliResult(JSON.stringify({ ...failure, usage: usage(10, 20), total_cost_usd: 0.012,
      modelUsage: { [MODELS.sonnet]: { inputTokens: 10, outputTokens: 20 } } })), (error) => {
      assert.ok(error && typeof error === "object" && "observations" in error);
      const observations = error.observations as { usage: unknown; reportedCostUsd: number; usageIterations: unknown[] };
      assert.deepEqual(observations.usage, usage(10, 20));
      assert.equal(observations.reportedCostUsd, 0.012);
      assert.equal(observations.usageIterations.length, 1);
      return true;
    });
  }
});

test("cancelling CLI work kills the spawned process before another model starts", async () => {
  const folder = mkdtempSync(join(tmpdir(), "dialin-cli-cancel-test-"));
  const executable = join(folder, "fake-cli");
  writeFileSync(executable, `#!${process.execPath}\nsetInterval(() => {}, 1000);\n`);
  chmodSync(executable, 0o700);
  const controller = new AbortController();
  let calls = 0;
  const attempt = cliAttempt(executable);
  const start = Date.now();
  const result = makeAsk(async (...args) => { calls += 1; return attempt(...args); }, "fake-cli")(req(controller.signal));
  const timer = setTimeout(() => controller.abort(), 30);
  try {
    await assert.rejects(result, { name: "AbortError" });
    assert.equal(calls, 1);
    assert.ok(Date.now() - start < 2_000);
  } finally { clearTimeout(timer); rmSync(folder, { recursive: true, force: true }); }
});

test("CLI process stopwatch stays separate from its reported aggregates on success and failure", async () => {
  const folder = mkdtempSync(join(tmpdir(), "dialin-cli-timing-test-"));
  const executable = join(folder, "fake-cli");
  try {
    for (const failed of [false, true]) {
      const response = { structured_output: { ok: true }, is_error: failed, result: "synthetic failure",
        duration_ms: 1234, duration_api_ms: 1100, num_turns: 2 };
      writeFileSync(executable, `#!${process.execPath}\nsetTimeout(() => process.stdout.write(${JSON.stringify(JSON.stringify(response))}), 25);\n`);
      chmodSync(executable, 0o700);
      const result = await makeAsk(cliAttempt(executable), "fake-cli")({ ...req(), fallback: null });
      assert.equal(result.ok, !failed);
      assert.equal(result.tries.length, 1);
      const timing = result.tries[0].timing;
      assert.ok(timing && typeof timing.transportMs === "number" && timing.transportMs >= 20);
      assert.equal(timing.transport, "cli_process");
      assert.equal(timing.cliReportedDurationMs, 1234);
      assert.equal(timing.cliReportedApiMs, 1100);
      assert.equal(timing.cliReportedTurns, 2);
      assert.equal(timing.firstTokenMs, null);
      assert.equal(timing.firstTokenUnavailableReason, "cli_single_result");
    }
  } finally { rmSync(folder, { recursive: true, force: true }); }
});

test("SDK timing does not turn owner cancellation into a timed-out attempt or start a fallback", async () => {
  const owner = new AbortController();
  let starts = 0;
  const client: SdkLike = { beta: { messages: { create: async (_params, options) => {
    starts += 1;
    owner.abort();
    assert.equal(options?.signal?.aborted, true);
    throw new Error("SDK aborted synthetic request");
  } } } };
  await assert.rejects(makeAsk(sdkAttempt(client), "api")(req(owner.signal)), { name: "AbortError" });
  assert.equal(starts, 1);
});

test("forecast cancellation cannot fall back to a second network request or populate a cache", async () => {
  clearCaches();
  const controller = new AbortController();
  let calls = 0;
  const previous = setGetJson(async (_url, _headers, _timeout, signal) => {
    calls += 1;
    assert.equal(signal, controller.signal);
    controller.abort();
    return { timezone: "UTC" };
  });
  try {
    await assert.rejects(dayConditions({ name: "Synthetic", lat: 0, lon: 0 }, "2026-10-14", controller.signal), { name: "AbortError" });
    assert.equal(calls, 1);
    await assert.rejects(geocode("Synthetic", controller.signal), { name: "AbortError" });
    assert.equal(calls, 1);
  } finally { setGetJson(previous); clearCaches(); }
});

test("client disconnection after its body completes aborts the model-work owner", async () => {
  let entered!: () => void;
  const started = new Promise<void>((resolve) => { entered = resolve; });
  let departed!: () => void;
  const disconnected = new Promise<void>((resolve) => { departed = resolve; });
  const server = createServer(async (incoming, response) => {
    const owner = nodeRequestOwner(incoming, response);
    for await (const _chunk of incoming) { /* consume the complete body */ }
    owner.signal.addEventListener("abort", departed, { once: true });
    entered();
    await disconnected;
    owner.dispose();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const client = request({ host: "127.0.0.1", port: address.port, method: "POST" });
  client.on("error", () => {});
  client.end("{}");
  try {
    await started;
    client.destroy();
    const timer = setTimeout(() => departed(), 1_000);
    // The timeout merely prevents a hanging fixture; assert the actual abort separately.
    let aborted = false;
    // Registering another close listener is unnecessary: model owner completion occurs via abort above.
    await Promise.race([disconnected.then(() => { aborted = true; }), new Promise<void>((resolve) => setTimeout(resolve, 500))]);
    clearTimeout(timer);
    assert.equal(aborted, true);
  } finally { client.destroy(); server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve())); }
});
