// Parse public label/value facts only. No source prose, inferred defaults, camera writes or creator-style adaptation.
import type { CameraCaps } from "../cameras.js";
import type { RecipeFields } from "../plan/types.js";
import type { NativeFilmSimulation, NativeRecipeSettings, NativeWhiteBalance, NormalizationIssue, NormalizedRecipe,
  NormalizedSettingFact, NormalizedSettingKey, RawRecipeRecord, RecipeCameraAssessment, RecipeSettingKey } from "./types.js";

// Official labels/aliases: https://fujifilm-dsc.com/en/manual/x100vi/menu_shooting/image_quality_setting/
const key = (value: string) => value.normalize("NFKC").toLowerCase().replace(/[−–]/g, "-").replace(/[^a-z0-9]/g, "");
const clean = (value: string) => value.normalize("NFKC").replace(/[−–]/g, "-").trim();
const table = <T extends string>(groups: readonly (readonly [T, ...string[]])[]) => new Map(groups.flatMap(([canonical, ...aliases]) => [canonical, ...aliases].map((value) => [key(value), canonical] as const)));
const sims = table<NativeFilmSimulation>([
  ["Provia", "Provia/Standard", "Provia/STD", "Standard"], ["Velvia", "Velvia/Vivid", "Vivid"], ["Astia", "Astia/Soft", "Soft"],
  ["Classic Chrome"], ["Reala Ace"], ["Pro Neg Hi", "Pro Neg. Hi", "Pro Negative High"],
  ["Pro Neg Std", "Pro Neg. Std", "Pro Negative Standard"], ["Classic Neg", "Classic Neg.", "Classic Negative"],
  ["Nostalgic Neg", "Nostalgic Neg.", "Nostalgic Negative"], ["Eterna", "Eterna/Cinema", "Cinema"],
  ["Eterna Bleach Bypass", "Eterna/Bleach Bypass"], ["Acros"], ["Acros+Ye", "Acros+Yellow", "Acros+Ye Filter", "Acros (Ye)"],
  ["Acros+R", "Acros+Red", "Acros+R Filter", "Acros (R)"], ["Acros+G", "Acros+Green", "Acros+G Filter", "Acros (G)"],
  ["Monochrome"], ["Monochrome+Ye", "Monochrome+Yellow", "Monochrome+Ye Filter", "Monochrome (Ye)"],
  ["Monochrome+R", "Monochrome+Red", "Monochrome+R Filter", "Monochrome (R)"],
  ["Monochrome+G", "Monochrome+Green", "Monochrome+G Filter", "Monochrome (G)"], ["Sepia"],
]);
const whiteBalances = table<NativeWhiteBalance>([
  ["Auto", "Auto WB", "AWB"], ["Auto White Priority", "Auto (White Priority)", "White Priority", "Auto WB White Priority"],
  ["Auto Ambience", "Auto Ambience Priority", "Auto (Ambience Priority)", "Ambience Priority", "Auto WB Ambience Priority"],
  ["Daylight", "Fine", "Daylight/Fine", "Fine/Daylight", "Sunny"], ["Shade"], ["Incandescent", "Tungsten"],
  ["Fluorescent 1", "Fluorescent Light-1", "Fluorescent 1 (Daylight Fluorescent)"],
  ["Fluorescent 2", "Fluorescent Light-2", "Fluorescent 2 (Warm White Fluorescent)"],
  ["Fluorescent 3", "Fluorescent Light-3", "Fluorescent 3 (Cool White Fluorescent)"],
  ["Kelvin", "Color Temperature", "Colour Temperature"], ["Underwater"], ["Custom 1"], ["Custom 2"], ["Custom 3"],
]);
const effects = table<"Off" | "Weak" | "Strong">([["Off"], ["Weak"], ["Strong"]]);
const drs = table<"DR100" | "DR200" | "DR400" | "Auto">([["DR100", "100%", "100"], ["DR200", "200%", "200"], ["DR400", "400%", "400"], ["Auto", "DR Auto", "Auto DR"]]);
const priorities = table<"Off" | "Weak" | "Strong" | "Auto">([["Off"], ["Weak"], ["Strong"], ["Auto"]]);
const sizes = table<"Small" | "Large">([["Small"], ["Large"]]);
const onOff = table<"On" | "Off">([["On"], ["Off"]]);
const colorspaces = table<"sRGB" | "Adobe RGB">([["sRGB"], ["Adobe RGB"]]);
const unavailable = (value: string) => /^(?:n\/?a|not available|not applicable|unavailable|none on this camera)$/i.test(value.trim());
const alternatives = (value: string) => value.split(/\s+(?:or|to)\s+|\s*\|\s*|\s*\/\s*/i).map((v) => v.trim()).filter(Boolean);
const numeric = (value: string): number | null => {
  // Older source descriptors do not change the numeric fact, e.g. -2 (Low) is never remapped to -4.
  const match = /^([+-]?\d+(?:\.\d+)?)(?:\s*\((?:low|high|mid|std|standard|soft|hard|medium|medium[ -](?:low|high|soft|hard))\))?$/i.exec(clean(value));
  return match && Number.isFinite(Number(match[1])) ? Number(match[1]) : null;
};

