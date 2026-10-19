import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { noPlaceConditions } from "../../lib/plan/conditions.js";
import { makePlan, planFromClient } from "../../lib/plan/engine.js";
import { parsePlanRequest } from "../../lib/plan/http.js";
import { attributeRecipe, buildRecipeLibrary, recipeFactSignature, recipeKnowledgeContext, searchRecipes, selectRecipeCandidates,
  type PublicRecipeIndex, type RecipeKnowledge, type RecipeJudgment } from "../../lib/recipes/library.js";
import { recipeUsage, type RecipeUsageGrant } from "../../lib/recipes/permissions.js";
import { recipeFactLessons, recipeJudgmentLessons, type ReviewedJudgmentExample } from "../../lib/recipes/training.js";
import type { RawRecipeRecord } from "../../lib/recipes/types.js";
import { normalizeRecipe } from "../../lib/recipes/normalize.js";
import { answer, FakeAsk, look, recipe } from "./fixtures.js";

// Invented records and original test settings: no external source or photographic quality claims.
const now = Date.parse("2026-10-14T23:00:00Z");
const raw = (overrides: Partial<RawRecipeRecord> = {}): RawRecipeRecord => ({ id: "synthetic-recipe-a", title: "Synthetic Amber",
  source_url: "https://recipes.example/2026/01/01/synthetic-fixture/", groups: ["X-Trans V"], fetched_at: "2026-10-14T12:00:00Z",
  content_sha256: "a".repeat(64), status: "public_settings", source_scope: "public_web_facts", training_permission: "not_verified", notes: [],
  settings: { "Film Simulation": "Classic Chrome", "Grain Effect": "Off", "Color Chrome Effect": "Off", "Color Chrome FX Blue": "Off",
    "White Balance": "Auto, +1 Red & -1 Blue", "Dynamic Range": "DR200", "Highlight": "-1", "Shadow": "0", "Color": "0",
    "Sharpness": "-1", "Noise Reduction": "-4", "Clarity": "-2", "Kelvin": "0" }, ...overrides });
const grant = (r = raw(), scopes: RecipeUsageGrant["scopes"] = ["model_context", "training"]): RecipeUsageGrant => ({
  record_id: r.id, content_sha256: r.content_sha256!, scopes, reviewed_by: "Synthetic reviewer", reviewed_at: "2026-10-14T12:00:00Z",
  permission_evidence: "synthetic-test-only; not an actual permission" });
const judgment = (r = raw()): RecipeJudgment => ({ record_id: r.id, content_sha256: r.content_sha256!, camera_models: ["X100VI"],
  source_fact_signature: recipeFactSignature(normalizeRecipe(r)),
  scene_tags: ["family", "window"], intent_tags: ["warm", "memory"], avoid_tags: ["no warm cast"],
  rationale: "A synthetic deliberate warm interpretation.", tradeoff: "Check orange faces under warm lamps.",
  reviewed_by: "Synthetic test reviewer", reviewed_at: "2026-10-14T12:00:00Z", evidence: "desk_review" });
const brief = (intent = "warm family memory") => ({ intent, rendering_goal: intent, subjects: ["family"], lighting: ["window"],
  color_priorities: [], observations: [], uncertainties: ["Scene not metered"] });
const knowledge = (records = [raw()], mode: RecipeKnowledge["mode"] = "private_research"): RecipeKnowledge => ({
  library: buildRecipeLibrary({ version: "synthetic", observed_at: "2026-10-14", records, index_sha256: "b".repeat(64), fetch_summary: {} }),
  permissions: [], judgments: records.map(judgment), mode });

test("public records never self-grant commercial or training permission; explicit private research is separate", () => {
  const r = raw();
  assert.equal(recipeUsage(r, "training", [], now).allowed, false);
  assert.equal(recipeUsage(r, "training", [], now, "private_research").allowed, true);
  assert.equal(recipeUsage(r, "training", [grant(r)], now).allowed, true);
  assert.equal(recipeUsage(r, "training", [grant(r, ["model_context"])], now).allowed, false);
  assert.equal(recipeUsage(r, "training", [{ ...grant(r), content_sha256: "b".repeat(64) }], now).allowed, false);
  assert.equal(recipeUsage(r, "training", [{ ...grant(r), expires_at: "2020-01-01" }], now).allowed, false);
  assert.equal(recipeUsage(r, "training", [{ ...grant(r), reviewed_at: "2099-01-01" }], now).allowed, false);
  assert.equal(recipeUsage(r, "training", [{ ...grant(r), reviewed_by: "" }], now).allowed, false);
  assert.equal(r.training_permission, "not_verified");
});

