// Community-practice priors: generator, privacy check and planner integration. Catalogs here are synthetic; the real
// private catalog is checked only in the private-only test file.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { emptyRecipeKnowledge, loadRecipeKnowledge, type RecipeKnowledge, type RecipeReference } from "../../modules/recipes/knowledge.js";
import { assessLookPractice, buildRecipeSpacePriors, checkRecipeSpacePrivacy, loadRecipeSpacePriors, RECIPE_SPACE_PATH, serializeRecipeSpacePriors,
  type RecipeSpacePriors } from "../../modules/recipes/space.js";
import { finalizeAgentPlan, prepareAgentPlan } from "../../modules/planner/index.js";

const FIXTURE = fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url));
const fixture = loadRecipeKnowledge(FIXTURE, { fixture: true });
process.env.DIALIN_RECIPE_CATALOG = FIXTURE;
process.env.DIALIN_RECIPE_CATALOG_FIXTURE = "1";
const template = fixture.references.find((reference) => reference.title === "Harbor Glow 400")!;

/** A synthetic catalog of n records per simulation with deterministic, varied invented settings. */
function synthetic(spec: Record<string, number>, vary = true): RecipeKnowledge {
  const catalog = emptyRecipeKnowledge();
  let index = 0;
  for (const [sim, count] of Object.entries(spec)) for (let i = 0; i < count; i++, index++) {
    const reference = structuredClone(template) as RecipeReference;
    reference.id = `synthetic-${index}`; reference.title = `Synthetic look ${index}`; reference.source_url = `https://recipes.example/synthetic/${index}/`;
    const step = vary ? i : 0;
    reference.source_facts.fields = { ...reference.source_facts.fields, film_sim: sim as never, highlight: [-2, -1, -1, 0, 1, -1.5][step % 6], shadow: [-1, 0, 1, 2, 0, -0.5][step % 6],
      color: [0, 1, 2, -1, 3, 1][step % 6], wb_shift_r: [0, 2, 3, -1, 1, 4][step % 6], wb_shift_b: [0, -2, -4, 1, -1, -3][step % 6], clarity: [0, -2, -3, 1, 0, -1][step % 6],
      grain: (["Off", "Weak Small", "Strong Small", "Weak Large"] as const)[step % 4], dynamic_range: (["DR200", "DR400", "DR100"] as const)[step % 3] };
    if (/^(?:Acros|Monochrome)/.test(sim)) { delete reference.source_facts.fields.color; delete reference.source_facts.fields.color_chrome; delete reference.source_facts.fields.color_chrome_fx_blue; }
    catalog.references.push(reference);
  }
  return catalog;
}
const counts = (priors: RecipeSpacePriors) => priors.groups.flatMap((group) => [...Object.values(group.fields), ...Object.values(group.joint)]
  .flatMap((bins) => (bins as unknown[][]).map((bin) => bin[bin.length - 1] as number)));

test("the generator publishes only aggregate counts of at least k, with no names, links or identifiers", () => {
  const catalog = synthetic({ "Classic Chrome": 30, Velvia: 12, Provia: 3, Astia: 4, "Acros+R": 3, "Acros+G": 3, "Monochrome+G": 2 });
  const priors = buildRecipeSpacePriors(catalog);
  assert.ok(counts(priors).length > 20);
  assert.ok(counts(priors).every((count) => count >= 5));
  assert.deepEqual(priors.groups.map((group) => group.group), ["Velvia", "Classic Chrome", "Other color simulations", "Acros (any filter)"]);
  // Small simulations merge into groups that list every member by definition; a family below k is dropped.
  assert.ok(priors.groups.find((group) => group.group === "Other color simulations")!.sims.includes("Pro Neg Std"));
  const text = serializeRecipeSpacePriors(priors);
  for (const leak of ["Synthetic look", "synthetic-", "recipes.example", "https://", "Harbor"]) assert.ok(!text.includes(leak), leak);
  assert.ok(Buffer.byteLength(text) < 50_000);
  assert.equal(checkRecipeSpacePrivacy(priors, catalog).passed, true);
});

test("the generator is deterministic and independent of record order", () => {
  const catalog = synthetic({ "Classic Chrome": 25, Eterna: 9 });
  const reversed = structuredClone(catalog); reversed.references.reverse();
  assert.equal(serializeRecipeSpacePriors(buildRecipeSpacePriors(catalog)), serializeRecipeSpacePriors(buildRecipeSpacePriors(reversed)));
  // The invented fixture has no simulation with five records of its own; only the merged color group survives.
  assert.deepEqual(buildRecipeSpacePriors(fixture).groups.map((group) => group.group), ["Other color simulations"]);
});

