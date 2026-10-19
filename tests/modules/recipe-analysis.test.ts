// Settings-analysis mechanics. Catalog-wide coverage runs over the synthetic fixture; no third-party catalog ships with Dial In.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { loadRecipeKnowledge, publicRecipeFactsHash, type RecipeReference } from "../../modules/recipes/knowledge.js";
import { analyzeRecipe, analyzeRecipeCatalog, RECIPE_ANALYSIS_VERSION } from "../../modules/recipes/analysis.js";
import { SETTING_KNOWLEDGE, SIMULATION_PROFILES, EXPERT_SOURCES } from "../../lib/plan/expert-knowledge.js";

const catalog = loadRecipeKnowledge(fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url)), { fixture: true });
function fixture(fields: RecipeReference["source_facts"]["fields"], native: RecipeReference["source_facts"]["native"] = {}): RecipeReference {
  const reference = structuredClone(catalog.references[0]);
  reference.title = "Arbitrary name: not a source of facts";
  reference.source_record_status = "ambiguous";
  reference.source_facts = { ...reference.source_facts, fields, native, status: "needs_review", missing_fields: ["film_sim", "clarity"].filter((field) => !(field in fields)) as ("film_sim" | "clarity")[], inactive_fields: [], issues: [], published_core: { complete: false, missing_fields: [] } };
  reference.public_facts_sha256 = publicRecipeFactsHash(reference);
  return reference;
}
const statements = (analysis: ReturnType<typeof analyzeRecipe>) => [...analysis.observations, ...analysis.interactions, ...analysis.best_fit, ...analysis.cautions, ...analysis.adaptations];

test("every catalog reference has reproducible analysis coverage without fabricated photographic testing", () => {
  const result = analyzeRecipeCatalog(catalog.references);
  assert.equal(result.schema_version, RECIPE_ANALYSIS_VERSION);
  assert.equal(result.coverage.references, 19);
  assert.equal(result.coverage.fact_bearing, 18);
  assert.equal(result.coverage.insufficient_facts, 1);
  assert.equal(result.coverage.photographed, 0);
  assert.equal(result.coverage.hardware_tested, 0);
  assert.equal(result.coverage.human_preference_evaluated, 0);
  assert.equal(new Set(result.analyses.map((item) => item.binding.record_id)).size, 19);
  assert.deepEqual(result, analyzeRecipeCatalog(catalog.references));
  for (const analysis of result.analyses) {
    assert.equal(analysis.photographic_validation, "not_verified");
    assert.equal(analysis.evidence, "reproducible_settings_rules");
    assert.equal(analysis.camera_ready, false);
    if (analysis.status !== "insufficient_facts") assert.ok(analysis.observations.length >= 3, analysis.binding.record_id);
  }
});

test("every statement binds exact public field values and every supplied control remains accounted for", () => {
  const knownIDs = new Set([...SETTING_KNOWLEDGE.map((rule) => rule.id), ...SIMULATION_PROFILES.map((profile) => profile.id)]);
  const knownURLs = new Set(Object.values(EXPERT_SOURCES).map((source) => source.url));
  for (const reference of catalog.references) {
    const analysis = analyzeRecipe(reference);
    assert.equal(analysis.binding.source_url, reference.source_url);
    assert.equal(analysis.binding.public_facts_sha256, reference.public_facts_sha256);
    assert.equal(analysis.binding.source_fact_signature, reference.source_fact_signature);
    const described = new Set<string>();
    const facts = { fields: reference.source_facts.fields, native: reference.source_facts.native };
    for (const statement of statements(analysis)) {
      assert.ok(statement.controls.length, `${reference.id}:${statement.id}`);
      for (const evidence of statement.controls) {
        const [group, field] = evidence.field.split(".");
        const source = facts[group as keyof typeof facts] as Record<string, unknown>;
        assert.ok(Object.hasOwn(source, field), `${reference.id}:${evidence.field}`);
        assert.deepEqual(evidence.value, source[field]);
        described.add(evidence.field);
      }
      assert.ok(statement.knowledge_ids.every((id) => knownIDs.has(id)));
      assert.ok(statement.sources.every((source) => knownURLs.has(source.url as typeof EXPERT_SOURCES[keyof typeof EXPERT_SOURCES]["url"])));
    }
    for (const [group, source] of Object.entries(facts)) for (const field of Object.keys(source)) assert.ok(described.has(`${group}.${field}`), `${reference.id}: undescribed ${group}.${field}`);
  }
});

