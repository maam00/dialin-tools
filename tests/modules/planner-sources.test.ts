// Source tracing over the synthetic fixture catalog (invented recipes on recipes.example), the original book and
// stated outside inspirations. The planner reads the catalog from the environment, so this file pins the fixture.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createPlan, prepareAgentPlan } from "../../modules/planner/index.js";
import { buildSourceTrace } from "../../modules/planner/sources.js";
import { loadRecipeBook } from "../../modules/recipes/index.js";
import { emptyRecipeKnowledge, loadRecipeKnowledge } from "../../modules/recipes/knowledge.js";

const FIXTURE = fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url));
process.env.DIALIN_RECIPE_CATALOG = FIXTURE;
process.env.DIALIN_RECIPE_CATALOG_FIXTURE = "1";
const base = (await createPlan({ mode: "demo" })).plan;
const book = loadRecipeBook();
const catalog = loadRecipeKnowledge(FIXTURE, { fixture: true });
const original = { relationship: "original", references: [], reason: "An independently designed direction for the stated intention." };
// The demo fixture repeats original book directions verbatim; tests of "original" first move it away from every source.
const unique = (plan: typeof base) => { plan.day_looks[0].shadow = 2.5; plan.day_looks[0].sharpness = 3; };
const declare = (look: typeof base.day_looks[number]) => {
  const entry = book.recipes.find((item) => Object.entries(item.recipe).every(([key, value]) => key === "name" || key === "why" || look[key as keyof typeof look] === value));
  return entry ? { relationship: "exact", references: [{ kind: "book", id: entry.id }], reason: "Uses the represented book direction unchanged." } : original;
};
function trace(use: unknown = original, mutate: ((plan: typeof base) => void) | undefined = use === original ? unique : undefined, intention = "") {
  const plan = structuredClone(base);
  plan.day_looks = [plan.day_looks[0]];
  mutate?.(plan);
  return buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: use }], book, catalog, intention);
}

test("original declarations do not manufacture source ancestry", () => {
  const result = trace();
  assert.equal(result.status, "compared");
  assert.deepEqual(result.rows[0].comparisons, []);
  assert.equal(result.evidence, "model_declared_use_with_computed_setting_differences");
  assert.equal(trace({ ...original, references: [{ kind: "book", id: book.recipes[0].id }] }).status, "needs_revision");
});

test("computed source differences use final settings and retain reference URL and revision", () => {
  const source = catalog.references.find((ref) => ref.source_facts.fields.clarity !== undefined && ref.source_facts.fields.clarity !== 0)!;
  const result = trace({ relationship: "adapted", references: [{ kind: "catalog", id: source.id }], reason: "Zero clarity for responsiveness." }, (plan) => { plan.day_looks[0].clarity = 0; });
  assert.equal(result.status, "compared");
  const comparison = result.rows[0].comparisons[0];
  assert.equal(comparison.source_url, source.source_url);
  assert.equal(comparison.source_revision, source.public_facts_sha256);
  assert.deepEqual(comparison.changed_fields.find((item) => item.field === "clarity"), { field: "clarity", source: source.source_facts.fields.clarity, proposed: 0 });
  assert.equal(comparison.native_and_photographic_equivalence_verified, false);
});

test("exact claims cannot fill absent fields, ignore native fields, or override ambiguous provenance", () => {
  const guidance = ["iso", "iso_auto_max", "iso_min", "iso_max", "exposure_compensation", "exposure_compensation_min", "exposure_compensation_max"];
  for (const source of [catalog.references.find((ref) => ref.source_record_status === "ambiguous")!, catalog.references.find((ref) => Object.keys(ref.source_facts.native).some((key) => ![...guidance, "grain_strength", "grain_size"].includes(key)))!]) {
    const result = trace({ relationship: "exact", references: [{ kind: "catalog", id: source.id }], reason: "Claimed source copy." }, (plan) => Object.assign(plan.day_looks[0], source.source_facts.fields));
    assert.equal(result.status, "needs_revision");
    assert.match(result.issues.join(" "), /exact source claim is unsupported/);
  }
  const entry = book.recipes[0];
  const known = trace({ relationship: "exact", references: [{ kind: "book", id: entry.id }], reason: "Preserve represented book settings." }, (plan) => Object.assign(plan.day_looks[0], entry.recipe));
  assert.equal(known.status, "compared");
  assert.equal(known.rows[0].comparisons[0].comparison, "matches_represented_settings");
});