test("library rejects duplicate identity and keeps caller data isolated", () => {
  const r = raw(), k = knowledge([r]);
  r.settings.Clarity = "5";
  assert.equal(k.library.entries[0].recipe.fields.clarity, -2);
  assert.throws(() => knowledge([raw(), raw()]), /unique/);
  assert.throws(() => knowledge([raw({ training_permission: "approved" as never })]), /self-authorize/);
  for (const url of ["https://recipes.example:8443/wp-admin/", "https://recipes.example/wp-json/posts?x=1", "https://recipes.example/2026/01/01/example/?auth=x"]) {
    assert.throws(() => knowledge([raw({ source_url: url })]), /Unexpected recipe source/);
  }
  // One snapshot, one source host: a second host is refused.
  assert.throws(() => knowledge([raw(), raw({ id: "synthetic-recipe-b", source_url: "https://elsewhere.example/2026/01/02/other/" })]), /Unexpected recipe source/);
  const unavailable = knowledge([raw({ status: "unavailable", settings: {}, source_url: null, content_sha256: null, fetched_at: null })]);
  assert.equal(unavailable.library.entries[0].recipe.raw.source_url, null);
  assert.equal(selectRecipeCandidates(unavailable, { brief: brief(), camera: X100VI, now }).length, 0);
});

test("recipe name Reala Ace and native REALA ACE are separate search results", () => {
  const named = raw({ id: "named-reala", title: "Reala Ace" });
  const native = raw({ id: "base-reala", title: "Synthetic faithful", settings: { ...raw().settings, "Film Simulation": "REALA ACE" } });
  const results = searchRecipes(knowledge([named, native]).library, { query: "Reala Ace" });
  assert.deepEqual(results.map((r) => r.match), ["recipe_name", "base_simulation"]);
  assert.equal(results[0].recipe.base_film_sim, "Classic Chrome");
  assert.equal(results[1].recipe.base_film_sim, "Reala Ace");
});

test("shared article aliases discover records but never give every variant the same recipe identity", () => {
  const warm = raw({ title: "Synthetic Amber (X-Trans V)" });
  const cool = raw({ id: "synthetic-cool", title: "Synthetic Cool (X-Trans V)" });
  const k = knowledge([warm, cool]);
  const index: PublicRecipeIndex = { version: "test", observed_at: "2026-10-14", gaps: [], entries: [{
    id: "article", title: "Synthetic Amber", aliases: ["Synthetic Amber", "Synthetic Cool"], source_url: warm.source_url!, groups: [], index_urls: [],
  }] };
  k.library = buildRecipeLibrary({ version: "test", observed_at: "2026-10-14", records: [warm, cool], index_sha256: "", fetch_summary: {} }, index);
  k.judgments = [];
  const matches = searchRecipes(k.library, { query: "Synthetic Cool" });
  assert.equal(matches[0].recipe.id, cool.id);
  assert.equal(matches.find((m) => m.recipe.id === warm.id)?.match, "metadata");
  const candidates = selectRecipeCandidates(k, { brief: brief("Synthetic Cool"), camera: X100VI, now });
  // A variant suffix cannot turn a requested core recipe name into a match for the other recipe.
  assert.deepEqual(candidates.map((c) => c.recipe.id), [cool.id]);
});

test("a named recipe in a negative preference does not become a recommendation", () => {
  const k = knowledge();
  for (const intent of ["warm family but avoid Synthetic Amber", "I do not want Synthetic Amber", "Anything except Synthetic Amber", "No Synthetic Amber please",
    "Synthetic Amber is not my taste", "I liked Synthetic Amber, but do not use Synthetic Amber today"]) {
    assert.deepEqual(selectRecipeCandidates(k, { brief: brief(intent), camera: X100VI, now }), [], intent);
  }
  const k2 = knowledge([raw({ title: "Synthetic Cool" })]);
  assert.equal(selectRecipeCandidates(k2, { brief: brief("Avoid Synthetic Amber. Use Synthetic Cool"), camera: X100VI, now }).length, 1);
});