test("identical recipes are coarsened until none can be reconstructed; naive figures are caught", () => {
  // Eight copies of one recipe: exact per-setting counts would reveal its whole setting tuple.
  const catalog = synthetic({ Velvia: 8 }, false);
  const priors = buildRecipeSpacePriors(catalog);
  const check = checkRecipeSpacePrivacy(priors, catalog);
  assert.equal(check.passed, true);
  assert.ok(check.worst_unresolved! >= 3);
  const naive: RecipeSpacePriors = { ...priors, groups: [{ group: "Velvia", sims: ["Velvia"], joint: {}, fields: {
    highlight: [[-2, -2, 8]], shadow: [[-1, -1, 8]], color: [[0, 0, 8]], wb_shift_r: [[0, 0, 8]], wb_shift_b: [[0, 0, 8]], clarity: [[0, 0, 8]],
    grain: [[["Off"], 8]], dynamic_range: [[["DR200"], 8]], noise_reduction: [[-4, -4, 8]], sharpness: [[template.source_facts.fields.sharpness!, template.source_facts.fields.sharpness!, 8]],
    white_balance: [[[template.source_facts.fields.white_balance!], 8]], color_chrome: [[[template.source_facts.fields.color_chrome!], 8]] } }] };
  const caught = checkRecipeSpacePrivacy(naive, catalog);
  assert.equal(caught.passed, false);
  assert.ok(caught.findings.some((finding) => finding.rule === "reconstructable-record"));
  // The finding names the group and rule, never a setting value.
  assert.doesNotMatch(JSON.stringify(caught.findings), /DR200|Velvia recipe|-2/);
  const small = structuredClone(priors); (small.groups[0].fields as Record<string, unknown>).grain = [[["Off"], 3]];
  assert.ok(checkRecipeSpacePrivacy(small, catalog).findings.some((finding) => finding.rule === "small-cell"));
});

test("a joint class table cannot be used to pin a value hidden inside a merged range", () => {
  const catalog = synthetic({ "Classic Chrome": 12 });
  const priors = buildRecipeSpacePriors(catalog);
  const group = priors.groups[0];
  // Every published range and class cell together still leaves each record with at least three underivable settings.
  assert.ok(group.joint.tone || group.joint.wb_shift || Object.keys(group.fields).length);
  assert.ok(checkRecipeSpacePrivacy(priors, catalog).worst_unresolved! >= 3);
});

/** A synthetic catalog whose records carry exactly these source fields. */
function catalogOf(rows: Record<string, unknown>[]): RecipeKnowledge {
  const catalog = emptyRecipeKnowledge();
  rows.forEach((fields, index) => {
    const reference = structuredClone(template) as RecipeReference;
    reference.id = `exact-${index}`; reference.title = `Exact look ${index}`; reference.source_url = `https://recipes.example/exact/${index}/`;
    reference.source_facts.fields = fields as never;
    catalog.references.push(reference);
  });
  return catalog;
}

test("a joint class that pins a setting counts even after that setting's own figures are dropped", () => {
  // Highlight 0 is the only Highlight in this catalog, so a published "mid/mid" tone cell gives it away by itself.
  const catalog = catalogOf([0, 1, 2, 3, 4].map((i) => ({ film_sim: "Classic Chrome", highlight: 0, shadow: 0,
    grain: ["Off", "Weak Small"][i % 2], color_chrome: ["Off", "Weak"][i % 2] })));
  const fields = { grain: [[["Off", "Weak Small"], 5]], color_chrome: [[["Off", "Weak"], 5]], shadow: [[0, 0, 5]] } as RecipeSpacePriors["groups"][number]["fields"];
  const priors = (group: Partial<RecipeSpacePriors["groups"][number]>): RecipeSpacePriors => ({ ...buildRecipeSpacePriors(catalog),
    groups: [{ group: "Classic Chrome", sims: ["Classic Chrome"], fields, joint: {}, ...group }] });
  const explicit = priors({ fields: { ...fields, highlight: [[0, 0, 5]] } });
  const throughJoint = priors({ joint: { tone: [[["mid/mid"], 5]] } });
  assert.equal(checkRecipeSpacePrivacy(explicit, catalog).passed, false);
  assert.equal(checkRecipeSpacePrivacy(throughJoint, catalog).passed, false, "the same figures, with Highlight given away by its class");
  // The generator's own output must survive the same reading.
  const built = buildRecipeSpacePriors(catalog);
  for (const group of built.groups) if (group.joint.tone?.length === 1) {
    group.fields.highlight ??= [[0, 0, group.joint.tone[0][1]]]; group.fields.shadow ??= [[0, 0, group.joint.tone[0][1]]];
  }
  assert.equal(checkRecipeSpacePrivacy(built, catalog).passed, true);
});