const numericLabels: Record<string, RecipeSettingKey | "mono_wc" | "mono_mg"> = {
  kelvin: "kelvin", colortemperature: "kelvin", colourtemperature: "kelvin", wbshiftr: "wb_shift_r", wbred: "wb_shift_r", red: "wb_shift_r",
  whitebalancered: "wb_shift_r", wbshiftred: "wb_shift_r", wbshiftb: "wb_shift_b", wbblue: "wb_shift_b", blue: "wb_shift_b",
  whitebalanceblue: "wb_shift_b", wbshiftblue: "wb_shift_b", highlight: "highlight", highlights: "highlight", highlighttone: "highlight",
  shadow: "shadow", shadows: "shadow", shadowtone: "shadow", color: "color", colour: "color", sharpness: "sharpness", sharpening: "sharpness", sharpeness: "sharpness",
  noisereduction: "noise_reduction", highisonr: "noise_reduction", highisonoisereduction: "noise_reduction", nr: "noise_reduction",
  clarity: "clarity", monowc: "mono_wc", monochromaticcolorwc: "mono_wc", monochromaticcolourwc: "mono_wc", warmcool: "mono_wc", wc: "mono_wc",
  monomg: "mono_mg", monochromaticcolormg: "mono_mg", monochromaticcolourmg: "mono_mg", magentagreen: "mono_mg", mg: "mono_mg",
};
const enumLabels: Record<string, { field: NormalizedSettingKey; values: ReadonlyMap<string, string> }> = {};
for (const [labels, field, values] of [
  [["film simulation", "film sim", "simulation", "film_sim"], "film_sim", sims],
  [["color chrome effect", "color chrome", "chrome fx", "colour chrome effect"], "color_chrome", effects],
  [["color chrome fx blue", "color chrome effect blue", "color chrome blue", "chrome fx blue", "color_chrome_fx_blue"], "color_chrome_fx_blue", effects],
  [["dynamic range", "dr", "dynamic_range"], "dynamic_range", drs],
  [["d range priority", "dr priority", "dynamic range priority", "dr_priority"], "dr_priority", priorities],
  [["smooth skin effect", "smooth skin", "smooth_skin"], "smooth_skin", effects],
  [["grain strength", "grain roughness", "grain_strength"], "grain_strength", effects],
  [["grain size", "grain_size"], "grain_size", sizes],
  [["long exposure nr", "long exposure noise reduction"], "long_exposure_nr", onOff],
  [["color space", "colour space"], "color_space", colorspaces],
] as const) for (const label of labels) enumLabels[key(label)] = { field, values };