test("unknown, duplicate, missing, or dishonest source declarations require revision", () => {
  for (const use of [undefined, {}, { ...original, reason: "" }, { ...original, relationship: "adapted" },
    { relationship: "exact", references: [{ kind: "catalog", id: "invented-id" }], reason: "Unrecognized source." },
    { relationship: "adapted", references: [{ kind: "book", id: book.recipes[0].id }, { kind: "book", id: book.recipes[0].id }], reason: "Duplicate." }]) {
    const plan = structuredClone(base); plan.day_looks = [plan.day_looks[0]];
    assert.equal(buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: use }], book, catalog).status, "needs_revision");
  }
});

test("multi-source adaptations preserve each source separately; kept slots make no new source claim", () => {
  const refs = book.recipes.slice(0, 2).map((entry) => ({ kind: "book", id: entry.id }));
  assert.equal(trace({ relationship: "adapted", references: refs, reason: "Combine the separate texture and tone intentions." }).rows[0].comparisons.length, 2);
  const result = trace(undefined, (plan) => { plan.day_looks[0].status = "kept"; });
  assert.equal(result.rows[0].status, "kept_camera_recipe");
  assert.deepEqual(result.rows[0].comparisons, []);
});

test("an original declaration that repeats a complete source requires attribution", () => {
  const result = trace(original, () => undefined);
  assert.equal(result.status, "needs_revision");
  assert.match(result.issues.join(" "), /declared original, but its represented settings repeat book source/);
  const copied = catalog.references.find((ref) => ref.source_record_status === "public_settings" && ref.source_facts.published_core.complete)!;
  const fromCatalog = trace(original, (plan) => Object.assign(plan.day_looks[0], copied.source_facts.fields));
  assert.match(fromCatalog.issues.join(" "), new RegExp(`catalog source ${copied.id}`));
  assert.equal(trace(original).status, "compared");
});

test("exact catalog claims compare rendering settings and disclose ISO/exposure guidance instead of blocking on it", () => {
  const guidance = new Set(["iso", "iso_auto_max", "iso_min", "iso_max", "exposure_compensation", "exposure_compensation_min", "exposure_compensation_max"]);
  const source = catalog.references.find((ref) => ref.source_record_status === "public_settings" && ref.source_facts.published_core.complete
    && Object.keys(ref.source_facts.native).some((key) => guidance.has(key))
    && Object.keys(ref.source_facts.native).every((key) => guidance.has(key) || key === "grain_strength" || key === "grain_size"))!;
  const result = trace({ relationship: "exact", references: [{ kind: "catalog", id: source.id }], reason: "Published rendering settings unchanged." },
    (plan) => Object.assign(plan.day_looks[0], source.source_facts.fields));
  assert.equal(result.status, "compared", result.issues.join(" "));
  const comparison = result.rows[0].comparisons[0];
  assert.equal(comparison.comparison, "matches_represented_settings");
  assert.deepEqual(comparison.unrepresented_native_fields, []);
  assert.ok(comparison.unwritten_guidance_fields.length > 0 && comparison.unwritten_guidance_fields.every((item) => guidance.has(item.field)));
  // A changed rendering value still blocks the claim, and the issue names the exact difference.
  const changed = trace({ relationship: "exact", references: [{ kind: "catalog", id: source.id }], reason: "Claimed unchanged." },
    (plan) => Object.assign(plan.day_looks[0], source.source_facts.fields, { shadow: (source.source_facts.fields.shadow ?? 0) === 4 ? 3 : 4 }));
  assert.equal(changed.status, "needs_revision");
  assert.match(changed.issues.join(" "), /exact source claim is unsupported by shadow /);
});

