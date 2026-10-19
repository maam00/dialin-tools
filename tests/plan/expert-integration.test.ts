import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { noPlaceConditions } from "../../lib/plan/conditions.js";
import { makePlan, planFromClient } from "../../lib/plan/engine.js";
import { DESIGN_SETTINGS, expertGuidanceSignature, expertSettingsSignature } from "../../lib/plan/expert-metadata.js";
import { favoriteRecipes } from "../../lib/plan/favorite-recipes.js";
import { explainRecipe } from "../../lib/plan/reasoning.js";
import { PlanError, type ModelPlan, type RecipeDesign } from "../../lib/plan/types.js";
import { answer, FakeAsk, look, recipe } from "./fixtures.js";

const conditions = noPlaceConditions("2026-10-14");
const names = ["Gentle faces", "Quiet color", "Bright fabric", "Open shadows", "Warm memory", "Soft contrast", "Fine texture"];
const compact = (): RecipeDesign => ({ purpose: "Gentle color for people", scene_fit: "Keep the face prominent without overwhelming the room.",
  choices: [], detail_level: "compact", knowledge_ids: ["sim-pro-neg-std", "wb-mixed"],
  tradeoff: "Less color punch.", alternative: "Choose stronger color when the surroundings matter more.", uncertainty: "Check the actual mixture of window and lamp light." });
const detailed = (): RecipeDesign => ({ ...compact(), detail_level: "detailed",
  choices: DESIGN_SETTINGS.map((setting) => ({ setting, reason: "Support the stated gentle treatment of people.", knowledge_ids: ["taste-intent"] })) });
function palette(): ModelPlan {
  return { ...answer({ looks: names.map((name, i) => ({ ...look(name, "Family", { wb_shift_r: i - 3,
    exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false } }), design: compact() })),
    stops: [{ name: "Family", start: "", end: "", light: "Window and room light" }], replace: [] }), primary_look: names[2],
    photographic_brief: { intent: "Family memories", rendering_goal: "Gentle natural color", subjects: ["Family"],
      lighting: ["Window and lamp light"], color_priorities: ["Natural skin"], observations: ["The photographer described family indoors"], uncertainties: ["Actual light mixture"] } };
}
const input = { said: "Family indoors", cam: X100VI, conditions, count: 7, shootingMode: "automatic" as const,
  reasoningMode: "compact" as const, protectedSlots: [] };

test("compact planning returns all seven complete recipes and binds concise reasoning to the declared primary", async () => {
  const fake = new FakeAsk([palette()]);
  const plan = await makePlan({ ...input, ask: fake.ask });
  assert.equal(plan.palette_complete, true);
  assert.equal(plan.primary_slot, plan.day_looks.find((l) => l.name === names[2])?.slot);
  assert.equal(plan.primary_selection, "declared");
  assert.ok(plan.day_looks.every((l) => l.design?.detail_level === "compact" && !l.design.requires_review));
  assert.equal((plan.expertise as { status: string }).status, "reasoned_proposal");
  const schema = fake.calls[0].schema as any;
  assert.equal(schema.properties.looks.items.properties.design.properties.choices, undefined);
  assert.equal(schema.properties.looks.items.properties.white_balance.type, "string");
  assert.deepEqual(fake.calls[0].maxTokens, 9000);
});

test("explicit all-color intent cannot be bypassed by a monochrome alternate after retry", async () => {
  const bad = palette(); bad.looks[6].film_sim = "Acros"; bad.looks[6].color = 0;
  const fake = new FakeAsk([bad, bad]);
  const plan = await makePlan({ ...input, said: "All seven looks in color. No monochrome.", ask: fake.ask });
  assert.equal(fake.calls.length, 2);
  assert.equal(plan.palette_complete, false);
  assert.equal(plan.intent_satisfied, false);
  assert.ok(plan.day_looks.every((l) => l.film_sim !== "Acros"));
  assert.ok(plan.write.slots.length === 6);
});

test("primary color restriction permits a separately scoped monochrome treatment", async () => {
  const data = palette(); data.looks[0].film_sim = "Acros"; data.looks[0].color = 0;
  const plan = await makePlan({ ...input, said: "My primary look in color; a monochrome alternate is fine.", ask: new FakeAsk([data]).ask });
  assert.equal(plan.palette_complete, true);
  assert.equal(plan.intent_satisfied, true);
  assert.equal(plan.day_looks.find((l) => l.slot === plan.primary_slot)?.name, names[2]);
});

test("a protected monochrome bank is preserved and the intent conflict is disclosed", async () => {
  const data = palette();
  const fixed = recipe("My mono", { film_sim: "Acros", color: 0 });
  data.looks[6] = { ...data.looks[6], ...fixed, reuse: fixed.name, reuse_slot: 7 };
  const camera = Array.from({ length: 7 }, (_, i) => ({ slot: i + 1, name: i === 6 ? fixed.name : "", recipe: i === 6 ? fixed : null }));
  const plan = await makePlan({ ...input, said: "All color", cameraSlots: camera, protectedSlots: [7], ask: new FakeAsk([data]).ask });
  assert.equal(plan.day_looks.find((l) => l.slot === 7)?.status, "kept");
  assert.ok(!plan.write.slots.includes(7));
  assert.equal(plan.intent_satisfied, false);
  assert.match(plan.warnings.join(" "), /existing settings stay protected/);
});

