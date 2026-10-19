import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { assessRecipeForCamera, normalizeRecipe } from "../../lib/recipes/normalize.js";
import type { RawRecipeRecord } from "../../lib/recipes/types.js";

// Synthetic facts exercise official menu labels; this is not a copied creator recipe or a rendering reference.
const settings = (): Record<string, string> => ({ "Film Simulation": "CLASSIC CHROME", "Grain Effect": "Weak, Small",
  "Color Chrome Effect": "Weak", "Color Chrome FX Blue": "Off", "White Balance": "Auto, +1 Red & -1 Blue",
  "Dynamic Range": "200%", "Highlight": "+0.5", "Shadow": "+1", "Color": "0", "Sharpness": "-1",
  "Noise Reduction": "-4", "Clarity": "0", "D Range Priority": "Off", "Smooth Skin Effect": "Off", "Kelvin": "0" });
const record = (overrides: Partial<RawRecipeRecord> = {}): RawRecipeRecord => ({ id: "creator-exact-version-01", title: "Creator recipe title",
  source_url: "https://example.test/creator-recipe", groups: ["X-Trans II", "Source navigation group"], fetched_at: "2026-10-14T12:00:00Z",
  content_sha256: "a".repeat(64), settings: settings(), status: "public_settings", notes: ["Original source note kept only as raw provenance"],
  source_scope: "public_web_facts", training_permission: "not_verified", ...overrides });
const codes = (issues: { code: string; field: string | null }[]) => issues.map((issue) => `${issue.code}:${issue.field}`);

test("recipe version, source title and base native simulation remain separate; raw source facts stay exact and isolated", () => {
  const source = record();
  const normalized = normalizeRecipe(source);
  assert.equal(normalized.id, source.id);
  assert.equal(normalized.title, source.title);
  assert.equal(normalized.base_film_sim, "Classic Chrome");
  assert.equal(normalized.fields.name, undefined);
  assert.equal(normalized.fields.why, undefined);
  assert.deepEqual(normalized.source_groups, source.groups);
  assert.deepEqual(normalized.raw, source);
  assert.equal(normalized.facts.find((fact) => fact.field === "white_balance")?.value, "Auto, +1 Red & -1 Blue");
  source.settings["White Balance"] = "Different value";
  source.groups.push("Another body");
  assert.equal(normalized.raw.settings["White Balance"], "Auto, +1 Red & -1 Blue");
  assert.equal(normalized.source_groups.length, 2);
  assert.equal(normalized.training_export_allowed, false);
});

test("authoritative menu aliases normalize without confusing recipe titles for base simulations", () => {
  const aliases = [["PROVIA/Standard", "Provia"], ["Velvia / Vivid", "Velvia"], ["ASTIA/Soft", "Astia"],
    ["ClassicNeg", "Classic Neg"], ["PRO Neg. Std", "Pro Neg Std"], ["PRO Neg. Hi", "Pro Neg Hi"],
    ["Nostalgic Negative", "Nostalgic Neg"], ["ETERNA/CINEMA", "Eterna"], ["ETERNA BLEACH BYPASS", "Eterna Bleach Bypass"],
    ["REALA ACE", "Reala Ace"], ["ACROS + Ye FILTER", "Acros+Ye"], ["MONOCHROME (R)", "Monochrome+R"]];
  for (const [raw, expected] of aliases) assert.equal(normalizeRecipe(record({ settings: { "Film Simulation": raw } })).base_film_sim, expected);
  const noSetting = normalizeRecipe(record({ title: "Reala Ace", settings: {} }));
  assert.equal(noSetting.base_film_sim, null);
  assert.equal(noSetting.fields.film_sim, undefined);
});