test("linked-only records have unknown traits, no fits and no invented settings inferred from a name", () => {
  const linked = catalog.references.filter((item) => item.source_record_status === "linked_only");
  assert.ok(linked.length > 0);
  for (const reference of linked) {
    const analysis = analyzeRecipe(reference);
    assert.equal(analysis.status, "insufficient_facts");
    assert.deepEqual(statements(analysis), []);
    assert.deepEqual(analysis.semantic_tags, []);
    assert.ok(Object.values(analysis.traits).every((value) => value === "unknown"));
    assert.match(analysis.limits.join(" "), /Do not infer simulation/);
  }
});

test("ambiguous and partial source records remain conditional, including unknown monochrome simulations", () => {
  const reference = catalog.references.find((item) => item.title === "Fog Ledger")!;
  const analysis = analyzeRecipe(reference);
  assert.equal(analysis.status, "conditional");
  assert.equal(analysis.traits.rendering, "unknown");
  assert.equal(analysis.traits.color_intensity, "unknown");
  assert.equal(analysis.traits.warm_cast_risk, "unknown");
  assert.ok(!analysis.semantic_tags.includes("monochrome"));
  assert.match(analysis.observations.find((item) => item.id === "mono-toning")!.text, /conditional/);
  assert.ok(analysis.missing_controls.includes("fields.film_sim"));
});

test("missing WB axes, Kelvin, clarity and grain size are not replaced by defaults", () => {
  const analysis = analyzeRecipe(fixture({ film_sim: "Classic Chrome", white_balance: "Kelvin", wb_shift_r: 0 }, { grain_strength: "Weak" }));
  assert.equal(analysis.traits.warm_cast_risk, "unknown");
  assert.equal(analysis.traits.clarity_delay, "unknown");
  assert.match(analysis.observations.find((item) => item.id === "white-balance")!.text, /no published temperature/);
  assert.match(analysis.observations.find((item) => item.id === "grain")!.text, /size unknown/);
  assert.ok(statements(analysis).flatMap((item) => item.controls).every((item) => !["fields.kelvin", "fields.wb_shift_b", "fields.clarity", "native.grain_size"].includes(item.field)));
});

test("WB warmth assessment respects directional controls and never guarantees neutral skin", () => {
  const warm = analyzeRecipe(fixture({ film_sim: "Classic Chrome", white_balance: "Auto", wb_shift_r: 4, wb_shift_b: -5 }));
  const cool = analyzeRecipe(fixture({ film_sim: "Classic Chrome", white_balance: "Auto", wb_shift_r: -2, wb_shift_b: 3 }));
  assert.equal(warm.traits.warm_cast_risk, "elevated");
  assert.equal(cool.traits.warm_cast_risk, "not_indicated");
  for (const analysis of [warm, cool]) {
    assert.equal(analysis.traits.wb_versatility, "adaptive_with_caveats");
    assert.match(analysis.cautions.find((item) => item.id === "skin-cast-uncertainty")!.text, /Neither.*guarantee neutral skin/);
    assert.match(analysis.cautions.find((item) => item.id === "skin-cast-uncertainty")!.text, /cannot neutralize/);
  }
  const fixed = analyzeRecipe(fixture({ film_sim: "Pro Neg Std", white_balance: "Daylight", wb_shift_r: 0, wb_shift_b: 0 }));
  assert.equal(fixed.traits.wb_versatility, "illumination_sensitive");
  assert.ok(fixed.adaptations.some((item) => item.id === "changing-light-wb"));
});

