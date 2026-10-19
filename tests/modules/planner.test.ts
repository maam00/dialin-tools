import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createPlan, finalizeAgentPlan, ORIGINAL_PLAN_FIXTURE, prepareAgentPlan, type SceneInput } from "../../modules/planner/index.js";
import type { AskRequest } from "../../lib/plan/model.js";
import { loadRecipeBook } from "../../modules/recipes/index.js";

// The planner reads the optional private catalog from the environment; pin the synthetic fixture so results do not
// depend on whether this checkout has one. Tests that need "no catalog" set DIALIN_RECIPE_CATALOG=none locally.
process.env.DIALIN_RECIPE_CATALOG = fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url));
process.env.DIALIN_RECIPE_CATALOG_FIXTURE = "1";
const withoutCatalog = async <T>(work: () => Promise<T>): Promise<T> => {
  const previous = process.env.DIALIN_RECIPE_CATALOG;
  process.env.DIALIN_RECIPE_CATALOG = "none";
  try { return await work(); } finally { process.env.DIALIN_RECIPE_CATALOG = previous; }
};

const fixture = () => JSON.parse(readFileSync(ORIGINAL_PLAN_FIXTURE, "utf8")) as { input: SceneInput; answer: Record<string, unknown> & { looks: Record<string, unknown>[] } };
// The fixture's settings repeat original book directions verbatim, so honest declarations name that book entry.
const declaredSource = (look: Record<string, unknown>, reason: string) => {
  const entry = loadRecipeBook().recipes.find((item) => Object.entries(item.recipe).every(([key, value]) => key === "name" || key === "why" || look[key] === value));
  return entry ? { relationship: "exact", references: [{ kind: "book", id: entry.id }], reason } : { relationship: "original", references: [], reason };
};