test("an explicit adjacent bare enum preserves its empty source label; conflicts never choose a simulation", () => {
  const bare = normalizeRecipe(record({ settings: { "": "PROVIA/Standard", "Noise-Reduction": "-2 (Low)", Sharpening: "+1" } }));
  assert.equal(bare.base_film_sim, "Provia");
  assert.equal(bare.facts.find((fact) => fact.field === "film_sim")?.label, "");
  assert.equal(bare.fields.sharpness, 1);
  assert.equal(bare.fields.noise_reduction, -2);
  const conflicting = normalizeRecipe(record({ settings: { "": "PROVIA/Standard", "Film Simulation": "Velvia" } }));
  assert.equal(conflicting.base_film_sim, null);
  assert.ok(codes(conflicting.issues).includes("conflicting_values:film_sim"));
  assert.equal(normalizeRecipe(record({ settings: { "": "Provia or Velvia" } })).base_film_sim, null);
  const diagnostic = normalizeRecipe(record({ settings: {}, notes: ["Unlabelled simulation: Provia"] }));
  assert.equal(diagnostic.base_film_sim, null);
});

test("the exact published Provia/STD spelling resolves labelled and bare facts without inferring from a recipe name", () => {
  for (const label of ["Film Simulation", ""]) {
    const source = record({ settings: { [label]: "Provia/STD" } });
    const normalized = normalizeRecipe(source);
    assert.equal(normalized.base_film_sim, "Provia");
    assert.equal(normalized.raw.settings[label], "Provia/STD");
    assert.equal(normalized.facts.find((fact) => fact.field === "film_sim")?.label, label);
  }
  assert.equal(normalizeRecipe(record({ title: "Provia Morning", settings: {} })).base_film_sim, null);
});

test("reviewed source typo and combined toning labels retain only explicit numeric or axis facts", () => {
  const source = settings(); delete source.Sharpness;
  const normalized = normalizeRecipe(record({ settings: { ...source, Sharpeness: "-1", "Monochromatic Color (Toning)": "WC +2, MG -1" } }));
  assert.equal(normalized.fields.sharpness, -1);
  assert.deepEqual([normalized.native.mono_wc, normalized.native.mono_mg], [2, -1]);
  assert.equal(normalized.raw.settings.Sharpeness, "-1");
  const ambiguous = normalizeRecipe(record({ settings: { Sharpeness: "+1 or +2", "Monochromatic Color (Toning)": "+1 (warm)" } }));
  assert.equal(ambiguous.fields.sharpness, undefined);
  assert.equal(ambiguous.native.mono_wc, undefined);
  assert.equal(ambiguous.native.mono_mg, undefined);
});

test("missing settings and explicitly unavailable older features never acquire modern defaults", () => {
  const normalized = normalizeRecipe(record({ settings: { "Film Simulation": "PRO Neg. Std", "Noise Reduction": "-2 (Low)",
    "Highlight": "0 (Std)", "Color": "0 (Medium)", "Grain Effect": "N/A", "Color Chrome FX Blue": "Not available" } }));
  assert.equal(normalized.fields.noise_reduction, -2);
  assert.equal(normalized.fields.highlight, 0);
  assert.equal(normalized.fields.color, 0);
  assert.equal(normalized.fields.grain, undefined);
  assert.equal(normalized.fields.color_chrome_fx_blue, undefined);
  assert.equal(normalized.fields.clarity, undefined);
  assert.ok(normalized.unavailable_fields.includes("grain"));
  assert.ok(normalized.missing_fields.includes("clarity"));
  const result = assessRecipeForCamera(normalized, X100VI, { shootingMode: "automatic" });
  assert.equal(result.published_core.complete, false);
  assert.equal(result.exact_settings.eligible, false);
  assert.equal(result.new_write.supported, false);
  assert.ok(codes(result.new_write.issues).includes("unconfirmed_code:noise_reduction"));
  assert.deepEqual(result.automatic_adaptation.changes, []);
  assert.equal(normalized.fields.noise_reduction, -2); // source-group labels never convert -2 to -4
});