test("source binding uses accepted names, not draft order or metadata supplied by a client", () => {
  const result = buildSourceTrace(base, [...base.day_looks].reverse().map((look) => ({ name: look.name, source_use: declare(look) })), book, catalog);
  assert.equal(result.rows.length, base.day_looks.length);
  assert.equal(result.status, "compared");
  const missing = buildSourceTrace(base, [{ name: "wrong-name", source_use: original }], book, catalog);
  assert.equal(missing.status, "needs_revision");
});

test("exact source intention remains explicitly unresolved when a truthful adaptation is proposed", () => {
  const result = trace(original, undefined, "Use the source recipe Kodak Quayside 320 with exact settings for an afternoon portrait.");
  assert.equal(result.requested_fidelity.status, "unresolved");
  assert.equal(trace(original, undefined, "I do not want an exact copy; adapt the scene.").requested_fidelity.status, "not_requested");
});

test("source grain components are compared even when combined grain is missing", () => {
  const source = catalog.references.find((ref) => ref.source_facts.fields.grain === undefined && ref.source_facts.native.grain_strength === "Weak")!;
  const result = trace({ relationship: "adapted", references: [{ kind: "catalog", id: source.id }], reason: "Use stronger added grain than the known weak source." }, (plan) => { plan.day_looks[0].grain = "Strong Large"; });
  const comparison = result.rows[0].comparisons[0];
  assert.deepEqual(comparison.changed_native_fields.find((field) => field.field === "grain_strength"), { field: "grain_strength", source: "Weak", proposed: "Strong", represented_by: "grain" });
  assert.ok(comparison.supplied_missing_fields.some((field) => field.field === "grain"));
  assert.ok(!comparison.unrepresented_native_fields.includes("grain_strength"));
});

test("native grain size does not silently disappear when final added grain is off", () => {
  const source = catalog.references.find((ref) => ref.source_facts.native.grain_strength === "Strong" && ref.source_facts.native.grain_size === "Large")!;
  const result = trace({ relationship: "adapted", references: [{ kind: "catalog", id: source.id }], reason: "Turn off added grain for cleaner delivery." }, (plan) => { plan.day_looks[0].grain = "Off"; });
  const comparison = result.rows[0].comparisons[0];
  assert.deepEqual(comparison.changed_native_fields.find((field) => field.field === "grain_size"), { field: "grain_size", source: "Large", proposed: null, represented_by: "grain" });
  assert.ok(comparison.unrepresented_native_fields.includes("grain_size"));
});

test("counts and negated exact-copy instructions are not fidelity requests", () => {
  for (const intention of [
    "I want exactly seven looks for the day.",
    "I need exactly 3 recipes with different interpretations.",
    "I want Quayside inspiration, not exact settings.",
    "Do not copy exactly; use a useful adaptation.",
    "I don't want an exact copy of Kodak Quayside 320.",
    "I don’t want an exact copy of Kodak Quayside 320.",
    "There is no need for exact settings; adapt to this scene.",
    "Avoid an exact match to the source recipe.",
  ]) assert.equal(trace(original, undefined, intention).requested_fidelity.status, "not_requested", intention);
});

test("an unrelated exact book recipe cannot satisfy named source fidelity", () => {
  const entry = book.recipes[0];
  const use = { relationship: "exact", references: [{ kind: "book", id: entry.id }], reason: "Exactly the represented original book values." };
  for (const intention of ["Use Kodak Quayside 320 with exact settings.", "Use Quayside 320 with exact settings.", "Use Quayside 320 exactly.", "Copy the unknown Space Film recipe exactly."]) {
    const result = trace(use, (plan) => Object.assign(plan.day_looks[0], entry.recipe), intention);
    assert.equal(result.status, "compared");
    assert.equal(result.requested_fidelity.status, "unresolved", intention);
    assert.match(result.requested_fidelity.note, /unrelated exact copy cannot fulfill/);
  }
  const correct = trace(use, (plan) => Object.assign(plan.day_looks[0], entry.recipe), `Use ${entry.title} with exact settings.`);
  assert.equal(correct.requested_fidelity.status, "represented_settings_compared");
  assert.deepEqual(correct.requested_fidelity.requested_sources[0].matching_looks, [entry.recipe.name]);
});

