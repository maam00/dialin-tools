import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { noPlaceConditions } from "../../lib/plan/conditions.js";
import { checkPlan, makePlan, type PlanInput } from "../../lib/plan/engine.js";
import { recipeOf } from "../../lib/plan/looks.js";
import { enforcePaletteAnswer, palettePolicy } from "../../lib/plan/palette.js";
import { mergeTargetedRepair, targetedRepairFor, targetedRepairSchema } from "../../lib/plan/repair.js";
import { planSchema } from "../../lib/plan/prompts.js";
import type { CameraSlot, ModelLook, ModelPlan } from "../../lib/plan/types.js";
import { answer, FakeAsk, look, recipe } from "./fixtures.js";

const names = ["Open shade", "Warm faces", "Hard sunlight", "Cool interior", "Golden light", "After dark", "Quiet streets"];
const fresh = (n = 7): ModelLook[] => names.slice(0, n).map((name, i) => ({ ...look(name, "Today", { wb_shift_r: i - 3, wb_shift_b: 3 - i }), reuse_slot: 0 }));
const model = (looks = fresh()): ModelPlan => ({ ...answer({ looks, stops: [{ name: "Today", start: "08:00", end: "22:00", light: "Daylight and interiors" }], replace: [] }), primary_look: looks[0]?.name });
const base: PlanInput = { said: "A varied family day", cam: X100VI, count: 7, reasoningMode: "compact", conditions: noPlaceConditions("2026-10-14"), outputMode: "legacy" };
const selected = (raw: ModelPlan) => {
  const original = [...raw.looks];
  const policy = palettePolicy(7, [], null, X100VI, false);
  const problems = enforcePaletteAnswer(raw, null, policy);
  problems.push(...checkPlan(raw, null, 7, new Map(), X100VI)[0]);
  return targetedRepairFor(raw, original, problems, 7, policy, X100VI)!;
};

test("one missing look asks only for that look and preserves complete accepted siblings", async () => {
  const first = model(fresh(6));
  const fake = new FakeAsk([first, { looks: [fresh()[6]] }]);
  const plan = await makePlan({ ...base, ask: fake.ask });
  assert.deepEqual(fake.calls.map((call) => call.task), ["plan", "plan-repair"]);
  assert.match(fake.calls[1].text, /REPAIR ONLY 1 NEW LOOK/);
  assert.deepEqual(Object.keys(fake.calls[1].schema.properties as object), ["looks"]);
  assert.equal(fake.calls[1].maxTokens, 2500);
  assert.equal(plan.palette_complete, true);
  assert.equal(plan.primary_slot, 1);
  assert.deepEqual(plan.day_looks.slice(0, 6).map(recipeOf), first.looks.map(recipeOf));
  assert.deepEqual(plan.day_looks.map((look) => look.name), names);
});

test("a discarded duplicate plus missing entry returns only two entries and retains ordering and setup", async () => {
  const first = model(fresh(6));
  first.looks[5] = { ...first.looks[0], name: names[5], stop: "Dinner" };
  first.stops.push({ name: "Dinner", start: "19:00", end: "21:00", light: "Indoor lamps" });
  const repairs = [fresh()[6], { ...fresh()[5], stop: "Dinner", how: "Check Auto ISO minimum shutter 1/500 for moving people." }];
  const fake = new FakeAsk([first, { looks: repairs }]);
  const plan = await makePlan({ ...base, ask: fake.ask });
  assert.equal(fake.calls[1].task, "plan-repair");
  assert.match(fake.calls[1].text, /REPAIR ONLY 2 NEW LOOKS/);
  assert.match(fake.calls[1].text, /After dark/);
  assert.equal(plan.palette_complete, true);
  assert.deepEqual(plan.day_looks.map((look) => look.name), [...names.slice(0, 5), names[6], names[5]]); // existing assembly groups by stop
  assert.deepEqual(plan.day_looks.slice(0, 5).map(recipeOf), first.looks.slice(0, 5).map(recipeOf));
  assert.match(plan.day_looks.find((look) => look.name === names[5])!.tip, /minimum shutter 1\/500/);
});