test("a complete published core can still need native baseline/readback instead of being called invalid", () => {
  const source = settings(); delete source["D Range Priority"]; delete source["Smooth Skin Effect"];
  const normalized = normalizeRecipe(record({ settings: source }));
  assert.equal(normalized.status, "normalized");
  assert.equal(normalized.published_core.complete, true);
  assert.deepEqual(normalized.missing_fields, []);
  const result = assessRecipeForCamera(normalized, X100VI);
  assert.equal(result.published_core.complete, true);
  assert.equal(result.exact_settings.eligible, false);
  assert.ok(codes(result.exact_settings.issues).includes("missing_field:dr_priority"));
  assert.ok(codes(result.exact_settings.issues).includes("missing_field:smooth_skin"));
});

test("exact native eligibility and current writer encodings are independent and never hardware proof", () => {
  const normalized = normalizeRecipe(record());
  const result = assessRecipeForCamera(normalized, X100VI);
  assert.equal(result.exact_settings.eligible, true);
  assert.equal(result.new_write.supported, false); // source-native baseline controls have no Recipe writer field
  assert.ok(codes(result.new_write.issues).includes("manual_mapping:dr_priority"));
  assert.equal(result.photographic_equivalence_verified, false);
  assert.equal(result.training_export_allowed, false);
  const provia = normalizeRecipe(record({ settings: { ...settings(), "Film Simulation": "PROVIA/STANDARD" } }));
  const proviaResult = assessRecipeForCamera(provia, X100VI);
  assert.equal(proviaResult.exact_settings.eligible, true);
  assert.ok(codes(proviaResult.new_write.issues).includes("unconfirmed_code:film_sim"));
});

test("White Priority WB, DR Auto and native extras are preserved rather than flattened", () => {
  const normalized = normalizeRecipe(record({ settings: { ...settings(), "White Balance": "Auto (White Priority), +2 Red & -3 Blue",
    "Dynamic Range": "Auto", "Film Simulation": "ACROS+G", "Monochromatic Color": "WC -1, MG +2" } }));
  assert.equal(normalized.fields.white_balance, "Auto White Priority");
  assert.equal(normalized.native.auto_wb_priority, "White");
  assert.equal(normalized.fields.dynamic_range, "Auto");
  assert.equal(normalized.native.dynamic_range_auto, true);
  assert.deepEqual([normalized.native.mono_wc, normalized.native.mono_mg], [-1, 2]);
  assert.deepEqual([normalized.fields.wb_shift_r, normalized.fields.wb_shift_b], [2, -3]);
  const result = assessRecipeForCamera(normalized, X100VI);
  assert.equal(result.exact_settings.eligible, true);
  assert.equal(result.new_write.supported, false);
  assert.ok(codes(result.new_write.issues).includes("unconfirmed_code:white_balance"));
  assert.ok(codes(result.new_write.issues).includes("manual_mapping:dynamic_range"));
  assert.ok(codes(result.new_write.issues).includes("manual_mapping:mono_wc"));
});

test("inactive monochrome omissions do not invent Color0 or confuse a complete source core with writable fields", () => {
  const source: Record<string, string> = { ...settings(), "Film Simulation": "ACROS+G", "Monochromatic Color": "WC 0 MG 0" };
  delete source.Color; delete source["Color Chrome Effect"]; delete source["Color Chrome FX Blue"];
  const normalized = normalizeRecipe(record({ settings: source }));
  assert.equal(normalized.published_core.complete, true);
  assert.equal(normalized.fields.color, undefined);
  assert.ok(normalized.inactive_fields.includes("color"));
  const assessment = assessRecipeForCamera(normalized, X100VI);
  assert.equal(assessment.exact_settings.eligible, true);
  assert.equal(assessment.new_write.supported, false);
  assert.ok(codes(assessment.new_write.issues).includes("manual_mapping:color"));
});

