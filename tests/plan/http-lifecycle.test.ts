import assert from "node:assert/strict";
import { test } from "node:test";
import { DESIGN_SETTINGS } from "../../lib/plan/expert-metadata.js";
import { adjustHandler, planHandler, recipeReasoningHandler } from "../../lib/plan/http.js";
import type { Ask, AskAnswer, AskRequest } from "../../lib/plan/model.js";
import { answer, FakeAsk, DAY_NAMES, PAST } from "./fixtures.js";

const body = (said = "Synthetic beach portraits") => ({ said, camera: { model: "X100VI", firmware: "1.10", slots: DAY_NAMES }, past_looks: PAST });
function post(path: string, value: unknown, options: { signal?: AbortSignal; id?: string; device?: string; token?: string } = {}) {
  return new Request(`http://localhost/api/${path}`, { method: "POST", body: JSON.stringify(value), signal: options.signal,
    headers: { "content-type": "application/json", "x-device-id": options.device ?? "synthetic-device-01",
      ...(options.id ? { "x-request-id": options.id } : {}), ...(options.token ? { "x-app-token": options.token } : {}) } });
}
const result = (req: AskRequest, data: unknown = answer()): AskAnswer => ({ ok: true, data, model: req.model,
  via: "fake", ms: 1, error: null, code: null, usage: null, usd: null, tries: [] });
const turn = () => new Promise<void>((resolve) => setImmediate(resolve));

test("real plan handler reuses exact requests only after auth and within the same device", async () => {
  const fake = new FakeAsk([answer(), answer(), answer()]);
  const logs: Record<string, unknown>[] = [];
  const handler = planHandler({ ask: fake.ask, env: { APP_TOKEN: "synthetic-secret" }, log: (line) => logs.push(line) });
  const options = { token: "synthetic-secret", id: "synthetic-request-01" };
  const first = await handler(post("plan", body(), options));
  assert.equal(first.status, 200);
  const original = await first.json();
  original.day_looks[0].name = "Client mutation";
  const again = await handler(post("plan", body(), options));
  assert.equal(again.status, 200);
  assert.notEqual((await again.json()).day_looks[0].name, "Client mutation");
  assert.equal(fake.calls.length, 1);
  assert.equal((await handler(post("plan", body(), { ...options, token: "wrong-token" }))).status, 401);
  assert.equal(fake.calls.length, 1);
  assert.equal((await handler(post("plan", body(), { ...options, device: "synthetic-device-02" }))).status, 200);
  assert.equal(fake.calls.length, 2);
  const conflict = await handler(post("plan", body("Different synthetic input"), options));
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).code, "request_id_reused");
  assert.equal((await handler(post("plan", body(), { ...options, id: "synthetic-request-02" }))).status, 200);
  assert.equal(fake.calls.length, 3);
  assert.equal(logs.filter((line) => line.request_reuse === "reused").length, 1);
  const serialized = JSON.stringify(logs);
  for (const secret of ["synthetic-secret", "synthetic-device", "synthetic-request", "Synthetic beach", "Different synthetic"]) {
    assert.ok(!serialized.includes(secret), `Leaked ${secret}`);
  }
});

test("real handler subscriber cancellation does not cancel a surviving caller; all callers leaving removes late results", async () => {
  let starts = 0;
  const pending: { signal: AbortSignal; complete: () => void }[] = [];
  const ask: Ask = async (req) => {
    starts += 1;
    return new Promise<AskAnswer>((resolve) => { pending.push({ signal: req.signal!, complete: () => resolve(result(req)) }); });
  };
  const handler = planHandler({ ask, env: {}, log: () => {} });
  const one = new AbortController(), two = new AbortController();
  const options = { id: "shared-request-01" };
  const a = handler(post("plan", body(), { ...options, signal: one.signal }));
  const b = handler(post("plan", body(), { ...options, signal: two.signal }));
  for (let i = 0; i < 10 && !pending.length; i++) await turn();
  await turn();
  assert.equal(starts, 1);
  one.abort();
  assert.equal((await a).status, 499);
  assert.equal(pending[0].signal.aborted, false);
  pending[0].complete();
  assert.equal((await b).status, 200);

  const gone = new AbortController();
  const c = handler(post("plan", body(), { id: "shared-request-02", signal: gone.signal }));
  for (let i = 0; i < 10 && pending.length < 2; i++) await turn();
  gone.abort();
  assert.equal((await c).status, 499);
  assert.equal(pending[1].signal.aborted, true);
  pending[1].complete(); // deliberately ignores upstream abort
  await turn();
  const replacement = handler(post("plan", body(), { id: "shared-request-02" }));
  for (let i = 0; i < 10 && pending.length < 3; i++) await turn();
  assert.equal(starts, 3);
  pending[2].complete();
  assert.equal((await replacement).status, 200);
});