test("atomic patch merge keeps the envelope and siblings byte-equivalent with exact source bindings", () => {
  const first = model(fresh(6));
  first.looks[0].recipe_reference_id = "source-a";
  const target = selected(first);
  const before = JSON.stringify(first);
  const patch = { ...fresh()[6], recipe_reference_id: "source-b" };
  const merged = mergeTargetedRepair(first, { looks: [patch] }, target, null, new Map(), ["source-a", "source-b"])!;
  assert.equal(JSON.stringify(first), before);
  assert.deepEqual({ ...merged, looks: merged.looks.slice(0, 6) }, first);
  first.looks.forEach((look, index) => assert.equal(merged.looks[index], look));
  assert.equal(merged.looks[6].recipe_reference_id, "source-b");
  assert.equal(mergeTargetedRepair(first, { looks: [{ ...patch, recipe_reference_id: "invented" }] }, target, null, new Map(), ["source-a"]), null);
  assert.equal(mergeTargetedRepair(first, { ...model(), looks: [patch] }, target, null, new Map(), ["source-b"]), null);
});

test("a repair cannot rewrite siblings, reuse a camera identity, alter primary, or claim an unknown source", async () => {
  for (const bad of [
    { looks: [{ ...fresh()[6], name: names[0] }] },
    { looks: [{ ...fresh()[6], reuse: "Protected", reuse_slot: 3 }] },
    { looks: [fresh()[6]], primary_look: names[6] },
    { looks: [{ ...fresh()[6], recipe_reference_id: "not-supplied" }] },
  ]) {
    const first = model(fresh(6));
    const fake = new FakeAsk([first, bad]);
    const plan = await makePlan({ ...base, ask: fake.ask });
    assert.equal(fake.calls.length, 2);
    assert.equal(fake.calls[1].task, "plan-repair");
    assert.equal(plan.palette_complete, false);
    assert.deepEqual(plan.day_looks.map(recipeOf), first.looks.map(recipeOf));
    assert.match(plan.warnings.join(" "), /accepted looks were preserved/);
  }
});

test("complete validation rejects an invalid recipe or cross-palette intent conflict atomically", async () => {
  for (const patch of [{ ...fresh()[6], noise_reduction: 999 }, { ...fresh()[6], film_sim: "Acros", color: 0 }]) {
    const first = model(fresh(6));
    const fake = new FakeAsk([first, { looks: [patch] }]);
    const plan = await makePlan({ ...base, said: "A family day in color only, no black and white", ask: fake.ask });
    assert.equal(fake.calls[1].task, "plan-repair");
    assert.equal(plan.palette_complete, false);
    assert.deepEqual(plan.day_looks.map(recipeOf), first.looks.map(recipeOf));
    assert.match(plan.warnings.join(" "), /targeted repair rejected/);
  }
});

test("protected and unknown camera recipes stay fixed while only a genuinely missing new look is repaired", async () => {
  const kept = recipe("My favorite", { wb_shift_r: 9 });
  const camera: CameraSlot[] = Array.from({ length: 7 }, (_, index) => ({ slot: index + 1, name: "", recipe: null }));
  camera[1] = { slot: 2, name: kept.name, recipe: kept };
  camera[4] = { slot: 5, name: "Unknown", recipe: null };
  const preserved: ModelLook = { ...look(kept.name, "Today"), ...kept, reuse: kept.name, reuse_slot: 2 };
  const first = model([preserved, ...fresh(4)]);
  const fake = new FakeAsk([first, { looks: [fresh()[4]] }]);
  const plan = await makePlan({ ...base, cameraSlots: camera, protectedSlots: [2, 5], ask: fake.ask });
  assert.equal(fake.calls[1].task, "plan-repair");
  assert.equal(plan.day_looks.length, 6);
  assert.deepEqual(recipeOf(plan.day_looks.find((look) => look.slot === 2)!), kept);
  assert.deepEqual(plan.missing_slots, [5]);
  assert.deepEqual(plan.blocked_slots, [5]);
  assert.equal(plan.palette_complete, false);
  assert.ok(!plan.write.slots.includes(2) && !plan.write.slots.includes(5));
});