test("explicit ISO ceilings and EV ranges remain guidance bounds rather than invented single exposures", () => {
  const normalized = normalizeRecipe(record({ settings: { ...settings(), ISO: "Auto, up to ISO 6400", "Exposure Compensation": "+2/3 to +1 1/3 (typically)" } }));
  assert.equal(normalized.native.iso, "Auto");
  assert.equal(normalized.native.iso_auto_max, 6400);
  assert.equal(normalized.native.exposure_compensation, undefined);
  assert.equal(normalized.native.exposure_compensation_min, 2 / 3);
  assert.equal(normalized.native.exposure_compensation_max, 1 + 1 / 3);
  assert.equal(normalized.issues.length, 0);
  assert.equal(assessRecipeForCamera(normalized, X100VI).exact_settings.eligible, true);
  const ambiguous = normalizeRecipe(record({ settings: { ...settings(), ISO: "800 or 1600" } }));
  assert.equal(ambiguous.native.iso, undefined);
  assert.ok(codes(ambiguous.issues).includes("ambiguous_value:iso"));
});

test("grain strength without size is unresolved; Off does not invent an inactive size", () => {
  const weak = normalizeRecipe(record({ settings: { ...settings(), "Grain Effect": "Weak" } }));
  assert.equal(weak.native.grain_strength, "Weak");
  assert.equal(weak.native.grain_size, undefined);
  assert.equal(weak.fields.grain, undefined);
  assert.ok(weak.missing_fields.includes("grain"));
  const off = normalizeRecipe(record({ settings: { ...settings(), "Grain Effect": "Off" } }));
  assert.equal(off.fields.grain, "Off");
  assert.equal(off.native.grain_size, undefined);
  const separate = normalizeRecipe(record({ settings: { ...settings(), "Grain Effect": "Strong", "Grain Size": "Large" } }));
  assert.equal(separate.fields.grain, "Strong Large");
});

test("conflicting aliases and raw alternatives are reviewable without picking a winner", () => {
  const normalized = normalizeRecipe(record({ settings: { ...settings(), Simulation: "Velvia", "WB Red": "+3", "Shadow": "-1 or +2" } }));
  assert.equal(normalized.base_film_sim, null);
  assert.equal(normalized.fields.wb_shift_r, undefined);
  assert.equal(normalized.fields.shadow, undefined);
  assert.ok(codes(normalized.issues).includes("conflicting_values:film_sim"));
  assert.ok(codes(normalized.issues).includes("conflicting_values:wb_shift_r"));
  assert.deepEqual(normalized.facts.find((fact) => fact.field === "shadow")?.alternatives, ["-1", "+2"]);
  assert.equal(assessRecipeForCamera(normalized, X100VI).new_write.supported, false);
  const wb = normalizeRecipe(record({ settings: { ...settings(), "White Balance": "Auto or Daylight, +1 Red & -1 Blue" } }));
  assert.equal(wb.fields.white_balance, undefined);
  assert.ok(codes(wb.issues).includes("ambiguous_value:white_balance"));
  const shifts = normalizeRecipe(record({ settings: { ...settings(), "White Balance": "Auto, R+1 or +2, B-1" } }));
  assert.equal(shifts.fields.wb_shift_r, undefined);
  assert.equal(shifts.fields.wb_shift_b, undefined);
});

test("unknown fields, enum values and exact out-of-range numbers are retained and block eligibility", () => {
  const normalized = normalizeRecipe(record({ settings: { ...settings(), "Film Simulation": "Invented Neon", "Color": "+99", "Magic Halation": "Strong" } }));
  assert.equal(normalized.fields.film_sim, undefined);
  assert.equal(normalized.fields.color, 99); // factual transcription is retained, never clamped
  assert.equal(normalized.raw.settings["Magic Halation"], "Strong");
  const result = assessRecipeForCamera(normalized, X100VI);
  assert.equal(result.exact_settings.eligible, false);
  assert.ok(codes(result.exact_settings.issues).includes("out_of_range:color"));
  assert.ok(codes(result.exact_settings.issues).includes("unknown_label:null"));
  assert.ok(codes(result.exact_settings.issues).includes("unknown_value:film_sim"));
});

