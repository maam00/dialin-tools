import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { adjustPlan, makePlan, planFromClient } from "../../lib/plan/engine.js";
import { expertKnowledge, knowledgeIDs } from "../../lib/plan/expert-knowledge.js";
import { DESIGN_SETTINGS, expertSettingsSignature, photographicBrief, recipeDesign } from "../../lib/plan/expert-metadata.js";
import { planSchema } from "../../lib/plan/prompts.js";
import type { PhotographicBrief, RecipeDesign } from "../../lib/plan/types.js";
import { answer, FakeAsk, FakeNet, look, recipe } from "./fixtures.js";

beforeEach(() => { new FakeNet().install(); });

const brief: PhotographicBrief = { intent: "Warm café memories with natural-looking skin", subjects: ["My family", "Colorful food"],
  lighting: ["Window light mixed with warm bulbs, described by the photographer"], color_priorities: ["Keep faces neutral; retain some room warmth"],
  rendering_goal: "Gentle warm documentary color", observations: ["The photographer describes window and bulb light"],
  uncertainties: ["Actual source temperature and lighting mixture"] };
const design = (): RecipeDesign => ({ purpose: "Gentle skin-first color", scene_fit: "Prioritize faces while leaving the café warm.",
  choices: DESIGN_SETTINGS.map((setting) => ({ setting, reason: `${setting} serves the supplied subject and intended rendering.`,
    knowledge_ids: [setting === "film_sim" ? "sim-pro-neg-std" : "taste-intent"] })),
  tradeoff: "Less punch in the food colors.", alternative: "Prefer more vivid color for a food-only frame.", uncertainty: "Check skin under the actual mixed light." });
function detailedAnswer() {
  const data = answer();
  data.photographic_brief = structuredClone(brief);
  for (const l of data.looks) l.design = design();
  return data;
}

test("expert knowledge stays scoped to reviewed body; simulation existence cannot grant a write mapping", () => {
  const text = expertKnowledge(X100VI);
  assert.match(text, /Astia \(camera has it; NEW writes not mapped\)/);
  assert.ok(knowledgeIDs(X100VI).includes("dr-priority"));
  const other = { ...X100VI, id: "X100V" };
  assert.deepEqual(knowledgeIDs(other), []);
  assert.doesNotMatch(expertKnowledge(other), /DR200 needs ISO250/);
});

test("structured model output requests scene/intent analysis and setting-level decisions", () => {
  const schema = planSchema(X100VI) as { required: string[]; properties: Record<string, any> };
  assert.ok(schema.required.includes("photographic_brief"));
  assert.ok(schema.properties.looks.items.required.includes("design"));
  assert.ok(schema.properties.looks.items.properties.design.properties.choices.items.properties.knowledge_ids.items.enum.includes("wb-mixed"));
  assert.ok(!schema.properties.looks.items.properties.design.properties.requires_review);
});

test("invented knowledge IDs, duplicate choice groups and excess decisions cannot acquire a complete rationale", () => {
  const wrong = design();
  wrong.choices[0].knowledge_ids = ["made-up-camera-proof", "sim-pro-neg-std"];
  wrong.choices[1].setting = wrong.choices[0].setting;
  wrong.choices.push(wrong.choices[0]);
  const safe = recipeDesign(wrong, X100VI)!;
  assert.equal(safe.requires_review, true);
  assert.ok(!safe.choices.some((c) => c.knowledge_ids.includes("made-up-camera-proof")));
});

test("metadata has bounded textual evidence and refuses malformed/no-intent input", () => {
  assert.equal(photographicBrief({ subjects: ["café"] }), undefined);
  assert.equal(recipeDesign({ purpose: "Nice", scene_fit: "Nice", choices: "not an array" }, X100VI), undefined);
  const limited = photographicBrief({ ...brief, observations: Array(30).fill("x".repeat(500)), intent: "x".repeat(500) })!;
  assert.equal(limited.observations.length, 8);
  assert.equal(limited.observations[0].length, 160);
  assert.equal(limited.intent.length, 240);
});

test("settings signatures follow rendering changes, never cosmetic rename/reason changes", () => {
  const r = recipe("First");
  assert.equal(expertSettingsSignature(r), expertSettingsSignature({ ...r, name: "Second", why: "Other words" }));
  assert.notEqual(expertSettingsSignature(r), expertSettingsSignature({ ...r, wb_shift_b: r.wb_shift_b + 1 }));
});