test("factual mistakes are removed without changing camera values or certifying prose", async () => {
  const data = palette(); data.looks[0].design!.alternative = "Acros+R gives more drama but darkens red.";
  const plan = await makePlan({ ...input, ask: new FakeAsk([data]).ask });
  const first = plan.day_looks.find((l) => l.name === names[0])!;
  assert.equal(first.design?.alternative, "");
  assert.equal(first.design?.requires_review, true);
  assert.equal(first.wb_shift_r, -3);
  assert.equal((plan.factual_issues as unknown[]).length, 1);
  const client = structuredClone(plan);
  client.day_looks[0].design!.alternative = "Acros+R darkens red.";
  client.day_looks[0].design!.requires_review = false;
  assert.equal(planFromClient(client, X100VI).day_looks[0].design?.alternative, "");
});

test("inactive monochrome fields cannot manufacture additional distinct looks", async () => {
  const data = palette();
  for (const l of data.looks) { l.film_sim = "Acros"; l.color = 0; }
  const plan = await makePlan({ ...input, ask: new FakeAsk([data, data]).ask });
  assert.equal(plan.day_looks.length, 1);
  assert.equal(plan.palette_complete, false);
});

test("detailed explanations bind only the exact recipe and never return settings mutations", async () => {
  const plan = await makePlan({ ...input, ask: new FakeAsk([palette()]).ask });
  const original = JSON.stringify(plan);
  const l = plan.day_looks[2];
  const result = await explainRecipe({ plan, slot: l.slot!, cam: X100VI, ask: new FakeAsk([{ design: detailed() }]).ask });
  assert.equal(result.design.settings_signature, expertSettingsSignature(l));
  assert.equal(result.design.guidance_signature, expertGuidanceSignature(l));
  assert.equal(result.design.choices.length, 7);
  assert.equal(JSON.stringify(plan), original);
  assert.equal("recipe" in result, false);
});

test("failed factual explanations retain usage receipts and never acquire confidence", async () => {
  const plan = await makePlan({ ...input, ask: new FakeAsk([palette()]).ask });
  const wrong = detailed(); wrong.choices[0].reason = "Acros+R darkens red.";
  await assert.rejects(explainRecipe({ plan, slot: plan.day_looks[0].slot!, cam: X100VI,
    ask: new FakeAsk([{ design: wrong }]).ask }), (e: unknown) => e instanceof PlanError && e.code === "reasoning_review" && e.calls?.length === 1);
});

test("cancellation after a provider ignores abort cannot salvage a plan or start a retry", async () => {
  const controller = new AbortController();
  const fake = new FakeAsk([palette()]);
  await assert.rejects(makePlan({ ...input, signal: controller.signal, ask: async (request) => {
    assert.equal(request.signal, controller.signal);
    const result = await fake.ask(request); controller.abort(); return result;
  } }), { name: "AbortError" });
  assert.equal(fake.calls.length, 1);
});

test("favorites preserve same-name versions, deduplicate renamed exact settings and reject invalid recipes", () => {
  const make = (id: string, r: ReturnType<typeof recipe>) => ({ recipe_id: id.repeat(64), recipe: r, purpose: "Portrait", note: "Keep skin gentle" });
  const original = recipe("Same name");
  const values = favoriteRecipes({ favorites: [make("a", original), make("b", { ...original, wb_shift_r: 2 }),
    make("c", { ...original, name: "New name" }), make("d", { ...original, film_sim: "Invented" })] }, X100VI);
  assert.equal(values.length, 2);
  assert.equal(values[0].recipe.name, values[1].recipe.name);
  assert.notEqual(values[0].recipe.wb_shift_r, values[1].recipe.wb_shift_r);
});

test("final validation rejects an injected color look in a trailing-only monochrome request", async () => {
  const bad = palette();
  bad.looks.forEach((l, i) => { l.film_sim = i === 6 ? "Reala Ace" : "Acros"; l.color = 0; l.shadow = i / 2; });
  const plan = await makePlan({ ...input, said: "Exactly seven monochrome looks only. No color look at all.", ask: new FakeAsk([bad, bad]).ask });
  assert.equal(plan.intent_satisfied, false);
  assert.equal(plan.palette_complete, false);
  assert.ok(plan.day_looks.every((l) => l.film_sim !== "Reala Ace"));
});

test("explicit warm-cast avoidance survives retry and final settings validation", async () => {
  const bad = palette();
  Object.assign(bad.looks[0], { film_sim: "Nostalgic Neg", wb_shift_r: 4, wb_shift_b: -5 });
  const plan = await makePlan({ ...input, said: "Natural skin. Avoid amber, orange or nostalgic warm casts.", ask: new FakeAsk([bad, bad]).ask });
  assert.equal(plan.intent_satisfied, false);
  assert.ok(plan.day_looks.every((l) => l.film_sim !== "Nostalgic Neg"));
  assert.match(plan.warnings.join(" "), /warm-shifted/);
});

test("local source-audit observer sees the accepted draft and cannot mutate the final plan", async () => {
  const data = palette();
  let observed: ModelPlan | undefined;
  const plan = await makePlan({ ...input, ask: new FakeAsk([data]).ask, onValidatedModelPlan: (draft) => {
    observed = structuredClone(draft);
    draft.looks[0].name = "Observer must not change settings";
    draft.looks[0].film_sim = "Invalid simulation";
    draft.looks.splice(1);
  } });
  assert.equal(observed?.looks.length, 7);
  assert.equal(plan.day_looks.length, 7);
  assert.equal(plan.day_looks[0].name, names[0]);
  assert.ok(plan.day_looks.every((look) => look.film_sim !== "Invalid simulation"));
});