test("a family group whose catalog holds one simulation reveals that simulation", () => {
  // Only plain Acros occurs, so "Acros (any filter)" names it as surely as a single-simulation group would.
  const catalog = catalogOf([0, 1, 2, 3, 4, 5].map((i) => ({ film_sim: "Acros", highlight: 0, shadow: 0, dynamic_range: "DR200",
    grain: ["Off", "Weak Small"][i % 2], white_balance: ["Auto", "Daylight"][i % 2] })));
  const built = buildRecipeSpacePriors(catalog);
  assert.deepEqual(built.groups.map((group) => group.group), ["Acros (any filter)"]);
  const single = { ...built, groups: built.groups.map((group) => ({ ...group, sims: ["Acros"] })) };
  assert.equal(checkRecipeSpacePrivacy(single, catalog).passed, true, "the published figures must be safe once the simulation is known");
  assert.equal(checkRecipeSpacePrivacy(single, catalog).worst_unresolved, checkRecipeSpacePrivacy(built, catalog).worst_unresolved);
});

test("looks are placed in common, less common or unusual regions; uncovered simulations say so", () => {
  const catalog = synthetic({ "Classic Chrome": 30 });
  const priors = buildRecipeSpacePriors(catalog);
  const base = { slot: 3, name: "Test look", film_sim: "Classic Chrome", grain: "Off", color_chrome: template.source_facts.fields.color_chrome!, color_chrome_fx_blue: template.source_facts.fields.color_chrome_fx_blue!,
    white_balance: template.source_facts.fields.white_balance!, kelvin: 0, wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR200", highlight: -2, shadow: -1, color: 0,
    sharpness: template.source_facts.fields.sharpness!, noise_reduction: template.source_facts.fields.noise_reduction!, clarity: 0 };
  const common = assessLookPractice(base, priors);
  assert.equal(common.region, "common", common.note);
  assert.match(common.note, /^C3 "Test look" sits in a common region of community practice for Classic Chrome\. Informational\.$/);
  const odd = assessLookPractice({ ...base, highlight: 4, color: -4, clarity: 5 }, priors);
  assert.equal(odd.region, "unusual");
  assert.ok(odd.unusual_settings.some((item) => item.setting === "clarity" && item.share === 0));
  assert.match(odd.note, /departing from common practice can be the right choice/);
  const uncovered = assessLookPractice({ ...base, film_sim: "Sepia" }, priors);
  assert.equal(uncovered.region, "not_covered");
});

test("the published priors file is small, valid and holds only counts of at least k", () => {
  const priors = loadRecipeSpacePriors(RECIPE_SPACE_PATH);
  assert.ok(priors, "data/recipe-space/priors.json is present");
  assert.ok(statSync(RECIPE_SPACE_PATH).size < 50_000);
  assert.ok(counts(priors!).every((count) => count >= priors!.k) && priors!.k >= 5);
  const text = readFileSync(RECIPE_SPACE_PATH, "utf8");
  assert.doesNotMatch(text, /https?:|www\.|"id"|"title"|"source_url"/);
  const sims = new Set(["Provia", "Velvia", "Astia", "Classic Chrome", "Reala Ace", "Pro Neg Hi", "Pro Neg Std", "Classic Neg", "Nostalgic Neg", "Eterna", "Eterna Bleach Bypass",
    "Acros", "Acros+Ye", "Acros+R", "Acros+G", "Monochrome", "Monochrome+Ye", "Monochrome+R", "Monochrome+G", "Sepia"]);
  assert.ok(priors!.groups.every((group) => group.sims.every((sim) => sims.has(sim))));
});

const EXAMPLE_BRIEF = "Beach wedding: ceremony in harsh afternoon sun, family formals in open shade, golden hour couple portraits, reception under string lights. No Classic Chrome and nothing with Nostalgic Neg, the couple hates that look. Natural skin.";
const example = () => JSON.parse(readFileSync(new URL("../../examples/planner/agent-answer.example.json", import.meta.url), "utf8"));