test("explicit source IDs and exact variant names bind only those sources", () => {
  const entry = book.recipes[0];
  const result = trace({ relationship: "exact", references: [{ kind: "book", id: entry.id }], reason: "Keep the represented settings." }, (plan) => Object.assign(plan.day_looks[0], entry.recipe), `Use exact recipe settings from ${entry.id}.`);
  assert.equal(result.requested_fidelity.status, "represented_settings_compared");
  assert.deepEqual(result.requested_fidelity.requested_sources[0].candidates, [{ kind: "book", id: entry.id }]);
});

test("an unresolved exact request permits a proposal only with explicit adaptation permission", () => {
  const strict = "Use Kodak Quayside 320 with exact settings.";
  assert.equal(trace(original, undefined, strict).requested_fidelity.adaptation_permitted, false);
  const permitted = trace(original, undefined, strict + " Prepare one safe proposed interpretation and clearly state if the exact request cannot be satisfied.").requested_fidelity;
  assert.equal(permitted.status, "unresolved");
  assert.equal(permitted.adaptation_permitted, true);
  for (const suffix of [
    " Do not prepare one safe proposed interpretation if the exact request cannot be satisfied.",
    " Don’t offer an adaptation if the exact request cannot be satisfied.",
    " No adaptations are acceptable.",
    " Do not feel free to adapt.",
  ]) assert.equal(trace(original, undefined, strict + suffix).requested_fidelity.adaptation_permitted, false, suffix);
});

test("real exported model schema requests source declarations on each look", async () => {
  const request = await prepareAgentPlan({ text: "Natural portraits in open shade.", count: 1 });
  const looks = (request.model_request.schema.properties as Record<string, { items: { required: string[]; properties: Record<string, unknown> } }>).looks;
  assert.ok(looks.items.required.includes("source_use"));
  assert.ok(looks.items.properties.source_use);
  assert.match(request.model_request.system, /full catalog/);
});

test("an exact request for an article of unnamed blocks names every block as a candidate", () => {
  const blocks = catalog.references.filter((reference) => reference.article_title === "Tidewater Pro 160").map((reference) => reference.id).sort();
  const result = trace(original, undefined, "Copy Tidewater Pro 160 exactly.");
  assert.equal(result.requested_fidelity.status, "unresolved");
  assert.deepEqual(result.requested_fidelity.requested_sources.flatMap((source) => source.candidates.map((candidate) => candidate.id)).sort(), blocks);
});

test("a brand prefix may be omitted when naming a catalog source for an exact copy", () => {
  const source = catalog.references.find((reference) => reference.title === "Kodak Quayside 320")!;
  const use = { relationship: "exact", references: [{ kind: "catalog", id: source.id }], reason: "Published rendering settings unchanged." };
  const result = trace(use, (plan) => Object.assign(plan.day_looks[0], source.source_facts.fields), "Use Quayside 320 exactly.");
  assert.equal(result.status, "compared", result.issues.join(" "));
  assert.equal(result.requested_fidelity.status, "represented_settings_compared");
});

test("an outside inspiration is recorded as stated, unverified and unhashed, and only as inspiration", () => {
  const outside = { relationship: "inspired", references: [{ kind: "outside", id: "Sunset Linen (a friend's recipe)" }], reason: "The photographer liked a friend's recipe; its settings are not available." };
  const result = trace(outside, unique);
  assert.equal(result.status, "compared", result.issues.join(" "));
  const comparison = result.rows[0].comparisons[0];
  assert.equal(comparison.kind, "outside");
  assert.equal(comparison.title, "Sunset Linen (a friend's recipe)");
  assert.equal(comparison.verification, "unverified_stated_inspiration");
  assert.equal(comparison.comparison, "not_compared_outside_reference");
  assert.equal(comparison.source_url, null);
  assert.equal(comparison.source_revision, null);
  assert.deepEqual(comparison.changed_fields, []);
  for (const relationship of ["adapted", "exact"]) {
    const claimed = trace({ ...outside, relationship }, unique);
    assert.equal(claimed.status, "needs_revision", relationship);
    assert.match(claimed.issues.join(" "), /no settings available for comparison, so declare it inspired/);
  }
  // In a private checkout, naming an installed catalog recipe as outside asks for its catalog ID.
  const named = catalog.references.find((reference) => reference.title === "Meadow Pop")!;
  const known = trace({ ...outside, references: [{ kind: "outside", id: "meadow pop" }] }, unique);
  assert.equal(known.status, "needs_revision");
  assert.match(known.issues.join(" "), new RegExp(`is catalog source ${named.id}; cite it with kind catalog`));
});