test("Kelvin is a rendering setting, not a measured shoot temperature", () => {
  const analysis = analyzeRecipe(fixture({ film_sim: "Provia", white_balance: "Kelvin", kelvin: 7000, wb_shift_r: 0, wb_shift_b: 0 }));
  assert.equal(analysis.traits.warm_cast_risk, "elevated");
  assert.match(analysis.observations.find((item) => item.id === "kelvin-direction")!.text, /same illumination.*increasing.*warms/);
  assert.match(analysis.observations.find((item) => item.id === "kelvin-direction")!.text, /not a measurement/);
});

test("monochrome and sepia do not get vivid-color or orange-cast traits from inactive controls", () => {
  for (const sim of ["Acros+R", "Monochrome+G", "Sepia"] as const) {
    const analysis = analyzeRecipe(fixture({ film_sim: sim, color: 4, color_chrome: "Strong", color_chrome_fx_blue: "Strong", white_balance: "Kelvin", kelvin: 10000, wb_shift_r: 9, wb_shift_b: -9 }, { mono_wc: 2, mono_mg: -1 }));
    assert.equal(analysis.traits.color_intensity, "not_applicable");
    assert.equal(analysis.traits.warm_cast_risk, "not_applicable");
    assert.ok(!analysis.semantic_tags.includes("vivid"));
    assert.ok(!analysis.semantic_tags.includes("warm cast risk"));
    assert.ok(!analysis.interactions.some((item) => item.id === "warmth-stack" || item.id === "color-depth-stack"));
    assert.ok(!analysis.adaptations.some((item) => item.id === "changing-light-wb" || item.id === "reduce-observed-warm-cast"));
    assert.match(analysis.observations.find((item) => item.id === "inactive-color-controls")!.text, /Exclude those values/);
  }
});

test("raised Color on a restrained base is not mislabeled vivid across simulations", () => {
  for (const film_sim of ["Classic Chrome", "Eterna", "Eterna Bleach Bypass"] as const) {
    const analysis = analyzeRecipe(fixture({ film_sim, color: 3 }));
    assert.equal(analysis.traits.color_intensity, "unknown");
    assert.ok(!analysis.semantic_tags.includes("vivid"));
    assert.ok(!analysis.best_fit.some((item) => item.id === "vivid-color-intent"));
    assert.match(analysis.interactions.find((item) => item.id === "restrained-base-raised-color")!.text, /does not establish a vivid result/);
  }
  assert.equal(analyzeRecipe(fixture({ film_sim: "Velvia", color: 2 })).traits.color_intensity, "vivid");
});

test("opposing WB axes are a cast caveat rather than an automatic warm-intent recommendation", () => {
  for (const [wb_shift_r, wb_shift_b] of [[2, 2], [-3, -1]]) {
    const analysis = analyzeRecipe(fixture({ film_sim: "Provia", white_balance: "Auto", wb_shift_r, wb_shift_b }));
    assert.equal(analysis.traits.warm_cast_risk, "possible");
    assert.ok(!analysis.semantic_tags.includes("warm interpretation"));
    assert.ok(!analysis.best_fit.some((item) => item.id === "deliberate-warmth"));
  }
});

test("filter reasoning distinguishes subject hues and native tint from WB shifts", () => {
  const red = analyzeRecipe(fixture({ film_sim: "Acros+R", wb_shift_r: 3, wb_shift_b: -3 }, { mono_wc: 1, mono_mg: 0 }));
  assert.match(red.observations.find((item) => item.id === "monochrome-filter")!.text, /lightens reds relative to blues/);
  assert.match(red.cautions.find((item) => item.id === "monochrome-wb-is-not-toning")!.text, /dedicated monochromatic toning/);
  const green = analyzeRecipe(fixture({ film_sim: "Monochrome+G" }));
  assert.match(green.observations.find((item) => item.id === "monochrome-green-filter")!.text, /not skin smoothing/);
});

