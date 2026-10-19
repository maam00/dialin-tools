/** Reproducible, source-bound interpretation of published controls; never a rendered-photo evaluation. */
import { EXPERT_SOURCES, SETTING_KNOWLEDGE, SIMULATION_PROFILES } from "../../lib/plan/expert-knowledge.js";
import type { RecipeReference } from "./knowledge.js";

export const RECIPE_ANALYSIS_VERSION = "dialin.recipe-settings-analysis.v1";
type Value = string | number | boolean;
export type RecipeControlEvidence = { field: `fields.${string}` | `native.${string}`; value: Value };
export type RecipeAnalysisStatement = {
  id: string; kind: "setting_interpretation" | "design_hypothesis" | "limitation"; text: string;
  controls: RecipeControlEvidence[]; knowledge_ids: string[]; sources: { title: string; url: string }[];
};
export type RecipeAnalysisTraits = {
  rendering: "color" | "monochrome" | "sepia" | "unknown";
  wb_mode: "adaptive" | "fixed" | "custom" | "unknown";
  wb_versatility: "adaptive_with_caveats" | "illumination_sensitive" | "measured_light_only" | "unknown";
  warm_cast_risk: "elevated" | "possible" | "not_indicated" | "not_applicable" | "unknown";
  /** These tone labels describe explicit H/S adjustments, not contrast measured across simulations. */
  contrast: "hard" | "soft" | "mixed" | "baseline" | "unknown";
  highlight_rendering: "softened" | "hardened" | "baseline" | "auto_governed" | "unknown";
  color_intensity: "vivid" | "restrained" | "baseline" | "not_applicable" | "unknown";
  /** Added grain strength only; ISO noise and clarity/sharpening remain separate observations. */
  texture: "strong" | "moderate" | "restrained" | "unknown";
  iso_pressure: "raised_floor" | "auto_limited" | "not_indicated" | "unknown";
  clarity_delay: "present" | "not_indicated" | "unknown";
};
export type RecipeSettingsAnalysis = {
  schema_version: typeof RECIPE_ANALYSIS_VERSION;
  binding: { record_id: string; source_url: string; public_facts_sha256: string; source_fact_signature: string };
  evidence: "reproducible_settings_rules"; photographic_validation: "not_verified"; camera_ready: false;
  status: "assessed" | "conditional" | "insufficient_facts";
  traits: RecipeAnalysisTraits; semantic_tags: string[];
  observations: RecipeAnalysisStatement[]; interactions: RecipeAnalysisStatement[];
  best_fit: RecipeAnalysisStatement[]; cautions: RecipeAnalysisStatement[]; adaptations: RecipeAnalysisStatement[];
  missing_controls: string[]; inactive_controls: string[]; limits: string[];
};

const rules = new Map(SETTING_KNOWLEDGE.map((rule) => [rule.id, rule]));
const profiles = new Map(SIMULATION_PROFILES.map((profile) => [profile.simulation, profile]));
const unknownTraits = (): RecipeAnalysisTraits => ({ rendering: "unknown", wb_mode: "unknown", wb_versatility: "unknown", warm_cast_risk: "unknown", contrast: "unknown", highlight_rendering: "unknown", color_intensity: "unknown", texture: "unknown", iso_pressure: "unknown", clarity_delay: "unknown" });