test("the planner request carries the compact summary and finalization adds informational notes, never failures", async () => {
  const request = await prepareAgentPlan({ text: EXAMPLE_BRIEF, count: 4, date: "2026-10-17" });
  const practice = request.recipe_context.knowledge.community_practice!;
  assert.equal(practice.k, 5);
  assert.match(request.model_request.text, /COMMUNITY PRACTICE: aggregate counts, each covering at least 5 widely shared community recipes; no recipe is included/);
  assert.ok(practice.summary.every((line) => request.model_request.text.includes(line)));
  const result = await finalizeAgentPlan(request, example());
  assert.equal(result.validation.status, "proposal");
  assert.deepEqual(result.validation.warnings, []);
  assert.equal(result.community_practice!.looks.length, 4);
  assert.ok(result.community_practice!.looks.every((look) => ["common", "uncommon", "unusual", "not_covered"].includes(look.region) && /Informational/.test(look.note)));
  // With priors in which these looks sit off common practice, they are flagged in notes only; validation is unchanged.
  const dir = mkdtempSync(join(tmpdir(), "dialin-space-priors-"));
  const previous = process.env.DIALIN_RECIPE_SPACE;
  try {
    const path = join(dir, "priors.json");
    writeFileSync(path, serializeRecipeSpacePriors(buildRecipeSpacePriors(synthetic({ "Pro Neg Std": 20, "Reala Ace": 20 }))));
    process.env.DIALIN_RECIPE_SPACE = path;
    const flagged = await finalizeAgentPlan(await prepareAgentPlan({ text: EXAMPLE_BRIEF, count: 4, date: "2026-10-17" }), example());
    assert.equal(flagged.validation.status, "proposal");
    assert.deepEqual(flagged.validation.warnings, []);
    assert.ok(flagged.community_practice!.looks.some((look) => look.region === "unusual" && look.unusual_settings.length >= 2));
  } finally {
    if (previous === undefined) delete process.env.DIALIN_RECIPE_SPACE; else process.env.DIALIN_RECIPE_SPACE = previous;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("without priors the planner and CLI simply omit community practice", async () => {
  const previous = process.env.DIALIN_RECIPE_SPACE;
  process.env.DIALIN_RECIPE_SPACE = "none";
  try {
    const request = await prepareAgentPlan({ text: "Portraits in open shade", count: 1 });
    assert.equal(request.recipe_context.knowledge.community_practice, null);
    assert.doesNotMatch(request.model_request.text, /COMMUNITY PRACTICE/);
  } finally { if (previous === undefined) delete process.env.DIALIN_RECIPE_SPACE; else process.env.DIALIN_RECIPE_SPACE = previous; }
  const run = (env: Record<string, string>) => spawnSync(process.execPath, ["scripts/dialin.mjs", "recipes", "knowledge", "--query", "portraits"], {
    cwd: new URL("../../", import.meta.url), encoding: "utf8", env: { ...process.env, DIALIN_RECIPE_CATALOG: "none", ...env } });
  const shown = JSON.parse(run({}).stdout);
  assert.equal(shown.planner_context.community_practice.k, 5);
  assert.equal(JSON.parse(run({ DIALIN_RECIPE_SPACE: "none" }).stdout).planner_context.community_practice, null);
});

test("the generator CLI writes priors from a catalog, refuses silent replacement and never writes a failing file", () => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-space-"));
  try {
    const out = join(dir, "space", "priors.json");
    const run = (args: string[]) => spawnSync(process.execPath, ["--import", "tsx", "scripts/build-recipe-space.ts", ...args], {
      cwd: new URL("../../", import.meta.url), encoding: "utf8", env: { ...process.env, DIALIN_RECIPE_CATALOG: FIXTURE, DIALIN_RECIPE_CATALOG_FIXTURE: "1" } });
    assert.equal(run([]).status, 2);
    const first = run(["--out", out]);
    assert.equal(first.status, 0, first.stderr);
    assert.equal(JSON.parse(first.stdout).privacy.passed, true);
    assert.equal(loadRecipeSpacePriors(out)!.groups.length, 1);
    const bytes = readFileSync(out, "utf8");
    assert.equal(run(["--out", out]).status, 1);
    assert.equal(readFileSync(out, "utf8"), bytes);
    assert.equal(run(["--out", out, "--replace"]).status, 0);
    const none = spawnSync(process.execPath, ["--import", "tsx", "scripts/build-recipe-space.ts", "--out", join(dir, "none.json")], {
      cwd: new URL("../../", import.meta.url), encoding: "utf8", env: { ...process.env, DIALIN_RECIPE_CATALOG: "none" } });
    assert.equal(none.status, 1);
    assert.equal(existsSync(join(dir, "none.json")), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