test("DR and highlight rendering are separate and no clipped-data recovery or cross-body ISO promise is invented", () => {
  const soft = analyzeRecipe(fixture({ film_sim: "Provia", dynamic_range: "DR400", highlight: -2, shadow: 1 }));
  const hard = analyzeRecipe(fixture({ film_sim: "Provia", dynamic_range: "DR400", highlight: 2, shadow: 1 }));
  assert.equal(soft.traits.iso_pressure, "raised_floor");
  assert.equal(soft.traits.highlight_rendering, "softened");
  assert.equal(soft.traits.contrast, "mixed");
  assert.equal(hard.traits.highlight_rendering, "hardened");
  assert.equal(hard.traits.contrast, "hard");
  assert.match(soft.observations.find((item) => item.id === "dynamic-range")!.text, /X100VI specifically.*other bodies/);
  assert.match(soft.observations.find((item) => item.id === "dynamic-range")!.text, /not recovery of already clipped/);
  assert.match(hard.interactions.find((item) => item.id === "dr-and-highlight-curve")!.text, /DR alone does not make a gentle/);
  const auto = analyzeRecipe(fixture({ dynamic_range: "Auto" }, { dynamic_range_auto: true }));
  assert.match(auto.observations.find((item) => item.id === "dynamic-range")!.text, /does not select DR400/);
});

test("active DR priority prevents independent tone/ISO assertions", () => {
  const analysis = analyzeRecipe(fixture({ film_sim: "Provia", dynamic_range: "DR400", highlight: -2, shadow: -2 }, { dr_priority: "Strong" }));
  assert.equal(analysis.traits.highlight_rendering, "auto_governed");
  assert.equal(analysis.traits.contrast, "unknown");
  assert.equal(analysis.traits.iso_pressure, "auto_limited");
  assert.ok(!analysis.best_fit.some((item) => item.id === "important-highlight-detail" || item.id === "gentle-tonal-intent"));
  assert.ok(!analysis.interactions.some((item) => item.id === "dr-and-highlight-curve"));
  assert.match(analysis.cautions.find((item) => item.id === "dr-priority-overrides")!.text, /automatically/);
});

test("grain, capture noise, edge texture and clarity speed remain distinct", () => {
  const analysis = analyzeRecipe(fixture({ film_sim: "Classic Neg", grain: "Strong Large", noise_reduction: -4, sharpness: 2, clarity: 3 }));
  assert.equal(analysis.traits.texture, "strong");
  assert.equal(analysis.traits.clarity_delay, "present");
  assert.match(analysis.interactions.find((item) => item.id === "grain-and-noise")!.text, /separate texture layer/);
  assert.match(analysis.observations.find((item) => item.id === "clarity")!.text, /no fixed one-second delay/);
  assert.match(analysis.adaptations.find((item) => item.id === "responsive-capture")!.text, /Clarity 0.*does not guarantee burst speed/);
  assert.match(analysis.observations.find((item) => item.id === "sharpness")!.text, /cannot repair missed focus/);
});

test("Auto ISO maximum and published compensation are conditional settings, not exposure measurements", () => {
  const analysis = analyzeRecipe(fixture({ dynamic_range: "DR200" }, { iso: "Auto", iso_auto_max: 6400, exposure_compensation_min: 1 / 3, exposure_compensation_max: 1 }));
  assert.match(analysis.observations.find((item) => item.id === "iso-controls")!.text, /allowed maximum, not the ISO/);
  assert.match(analysis.cautions.find((item) => item.id === "exposure-hints")!.text, /not apply it universally/);
});

test("source titles and groups cannot silently change photographic conclusions", () => {
  const reference = structuredClone(catalog.references[0]);
  const before = analyzeRecipe(reference);
  reference.title = "Best sunny beach night street portrait neutral orange free monochrome";
  reference.source_groups = ["Imaginary camera generation"];
  assert.deepEqual(analyzeRecipe(reference), before);
  assert.match(before.limits.join(" "), /not verified camera compatibility/);
});

test("analysis leaves all original source facts untouched and labels its hypotheses", () => {
  const before = JSON.stringify(catalog);
  const result = analyzeRecipeCatalog(catalog.references);
  assert.equal(JSON.stringify(catalog), before);
  for (const analysis of result.analyses) {
    assert.ok([...analysis.best_fit, ...analysis.adaptations, ...analysis.interactions].every((statement) => statement.kind === "design_hypothesis"));
    assert.ok(analysis.observations.every((statement) => statement.kind === "setting_interpretation"));
  }
});