test("ambiguous names, omitted protected looks, missing primary and broader malformed answers retain a full retry", async () => {
  for (const kind of ["duplicate-name", "protected", "primary", "bad-value", "many-missing", "intent"]) {
    const first = model(fresh(6));
    const extra: Partial<PlanInput> = {};
    if (kind === "duplicate-name") first.looks[1].name = first.looks[0].name;
    if (kind === "protected") {
      const r = recipe("Protected", { wb_shift_r: 9 });
      extra.cameraSlots = [{ slot: 3, name: r.name, recipe: r }]; extra.protectedSlots = [3];
    }
    if (kind === "primary") first.primary_look = "Missing";
    if (kind === "bad-value") first.looks[0].white_balance = "Invented";
    if (kind === "many-missing") first.looks = first.looks.slice(0, 3);
    if (kind === "intent") { extra.said = "Only color, no black and white"; first.looks[0].film_sim = "Acros"; }
    const fake = new FakeAsk([first, model()]);
    await makePlan({ ...base, ...extra, ask: fake.ask });
    assert.equal(fake.calls[1].task, "plan-retry", kind);
  }
});

test("time budget and cancellation remain bounded across a targeted repair", async () => {
  const lowBudget = new FakeAsk([model(fresh(6)), { looks: [fresh()[6]] }]);
  const partial = await makePlan({ ...base, budgetMs: 20_000, ask: lowBudget.ask });
  assert.equal(lowBudget.calls.length, 1);
  assert.equal(partial.palette_complete, false);
  const controller = new AbortController();
  const fake = new FakeAsk([model(fresh(6)), { looks: [fresh()[6]] }]);
  await assert.rejects(makePlan({ ...base, signal: controller.signal, ask: async (request) => {
    assert.equal(request.signal, controller.signal);
    const result = await fake.ask(request);
    if (request.task === "plan-repair") controller.abort();
    return result;
  } }), { name: "AbortError" });
  assert.equal(fake.calls.length, 2);
});

test("the targeted response schema remains closed and carries the selected mode's look schema unchanged", () => {
  const original = planSchema(X100VI, true, true, ["source-a"]);
  const targeted = targetedRepairSchema(original);
  assert.equal(targeted.additionalProperties, false);
  assert.deepEqual(targeted.required, ["looks"]);
  assert.deepEqual(targeted.properties, { looks: (original.properties as Record<string, unknown>).looks });
});

const concise = (data = model()) => ({ ...data, photographic_brief: { intent: "A varied family day", subjects: ["Family"], lighting: [],
  rendering_goal: "Useful choices", color_priorities: [], observations: ["Family supplied in the request"], uncertainties: ["Exposure not measured"] },
  looks: data.looks.map(({ why, reason, ...item }) => ({ ...item, ideal_film_sim: item.film_sim, recipe_reference_id: null,
    design: { purpose: why, scene_fit: reason, tradeoff: "Check actual skin rendering", alternative: "A softer treatment for faces",
      uncertainty: "Exposure not measured", knowledge_ids: ["taste-intent"] } })) });