test("returned recommendations retain brief, exact rationale and curated source receipt without taste-proof claims", async () => {
  const fake = new FakeAsk([detailedAnswer()]);
  const plan = await makePlan({ said: brief.intent, cam: X100VI, ask: fake.ask });
  assert.deepEqual(plan.photographic_brief, brief);
  const receipt = plan.expertise as { status: string; evaluated_on_real_photographs: boolean; sources: { url: string }[] };
  assert.equal(receipt.status, "reasoned_proposal");
  assert.equal(receipt.evaluated_on_real_photographs, false);
  assert.ok(receipt.sources.every((s) => s.url.startsWith("https://www.fujifilm-x.com/")));
  assert.ok(plan.day_looks.every((l) => l.design?.settings_signature === expertSettingsSignature(l)));
});

test("legacy recipes remain usable but missing expertise cannot become a reasoned recommendation", async () => {
  const plan = await makePlan({ said: "My family in the café", cam: X100VI, ask: new FakeAsk([answer()]).ask });
  assert.ok(plan.day_looks.length);
  assert.equal((plan.expertise as { status: string }).status, "incomplete_reasoning");
  assert.equal(plan.photographic_brief, undefined);
});

test("one reasoned look among otherwise generic looks cannot certify the whole recommendation", async () => {
  const data = detailedAnswer();
  delete data.looks[1].design;
  const plan = await makePlan({ said: brief.intent, cam: X100VI, ask: new FakeAsk([data]).ask });
  assert.equal((plan.expertise as { status: string }).status, "incomplete_reasoning");
});

test("automatic normalization invalidates rationale for a different exposure or clarity proposal", async () => {
  const data = detailedAnswer();
  data.looks[0].clarity = 2;
  const plan = await makePlan({ said: brief.intent, cam: X100VI, shootingMode: "automatic", ask: new FakeAsk([data]).ask });
  const changed = plan.day_looks.find((l) => l.name === data.looks[0].name)!;
  assert.equal(changed.clarity, 0);
  assert.equal(changed.design?.requires_review, true);
  assert.notEqual(changed.design?.settings_signature, expertSettingsSignature(changed));
  assert.equal((plan.expertise as { status: string }).status, "incomplete_reasoning");
});

test("writable substitutions remain disclosed and cannot silently inherit the original aesthetic rationale", async () => {
  const data = detailedAnswer();
  data.looks[0].film_sim = "Astia";
  const plan = await makePlan({ said: brief.intent, cam: X100VI, ask: new FakeAsk([data]).ask });
  const changed = plan.day_looks.find((l) => l.name === data.looks[0].name)!;
  assert.notEqual(changed.film_sim, "Astia");
  assert.equal(changed.design?.requires_review, true);
  assert.ok(plan.warnings.some((w) => w.includes("Astia")));
});

test("adjustment sees the original intent and retains its rationale/provenance separately from writes", async () => {
  const plan = await makePlan({ said: brief.intent, cam: X100VI, ask: new FakeAsk([detailedAnswer()]).ask });
  const current = plan.day_looks[0];
  const next = look(current.name, current.stop);
  next.design = design();
  const fake = new FakeAsk([{ look: next, change: "A small WB correction." }]);
  const result = await adjustPlan({ plan, slot: current.slot!, said: "The face is too orange", cam: X100VI, ask: fake.ask });
  assert.match(fake.calls[0].text, /Warm café memories with natural-looking skin/);
  assert.ok(result.look.design);
  assert.equal(result.look.design?.settings_signature, expertSettingsSignature(result.look));
  assert.deepEqual(result.plan.photographic_brief, brief);
});

test("client-provided confidence and stale rationale cannot survive plan validation as photographic proof", async () => {
  const plan = await makePlan({ said: brief.intent, cam: X100VI, ask: new FakeAsk([detailedAnswer()]).ask });
  plan.day_looks[0].wb_shift_r += 1;
  plan.expertise = { status: "worlds_best", evaluated_on_real_photographs: true };
  const valid = planFromClient(plan, X100VI);
  assert.equal(valid.day_looks[0].design?.requires_review, true);
  assert.equal((valid.expertise as { evaluated_on_real_photographs: boolean }).evaluated_on_real_photographs, false);
  assert.equal((valid.expertise as { status: string }).status, "incomplete_reasoning");
});
