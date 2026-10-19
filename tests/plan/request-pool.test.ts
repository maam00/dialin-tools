import assert from "node:assert/strict";
import { test } from "node:test";
import { ExactRequestPool, requestFingerprint } from "../../lib/plan/request-pool.js";

test("identical subscribers share work; one cancellation leaves the other alive and returned copies are isolated", async () => {
  const pool = new ExactRequestPool<{ value: number[] }>();
  const first = new AbortController(), second = new AbortController();
  let complete!: (value: { value: number[] }) => void;
  let upstream!: AbortSignal;
  let starts = 0;
  const start = (signal: AbortSignal) => {
    starts += 1; upstream = signal;
    return new Promise<{ value: number[] }>((resolve) => { complete = resolve; });
  };
  const a = pool.run("device:request", "same", first.signal, start);
  const b = pool.run("device:request", "same", second.signal, start);
  await Promise.resolve();
  first.abort();
  await assert.rejects(a, { name: "AbortError" });
  assert.equal(upstream.aborted, false);
  complete({ value: [1] });
  const result = await b;
  assert.equal(result.disposition, "joined");
  result.value.value.push(2);
  const reused = await pool.run("device:request", "same", new AbortController().signal, start);
  assert.deepEqual(reused.value.value, [1]);
  assert.equal(reused.disposition, "reused");
  assert.equal(starts, 1);
});

test("all subscribers leaving aborts upstream and a late success cannot become a cached result", async () => {
  const pool = new ExactRequestPool<number>();
  const first = new AbortController(), second = new AbortController();
  let complete!: (value: number) => void;
  let upstream!: AbortSignal;
  const start = (signal: AbortSignal) => { upstream = signal; return new Promise<number>((resolve) => { complete = resolve; }); };
  const a = pool.run("same", "input", first.signal, start);
  const b = pool.run("same", "input", second.signal, start);
  await Promise.resolve();
  first.abort(); second.abort();
  await Promise.all([assert.rejects(a, { name: "AbortError" }), assert.rejects(b, { name: "AbortError" })]);
  assert.equal(upstream.aborted, true);
  complete(1);
  await Promise.resolve();
  const next = await pool.run("same", "input", new AbortController().signal, async () => 2);
  assert.equal(next.disposition, "new");
  assert.equal(next.value, 2);
});

test("device namespaces, mismatched payloads, failures, TTL and cache capacity are bounded", async () => {
  const pool = new ExactRequestPool<number>(1, 5);
  const signal = new AbortController().signal;
  assert.equal((await pool.run("device-a:id", "body", signal, async () => 1)).value, 1);
  await assert.rejects(pool.run("device-a:id", "different", signal, async () => 99), { code: "request_id_reused" });
  assert.equal((await pool.run("device-b:id", "body", signal, async () => 2)).value, 2); // completed A evicted
  assert.equal((await pool.run("device-a:id", "body", signal, async () => 3)).disposition, "new");
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal((await pool.run("device-a:id", "body", signal, async () => 4)).disposition, "new");
  await assert.rejects(pool.run("failure", "body", signal, async () => { throw new Error("failed"); }));
  assert.equal((await pool.run("failure", "body", signal, async () => 5)).value, 5);
  let failed = false;
  await pool.run("falsey-failure", "body", signal, async () => { throw null; }).then(
    () => assert.fail("A rejection must never become a successful cached result"),
    (error) => { failed = true; assert.equal(error, null); });
  assert.equal(failed, true);
  const active = new ExactRequestPool<number>(1);
  let complete!: (value: number) => void;
  const pending = active.run("first", "body", signal, async () => new Promise<number>((resolve) => { complete = resolve; }));
  await Promise.resolve();
  await assert.rejects(active.run("second", "body", signal, async () => 2), { code: "planner_busy" });
  complete(1); await pending;
});

test("canonical fingerprints tolerate JSON object order but include every private input", () => {
  assert.equal(requestFingerprint({ camera: { model: "X100VI", firmware: "1.10" }, said: "synthetic" }),
    requestFingerprint({ said: "synthetic", camera: { firmware: "1.10", model: "X100VI" } }));
  assert.notEqual(requestFingerprint({ protected_slots: [1] }), requestFingerprint({ protected_slots: [2] }));
});