test("concise opt-in expands the complete palette and targeted additions through the same validation", async () => {
  const wire = concise(model(fresh(6)));
  const patch = concise().looks[6];
  const fake = new FakeAsk([wire, { looks: [patch] }]);
  const plan = await makePlan({ ...base, outputMode: "concise", ask: fake.ask });
  assert.deepEqual(fake.calls.map((call) => call.task), ["plan", "plan-repair"]);
  assert.equal(plan.output_mode, "concise");
  assert.equal(plan.palette_complete, true);
  assert.deepEqual(plan.day_looks.map((look) => look.name), names);
  const expected = model().looks.map(recipeOf);
  assert.deepEqual(plan.day_looks.map(recipeOf), expected);
  assert.ok(plan.day_looks.every((look) => look.design?.settings_signature && look.design?.guidance_signature));
  assert.ok(plan.day_looks.every((look) => look.tip === "Shoot it like this."));
  const properties = ((fake.calls[0].schema.properties as any).looks.items.properties);
  assert.equal(properties.why, undefined);
  assert.equal(properties.reason, undefined);
  assert.ok(properties.how && properties.exposure);
});

test("malformed concise answers use the existing one full retry and exhausted errors retain call receipts", async () => {
  const invalid = concise() as any;
  delete invalid.looks[0].clarity;
  const repaired = new FakeAsk([invalid, concise()]);
  const plan = await makePlan({ ...base, outputMode: "concise", ask: repaired.ask });
  assert.deepEqual(repaired.calls.map((call) => call.task), ["plan", "plan-retry"]);
  assert.match(repaired.calls[1].text, /look.clarity must be an explicit finite number/);
  assert.equal(plan.palette_complete, true);
  const exhausted = new FakeAsk([invalid, invalid]);
  await assert.rejects(makePlan({ ...base, outputMode: "concise", ask: exhausted.ask }), (error: any) => error.code === "invalid_plan"
    && error.status === 502 && error.calls.length === 2);
  const budget = new FakeAsk([invalid]);
  await assert.rejects(makePlan({ ...base, outputMode: "concise", budgetMs: 20_000, ask: budget.ask }), (error: any) => error.code === "invalid_plan"
    && error.calls.length === 1);
});

test("malformed concise targeted replies preserve accepted settings and cannot replace the envelope", async () => {
  for (const kind of ["missing", "source", "envelope"]) {
    const partial = concise(model(fresh(6)));
    const patch: any = { looks: [concise().looks[6]] };
    if (kind === "missing") delete patch.looks[0].how;
    if (kind === "source") patch.looks[0].recipe_reference_id = "invented";
    if (kind === "envelope") patch.summary = "Replace accepted instructions";
    const fake = new FakeAsk([partial, patch]);
    const plan = await makePlan({ ...base, outputMode: "concise", ask: fake.ask });
    assert.deepEqual(fake.calls.map((call) => call.task), ["plan", "plan-repair"]);
    assert.equal(plan.palette_complete, false);
    assert.deepEqual(plan.day_looks.map(recipeOf), model(fresh(6)).looks.map(recipeOf));
  }
});

test("concise environment rollout stays compact-only and explicit legacy restores the old wire format", async () => {
  const previous = process.env.DIALIN_PLAN_OUTPUT;
  try {
    process.env.DIALIN_PLAN_OUTPUT = "concise";
    const inherited = await makePlan({ ...base, outputMode: undefined, ask: new FakeAsk([concise()]).ask });
    assert.equal(inherited.output_mode, "concise");
    const explicit = await makePlan({ ...base, ask: new FakeAsk([model()]).ask });
    assert.equal(explicit.output_mode, "legacy");
    const detailed = await makePlan({ ...base, reasoningMode: "detailed", outputMode: "concise", ask: new FakeAsk([model()]).ask });
    assert.equal(detailed.output_mode, "legacy");
    delete process.env.DIALIN_PLAN_OUTPUT;
    const defaulted = await makePlan({ ...base, outputMode: undefined, ask: new FakeAsk([model()]).ask });
    assert.equal(defaulted.output_mode, "legacy");
  } finally {
    if (previous === undefined) delete process.env.DIALIN_PLAN_OUTPUT;
    else process.env.DIALIN_PLAN_OUTPUT = previous;
  }
});
