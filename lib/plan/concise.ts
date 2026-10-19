// Experimental model wire format only. The saved/native Plan contract is unchanged.
// Settings are always explicit; this adapter never fills missing camera values.
import { RECIPE_KEYS, type ModelLook, type ModelPlan, type PhotographicBrief, type RecipeDesign, type RecipeFields } from "./types.js";

export type ConciseDesign = Pick<RecipeDesign, "purpose" | "scene_fit" | "tradeoff" | "alternative" | "uncertainty"> & {
  knowledge_ids: string[];
};
export type ConciseLook = Omit<ModelLook, "why" | "reason" | "design" | "recipe_reference_id"> & {
  design: ConciseDesign;
  recipe_reference_id: string | null;
};
export type ConcisePlan = Omit<ModelPlan, "looks" | "primary_look" | "photographic_brief"> & {
  looks: ConciseLook[];
  primary_look: string;
  photographic_brief: PhotographicBrief;
};

export class ConcisePlanError extends Error {
  readonly rules: string[];
  constructor(rule: string) {
    super(`Invalid concise plan: ${rule}`);
    this.name = "ConcisePlanError";
    this.rules = [rule];
  }
}

type RecordValue = Record<string, unknown>;
const bad = (rule: string): never => { throw new ConcisePlanError(rule); };
function object(value: unknown, path: string): RecordValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) return bad(`${path} must be an object`);
  return value as RecordValue;
}
function string(value: unknown, path: string): string {
  if (typeof value !== "string") return bad(`${path} must be an explicit string`);
  return value;
}
function nonempty(value: unknown, path: string): string {
  const text = string(value, path);
  if (!text.trim()) return bad(`${path} must not be empty`);
  return text;
}
function number(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return bad(`${path} must be an explicit finite number`);
  return value;
}
function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) return bad(`${path} must be an array`);
  return value;
}
function strings(value: unknown, path: string): string[] {
  return array(value, path).map((item, i) => string(item, `${path}[${i}]`));
}

const NUMERIC_SETTINGS = new Set(["kelvin", "wb_shift_r", "wb_shift_b", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity"]);

/**
 * Expand one independently replaceable look. why and reason are verbatim display aliases of the
 * authored purpose and scene_fit, not additional model judgments. No identity is normalized here.
 * Enum/range, camera-writing, reuse and palette validation remain the engine's responsibility.
 */
export function expandConciseLook(raw: unknown, allowedRecipeIDs: readonly string[] = []): ModelLook {
  const look = object(raw, "look");
  if ("why" in look || "reason" in look) bad("concise looks use design.purpose and design.scene_fit, not separate why/reason fields");
  const design = object(look.design, "look.design");
  const purpose = nonempty(design.purpose, "look.design.purpose");
  const sceneFit = nonempty(design.scene_fit, "look.design.scene_fit");
  const settings = Object.fromEntries(RECIPE_KEYS.filter((key) => key !== "why").map((key) => [key,
    NUMERIC_SETTINGS.has(key) ? number(look[key], `look.${key}`) : string(look[key], `look.${key}`)])) as Omit<RecipeFields, "why">;
  const exposure = object(look.exposure, "look.exposure");
  if (typeof exposure.nd !== "boolean") bad("look.exposure.nd must be an explicit boolean");
  const source = look.recipe_reference_id;
  if (source !== null && (typeof source !== "string" || !allowedRecipeIDs.includes(source))) {
    bad("look.recipe_reference_id must be null or an exact ID from the supplied recipe shortlist");
  }
  if (look.reuse_slot !== undefined && (typeof look.reuse_slot !== "number" || !Number.isInteger(look.reuse_slot))) {
    bad("look.reuse_slot must be an explicit integer when supplied");
  }
  return {
    ...settings,
    why: purpose,
    reason: sceneFit,
    design: { purpose, scene_fit: sceneFit, choices: [], detail_level: "compact",
      tradeoff: string(design.tradeoff, "look.design.tradeoff"),
      alternative: string(design.alternative, "look.design.alternative"),
      uncertainty: string(design.uncertainty, "look.design.uncertainty"),
      knowledge_ids: strings(design.knowledge_ids, "look.design.knowledge_ids") },
    recipe_reference_id: source as string | null,
    ideal_film_sim: string(look.ideal_film_sim, "look.ideal_film_sim"),
    stop: string(look.stop, "look.stop"),
    when: string(look.when, "look.when"),
    reuse: string(look.reuse, "look.reuse"),
    ...(look.reuse_slot !== undefined ? { reuse_slot: look.reuse_slot as number } : {}),
    based_on: string(look.based_on, "look.based_on"),
    exposure: { aperture: string(exposure.aperture, "look.exposure.aperture"),
      shutter: string(exposure.shutter, "look.exposure.shutter"), iso: string(exposure.iso, "look.exposure.iso"),
      exp_comp: string(exposure.exp_comp, "look.exposure.exp_comp"), nd: exposure.nd as boolean },
    focus: string(look.focus, "look.focus"), drive: string(look.drive, "look.drive"), how: string(look.how, "look.how"),
  };
}

/** Full answer expansion preserves authored brief, stop order/times, replacements and exact primary identity. */
export function expandConcisePlan(raw: unknown, allowedRecipeIDs: readonly string[] = []): ModelPlan {
  const plan = object(raw, "plan");
  const brief = object(plan.photographic_brief, "photographic_brief");
  const photographicBrief: PhotographicBrief = {
    intent: string(brief.intent, "photographic_brief.intent"),
    subjects: strings(brief.subjects, "photographic_brief.subjects"),
    lighting: strings(brief.lighting, "photographic_brief.lighting"),
    color_priorities: strings(brief.color_priorities, "photographic_brief.color_priorities"),
    rendering_goal: string(brief.rendering_goal, "photographic_brief.rendering_goal"),
    observations: strings(brief.observations, "photographic_brief.observations"),
    uncertainties: strings(brief.uncertainties, "photographic_brief.uncertainties"),
  };
  const looks = array(plan.looks, "looks").map((item) => expandConciseLook(item, allowedRecipeIDs));
  const primary = nonempty(plan.primary_look, "primary_look");
  if (looks.filter((look) => look.name === primary).length !== 1) bad("primary_look must exactly name one unique returned look");
  const stops = array(plan.stops, "stops").map((item, i) => {
    const stop = object(item, `stops[${i}]`);
    return { name: string(stop.name, `stops[${i}].name`), start: string(stop.start, `stops[${i}].start`),
      end: string(stop.end, `stops[${i}].end`), light: string(stop.light, `stops[${i}].light`) };
  });
  for (const look of looks) {
    if (stops.filter((stop) => stop.name === look.stop).length !== 1) bad(`${look.name}: stop must exactly name one unique supplied stop`);
  }
  const replace = array(plan.replace, "replace").map((item, i) => {
    const replacement = object(item, `replace[${i}]`);
    return { name: string(replacement.name, `replace[${i}].name`), why: string(replacement.why, `replace[${i}].why`) };
  });
  return { photographic_brief: photographicBrief, primary_look: primary, summary: string(plan.summary, "summary"),
    count_why: string(plan.count_why, "count_why"), stops, looks, replace };
}