test("original demo uses the real planner, returns seven explicit slots, and is deterministic without network", async (t) => {
  t.mock.method(globalThis, "fetch", () => { throw new Error("Network is forbidden in the rehearsal."); });
  const first = await createPlan({ mode: "demo" });
  const second = await createPlan({ mode: "demo" });
  assert.deepEqual(first, second);
  assert.equal(first.schema_version, "dialin.planner.v1");
  assert.equal(first.execution.source, "original_fixture");
  assert.equal(first.execution.provider_calls, 0);
  assert.equal(first.execution.hardware_validated, false);
  assert.equal(first.execution.photographic_quality_validated, false);
  assert.equal(first.validation.palette_complete, true);
  assert.deepEqual(first.plan.write.slots, [1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(first.validation.warnings, []);
  assert.equal(new Set(first.plan.day_looks.map((look) => look.reason)).size, 7);
  assert.equal(first.plan.model, "original-fixture");
  assert.doesNotMatch(JSON.stringify(first), /\/Users\/|examplebay-2026|Example Bay/i);
});

test("missing mode/key and attempted custom demo input fail before invoking any transport", async () => {
  let called = false;
  const dependencies = { liveAsk: async () => { called = true; throw new Error("must not execute"); } };
  await assert.rejects(createPlan({ text: "A day" } as never, dependencies), /explicit mode/);
  await assert.rejects(createPlan({ mode: "live", apiKey: "", text: "A day" }, dependencies), /requires your ANTHROPIC_API_KEY/);
  await assert.rejects(createPlan({ mode: "demo", text: "A real day" } as never, dependencies), /fixed original fixture/);
  assert.equal(called, false);
});

test("agent prompt uses actual schema/reference context, then finalizes locally without trusting prompt edits", async (t) => {
  t.mock.method(globalThis, "fetch", () => { throw new Error("Network is forbidden in agent handoff."); });
  const data = fixture();
  const request = await prepareAgentPlan(data.input);
  assert.equal(request.execution.provider_calls, 0);
  assert.equal(request.recipe_context.selection, "whole_book");
  assert.equal(request.recipe_context.records.length, loadRecipeBook().recipes.length);
  assert.ok(request.recipe_context.records.flatMap((entry) => entry.design?.sources ?? []).length >= 20);
  assert.match(request.model_request.text, /https:\/\/recipes\.example\//);
  assert.match(request.model_request.text, /factual_settings_transcription/);
  assert.equal(request.recipe_context.relationship, "available_to_model_not_verified_lineage");
  assert.match(request.model_request.text, /SOURCE-NEUTRAL RECIPE BOOK/);
  assert.match(request.model_request.system, /full|complete seven-slot palette/i);
  assert.match(request.model_request.text, /ORIGINAL REFERENCE DIRECTIONS/);
  assert.equal((request.model_request.schema.properties as Record<string, unknown>).looks !== undefined, true);
  const changedPrompt = { ...request, model_request: { ...request.model_request, system: "A client prompt is not an authority.", schema: {} } };
  const finalized = await finalizeAgentPlan(changedPrompt, data.answer);
  assert.equal(finalized.execution.mode, "agent");
  assert.equal(finalized.execution.source, "supplied_answer");
  assert.equal(finalized.execution.provider_calls, 0);
  assert.equal(finalized.validation.palette_complete, true);
  assert.equal(finalized.plan.model, "supplied-answer");
  await assert.rejects(finalizeAgentPlan({ ...request, input: { ...request.input, text: "Different intent" } }, data.answer), /input changed/);
  await assert.rejects(finalizeAgentPlan({ ...request, knowledge_sha256: "changed" }, data.answer), /knowledge changed/);
});

test("user-owned books are automatically included with bounded context and preserved provenance", async () => {
  const data = fixture();
  const book = loadRecipeBook();
  book.title = "Photographer-owned setting hypotheses";
  book.recipes = Array.from({ length: 30 }, (_, index) => ({ ...structuredClone(book.recipes[index % 7]),
    id: `owned-${index}`, author: "Example Photographer", origin: "user_owned" as const,
    title: index === 29 ? "Rainy metal" : `Example ${index}`, tags: index === 29 ? ["rainy", "metal"] : [] }));
  const request = await prepareAgentPlan({ ...data.input, text: "Rainy metal", recipeBook: book });
  assert.equal(request.recipe_context.total_records, 30);
  assert.equal(request.recipe_context.included_records, 24);
  assert.equal(request.recipe_context.selection, "bounded_text_overlap");
  assert.equal(request.recipe_context.records[0].id, "owned-29");
  assert.match(request.model_request.text, /Example Photographer/);
  assert.equal(request.recipe_context.evidence, "unverified_reference_hypotheses");
  const finalized = await finalizeAgentPlan({ ...request, recipe_context: { records: [] } }, data.answer);
  assert.deepEqual(finalized.recipe_context, request.recipe_context);
  const changed = structuredClone(request);
  changed.input.recipeBook!.recipes[0].recipe.color = 4;
  await assert.rejects(finalizeAgentPlan(changed, data.answer), /input changed/);
});

test("photo-only and combined input are handed off as image context, malformed or oversized images fail", async () => {
  // Synthetic SOF header only: tests existing image validation/control flow, never photographic interpretation.
  const header = Buffer.from([0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 0, 1, 0, 1, 3, 1, 17, 0, 2, 17, 0, 3, 17, 0, 0xff, 0xd9]);
  for (const text of ["", "Natural color for this scene"]) {
    const request = await prepareAgentPlan({ text, imageBase64: header.toString("base64"), date: "2026-01-01" });
    assert.equal(request.model_request.image_input, "input.imageBase64");
    assert.equal(request.input.imageBase64, header.toString("base64"));
    assert.equal(request.input.text, text);
  }
  await assert.rejects(prepareAgentPlan({ text: "A scene", imageBase64: "not-an-image" }), /base64|JPEG/);
  const oversized = Buffer.from(header); oversized[9] = 0x10;
  await assert.rejects(prepareAgentPlan({ imageBase64: oversized.toString("base64") }), /Resize/);
  await assert.rejects(prepareAgentPlan({ text: "" }), /send a photo/);
});

test("finalization applies existing unknown-protected-slot rules and labels incomplete output", async () => {
  const data = fixture();
  const request = await prepareAgentPlan({ ...data.input, cameraSlots: [{ slot: 5, name: "Favourite" }], protectedSlots: [5] });
  const finalized = await finalizeAgentPlan(request, data.answer);
  assert.equal(finalized.validation.status, "needs_revision");
  assert.equal(finalized.validation.palette_complete, false);
  assert.ok(!finalized.plan.write.slots.includes(5));
  assert.ok(finalized.plan.missing_slots?.includes(5));
  assert.match(finalized.validation.warnings.join(" "), /protected.*wasn't read/);
});

test("agent finalization surfaces missing brief or per-look reasoning as a revision", async () => {
  const data = fixture();
  const request = await prepareAgentPlan(data.input);
  const withoutDesign = await finalizeAgentPlan(request, data.answer);
  assert.equal(withoutDesign.validation.palette_complete, true);
  assert.equal(withoutDesign.validation.status, "needs_revision");
  assert.match(withoutDesign.validation.warnings.join(" "), /Photographic reasoning is incomplete/);

  // Synthetic rationale exercises completeness, not the quality of photographic judgment.
  const answer = structuredClone(data.answer);
  for (const look of answer.looks) look.design = {
    purpose: "Synthetic test role", scene_fit: "Synthetic test scene",
    choices: ["film_sim", "white_balance", "dynamic_range", "tone_curve", "color", "texture", "exposure"]
      .map((setting) => ({ setting, reason: "Synthetic test rationale", knowledge_ids: ["taste-intent"] })),
    tradeoff: "Synthetic test tradeoff", alternative: "Synthetic test alternative", uncertainty: "Not a photographed recipe",
  };
  for (const look of answer.looks) look.source_use = declaredSource(look, "Synthetic test declaration; not a photographic quality assessment.");
  const complete = await finalizeAgentPlan(request, answer);
  assert.equal(complete.validation.status, "proposal");
  assert.deepEqual(complete.validation.warnings, []);
  delete answer.photographic_brief;
  const withoutBrief = await finalizeAgentPlan(request, answer);
  assert.equal(withoutBrief.validation.status, "needs_revision");
  assert.match(withoutBrief.validation.warnings.join(" "), /photographic_brief/);
});

test("CLI creates private output folders and returns revision status for incomplete reasoning", () => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-planner-first-run-"));
  const script = "import {runPlanner} from './modules/planner/cli.ts'; process.exitCode=await runPlanner(process.argv.slice(1));";
  const run = (args: string[]) => spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", script, "--", ...args], {
    cwd: new URL("../../", import.meta.url), encoding: "utf8", env: { ...process.env, ANTHROPIC_API_KEY: "" },
  });
  try {
    const requestPath = join(dir, "new-shoot", "request.json");
    const prepared = run(["--mode", "agent", "--text", "Rainy portraits and a cafe", "--out", requestPath]);
    assert.equal(prepared.status, 0, prepared.stderr);
    assert.equal(JSON.parse(readFileSync(requestPath, "utf8")).schema_version, "dialin.planner.request.v1");
    const answerPath = join(dir, "answer.json");
    writeFileSync(answerPath, JSON.stringify(fixture().answer));
    const planPath = join(dir, "review", "plan.json");
    const finalized = run(["finalize", "--request", requestPath, "--answer", answerPath, "--out", planPath]);
    assert.equal(finalized.status, 2, finalized.stderr);
    assert.equal(JSON.parse(readFileSync(planPath, "utf8")).validation.status, "needs_revision");
    const original = readFileSync(planPath, "utf8");
    assert.equal(run(["--mode", "demo", "--out", planPath]).status, 1);
    assert.equal(readFileSync(planPath, "utf8"), original);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("explicit live API seam disables hidden fallbacks and labels injected evidence honestly", async () => {
  const data = fixture();
  const calls: AskRequest[] = [];
  const result = await createPlan({ mode: "live", apiKey: "unit-test-key", ...data.input, model: "claude-test-model" }, {
    liveAsk: async (request) => {
      calls.push(request);
      return { ok: true, data: data.answer, model: "fake", via: "fake", ms: 0, error: null, code: null, usage: null, usd: null, tries: [] };
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].model, "claude-test-model");
  assert.equal(calls[0].fallback, null);
  assert.equal(calls[0].serverFallback, false);
  assert.match(calls[0].text, /SOURCE-NEUTRAL RECIPE BOOK/);
  assert.equal(result.execution.source, "injected_test_provider");
  assert.equal(result.execution.provider_calls, null);
  assert.doesNotMatch(JSON.stringify(result), /unit-test-key/);
});

test("CLI missing-key guard ignores authenticated CLI mode and output files are never overwritten", () => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-planner-module-"));
  const script = "import {runPlanner} from './modules/planner/cli.ts'; process.exitCode=await runPlanner(process.argv.slice(1));";
  try {
    const rejected = spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", script, "--", "--mode", "live", "--text", "A day"], {
      cwd: new URL("../../", import.meta.url), encoding: "utf8",
      env: { ...process.env, ANTHROPIC_API_KEY: "", DIALIN_MODEL_TRANSPORT: "cli", DIALIN_CLAUDE: "/must-not-run" },
    });
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /requires ANTHROPIC_API_KEY/);
    const out = join(dir, "plan.json");
    writeFileSync(out, "keep-me");
    const protectedFile = spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", script, "--", "--mode", "demo", "--out", out], {
      cwd: new URL("../../", import.meta.url), encoding: "utf8",
    });
    assert.equal(protectedFile.status, 1);
    assert.match(protectedFile.stderr, /Output already exists/);
    assert.equal(readFileSync(out, "utf8"), "keep-me");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("unresolved exact copying requires revision unless the photographer explicitly allows a proposed interpretation", async () => {
  const data = fixture();
  const answer = structuredClone(data.answer);
  for (const look of answer.looks) {
    look.source_use = declaredSource(look, "Synthetic proposal, not the requested source copy.");
    look.design = { purpose: "Synthetic role", scene_fit: "Synthetic scene",
      choices: ["film_sim", "white_balance", "dynamic_range", "tone_curve", "color", "texture", "exposure"]
        .map((setting) => ({ setting, reason: "Synthetic rationale", knowledge_ids: ["taste-intent"] })),
      tradeoff: "Synthetic tradeoff", alternative: "Synthetic alternative", uncertainty: "No photographic validation" };
  }
  const exact = "Use the source recipe Kodak Quayside 320 with exact settings.";
  const strict = await finalizeAgentPlan(await prepareAgentPlan({ ...data.input, text: exact }), answer);
  assert.equal(strict.source_trace?.requested_fidelity.status, "unresolved");
  assert.equal(strict.validation.status, "needs_revision");
  const permitted = await finalizeAgentPlan(await prepareAgentPlan({ ...data.input, text: exact + " Prepare one safe proposed interpretation and clearly state if the exact request cannot be satisfied." }), answer);
  assert.equal(permitted.source_trace?.requested_fidelity.status, "unresolved");
  assert.equal(permitted.source_trace?.requested_fidelity.adaptation_permitted, true);
  assert.equal(permitted.validation.status, "proposal");
  assert.match(permitted.validation.warnings.join(" "), /does not satisfy exact source fidelity/);
});

// The documented hand-authored example answer (examples/planner/agent-answer.example.json) and its brief.
const EXAMPLE_BRIEF = "Beach wedding: ceremony in harsh afternoon sun, family formals in open shade, golden hour couple portraits, reception under string lights. No Classic Chrome and nothing with Nostalgic Neg, the couple hates that look. Natural skin.";
const exampleAnswer = () => JSON.parse(readFileSync(new URL("../../examples/planner/agent-answer.example.json", import.meta.url), "utf8")) as { looks: Record<string, unknown>[] } & Record<string, unknown>;
const exampleRequest = () => prepareAgentPlan({ text: EXAMPLE_BRIEF, count: 4, date: "2026-10-17" });

test("the documented example answer finalizes as a proposal with honest source comparisons", async () => {
  assert.ok(readFileSync(new URL("../../examples/planner/README.md", import.meta.url), "utf8").includes(EXAMPLE_BRIEF), "README documents the same brief");
  const result = await finalizeAgentPlan(await exampleRequest(), exampleAnswer());
  assert.equal(result.validation.status, "proposal", result.validation.warnings.join(" | "));
  assert.deepEqual(result.validation.warnings, []);
  assert.deepEqual((result.plan.photographic_policy as { avoidSimulations?: string[] }).avoidSimulations, ["Classic Chrome", "Nostalgic Neg"]);
  const rows = Object.fromEntries(result.source_trace!.rows.map((row) => [row.name, row]));
  assert.equal(rows["Shade family"].comparisons[0].comparison, "matches_represented_settings");
  assert.deepEqual(rows["Ceremony sun"].comparisons[0].changed_fields.map((item) => item.field), ["dynamic_range", "highlight", "shadow"]);
  assert.equal(rows["Golden couple"].comparisons[0].kind, "outside");
  assert.equal(rows["Golden couple"].comparisons[0].verification, "unverified_stated_inspiration");
  assert.equal(rows["Golden couple"].comparisons[0].source_revision, null);
  // The example names no catalog record, so it is the same proposal with or without a private catalog.
  const bare = await withoutCatalog(async () => finalizeAgentPlan(await exampleRequest(), exampleAnswer()));
  assert.equal(bare.validation.status, "proposal", bare.validation.warnings.join(" | "));
  assert.equal(bare.recipe_context.knowledge.retrieval.selection_status, "no_catalog_installed");
});

test("a banned simulation fails finalization; a USB-verified neighbour is kept as chosen, not swapped for a stand-in", async () => {
  const request = await exampleRequest();
  const banned = exampleAnswer();
  Object.assign(banned.looks[2], { film_sim: "Classic Chrome", ideal_film_sim: "Classic Chrome" });
  const result = await finalizeAgentPlan(request, banned);
  assert.equal(result.validation.status, "needs_revision");
  assert.match(result.validation.warnings.join(" "), /asked to avoid Classic Chrome/);
  assert.ok(!result.plan.day_looks.some((look) => look.film_sim === "Classic Chrome"));
  // Classic Neg has been written and read back over USB, so the desktop planner writes it as chosen. (The engine's
  // automatic stand-in for unmapped simulations is covered in tests/plan with the Bluetooth settings-file contract.)
  const neighbour = exampleAnswer();
  Object.assign(neighbour.looks[2], { film_sim: "Classic Neg", ideal_film_sim: "Classic Neg" });
  const kept = await finalizeAgentPlan(request, neighbour);
  assert.equal(kept.plan.day_looks.find((look) => look.name === "Golden couple")?.film_sim, "Classic Neg");
  assert.doesNotMatch(kept.validation.warnings.join(" "), /asked to avoid Classic Chrome|isn't mapped/);
});

test("looks that differ only in texture sliders are not distinct palette roles", async () => {
  const answer = exampleAnswer();
  const copy = structuredClone(answer.looks[0]);
  Object.assign(answer.looks[1], { ...copy, name: answer.looks[1].name, stop: answer.looks[1].stop, sharpness: 1, grain: "Weak Small",
    source_use: { relationship: "adapted", references: [{ kind: "book", id: "ref-saturated-detail" }], reason: "Same base, different texture." } });
  const result = await finalizeAgentPlan(await exampleRequest(), answer);
  assert.equal(result.validation.status, "needs_revision");
  assert.match(result.validation.warnings.join(" "), /differ only in grain, sharpness, noise reduction or Clarity/);
});

test("automatic mode offers only kept values in the schema and names any normalized look, field and value", async () => {
  const request = await exampleRequest();
  const looks = (request.model_request.schema.properties as Record<string, { items: { properties: Record<string, { enum?: unknown[]; properties?: Record<string, { enum?: unknown[] }> }> } }>).looks.items.properties;
  assert.deepEqual(looks.clarity.enum, [0]);
  assert.deepEqual(looks.exposure.properties!.aperture.enum, ["A"]);
  // USB-verified values only: every film simulation, but not the white balances whose encodings are only cited.
  assert.equal(looks.film_sim.enum!.length, 20);
  assert.ok(looks.film_sim.enum!.includes("Classic Neg") && !looks.white_balance.enum!.includes("Auto Ambience") && !looks.white_balance.enum!.includes("Shade"));
  const full = await prepareAgentPlan({ text: EXAMPLE_BRIEF, date: "2026-10-17" });
  const fullLooks = ((full.model_request.schema.properties as typeof request.model_request.schema).looks as { items: { properties: Record<string, { enum: unknown[] }> } }).items.properties;
  assert.deepEqual(fullLooks.white_balance.enum, ["Auto", "Daylight", "Kelvin"], "full palettes without known camera recipes offer written values only");
  assert.deepEqual(fullLooks.noise_reduction.enum, [-4]);
  const answer = exampleAnswer();
  answer.looks[1].clarity = 2;
  const result = await finalizeAgentPlan(request, answer);
  assert.equal(result.validation.status, "needs_revision");
  const text = result.validation.warnings.join(" ");
  assert.match(text, /"Shade family": automatic shooting mode changed Clarity \+2 to 0/);
  assert.match(text, /Photographic reasoning is incomplete: C2 "Shade family"/);
  assert.doesNotMatch(text, /Supply photographic_brief/);
});

test("agent requests list instructions first and the CLI writes a short Markdown guide beside them", () => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-planner-guide-"));
  const script = "import {runPlanner} from './modules/planner/cli.ts'; process.exitCode=await runPlanner(process.argv.slice(1));";
  const run = (args: string[]) => spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", script, "--", ...args], {
    cwd: new URL("../../", import.meta.url), encoding: "utf8", env: { ...process.env, ANTHROPIC_API_KEY: "" },
  });
  try {
    const requestPath = join(dir, "shoot", "request.json");
    assert.equal(run(["--mode", "agent", "--text", EXAMPLE_BRIEF, "--count", "4", "--out", requestPath]).status, 0);
    const request = JSON.parse(readFileSync(requestPath, "utf8"));
    assert.deepEqual(Object.keys(request).slice(0, 2), ["schema_version", "instructions"]);
    const guide = readFileSync(join(dir, "shoot", "request.md"), "utf8");
    assert.ok(Buffer.byteLength(guide) < 8000);
    assert.match(guide, /Excluded simulations: Classic Chrome, Nostalgic Neg/);
    assert.ok(guide.includes(`--answer ${JSON.stringify(join(dir, "shoot", "answer.json"))}`));
    assert.match(guide, /Skip `recipe_context`/);
    const again = run(["--mode", "agent", "--text", EXAMPLE_BRIEF, "--out", join(dir, "shoot", "request.md").replace(/\.md$/, ".json")]);
    assert.equal(again.status, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("without a private catalog, an agent request still carries the original guidance and the user's own book", async () => {
  const book = loadRecipeBook();
  book.title = "Photographer-owned looks";
  book.recipes = book.recipes.slice(0, 3).map((entry, index) => ({ ...structuredClone(entry), id: `owned-${index}`, author: "Example Photographer", origin: "user_owned" as const }));
  const request = await withoutCatalog(() => prepareAgentPlan({ text: "Family portraits in open shade, then a market.", count: 3, recipeBook: book }));
  const retrieval = request.recipe_context.knowledge.retrieval;
  assert.equal(retrieval.available_references, 0);
  assert.equal(retrieval.selection_status, "no_catalog_installed");
  assert.ok(retrieval.selected_original_directions > 0);
  assert.equal(request.recipe_context.book_title, "Photographer-owned looks");
  assert.match(request.model_request.system, /REVIEWED FUJIFILM KNOWLEDGE/);
  assert.match(request.model_request.text, /ORIGINAL REFERENCE DIRECTIONS/);
  assert.match(request.model_request.text, /ORIGINAL RECIPE GUIDANCE/);
  assert.match(request.model_request.text, /owned-0/);
  assert.doesNotMatch(request.model_request.text, /recipes\.example/);
  assert.match(request.instructions.join(" "), /when one is installed, the private recipe catalog/);
});