test("scene shortlist is bounded, permission-scoped and independently reviewed for the exact source revision", () => {
  const k = knowledge();
  assert.equal(selectRecipeCandidates(k, { brief: brief(), camera: X100VI, now }).length, 1);
  assert.equal(selectRecipeCandidates({ ...k, mode: "permission_reviewed" }, { brief: brief(), camera: X100VI, now }).length, 0);
  assert.equal(selectRecipeCandidates({ ...k, mode: "permission_reviewed", permissions: [grant()] }, { brief: brief(), camera: X100VI, now }).length, 1);
  assert.equal(selectRecipeCandidates({ ...k, judgments: [{ ...judgment(), content_sha256: "c".repeat(64) }] }, { brief: brief(), camera: X100VI, now }).length, 0);
  assert.equal(selectRecipeCandidates(k, { brief: brief("warm family, no warm cast"), camera: X100VI, now }).length, 0);
  assert.equal(selectRecipeCandidates(k, { brief: brief(), camera: { ...X100VI, id: "X100V" }, now }).length, 0);
  const many = knowledge(Array.from({ length: 8 }, (_, i) => raw({ id: `synthetic-${i}` })));
  assert.equal(selectRecipeCandidates(many, { brief: brief(), camera: X100VI, now, limit: 99 }).length, 3);
});

test("specific intent beats generic color tags and plural wording does not hide portrait references", () => {
  const k = knowledge([raw(), raw({ id: "generic", title: "Synthetic vivid" })]);
  k.judgments = [{ ...judgment(), intent_tags: ["natural color", "gentle color"], scene_tags: ["portraits", "food"] },
    { ...judgment(raw({ id: "generic" })), intent_tags: ["color"], scene_tags: ["daylight"] }];
  for (const intent of ["natural food color", "soft portrait in daylight"]) {
    const result = selectRecipeCandidates(k, { brief: { ...brief(intent), subjects: [intent] }, camera: X100VI, now });
    assert.equal(result[0].recipe.id, raw().id);
  }
  assert.equal(selectRecipeCandidates(k, { brief: brief("All monochrome"), camera: X100VI, now }).length, 0);
});

test("negated style words cannot promote a nostalgic reference through an otherwise matching scene", () => {
  const warm = raw(), neutral = raw({ id: "neutral", title: "Synthetic natural" });
  const k = knowledge([warm, neutral]);
  k.judgments = [{ ...judgment(warm), intent_tags: ["warm nostalgia", "nostalgic"], scene_tags: ["people", "daylight"], avoid_tags: [] },
    { ...judgment(neutral), intent_tags: ["natural color"], scene_tags: ["people", "daylight"], avoid_tags: [] }];
  const request = { ...brief("No nostalgia. Natural color for people in daylight."), subjects: ["people"], lighting: ["daylight"] };
  assert.deepEqual(selectRecipeCandidates(k, { brief: request, camera: X100VI, now }).map((c) => c.recipe.id), [neutral.id]);
  assert.deepEqual(selectRecipeCandidates(k, { brief: { ...request, intent: "Natural color, no vintage orange." }, camera: X100VI, now }).map((c) => c.recipe.id), [neutral.id]);
});

test("reordered neutral-skin requests exclude a conflicting desk direction, while a negated request does not", () => {
  const k = knowledge();
  k.judgments = [{ ...judgment(), avoid_tags: ["neutral skin"] }];
  assert.deepEqual(selectRecipeCandidates(k, { brief: brief("Keep skin tones neutral for these family portraits."), camera: X100VI, now }), []);
  assert.equal(selectRecipeCandidates(k, { brief: brief("Warm family memory. I do not want neutral skin."), camera: X100VI, now }).length, 1);
});