/** The caller validates the catalog; this function never invents absent controls or rewrites source facts. */
export function analyzeRecipe(reference: RecipeReference): RecipeSettingsAnalysis {
  const facts = reference.source_facts;
  const f = facts.fields;
  const n = facts.native;
  const available: RecipeControlEvidence[] = [
    ...Object.entries(f).map(([field, value]) => ({ field: `fields.${field}` as const, value })),
    ...Object.entries(n).map(([field, value]) => ({ field: `native.${field}` as const, value })),
  ];
  const controls = (...keys: string[]) => available.filter((item) => keys.includes(item.field));
  const output: RecipeSettingsAnalysis = {
    schema_version: RECIPE_ANALYSIS_VERSION,
    binding: { record_id: reference.id, source_url: reference.source_url, public_facts_sha256: reference.public_facts_sha256, source_fact_signature: reference.source_fact_signature },
    evidence: "reproducible_settings_rules", photographic_validation: "not_verified", camera_ready: false,
    status: !available.length ? "insufficient_facts" : reference.source_record_status === "public_settings" && facts.status === "normalized" ? "assessed" : "conditional",
    traits: unknownTraits(), semantic_tags: [], observations: [], interactions: [], best_fit: [], cautions: [], adaptations: [],
    missing_controls: facts.missing_fields.map((field) => `fields.${field}`),
    inactive_controls: facts.inactive_fields.map((field) => `fields.${field}`),
    limits: [
      "Rule-based interpretation of published settings; no recipe was rendered, photographed, rated for beauty or physically tested by this analysis.",
      "Source generation groups are discovery metadata, not verified camera compatibility or writable codes. Complete source facts do not make a reference camera-ready.",
      "Best-fit statements and adaptation suggestions are conditional design hypotheses. Preserve photographer intent; changed values create an adaptation, not an exact creator recipe.",
      "Unpublished native controls remain unknown, including D Range Priority and monochromatic tint. Traits describe the known controls, not guaranteed active camera state or measured output.",
    ],
  };
  const statement = (id: string, kind: RecipeAnalysisStatement["kind"], text: string, evidence: RecipeControlEvidence[], ids: string[]): RecipeAnalysisStatement => {
    const sourceIDs = new Set<keyof typeof EXPERT_SOURCES>();
    for (const key of ids) {
      const rule = rules.get(key);
      if (rule) for (const source of rule.sources) sourceIDs.add(source);
      const profile = SIMULATION_PROFILES.find((item) => item.id === key);
      if (profile) sourceIDs.add(profile.source);
    }
    return { id, kind, text, controls: evidence, knowledge_ids: ids, sources: [...sourceIDs].map((key) => ({ ...EXPERT_SOURCES[key] })) };
  };
  const add = (section: "observations" | "interactions" | "best_fit" | "cautions" | "adaptations", id: string, text: string, evidence: RecipeControlEvidence[], ids: string[] = []) => {
    if (!evidence.length || (section === "interactions" && evidence.length < 2)) return;
    output[section].push(statement(id, section === "best_fit" || section === "adaptations" || section === "interactions" ? "design_hypothesis" : section === "cautions" ? "limitation" : "setting_interpretation", text, evidence, ids));
  };
  const tag = (...tags: string[]) => output.semantic_tags.push(...tags);
  if (!available.length) {
    output.limits.push("This linked reference has no published setting facts. Do not infer simulation, scene suitability, recipe values or adaptation from its title.");
    return output;
  }
  if (output.status === "conditional") output.limits.push("Partial or ambiguous source: interpretations apply only to explicit controls. Resolve source issues and missing active controls before constructing a complete recipe.");
  if (facts.issues.length) output.limits.push(`Unresolved source classifications: ${facts.issues.map((issue) => `${issue.code}:${issue.field ?? "record"}`).join(", ")}.`);

  const t = output.traits;
  const sim = f.film_sim;
  const profile = sim ? profiles.get(sim) : undefined;
  const mono = sim !== undefined && /^(Acros|Monochrome)(\+|$)/.test(sim);
  const sepia = sim === "Sepia";
  const colorRendering = !!sim && !mono && !sepia;
  const simControls = controls("fields.film_sim");
  const simIDs = profile ? [profile.id] : [];
  if (sim) {
    t.rendering = mono ? "monochrome" : sepia ? "sepia" : "color";
    tag(t.rendering);
    add("observations", "simulation", `${sim}: ${profile?.character ?? "Known simulation; photographic response remains scene-dependent."}`, simControls, simIDs);
    if (profile) {
      add("best_fit", "simulation-intent", profile.consider, simControls, simIDs);
      add("cautions", "simulation-tradeoff", profile.watch, simControls, simIDs);
    }
    if (mono) {
      tag("form", "gesture", "luminance", "black and white");
      add("cautions", "color-story", "This monochrome base discards color distinctions. Exclude it when the photographer requires all-color images or color is essential to the story.", simControls, ["intent-scope"]);
    }
    if (sepia) add("cautions", "sepia-is-not-warm-color", "Sepia is brown-toned monochrome, not a warm full-color option. Do not select it for an all-color brief.", simControls, simIDs);
    if (sim.endsWith("+R") || sim.endsWith("+Ye")) add("observations", "monochrome-filter", "The filter changes subject-color separation in monochrome. Red filtering lightens reds relative to blues and darkens blue skies more than yellow filtering; it does not darken red subjects simply because it is red.", simControls, ["monochrome-filter-direction"]);
    if (sim.endsWith("+G")) add("observations", "monochrome-green-filter", "Green filtering changes skin/foliage tonal separation; this is not skin smoothing or a universal portrait improvement.", simControls, ["monochrome-filters"]);
  }

  const wb = f.white_balance;
  const wbControls = controls("fields.white_balance", "fields.kelvin", "fields.wb_shift_r", "fields.wb_shift_b", "native.auto_wb_priority");
  if (wb) {
    t.wb_mode = wb.startsWith("Auto") ? "adaptive" : wb.startsWith("Custom") ? "custom" : "fixed";
    t.wb_versatility = t.wb_mode === "adaptive" ? "adaptive_with_caveats" : t.wb_mode === "custom" ? "measured_light_only" : "illumination_sensitive";
    add("observations", "white-balance", `${wb}${wb === "Kelvin" ? f.kelvin === undefined ? " with no published temperature" : ` at ${f.kelvin} K` : ""}: ${t.wb_mode === "adaptive" ? "responds to illumination; its behavior still depends on the subject and light" : t.wb_mode === "custom" ? "depends on a measured custom balance that is not contained in these numerical facts" : "a fixed balance setting used while the real illumination can change"}.${mono || sepia ? " This monochrome base does not produce a full-color skin-rendering result." : ""}`, wbControls, ["wb-source", "wb-mixed"]);
    if (colorRendering && t.wb_mode === "adaptive") tag("changing light", "adaptive white balance");
    if (t.wb_mode === "fixed" && colorRendering) {
      tag("fixed white balance");
      add("cautions", "fixed-wb-transitions", "Check this fixed WB when moving among daylight, shade, tungsten and LEDs. Its source reference does not establish neutral color in each light.", wbControls, ["wb-mixed", "wb-flash"]);
      add("adaptations", "changing-light-wb", "If the shoot crosses different light sources and the existing cast is unwanted, consider an adaptive or measured WB for the dominant subject light; then revisit shifts. This changes the creator recipe.", wbControls, ["wb-source", "wb-mixed"]);
    }
    if (wb === "Kelvin" && f.kelvin !== undefined) add("observations", "kelvin-direction", "For the same illumination, increasing the camera Kelvin setting generally warms the rendering and decreasing it cools it. This number is not a measurement of this shoot's actual light.", controls("fields.white_balance", "fields.kelvin"), ["wb-kelvin-render"]);
    if (colorRendering && (wb === "Auto Ambience" || n.auto_wb_priority === "Ambience")) add("observations", "ambience-priority", "Ambience Priority is intended to retain more lighting ambience, so it is not a promise of neutral skin under warm lighting.", wbControls, ["wb-source", "wb-outcome-uncertainty"]);
    if (colorRendering && (wb === "Auto White Priority" || n.auto_wb_priority === "White")) add("observations", "white-priority", "White Priority aims to reduce lighting cast. Mixed light, LEDs and the published shifts still affect the resulting colors.", wbControls, ["wb-source", "wb-outcome-uncertainty"]);
  }
  if (f.wb_shift_r !== undefined || f.wb_shift_b !== undefined) {
    const shift = [f.wb_shift_r === undefined ? null : `R ${f.wb_shift_r > 0 ? "+" : ""}${f.wb_shift_r}`, f.wb_shift_b === undefined ? null : `B ${f.wb_shift_b > 0 ? "+" : ""}${f.wb_shift_b}`].filter(Boolean).join(", ");
    add("observations", "wb-shift", `${shift}. Positive R biases toward red, negative R toward cyan; positive B toward blue, negative B toward yellow. The effect combines with the WB mode and real illumination; missing axes remain unknown.`, controls("fields.wb_shift_r", "fields.wb_shift_b", "fields.white_balance"), ["wb-source", "wb-outcome-uncertainty"]);
  }
  if (mono || sepia) {
    t.warm_cast_risk = "not_applicable";
    add("cautions", "monochrome-wb-is-not-toning", "Do not interpret WB shifts as a warm full-color cast or as dedicated monochromatic toning. The camera's mono tint controls are separate, and current upload mapping is a separate limitation.", [...simControls, ...wbControls], ["monochrome-filters", "workflow-seven"]);
  } else if (colorRendering) {
    const strongWarmShift = f.wb_shift_b !== undefined && f.wb_shift_b <= -3 && f.wb_shift_r !== undefined && f.wb_shift_r > 0;
    const warmKelvin = wb === "Kelvin" && f.kelvin !== undefined && f.kelvin >= 6500;
    t.warm_cast_risk = strongWarmShift || sim === "Nostalgic Neg" || warmKelvin ? "elevated" : (f.wb_shift_r ?? 0) > 0 || (f.wb_shift_b ?? 0) < 0 || wb === "Auto Ambience" || n.auto_wb_priority === "Ambience" ? "possible" : wb && f.wb_shift_r !== undefined && f.wb_shift_b !== undefined ? "not_indicated" : "unknown";
    add("cautions", "skin-cast-uncertainty", "Neither these WB values nor a skin-oriented simulation guarantee neutral skin. Evaluate the actual dominant light and any observed cast; a single global WB cannot neutralize different-colored light across a face.", [...simControls, ...wbControls], ["wb-outcome-uncertainty", "wb-mixed"]);
    if (t.warm_cast_risk === "elevated" || t.warm_cast_risk === "possible") {
      const coherentWarmBias = f.wb_shift_r !== undefined && f.wb_shift_b !== undefined && f.wb_shift_r >= 0 && f.wb_shift_b <= 0 && (f.wb_shift_r > 0 || f.wb_shift_b < 0);
      const warmIntentCandidate = coherentWarmBias || sim === "Nostalgic Neg" || warmKelvin;
      if (warmIntentCandidate) tag("warm interpretation");
      if (t.warm_cast_risk === "elevated") tag("warm cast risk");
      add("interactions", "warmth-stack", "A warm base character, WB mode or red/yellow-biased shift can contribute warmth, while any opposing shift can offset part of it. Under already-warm light, faces or pale objects may become warmer than intended; this is a risk hypothesis, not a predicted skin-color result.", [...simControls, ...wbControls], ["wb-mixed", "wb-outcome-uncertainty"]);
      add("adaptations", "reduce-observed-warm-cast", "If faces actually look too warm and that conflicts with intent, diagnose the light first; reduce a contributing warm shift or change WB before replacing unrelated tone/texture settings. Keep wanted room ambience in view.", [...simControls, ...wbControls], ["wb-source", "wb-outcome-uncertainty"]);
      if (warmIntentCandidate) add("best_fit", "deliberate-warmth", "Consider when an intentionally warm interpretation is wanted and important skin/neutral colors can be checked under the actual light.", [...simControls, ...wbControls], ["taste-intent", "wb-outcome-uncertainty"]);
    }
  }

  const h = f.highlight;
  const s = f.shadow;
  const toneControls = controls("fields.highlight", "fields.shadow", "native.dr_priority");
  const priority = n.dr_priority !== undefined && n.dr_priority !== "Off";
  if (priority) {
    t.highlight_rendering = "auto_governed";
    t.iso_pressure = "auto_limited";
    add("cautions", "dr-priority-overrides", "Active D Range Priority governs DR and tone curve automatically. Do not describe the independent published highlight/shadow settings as the guaranteed active curve.", controls("native.dr_priority", "fields.dynamic_range", "fields.highlight", "fields.shadow"), ["dr-priority"]);
  } else {
    if (h !== undefined) t.highlight_rendering = h < 0 ? "softened" : h > 0 ? "hardened" : "baseline";
    if (h !== undefined && s !== undefined) t.contrast = h * s < 0 ? "mixed" : h > 0 || s > 0 ? "hard" : h < 0 || s < 0 ? "soft" : "baseline";
  }
  if (h !== undefined || s !== undefined) {
    add("observations", "tone-curve", `${h !== undefined ? `Highlight ${h}: ${h < 0 ? "softened" : h > 0 ? "hardened" : "baseline"} highlight rendering.` : "Highlight control is unknown."} ${s !== undefined ? `Shadow ${s}: ${s < 0 ? "softened" : s > 0 ? "hardened" : "baseline"} shadow rendering.` : "Shadow control is unknown."} These controls act on the simulation's own curve; they do not recover clipped capture data.${priority ? " D Range Priority overrides independent application here." : ""}`, toneControls, ["tone-curve", "dr-priority"]);
    if (!priority && t.contrast === "hard") {
      tag("contrast", "graphic", "flat light");
      add("best_fit", "flat-light-separation", "Consider for deliberate tonal separation in flatter light. Check important faces and shadow detail before applying the same curve in harsh light.", [...simControls, ...toneControls], ["tone-curve", "taste-intent"]);
      add("adaptations", "hard-light-tones", "If important face or shadow detail is too harsh, soften the contributing highlight or shadow control; inspect exposure independently. Preserve the other parts of the rendering unless they also conflict with intent.", toneControls, ["tone-curve", "exposure-render"]);
    }
    if (!priority && t.contrast === "soft") {
      tag("gentle tones", "soft contrast");
      add("best_fit", "gentle-tonal-intent", "Consider when gentle transitions or a quiet interpretation are wanted; in flat light, verify the subject still separates from the background.", [...simControls, ...toneControls], ["tone-curve", "taste-intent"]);
    }
    if (!priority && t.contrast === "mixed") add("interactions", "asymmetric-tone-curve", `Highlight ${h} and Shadow ${s} move different parts of the curve in opposite directions. This is not uniformly high or low contrast: assess bright subjects and dark subjects separately.`, toneControls, ["tone-curve", "taste-intent"]);
    if (!priority && s !== undefined && s > 0 && h === undefined) add("adaptations", "partial-shadow-curve", "If dark faces or important shadow texture become too hard, soften the known Shadow control and inspect exposure. The missing Highlight setting remains unknown; do not construct a complete tone curve from this partial source.", controls("fields.shadow"), ["tone-curve", "exposure-render"]);
  }
  const dr = f.dynamic_range;
  const drControls = controls("fields.dynamic_range", "native.dynamic_range_auto", "native.dr_priority", "native.iso", "native.iso_auto_max", "native.iso_min", "native.iso_max");
  if (dr || n.dynamic_range_auto) {
    t.iso_pressure = dr === "DR200" || dr === "DR400" ? "raised_floor" : dr === "Auto" || n.dynamic_range_auto ? "auto_limited" : "not_indicated";
    add("observations", "dynamic-range", dr === "DR200" || dr === "DR400" ? `${dr} uses a raised minimum ISO. For X100VI specifically, DR200 requires ISO 250+ and DR400 ISO 500+; other bodies require their own manual. This is a highlight-rendering/exposure tradeoff, not recovery of already clipped data.` : dr === "Auto" || n.dynamic_range_auto ? "Auto DR may choose DR100 or DR200 on X100VI; it does not select DR400. Source-camera behavior and ISO limits must be checked separately." : "DR100 does not impose the raised DR200/DR400 ISO floor. It does not guarantee sufficient highlight detail for a high-contrast scene.", drControls, ["dr-iso", "dr-scene-strategy", "tone-curve"]);
    if (priority) t.iso_pressure = "auto_limited";
    if (!priority && (dr === "DR200" || dr === "DR400") && h !== undefined) {
      add("interactions", "dr-and-highlight-curve", h < 0 ? "Raised DR plus softened highlights can support a gentler bright-tone rendering when important highlights warrant it. The ISO/exposure cost and capture clipping still need separate judgment." : "Raised DR and a harder or baseline highlight curve can coexist: capture/exposure strategy and the desired bright-tone rendering are different choices. DR alone does not make a gentle highlight look.", [...drControls, ...controls("fields.highlight")], ["dr-scene-strategy", "tone-curve"]);
      if (h < 0) {
        tag("bright highlights", "high contrast light", "gentle highlights");
        add("best_fit", "important-highlight-detail", "A candidate for scenes with important bright detail and a gentle highlight intention, provided the DR ISO floor, shutter needs and actual exposure are acceptable.", [...drControls, ...controls("fields.highlight")], ["dr-scene-strategy", "exposure-render"]);
      }
    }
    if (!priority && (dr === "DR200" || dr === "DR400")) add("adaptations", "dr-under-low-light", "For dim scenes or moving subjects, weigh the raised DR ISO floor against needed shutter speed and highlight detail. Select DR for real contrast; do not lower it merely to diversify a palette or raise it because the name sounds cinematic.", drControls, ["dr-scene-strategy", "exposure-render"]);
    if (!priority && dr === "DR100" && h !== undefined && h > 0) add("interactions", "dr100-hard-highlights", "DR100 together with harder highlight rendering can suit an intentionally graphic interpretation but needs care around important bright detail. Neither lowering the tone control nor changing DR recovers already-clipped capture data.", controls("fields.dynamic_range", "fields.highlight"), ["dr-scene-strategy", "tone-curve"]);
  }
  const isoControls = controls("native.iso", "native.iso_auto_max", "native.iso_min", "native.iso_max");
  if (isoControls.length) {
    add("observations", "iso-controls", `Published ISO controls: ${isoControls.map((item) => `${item.field.slice(7)}=${item.value}`).join(", ")}. An Auto ISO ceiling is an allowed maximum, not the ISO that will be used; no minimum shutter speed is supplied by these facts.`, isoControls, ["dr-iso", "exposure-render"]);
    if (typeof n.iso === "number" && n.iso >= 3200) tag("high ISO texture");
  }
  const exposureControls = controls("native.exposure_compensation", "native.exposure_compensation_min", "native.exposure_compensation_max");
  if (exposureControls.length) add("cautions", "exposure-hints", `Published compensation ${exposureControls.map((item) => `${item.field.slice(7)}=${item.value} EV`).join(", ")} is a starting hint. Metering, subject brightness, motion and important highlights govern exposure; do not apply it universally or treat it as a recipe's measured optimum.`, exposureControls, ["exposure-render"]);

  const colorControls = controls("fields.color", "fields.color_chrome", "fields.color_chrome_fx_blue");
  if (mono || sepia) {
    t.color_intensity = "not_applicable";
    if (colorControls.length) add("observations", "inactive-color-controls", "Published color/chrome values do not make this monochrome or sepia simulation a vivid color recipe. Exclude those values from color-intensity and saturated-color fit reasoning.", [...simControls, ...colorControls], ["intent-scope", "chrome-color"]);
  } else if (colorRendering) {
    const vividBase = sim === "Velvia";
    const restrainedBase = ["Classic Chrome", "Pro Neg Std", "Eterna", "Eterna Bleach Bypass"].includes(sim!);
    t.color_intensity = restrainedBase && f.color !== undefined && f.color >= 2 ? "unknown" : f.color !== undefined && f.color >= 2 ? "vivid" : f.color !== undefined && f.color <= -2 ? "restrained" : vividBase ? "vivid" : restrainedBase ? "restrained" : f.color !== undefined ? "baseline" : "unknown";
    if (f.color !== undefined) add("observations", "color-strength", `Color ${f.color} ${f.color > 0 ? "increases" : f.color < 0 ? "reduces" : "leaves the baseline"} color strength relative to ${sim}. It is not interchangeable with Color Chrome tonal depth.`, [...simControls, ...controls("fields.color")], ["chrome-color", ...simIDs]);
    if (restrainedBase && f.color !== undefined && f.color >= 2) {
      tag("raised color");
      add("interactions", "restrained-base-raised-color", `Raised Color on ${sim} increases color relative to that restrained base. It does not establish a vivid result relative to other simulations; compare actual important hues before assigning a vivid or muted overall label.`, [...simControls, ...controls("fields.color")], [...simIDs, "taste-intent"]);
    }
    if (t.color_intensity === "vivid") {
      tag("vivid", "colorful", "nature", "landscape");
      add("best_fit", "vivid-color-intent", "Consider for deliberately vivid nature, flowers or color-led scenes. Inspect already-saturated subjects and faces before assuming the same strength is desirable everywhere.", [...simControls, ...controls("fields.color")], ["taste-intent", "texture-restraint"]);
    }
    if (t.color_intensity === "restrained") {
      tag("muted", "restrained color", "documentary");
      add("best_fit", "quiet-color-intent", "Consider for a restrained color story or documentary interpretation; ensure colors needed for the subject or series remain distinguishable.", [...simControls, ...controls("fields.color")], ["taste-intent"]);
    }
  }
  if (colorRendering || !sim) {
    if (f.color_chrome !== undefined) add("observations", "color-chrome", `Color Chrome ${f.color_chrome}: ${f.color_chrome === "Off" ? "no added depth from this effect" : "tonal depth in saturated colors, especially reds/yellows/greens"}. It is not simply saturation.${!sim ? " Its active relevance is conditional until the simulation is known." : ""}`, controls("fields.color_chrome", "fields.film_sim"), ["chrome-color"]);
    if (f.color_chrome_fx_blue !== undefined) add("observations", "blue-chrome", `FX Blue ${f.color_chrome_fx_blue} controls blue tonal depth independently of general Color Chrome and Color.${!sim ? " Its active relevance is conditional until the simulation is known." : ""} No universal strength correction follows from the source generation group.`, controls("fields.color_chrome_fx_blue", "fields.film_sim"), ["chrome-blue", "recipe-provenance"]);
    if (colorRendering && f.color_chrome_fx_blue === "Strong") {
      tag("blue depth");
      add("cautions", "blue-story", "Strong blue depth may make skies, water or blue clothing denser than wanted. Check those actual subjects; the source's X-Trans group does not justify a blanket blue correction.", controls("fields.color_chrome_fx_blue", "fields.film_sim"), ["chrome-blue", "recipe-provenance"]);
    }
    if (colorRendering && f.color !== undefined && f.color > 0 && f.color_chrome === "Strong") add("interactions", "color-depth-stack", "Raised Color plus Strong Color Chrome combines stronger color with additional saturated-color depth. Consider the difference between an intentional rich palette and losing separation in already-dense colors.", controls("fields.color", "fields.color_chrome", "fields.film_sim"), ["chrome-color", "texture-restraint"]);
  }

  const grainControls = controls("fields.grain", "native.grain_strength", "native.grain_size");
  const grainStrength = f.grain?.split(" ")[0] ?? n.grain_strength;
  const grainSize = f.grain?.split(" ")[1] ?? n.grain_size;
  if (grainStrength) {
    t.texture = grainStrength === "Strong" ? "strong" : grainStrength === "Weak" ? "moderate" : "restrained";
    tag(grainStrength === "Strong" ? "strong grain" : grainStrength === "Weak" ? "subtle grain" : "grain off");
    add("observations", "grain", `Grain ${grainStrength}${grainStrength === "Off" ? "" : grainSize ? ` / ${grainSize}` : " / size unknown"}. Added grain is separate from capture noise and optical diffusion; an unpublished size is not assumed Small.`, grainControls, ["grain-texture", "texture-restraint"]);
    if (grainStrength === "Strong") {
      add("best_fit", "intentional-visible-texture", "Consider when visible texture supports the intended documentary or tactile treatment; judge at the final print/display size.", grainControls, ["grain-texture", "texture-restraint"]);
      add("adaptations", "texture-for-clean-delivery", "If the photographer wants cleaner detail or smooth skin, reduce added grain before changing unrelated WB or simulation. Keep capture noise and processing texture separate.", grainControls, ["grain-texture", "texture-restraint"]);
    }
  }
  const textureControls = controls("fields.clarity", "fields.sharpness", "fields.noise_reduction");
  if (f.clarity !== undefined) {
    t.clarity_delay = f.clarity === 0 ? "not_indicated" : "present";
    add("observations", "clarity", `Clarity ${f.clarity}: ${f.clarity < 0 ? "softer local texture" : f.clarity > 0 ? "stronger local texture" : "no added clarity adjustment"}.${f.clarity !== 0 ? " Nonzero Clarity increases save time; no fixed one-second delay is claimed." : " This does not prove uninterrupted burst throughput."} It does not create optical diffusion or halation.`, controls("fields.clarity"), ["clarity-speed", "texture-restraint"]);
    if (f.clarity !== 0) {
      tag("clarity save delay");
      add("adaptations", "responsive-capture", "For fast gestures, children or action where responsiveness matters, consider Clarity 0 and accept the changed local texture. This is an adaptation of the source and does not guarantee burst speed.", controls("fields.clarity"), ["clarity-speed"]);
    } else tag("zero clarity");
  }
  if (f.sharpness !== undefined) add("observations", "sharpness", `Sharpness ${f.sharpness} adjusts edge processing; it cannot repair missed focus or motion blur. Judge it alongside the existing texture controls at delivery size.`, controls("fields.sharpness"), ["texture-restraint", "exposure-render"]);
  if (f.noise_reduction !== undefined) add("observations", "noise-reduction", `High ISO NR ${f.noise_reduction}: ${f.noise_reduction < 0 ? "less smoothing, retaining more visible outlines/noise" : f.noise_reduction > 0 ? "more smoothing, trading fine texture for noise suppression" : "baseline smoothing"}. Neither minimum nor maximum is universally best.`, controls("fields.noise_reduction"), ["nr-detail"]);
  if (grainStrength && grainStrength !== "Off" && f.noise_reduction !== undefined && f.noise_reduction < 0) add("interactions", "grain-and-noise", `${grainStrength} added grain plus low High ISO NR can retain capture noise while adding a separate texture layer. The combined appearance may be useful or too busy depending on ISO, subject and output size.`, [...grainControls, ...controls("fields.noise_reduction", "native.iso", "native.iso_auto_max")], ["grain-texture", "nr-detail", "texture-restraint"]);
  if (f.clarity !== undefined && f.sharpness !== undefined && ((f.clarity > 0 && f.sharpness > 0) || (f.clarity < 0 && f.sharpness < 0))) add("interactions", "edge-texture-stack", f.clarity > 0 ? "Positive Clarity and sharpening can reinforce edge/local contrast. Check faces, foliage and fine high-contrast edges before equating more bite with better detail." : "Negative Clarity and sharpening reduce two aspects of processed crispness. This can support gentler rendering, but neither changes focus, depth of field or lens diffusion.", textureControls, ["texture-restraint", "clarity-speed"]);
  if (f.clarity !== undefined && f.sharpness !== undefined && f.clarity * f.sharpness < 0) add("interactions", "edge-texture-opposition", "Clarity and sharpening move in opposite directions. Local texture and edge processing are distinct controls, so do not assume the values cancel or that this is uniformly soft or crisp.", textureControls, ["texture-restraint", "clarity-speed"]);
  if (f.sharpness !== undefined && f.sharpness < 0 && f.noise_reduction !== undefined && f.noise_reduction < 0) {
    add("interactions", "edge-noise-balance", "Reduced edge sharpening coexists with reduced noise smoothing. This can leave visible texture without as much processed edge bite; it does not imply missed focus, film equivalence or optically diffused light.", controls("fields.sharpness", "fields.noise_reduction"), ["nr-detail", "texture-restraint"]);
    add("adaptations", "edge-noise-adjustment", "When reviewing actual photographs, distinguish visible noise from weak edge crispness. Adjust the corresponding NR or sharpening control independently; do not replace the whole recipe or invent missing controls.", controls("fields.sharpness", "fields.noise_reduction"), ["nr-detail", "texture-restraint"]);
  }

  const monoControls = controls("native.mono_wc", "native.mono_mg");
  if (monoControls.length) add("observations", "mono-toning", `Published monochromatic tint axes: ${monoControls.map((item) => `${item.field.slice(7)}=${item.value}`).join(", ")}. ${mono ? "These are separate from WB shift; preserve their values when reasoning about tone." : "Their relevance remains conditional on a compatible monochrome simulation; do not infer that simulation from the recipe title."} Camera availability and upload mapping require separate verification.`, [...simControls, ...monoControls], ["monochrome-filters", "workflow-seven"]);
  const otherNative = controls("native.smooth_skin", "native.long_exposure_nr", "native.color_space");
  if (otherNative.length) add("cautions", "native-output-controls", `Additional published controls: ${otherNative.map((item) => `${item.field.slice(7)}=${item.value}`).join(", ")}. Preserve them in the source description; they are not silently represented or guaranteed transferable by the core recipe writer.`, otherNative, ["workflow-seven", "recipe-provenance"]);
  if (n.dr_priority === "Off") add("observations", "dr-priority-off", "D Range Priority is explicitly Off, so it does not automatically override the independently supplied DR/tone controls.", controls("native.dr_priority"), ["dr-priority"]);

  // Even unusual partial records retain every explicit fact without assigning an unsupported aesthetic meaning.
  const described = new Set([...output.observations, ...output.interactions, ...output.cautions, ...output.best_fit, ...output.adaptations].flatMap((item) => item.controls.map((control) => control.field)));
  const unclassified = available.filter((item) => !described.has(item.field));
  if (unclassified.length) add("cautions", "unresolved-control-relevance", `These explicit controls remain available, but their active aesthetic relevance cannot be inferred safely from the other known facts: ${unclassified.map((item) => `${item.field}=${item.value}`).join(", ")}.`, unclassified, ["recipe-provenance"]);
  output.semantic_tags = [...new Set(output.semantic_tags)];
  return output;
}

export function analyzeRecipeCatalog(references: readonly RecipeReference[]) {
  const analyses = references.map(analyzeRecipe);
  const statuses = { assessed: 0, conditional: 0, insufficient_facts: 0 };
  for (const analysis of analyses) statuses[analysis.status]++;
  return {
    schema_version: RECIPE_ANALYSIS_VERSION,
    coverage: { references: references.length, fact_bearing: analyses.filter((item) => item.status !== "insufficient_facts").length, ...statuses,
      with_interactions: analyses.filter((item) => item.interactions.length).length,
      with_adaptations: analyses.filter((item) => item.adaptations.length).length,
      photographed: 0, hardware_tested: 0, human_preference_evaluated: 0 },
    analyses,
  };
}