test("an outside reference that names a book or catalog source asks for its stable ID instead of hiding the comparison", () => {
  const entry = book.recipes[0];
  const named = catalog.references.find((reference) => reference.title === "Meadow Pop")!;
  for (const [id, kind, source] of [[entry.title, "book", entry.id], [entry.id, "book", entry.id], [named.id, "catalog", named.id]]) {
    const result = trace({ relationship: "inspired", references: [{ kind: "outside", id }], reason: "Named idea only." }, unique);
    assert.equal(result.status, "needs_revision", id);
    assert.match(result.issues.join(" "), new RegExp(`is ${kind} source ${source}; cite it with kind ${kind}`), id);
  }
  // Without a private catalog the book is the only source, and the same rule holds.
  const plan = structuredClone(base); plan.day_looks = [plan.day_looks[0]]; unique(plan);
  const none = buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: { relationship: "inspired", references: [{ kind: "outside", id: entry.title.toUpperCase() }], reason: "Named." } }], book, emptyRecipeKnowledge());
  assert.equal(none.status, "needs_revision");
});

test("without a private catalog, book and outside sources still trace and a catalog ID explains why it is unknown", () => {
  const plan = structuredClone(base); plan.day_looks = [plan.day_looks[0]]; unique(plan);
  const none = emptyRecipeKnowledge();
  const book0 = book.recipes[0];
  const fromBook = buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: { relationship: "adapted", references: [{ kind: "book", id: book0.id }], reason: "Adapted tones." } }], book, none);
  assert.equal(fromBook.status, "compared");
  const outside = buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: { relationship: "inspired", references: [{ kind: "outside", id: "A remembered magazine recipe" }], reason: "Named idea only." } }], book, none);
  assert.equal(outside.status, "compared");
  const cited = buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: { relationship: "adapted", references: [{ kind: "catalog", id: "any-catalog-id" }], reason: "Catalog source." } }], book, none);
  assert.equal(cited.status, "needs_revision");
  assert.match(cited.issues.join(" "), /No private recipe catalog is installed; cite a book ID, or name a recipe from elsewhere with kind outside/);
  const exact = buildSourceTrace(plan, [{ name: plan.day_looks[0].name, source_use: { relationship: "inspired", references: [{ kind: "outside", id: "Kodak Quayside 320" }], reason: "Named." } }], book, none, "Use the Kodak Quayside 320 recipe with exact settings.");
  assert.equal(exact.requested_fidelity.status, "unresolved");
});

test("without a private catalog, the request schema and prompt offer book and outside sources, never catalog IDs", async () => {
  const previous = process.env.DIALIN_RECIPE_CATALOG;
  process.env.DIALIN_RECIPE_CATALOG = "none";
  try {
    const request = await prepareAgentPlan({ text: "Natural portraits in open shade.", count: 1 });
    assert.equal(request.recipe_context.knowledge.retrieval.selection_status, "no_catalog_installed");
    assert.match(request.model_request.system, /references of kind book with exact stable IDs \(no private recipe catalog is installed/);
    assert.match(request.model_request.system, /kind outside, with its name as id/);
    assert.doesNotMatch(request.model_request.system, /full catalog/);
    assert.match(request.model_request.text, /ORIGINAL RECIPE GUIDANCE/);
    assert.match(request.model_request.text, /SOURCE-NEUTRAL RECIPE BOOK/);
    const looks = (request.model_request.schema.properties as Record<string, { items: { properties: Record<string, { properties: { references: { items: { properties: { kind: { enum: string[] } } } } } }> } }>).looks;
    assert.deepEqual(looks.items.properties.source_use.properties.references.items.properties.kind.enum, ["catalog", "book", "outside"]);
  } finally { process.env.DIALIN_RECIPE_CATALOG = previous; }
});