test("a current named adaptation overrides old taste and carries the actual conflict as a caution", () => {
  const k = knowledge();
  k.judgments = [{ ...judgment(), avoid_tags: ["neutral skin"] }];
  const request = { ...brief("Use Synthetic Amber as a starting point, but keep skin tones neutral."), rendering_goal: "No Synthetic Amber." };
  const result = selectRecipeCandidates(k, { brief: request, camera: X100VI, now });
  assert.equal(result.length, 1);
  assert.equal(result[0].retrieval_basis, "named_request");
  assert.ok(result[0].adaptation_cautions.some((caution) => caution.includes("neutral skin")));
  assert.match(recipeKnowledgeContext(result), /adapt and review/);
  assert.equal(selectRecipeCandidates(k, { brief: { ...brief("Do not use Synthetic Amber."), rendering_goal: "Use Synthetic Amber." }, camera: X100VI, now }).length, 0);
});

test("today's explicit warm goal overrides historical neutral taste while unrelated detail preferences survive", () => {
  const warm = raw(), neutral = raw({ id: "neutral", title: "Synthetic natural" });
  const k = knowledge([warm, neutral]);
  k.judgments = [{ ...judgment(warm), intent_tags: ["warm nostalgia", "nostalgic"], scene_tags: ["family", "daylight"], avoid_tags: ["neutral skin", "fine detail"] },
    { ...judgment(neutral), intent_tags: ["neutral color"], scene_tags: ["family", "daylight"], avoid_tags: [] }];
  const today = { ...brief("Today I want warm nostalgic family memories. Keep the warm color."), lighting: ["daylight"] };
  const choose = (intent: string, history: string) => selectRecipeCandidates(k, { brief: { ...today, intent, rendering_goal: history }, camera: X100VI, now });
  assert.equal(choose(today.intent, "")[0].recipe.id, warm.id);
  assert.equal(choose(today.intent, "Neutral skin and accurate product color.")[0].recipe.id, warm.id);
  assert.ok(!choose(today.intent, "Neutral skin and fine detail.").some((candidate) => candidate.recipe.id === warm.id));
  assert.ok(!choose("Family photographs in daylight.", "Neutral skin.").some((candidate) => candidate.recipe.id === warm.id));
  assert.ok(!choose("Family photographs in daylight.", "No nostalgia.").some((candidate) => candidate.recipe.id === warm.id));
});

test("ordinary child and portrait wording matches only supplied scene evidence and retains speed adaptations", () => {
  const k = knowledge();
  k.judgments = [{ ...judgment(), intent_tags: ["natural color"], scene_tags: ["people", "portraits", "daylight"], avoid_tags: [] }];
  const result = selectRecipeCandidates(k, { brief: { ...brief("Natural color for children running outside."), subjects: ["children"], lighting: ["daylight"] },
    camera: X100VI, now, shootingMode: "automatic" });
  assert.equal(result.length, 1);
  assert.deepEqual(result[0].matched_scene_tags, ["people", "daylight"]);
  assert.equal(result[0].recipe.fields.clarity, -2);
  assert.deepEqual(result[0].camera.automatic_adaptation.changes, [{ field: "clarity", from: -2, to: 0, changes_creator_recipe: true }]);
  assert.equal(result[0].judgment?.evidence, "desk_review");
});

test("fixed-WB food references disclose the mixed-light limit without changing source facts", () => {
  const source = raw({ settings: { ...raw().settings, "White Balance": "Daylight, 0 Red & 0 Blue" } });
  const k = knowledge([source]);
  k.judgments = [{ ...judgment(source), intent_tags: ["natural color"], scene_tags: ["food"], avoid_tags: [] }];
  const result = selectRecipeCandidates(k, { brief: { ...brief("Natural food color in mixed light."), subjects: ["food"], lighting: ["mixed light"] }, camera: X100VI, now });
  assert.equal(result.length, 1);
  assert.equal(result[0].recipe.fields.white_balance, "Daylight");
  assert.ok(result[0].adaptation_cautions.some((caution) => caution.includes("does not establish a white reference")));
});