export const SOURCE_RECIPE_FIELDS: readonly RecipeSettingKey[] = ["film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance",
  "wb_shift_r", "wb_shift_b", "dynamic_range", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity"];

export function normalizeRecipe(record: RawRecipeRecord): NormalizedRecipe {
  const raw = structuredClone(record);
  const facts: NormalizedSettingFact[] = [];
  const issues: NormalizationIssue[] = [];
  const parsed = new Map<NormalizedSettingKey, (string | number | boolean)[]>();
  const unavailableFields = new Set<NormalizedSettingKey>();
  const blocked = new Set<NormalizedSettingKey>();
  const issue = (code: NormalizationIssue["code"], field: NormalizedSettingKey | null, label: string, value: string, message: string) => {
    issues.push({ code, severity: "needs_review", field, raw_labels: [label], raw_values: [value], message });
    if (field) blocked.add(field);
  };
  const set = (field: NormalizedSettingKey, value: string | number | boolean, label: string, rawValue: string) => {
    parsed.set(field, [...(parsed.get(field) ?? []), value]);
    facts.push({ field, label, value: rawValue, normalized_value: value, status: "parsed" });
  };
  const missing = (field: NormalizedSettingKey, label: string, value: string) => {
    unavailableFields.add(field);
    facts.push({ field, label, value, status: "unavailable" });
    issue("source_unavailable", field, label, value, "The source explicitly omits this feature; a modern camera default cannot be assumed.");
  };
  const unknown = (field: NormalizedSettingKey | null, label: string, value: string) => {
    const choices = alternatives(value);
    facts.push({ field, label, value, status: choices.length > 1 ? "ambiguous" : "unrecognized", ...(choices.length > 1 ? { alternatives: choices } : {}) });
    issue(choices.length > 1 ? "ambiguous_value" : "unknown_value", field, label, value, "The source value needs review; no value was selected or invented.");
  };
  const enumValue = (field: NormalizedSettingKey, values: ReadonlyMap<string, string>, label: string, value: string, original = value) => {
    if (unavailable(value)) return missing(field, label, original);
    const found = values.get(key(value));
    found === undefined ? unknown(field, label, original) : set(field, found, label, original);
  };
  const numberValue = (field: NormalizedSettingKey, label: string, value: string) => {
    if (unavailable(value)) return missing(field, label, value);
    const found = numeric(field === "kelvin" ? clean(value).replace(/\s*k(?:elvin)?$/i, "") : value);
    found === null ? unknown(field, label, value) : set(field, found, label, value);
  };
  const axes = (label: string, value: string, a: string, b: string, fieldA: NormalizedSettingKey, fieldB: NormalizedSettingKey) => {
    if (/\b(?:or|to)\b|\||\d\s*\/|\/\s*[+-]?\d/i.test(value)) {
      unknown(fieldA, label, value); unknown(fieldB, label, value); return true;
    }
    let found = false;
    for (const [axis, field] of [[a, fieldA], [b, fieldB]] as const) {
      const pattern = new RegExp(`(?:([+-]?\\d+(?:\\.\\d+)?)\\s*${axis}\\b|\\b${axis}\\s*:?\\s*([+-]?\\d+(?:\\.\\d+)?))`, "ig");
      for (const match of clean(value).matchAll(pattern)) { set(field, Number(match[1] ?? match[2]), label, value); found = true; }
    }
    return found;
  };
  if (record.status !== "public_settings") issues.push({ code: "source_status", severity: "needs_review", field: null,
    message: "The source has not supplied one unambiguous public settings record.", raw_labels: [], raw_values: [record.status] });
  else {
    let publicURL = false;
    try { const url = new URL(record.source_url ?? ""); publicURL = url.protocol === "https:" && !url.username && !url.password; } catch { /* unresolved provenance stays unresolved */ }
    if (!publicURL || !record.content_sha256 || !/^[a-f0-9]{64}$/.test(record.content_sha256)) issues.push({
      code: "source_status", severity: "needs_review", field: null,
      message: "A public settings record needs a real public URL and source-content hash; missing provenance is never invented.", raw_labels: [], raw_values: [] });
  }
  for (const [label, value] of Object.entries(record.settings)) {
    const normalizedLabel = key(label);
    if (label === "") { enumValue("film_sim", sims, label, value); continue; } // explicit, uniquely adjacent bare enum; never diagnostic notes/title
    if (Object.hasOwn(numericLabels, normalizedLabel)) { numberValue(numericLabels[normalizedLabel], label, value); continue; }
    if (Object.hasOwn(enumLabels, normalizedLabel)) { const e = enumLabels[normalizedLabel]; enumValue(e.field, e.values, label, value); continue; }
    if (["whitebalance", "wb"].includes(normalizedLabel)) {
      if (unavailable(value)) { missing("white_balance", label, value); continue; }
      const shiftStart = clean(value).search(/[+-]?\d+(?:\.\d+)?\s*(?:red|blue)\b|\b(?:red|blue|r|b)\s*:?\s*[+-]?\d+/i);
      const mode = clean(value).slice(0, shiftStart < 0 ? undefined : shiftStart).replace(/[,&; ]+$/, "");
      const kelvin = /^(\d{4,5})\s*k(?:elvin)?$/i.exec(mode);
      if (kelvin) { set("white_balance", "Kelvin", label, value); set("kelvin", Number(kelvin[1]), label, value); }
      else enumValue("white_balance", whiteBalances, label, mode, value);
      axes(label, value, "(?:red|r)", "(?:blue|b)", "wb_shift_r", "wb_shift_b");
      continue;
    }
    if (["wbshift", "whitebalanceshift"].includes(normalizedLabel)) {
      if (!axes(label, value, "(?:red|r)", "(?:blue|b)", "wb_shift_r", "wb_shift_b")) unknown("wb_shift_r", label, value);
      continue;
    }
    if (["monochromaticcolor", "monochromaticcolour", "monochromaticcolortoning", "monochromaticcolourtoning", "monochromecolor", "monochromecolour", "toning"].includes(normalizedLabel)) {
      if (unavailable(value)) { missing("mono_wc", label, value); missing("mono_mg", label, value); }
      else if (!axes(label, value, "wc", "mg", "mono_wc", "mono_mg")) unknown("mono_wc", label, value);
      continue;
    }
    if (["grain", "graineffect"].includes(normalizedLabel)) {
      if (unavailable(value)) { missing("grain", label, value); continue; }
      const combined = /^(off|weak|strong)(?:\s*[,/ -]\s*|\s+)?(small|large)?$/i.exec(clean(value));
      if (!combined) { unknown("grain", label, value); continue; }
      set("grain_strength", effects.get(key(combined[1]))!, label, value);
      if (combined[2]) set("grain_size", sizes.get(key(combined[2]))!, label, value);
      continue;
    }
    if (["tonecurve", "tone"].includes(normalizedLabel)) {
      if (!axes(label, value, "(?:highlights?|h)", "(?:shadows?|s)", "highlight", "shadow")) unknown("highlight", label, value);
      continue;
    }
    if (["iso", "sensitivity"].includes(normalizedLabel)) {
      const text = clean(value).replace(/\s*\(typically\)$/i, "");
      const automatic = /^auto\s*,?\s*up to\s*(?:iso\s*)?(\d+)$/i.exec(text);
      const range = /^(?:iso\s*)?(\d+)\s*(?:to|-)\s*(?:iso\s*)?(\d+)$/i.exec(text);
      if (/^auto$/i.test(text)) set("iso", "Auto", label, value);
      else if (automatic) { set("iso", "Auto", label, value); set("iso_auto_max", Number(automatic[1]), label, value); }
      else if (range) { set("iso_min", Math.min(Number(range[1]), Number(range[2])), label, value); set("iso_max", Math.max(Number(range[1]), Number(range[2])), label, value); }
      else numberValue("iso", label, value);
      continue;
    }
    if (["exposurecompensation", "expcomp", "ev"].includes(normalizedLabel)) {
      const text = clean(value).replace(/\s*\(typically\)$/i, "");
      const ev = (s: string): number | null => {
        const n = numeric(s); if (n !== null) return n;
        const match = /^([+-]?)\s*(?:(\d+)[ -])?(\d+)\s*\/\s*(\d+)$/.exec(s.trim());
        return match && Number(match[4]) > 0 ? (match[1] === "-" ? -1 : 1) * (Number(match[2] ?? 0) + Number(match[3]) / Number(match[4])) : null;
      };
      const bounds = text.split(/\s+to\s+/i).map(ev);
      if (bounds.length === 2 && bounds.every((n): n is number => n !== null)) {
        set("exposure_compensation_min", Math.min(...bounds), label, value); set("exposure_compensation_max", Math.max(...bounds), label, value);
      } else if (bounds.length === 1 && bounds[0] !== null) set("exposure_compensation", bounds[0], label, value);
      else unknown("exposure_compensation", label, value);
      continue;
    }
    if (["sensor", "sensorgeneration", "camera", "cameras"].includes(normalizedLabel)) {
      facts.push({ field: null, label, value, status: "metadata" }); continue;
    }
    facts.push({ field: null, label, value, status: "unrecognized" });
    issue("unknown_label", null, label, value, "An unrecognized source setting is retained for manual review.");
  }
  const resolved: Partial<Record<NormalizedSettingKey, string | number | boolean>> = {};
  for (const [field, values] of parsed) {
    const distinct = [...new Set(values)];
    if (distinct.length > 1) {
      const evidence = facts.filter((fact) => fact.field === field);
      issues.push({ code: "conflicting_values", severity: "needs_review", field, message: "The source supplies conflicting values; neither is selected.",
        raw_labels: evidence.map((f) => f.label), raw_values: evidence.map((f) => f.value) });
      blocked.add(field);
    }
    if (!blocked.has(field) && distinct.length === 1) resolved[field] = distinct[0];
  }
  if (!blocked.has("grain")) {
    if (resolved.grain_strength === "Off") resolved.grain = "Off";
    else if (resolved.grain_strength && resolved.grain_size) resolved.grain = `${resolved.grain_strength} ${resolved.grain_size}`;
  }
  const fields = Object.fromEntries(Object.entries(resolved).filter(([field]) => [...SOURCE_RECIPE_FIELDS, "kelvin"].includes(field as RecipeSettingKey))) as Partial<RecipeFields>;
  const native = Object.fromEntries(Object.entries(resolved).filter(([field]) => ![...SOURCE_RECIPE_FIELDS, "kelvin"].includes(field as RecipeSettingKey))) as NativeRecipeSettings;
  if (fields.white_balance === "Auto White Priority") native.auto_wb_priority = "White";
  if (fields.white_balance === "Auto Ambience") native.auto_wb_priority = "Ambience";
  if (fields.dynamic_range === "Auto") native.dynamic_range_auto = true;
  const inactive: RecipeSettingKey[] = mono(fields.film_sim) ? ["color", "color_chrome", "color_chrome_fx_blue"] : [];
  const required = [...SOURCE_RECIPE_FIELDS.filter((field) => !inactive.includes(field)), ...(fields.white_balance === "Kelvin" ? ["kelvin" as const] : [])];
  const missingFields = required.filter((field) => fields[field] === undefined);
  const coreIssues = issues.filter((item) => item.field === null || [...SOURCE_RECIPE_FIELDS, "kelvin"].includes(item.field as RecipeSettingKey));
  const publishedCore = { complete: record.status === "public_settings" && !coreIssues.length && !missingFields.length, missing_fields: [...missingFields] };
  return { id: record.id, title: record.title, base_film_sim: (fields.film_sim as NativeFilmSimulation | undefined) ?? null,
    fields, native, source_groups: [...record.groups], raw, facts, issues, missing_fields: missingFields, inactive_fields: inactive,
    published_core: publishedCore, unavailable_fields: [...unavailableFields], status: record.status === "linked_only" || record.status === "unavailable" ? "no_public_settings"
      : issues.length || missingFields.length ? "needs_review" : "normalized", training_export_allowed: false };
}

const mono = (simulation: string | undefined) => /^(?:Acros|Monochrome)(?:\+|$)/.test(simulation ?? "");
const extraNative = new Set<keyof NativeRecipeSettings>(["dr_priority", "smooth_skin", "mono_wc", "mono_mg", "auto_wb_priority", "dynamic_range_auto"]);
const addIssue = (issues: NormalizationIssue[], recipe: NormalizedRecipe, code: NormalizationIssue["code"], field: NormalizedSettingKey,
  message: string, severity: NormalizationIssue["severity"] = "needs_review") => {
  const facts = recipe.facts.filter((fact) => fact.field === field);
  issues.push({ code, severity, field, message, raw_labels: facts.map((fact) => fact.label), raw_values: facts.map((fact) => fact.value) });
};

export function assessRecipeForCamera(recipe: NormalizedRecipe, cam: CameraCaps,
  options: { shootingMode?: "automatic" | "guided" } = {}): RecipeCameraAssessment {
  const exact = structuredClone(recipe.issues);
  const fields = recipe.fields;
  for (const field of recipe.missing_fields) addIssue(exact, recipe, "missing_field", field, "The source does not define this setting; no camera default is assumed.");
  const numeric: [RecipeSettingKey, readonly number[]][] = [["wb_shift_r", cam.shifts], ["wb_shift_b", cam.shifts], ["highlight", cam.tones],
    ["shadow", cam.tones], ["color", cam.color], ["sharpness", cam.sharpness], ["noise_reduction", cam.noiseReduction], ["clarity", cam.clarity]];
  for (const [field, allowed] of numeric) {
    const value = fields[field];
    if (value !== undefined && (typeof value !== "number" || !allowed.includes(value))) addIssue(exact, recipe, "out_of_range", field, "The exact numeric source value is outside this camera's reviewed range.");
  }
  const x100vi = cam.id === "X100VI";
  const nativeWB = x100vi ? [...cam.whiteBalances, "Auto White Priority", "Underwater", "Custom 1", "Custom 2", "Custom 3"] : cam.whiteBalances;
  for (const [field, allowed] of [["film_sim", cam.filmSims], ["grain", cam.grains], ["color_chrome", cam.effects],
    ["color_chrome_fx_blue", cam.effects], ["white_balance", nativeWB], ["dynamic_range", x100vi ? [...cam.dynamicRanges, "Auto"] : cam.dynamicRanges]] as const) {
    if (fields[field] !== undefined && !allowed.includes(fields[field]!)) addIssue(exact, recipe, "unsupported_camera_value", field, "The exact source value is not a reviewed native setting for this camera.");
  }
  if (fields.white_balance === "Kelvin" && fields.kelvin !== undefined) {
    const legal = x100vi ? Number.isInteger(fields.kelvin) && fields.kelvin >= 2500 && fields.kelvin <= 10000 && fields.kelvin % 10 === 0 : cam.kelvins.includes(fields.kelvin);
    if (!legal) addIssue(exact, recipe, "out_of_range", "kelvin", "The exact color temperature is outside this camera's reviewed native values.");
  }
  if (fields.white_balance?.startsWith("Custom ")) addIssue(exact, recipe, "manual_mapping", "white_balance", "A custom WB bank number does not supply its measured white reference; the target camera needs an explicit reference.", "manual_mapping");
  const nativeRequired: (keyof NativeRecipeSettings)[] = x100vi ? ["dr_priority", "smooth_skin", ...(mono(fields.film_sim) ? ["mono_wc", "mono_mg"] as const : [])] : [];
  for (const field of nativeRequired) if (recipe.native[field] === undefined) addIssue(exact, recipe, "missing_field", field, "The source leaves a native rendering control unresolved on this camera; its default cannot be inferred from the source group.");
  for (const field of ["mono_wc", "mono_mg"] as const) {
    const value = recipe.native[field];
    if (value !== undefined && (!x100vi || !Number.isInteger(value) || value < -18 || value > 18)) addIssue(exact, recipe, x100vi ? "out_of_range" : "manual_mapping", field, "Monochromatic color needs this body's reviewed native range.");
  }
  for (const field of ["iso", "iso_auto_max", "iso_min", "iso_max"] as const) if (typeof recipe.native[field] === "number" && !cam.isos.includes(String(recipe.native[field]))) {
    addIssue(exact, recipe, "out_of_range", field, "The source sensitivity is outside this camera's reviewed ISO values.");
  }
  for (const field of ["exposure_compensation", "exposure_compensation_min", "exposure_compensation_max"] as const) {
    const ev = recipe.native[field];
    if (ev !== undefined && (!Number.isFinite(ev) || Math.abs(ev) > 3 || Math.abs(ev * 3 - Math.round(ev * 3)) > 1e-8)) addIssue(exact, recipe, "out_of_range", field, "The exact compensation needs review against the supported dial range and thirds.");
  }
  if (!x100vi) for (const field of Object.keys(recipe.native) as (keyof NativeRecipeSettings)[]) {
    if (extraNative.has(field)) addIssue(exact, recipe, "manual_mapping", field, "This native feature has not been reviewed for the target body.", "manual_mapping");
  }
  if (recipe.native.dr_priority && recipe.native.dr_priority !== "Off") addIssue(exact, recipe, "dependent_setting", "dr_priority", "D Range Priority changes tone curve and dynamic range automatically; the source's fixed tone/DR values cannot all be asserted active.");

  const writes = structuredClone(exact);
  for (const field of recipe.inactive_fields) if (fields[field] === undefined) addIssue(writes, recipe, "manual_mapping", field, "This inactive source field is omitted; the current writer still requires an explicit tuple value, so no default is invented.", "manual_mapping");
  const confirmedEnums = [["film_sim", cam.confirmed.filmSims], ["white_balance", cam.confirmed.whiteBalances],
    ["color", cam.confirmed.color], ["noise_reduction", cam.confirmed.noiseReduction]] as const;
  for (const [field, confirmed] of confirmedEnums) if (fields[field] !== undefined && !(String(fields[field]) in confirmed)) {
    addIssue(writes, recipe, "unconfirmed_code", field, "The camera may have this value, but its exact new-write encoding is not confirmed.", "manual_mapping");
  }
  for (const field of ["grain", "color_chrome", "color_chrome_fx_blue", "dynamic_range", "highlight", "shadow", "sharpness", "clarity", "kelvin", "wb_shift_r", "wb_shift_b"] as const) {
    const codeField = field === "wb_shift_r" || field === "wb_shift_b" ? "wb_shift" : field;
    if (fields[field] !== undefined && !cam.confirmed.wholeRange[codeField]) addIssue(writes, recipe, "unconfirmed_code", field, "The exact field encoding has not been confirmed for this camera.", "manual_mapping");
  }
  for (const field of Object.keys(recipe.native) as (keyof NativeRecipeSettings)[]) if (field !== "grain_strength" && field !== "grain_size") {
    addIssue(writes, recipe, "manual_mapping", field, "This source-native setting is not represented by the current Recipe writer; it cannot be silently discarded, even when neutral.", "manual_mapping");
  }
  if (fields.dynamic_range === "Auto") addIssue(writes, recipe, "manual_mapping", "dynamic_range", "DR Auto is not represented by the current fixed-DR writer.", "manual_mapping");
  if (fields.kelvin === undefined || !cam.kelvins.includes(fields.kelvin)) addIssue(writes, recipe, "manual_mapping", "kelvin", "The current writer requires an explicit supported Kelvin field, including its inactive value; none is invented.", "manual_mapping");
  const changes: RecipeCameraAssessment["automatic_adaptation"]["changes"] = options.shootingMode === "automatic" && typeof fields.clarity === "number" && cam.clarity.includes(fields.clarity) && fields.clarity !== 0
    ? [{ field: "clarity", from: fields.clarity, to: 0, changes_creator_recipe: true }] : [];
  return { camera_model: cam.id, published_core: structuredClone(recipe.published_core), exact_settings: { eligible: exact.length === 0, issues: exact },
    new_write: { supported: writes.length === 0, issues: writes }, automatic_adaptation: { changes, requires_confirmation: changes.length > 0 },
    training_export_allowed: false, photographic_equivalence_verified: false };
}