test("documented native Kelvin increments do not expand the old app representation", () => {
  const normalized = normalizeRecipe(record({ settings: { ...settings(), "White Balance": "4350K, 0 Red & -2 Blue", "Kelvin": "4350K" } }));
  const result = assessRecipeForCamera(normalized, X100VI);
  assert.equal(normalized.fields.kelvin, 4350);
  assert.equal(result.exact_settings.eligible, true);
  assert.equal(X100VI.kelvins.includes(4350), false);
  assert.ok(codes(result.new_write.issues).includes("manual_mapping:kelvin"));
});

test("nonzero creator clarity is an explicit automatic-mode proposal, never an in-place source mutation", () => {
  const normalized = normalizeRecipe(record({ settings: { ...settings(), Clarity: "-2" } }));
  const before = JSON.stringify(normalized);
  const automatic = assessRecipeForCamera(normalized, X100VI, { shootingMode: "automatic" });
  assert.deepEqual(automatic.automatic_adaptation.changes, [{ field: "clarity", from: -2, to: 0, changes_creator_recipe: true }]);
  assert.equal(automatic.automatic_adaptation.requires_confirmation, true);
  assert.equal(automatic.exact_settings.eligible, true);
  assert.deepEqual(assessRecipeForCamera(normalized, X100VI, { shootingMode: "guided" }).automatic_adaptation.changes, []);
  assert.equal(JSON.stringify(normalized), before);
});

test("DR Priority dependencies, custom WB references and unresolved monochrome axes remain explicit", () => {
  const dr = assessRecipeForCamera(normalizeRecipe(record({ settings: { ...settings(), "D Range Priority": "Strong" } })), X100VI);
  assert.ok(codes(dr.exact_settings.issues).includes("dependent_setting:dr_priority"));
  const custom = assessRecipeForCamera(normalizeRecipe(record({ settings: { ...settings(), "White Balance": "Custom 1, 0 Red & 0 Blue" } })), X100VI);
  assert.ok(codes(custom.exact_settings.issues).includes("manual_mapping:white_balance"));
  const monochrome = assessRecipeForCamera(normalizeRecipe(record({ settings: { ...settings(), "Film Simulation": "Acros" } })), X100VI);
  assert.ok(codes(monochrome.exact_settings.issues).includes("missing_field:mono_wc"));
  assert.ok(codes(monochrome.exact_settings.issues).includes("missing_field:mono_mg"));
});

test("linked-only, unavailable and ambiguous sources cannot acquire eligibility or training permission", () => {
  for (const status of ["linked_only", "unavailable", "ambiguous"] as const) {
    const normalized = normalizeRecipe(record({ status }));
    const result = assessRecipeForCamera(normalized, X100VI);
    assert.equal(result.published_core.complete, false);
    assert.equal(result.exact_settings.eligible, false);
    assert.equal(result.new_write.supported, false);
    assert.equal(normalized.training_export_allowed, false);
    assert.equal(result.training_export_allowed, false);
    assert.equal(normalized.raw.training_permission, "not_verified");
  }
  const unavailable = normalizeRecipe(record({ status: "unavailable", source_url: null, fetched_at: null, content_sha256: null, settings: {} }));
  assert.equal(unavailable.raw.source_url, null);
  assert.equal(unavailable.raw.content_sha256, null);
  assert.equal(unavailable.status, "no_public_settings");
  assert.equal(assessRecipeForCamera(unavailable, X100VI).new_write.supported, false);
  const missingEvidence = normalizeRecipe(record({ content_sha256: null }));
  assert.equal(missingEvidence.published_core.complete, false);
  assert.equal(assessRecipeForCamera(missingEvidence, X100VI).exact_settings.eligible, false);
});

test("untrusted source labels cannot resolve through Object.prototype", () => {
  const normalized = normalizeRecipe(record({ settings: { constructor: "Unknown source control" } }));
  assert.ok(codes(normalized.issues).includes("unknown_label:null"));
  assert.equal(normalized.facts[0].label, "constructor");
});