test("a varied seven-slot outing keeps night inspiration instead of filling the shortlist with two monochrome roles", () => {
  const natural = raw({ id: "natural", title: "Synthetic natural" });
  const portrait = raw({ id: "portrait-mono", title: "Synthetic gentle mono", settings: { ...raw().settings, "Film Simulation": "Monochrome" } });
  const street = raw({ id: "street-mono", title: "Synthetic street mono", settings: { ...raw().settings, "Film Simulation": "Monochrome" } });
  const night = raw({ id: "night", title: "Synthetic night" });
  const interior = raw({ id: "interior", title: "Synthetic interior" });
  const k = knowledge([natural, portrait, street, night, interior]);
  k.judgments = [
    { ...judgment(natural), intent_tags: ["natural color"], scene_tags: ["food", "people", "daylight"], avoid_tags: [] },
    { ...judgment(portrait), intent_tags: ["black and white"], scene_tags: ["portraits"], avoid_tags: [] },
    { ...judgment(street), intent_tags: ["black and white"], scene_tags: ["street"], avoid_tags: [] },
    { ...judgment(night), intent_tags: ["moody color"], scene_tags: ["night", "neon"], avoid_tags: [] },
    { ...judgment(interior), intent_tags: ["experimental color"], scene_tags: ["interiors", "portraits"], avoid_tags: [] },
  ];
  const request = { ...brief("Natural color for a full day, moody neon at night, with one black and white alternative."), subjects: ["people", "food", "portraits", "street", "interiors"],
    lighting: ["daylight", "night", "neon"] };
  const result = selectRecipeCandidates(k, { brief: request, camera: X100VI, now });
  assert.equal(result.length, 3);
  assert.equal(result[0].recipe.id, natural.id);
  assert.ok(result.some((c) => c.recipe.id === night.id));
  assert.equal(result.filter((c) => c.recipe.base_film_sim === "Monochrome").length, 1);
  // The reference budget does not replace or certify the seven-slot plan.
  assert.ok(result.every((c) => c.camera.photographic_equivalence_verified === false));
});

test("adaptation retains the reference facts and never calls Clarity0 an exact creator copy", () => {
  const k = knowledge(), candidate = selectRecipeCandidates(k, { brief: brief(), camera: X100VI, now, shootingMode: "automatic" })[0];
  const final = recipe("Gentle family", { ...candidate.recipe.fields, clarity: 0 });
  const attribution = attributeRecipe(final, candidate);
  assert.equal(attribution.relationship, "adapted");
  assert.deepEqual(attribution.changed_fields, ["clarity"]);
  assert.equal(attribution.native_fidelity, "requires_camera_baseline");
  assert.equal(candidate.recipe.fields.clarity, -2);
  assert.match(recipeKnowledgeContext([candidate]), /Copying is not the goal/);
  assert.match(recipeKnowledgeContext([candidate]), /improvement a hypothesis/);
});

test("planner uses trusted catalog references then binds attribution after automatic changes", async () => {
  const k = knowledge();
  const data = answer({ looks: [{ ...look("Gentle family", "Family", { ...k.library.entries[0].recipe.fields }), recipe_reference_id: raw().id }],
    stops: [{ name: "Family", start: "", end: "", light: "window" }], replace: [] });
  const fake = new FakeAsk([data]);
  const plan = await makePlan({ said: "warm family memory", cam: X100VI, conditions: noPlaceConditions("2026-10-14"),
    count: 1, shootingMode: "automatic", recipeKnowledge: k, ask: fake.ask });
  assert.match(fake.calls[0].text, /REVIEWED RECIPE REFERENCES/);
  assert.deepEqual((fake.calls[0].schema as any).properties.looks.items.properties.recipe_reference_id.enum, [raw().id, null]);
  const references = plan.recipe_references as { relationship: string; changed_fields: string[] }[];
  assert.equal(references[0].relationship, "adapted");
  assert.ok(references[0].changed_fields.includes("clarity"));
  assert.equal((plan.recipe_knowledge as any).model_weights_trained, false);
  assert.equal(planFromClient(plan, X100VI).recipe_references, undefined);
});

test("an HTTP body cannot inject a catalog or a creator usage grant", () => {
  const parsed = parsePlanRequest({ said: "family", camera: { model: "X100VI" }, recipeKnowledge: knowledge(), permissions: [grant()] }, false);
  assert.equal("recipeKnowledge" in parsed, false);
  assert.equal("permissions" in parsed, false);
});

