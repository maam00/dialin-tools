// Bounded rationale/provenance for review, separate from the settings that are written to a camera.
import type { CameraCaps } from "../cameras.js";
import { EXPERT_KNOWLEDGE_VERSION, EXPERT_SOURCES, knowledgeIDs, SETTING_KNOWLEDGE, SIMULATION_PROFILES } from "./expert-knowledge.js";
import { RECIPE_KEYS, type Exposure, type PhotographicBrief, type RecipeDesign, type RecipeFields } from "./types.js";

export const DESIGN_SETTINGS = ["film_sim", "white_balance", "dynamic_range", "tone_curve", "color", "texture", "exposure"] as const;
const record = (v: unknown): Record<string, unknown> | null => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
const line = (v: unknown, max = 240) => typeof v === "string" ? v.replace(/\0/g, "").trim().slice(0, max) : "";
const lines = (v: unknown) => Array.isArray(v) ? v.slice(0, 8).map((x) => line(x, 160)).filter(Boolean) : [];

export function photographicBrief(raw: unknown): PhotographicBrief | undefined {
  const b = record(raw);
  if (!b || !line(b.intent) || !line(b.rendering_goal)) return undefined;
  return { intent: line(b.intent), subjects: lines(b.subjects), lighting: lines(b.lighting), color_priorities: lines(b.color_priorities),
    rendering_goal: line(b.rendering_goal), observations: lines(b.observations), uncertainties: lines(b.uncertainties) };
}

/** Canonical Recipe representation, not a full-render/device fingerprint. Unrepresented native options stay unknown. */
export function expertSettingsSignature(recipe: RecipeFields): string {
  return JSON.stringify(RECIPE_KEYS.filter((key) => key !== "name" && key !== "why").map((key) => [key, recipe[key]]));
}

export function expertGuidanceSignature(look: { exposure: Exposure; focus: string; drive: string }): string {
  return JSON.stringify([look.exposure, look.focus, look.drive]);
}

export function recipeDesign(raw: unknown, cam: CameraCaps, mode?: "compact" | "detailed"): RecipeDesign | undefined {
  const d = record(raw);
  if (!d || !line(d.purpose) || !line(d.scene_fit)) return undefined;
  const known = new Set(knowledgeIDs(cam));
  if (mode === "compact" || (mode === undefined && d.detail_level === "compact")) {
    const ids = Array.isArray(d.knowledge_ids) ? d.knowledge_ids.slice(0, 3) : [];
    const validIDs = [...new Set(ids.filter((id): id is string => typeof id === "string" && known.has(id)))];
    return { purpose: line(d.purpose), scene_fit: line(d.scene_fit), choices: [], detail_level: "compact",
      knowledge_ids: validIDs, tradeoff: line(d.tradeoff), alternative: line(d.alternative), uncertainty: line(d.uncertainty),
      requires_review: !line(d.tradeoff) || !line(d.alternative) || validIDs.length !== ids.length || !validIDs.length };
  }
  if (!Array.isArray(d.choices)) return undefined;
  const settings = new Set<string>(DESIGN_SETTINGS);
  const seen = new Set<string>();
  let incomplete = d.choices.length !== DESIGN_SETTINGS.length;
  const choices: RecipeDesign["choices"] = [];
  for (const rawChoice of d.choices.slice(0, DESIGN_SETTINGS.length)) {
    const choice = record(rawChoice);
    const setting = line(choice?.setting, 32);
    const reason = line(choice?.reason);
    if (!choice || !settings.has(setting) || seen.has(setting) || !reason) { incomplete = true; continue; }
    seen.add(setting);
    const ids = Array.isArray(choice.knowledge_ids) ? choice.knowledge_ids.slice(0, 5) : [];
    if (ids.some((id) => typeof id !== "string" || !known.has(id))) incomplete = true;
    choices.push({ setting: setting as RecipeDesign["choices"][number]["setting"], reason,
      knowledge_ids: [...new Set(ids.filter((id): id is string => typeof id === "string" && known.has(id)))] });
  }
  if (!choices.length) return undefined;
  const tradeoff = line(d.tradeoff);
  const alternative = line(d.alternative);
  return { purpose: line(d.purpose), scene_fit: line(d.scene_fit), choices, detail_level: "detailed", tradeoff, alternative, uncertainty: line(d.uncertainty),
    requires_review: incomplete || seen.size !== DESIGN_SETTINGS.length || !tradeoff || !alternative };
}

export function expertSourceRecords(ids: readonly string[]) {
  const selected = new Set(ids);
  const sources = new Set<string>();
  for (const p of SIMULATION_PROFILES) if (selected.has(p.id)) sources.add(p.source);
  for (const r of SETTING_KNOWLEDGE) if (selected.has(r.id)) r.sources.forEach((s) => sources.add(s));
  return [...sources].map((id) => ({ id, ...EXPERT_SOURCES[id as keyof typeof EXPERT_SOURCES], reviewed_at: "2026-10-14" }));
}

export function expertReceipt(designs: readonly RecipeDesign[], hasBrief: boolean, expectedLooks: number) {
  return { knowledge_version: EXPERT_KNOWLEDGE_VERSION, status: hasBrief && expectedLooks > 0 && designs.length === expectedLooks && designs.every((d) => !d.requires_review)
    ? "reasoned_proposal" : "incomplete_reasoning", evaluated_on_real_photographs: false,
    sources: expertSourceRecords(designs.flatMap((d) => [...(d.knowledge_ids ?? []), ...d.choices.flatMap((c) => c.knowledge_ids)])) };
}