test("failed plans are never cached and their safe failure receipts survive HTTP errors", async () => {
  let starts = 0;
  const handler = planHandler({ env: {}, log: (line) => logs.push(line), ask: async (req) => {
    starts += 1;
    return starts === 1 ? { ...result(req), ok: false, data: null, code: "max_tokens", error: "Safe failure",
      usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }, usd: 0.01,
      requestedModel: req.model, servedModel: req.model, usageComplete: true } : result(req);
  } });
  const logs: Record<string, unknown>[] = [];
  const options = { id: "failure-request-01" };
  assert.equal((await handler(post("plan", body(), options))).status, 502);
  assert.equal((logs[0].calls as { out: number }[])[0].out, 20);
  assert.equal(logs[0].usd, 0.01);
  assert.equal((await handler(post("plan", body(), options))).status, 200);
  assert.equal(starts, 2);
});

test("body cancellation and byte limits stop before forecast or model work", async () => {
  const fake = new FakeAsk([answer()]);
  const handler = planHandler({ ask: fake.ask, env: {}, log: () => {} });
  const controller = new AbortController();
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({ start(sink) { sink.enqueue(new TextEncoder().encode('{"said":"partial')); },
    cancel() { cancelled = true; } });
  const request = new Request("http://localhost/api/plan", { method: "POST", body: stream, duplex: "half", signal: controller.signal } as RequestInit);
  const response = handler(request);
  await turn(); controller.abort();
  assert.equal((await response).status, 499);
  assert.equal(cancelled, true);
  assert.equal(fake.calls.length, 0);
  // Length measured as UTF-8 bytes, not JavaScript characters.
  const oversize = await handler(post("plan", { padding: "界".repeat(900_000) }));
  assert.equal(oversize.status, 413);
  assert.equal(fake.calls.length, 0);
  assert.equal((await handler(post("plan", body(), { id: "bad id with spaces" }))).status, 400);
  assert.equal(fake.calls.length, 0);
});

test("read-only recipe reasoning validates/authenticates and never returns replacement settings", async () => {
  const original = await planHandler({ ask: new FakeAsk([answer()]).ask, env: {}, log: () => {} })(post("plan", body()));
  const plan = await original.json();
  const saved = JSON.stringify(plan);
  const design = { purpose: "Protect the subject's intended rendering", scene_fit: "A restrained rendering of the supplied beach scene.",
    choices: DESIGN_SETTINGS.map((setting) => ({ setting, reason: "Supports the intended rendering with a visible tradeoff.", knowledge_ids: ["taste-intent"] })),
    tradeoff: "Less vivid color.", alternative: "Use a punchier rendering when color dominates the subject.", uncertainty: "Inspect the actual face and highlights." };
  const fake = new FakeAsk([{ design }]);
  const handler = recipeReasoningHandler({ ask: fake.ask, env: { APP_TOKEN: "synthetic-secret" }, log: () => {} });
  const value = { camera: { model: "X100VI" }, plan, slot: plan.day_looks[0].slot };
  assert.equal((await handler(post("recipe-reasoning", value))).status, 401);
  assert.equal((await handler(post("recipe-reasoning", { ...value, slot: 8 }, { token: "synthetic-secret" }))).status, 400);
  assert.equal(fake.calls.length, 0);
  const response = await handler(post("recipe-reasoning", value, { token: "synthetic-secret" }));
  assert.equal(response.status, 200);
  const explanation = await response.json();
  assert.equal(explanation.slot, value.slot);
  assert.equal(explanation.design.detail_level, "detailed");
  assert.ok(!("look" in explanation) && !("plan" in explanation) && !("write_slot" in explanation));
  assert.equal(JSON.stringify(plan), saved);
  assert.equal(fake.calls.length, 1);
});

test("adjust and reasoning cancellation reaches their model and cannot apply a late result", async () => {
  const original = await planHandler({ ask: new FakeAsk([answer()]).ask, env: {}, log: () => {} })(post("plan", body()));
  const plan = await original.json();
  for (const [path, factory] of [["adjust", adjustHandler], ["recipe-reasoning", recipeReasoningHandler]] as const) {
    const owner = new AbortController();
    let calls = 0;
    const handler = factory({ env: {}, log: () => {}, ask: async (req) => {
      calls += 1;
      assert.ok(req.signal);
      owner.abort();
      return result(req); // deliberately ignores abort
    } });
    const response = await handler(post(path, { camera: { model: "X100VI" }, plan, slot: plan.day_looks[0].slot, said: "Slightly cooler" }, { signal: owner.signal }));
    assert.equal(response.status, 499);
    assert.equal(calls, 1);
  }
});