test("fact training export is labelled recall, excludes ambiguous sources and never starts a training job", () => {
  const k = knowledge([raw(), raw({ id: "ambiguous", status: "ambiguous" })]);
  const facts = recipeFactLessons(k, now);
  assert.equal(facts.included.length, 1);
  assert.equal(facts.excluded.length, 1);
  assert.equal(facts.receipt.model_weights_changed, false);
  assert.equal(facts.receipt.human_judgment_examples, 0);
  assert.equal(recipeFactLessons({ ...k, mode: "permission_reviewed" }, now).included.length, 0);
});

const preference = (overrides: Partial<ReviewedJudgmentExample> = {}): ReviewedJudgmentExample => ({ id: "test-review", family_id: "synthetic-family",
  source_record_id: raw().id, source_content_sha256: raw().content_sha256!, camera_model: "X100VI", brief: brief(),
  source_fact_signature: recipeFactSignature(normalizeRecipe(raw())),
  adapted_settings: recipe("Family", { ...knowledge().library.entries[0].recipe.fields, clarity: 0 }), changes: [{ field: "clarity", reason: "Faster moving-family capture" }],
  rationale: "Synthetic test preference", tradeoff: "Less microcontrast adjustment", review: { reviewer: "Synthetic tester", reviewer_kind: "human",
    status: "approved", reviewed_at: "2026-10-14T12:00:00Z", comparison_receipt: "synthetic-test-only", scene_data_authorized: true }, ...overrides });

test("judgment export refuses synthetic authority, stale sources and family leakage", () => {
  const k = knowledge();
  const valid = recipeJudgmentLessons(k, [preference()], now);
  assert.equal(valid.accepted.length, 1);
  assert.equal(valid.train.length + valid.evaluation.length, 1);
  assert.equal(recipeJudgmentLessons(k, [preference({ review: { ...preference().review, reviewer_kind: "model" as never } })], now).accepted.length, 0);
  assert.equal(recipeJudgmentLessons(k, [preference({ source_content_sha256: "c".repeat(64) })], now).accepted.length, 0);
  assert.equal(recipeJudgmentLessons(k, [preference({ changes: [] })], now).accepted.length, 0);
  const invented = preference();
  (invented.adapted_settings as any).unrecognized_control = "invented control";
  invented.changes.push({ field: "unrecognized_control", reason: "Not a camera field" });
  assert.equal(recipeJudgmentLessons(k, [invented], now).accepted.length, 0);
  const leakage = recipeJudgmentLessons(k, [preference(), preference({ id: "other", family_id: "different-family" })], now);
  assert.equal(leakage.accepted.length, 0);
  assert.ok(leakage.excluded.every((e) => /family/.test(e.reason)));
});

test("correcting extracted settings invalidates a previous scene review even when the article hash is unchanged", () => {
  const k = knowledge();
  const corrected = raw({ settings: { ...raw().settings, "Shadow": "+2" } });
  const changed = knowledge([corrected]); changed.judgments = k.judgments;
  assert.deepEqual(selectRecipeCandidates(changed, { brief: brief(), camera: X100VI, now }), []);
  assert.equal(recipeJudgmentLessons(changed, [preference()], now).accepted.length, 0);
  assert.notEqual(k.library.revision, changed.library.revision);
});

test("catalog adaptation still prepares seven distinct slots and rejects invented reference IDs", async () => {
  const k = knowledge();
  const names = ["Gentle faces", "Soft windows", "Quiet color", "Warm memory", "Fine texture", "Deep contrast", "Bright fabric"];
  const data = answer({ looks: names.map((name, i) => ({ ...look(name, "Family", { ...k.library.entries[0].recipe.fields, wb_shift_r: i - 3 }),
    recipe_reference_id: i === 0 ? raw().id : "not-a-supplied-reference" })),
    stops: [{ name: "Family", start: "", end: "", light: "window" }], replace: [] });
  const plan = await makePlan({ said: "Warm family memory", cam: X100VI, count: 7, protectedSlots: [], shootingMode: "automatic",
    conditions: noPlaceConditions("2026-10-14"), recipeKnowledge: k, ask: new FakeAsk([data]).ask });
  assert.equal(plan.palette_complete, true);
  assert.equal(plan.day_looks.length, 7);
  assert.equal((plan.recipe_references as unknown[]).length, 1);
  assert.ok(plan.day_looks.every((l) => l.clarity === 0));
});
