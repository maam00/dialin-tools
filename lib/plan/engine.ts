// Plan a shoot: what they said (and/or a photo of the scene) + place, date, the camera's slots and their taste →
// a short set of looks with plain names, which slots they go into, and a cheat sheet of what to set by hand.
// Adjust one look: "less yellow" → one regenerated look for one slot.
//
// A port of studio/plan.py (make_plan, _plan_content, _check_plan, _salvage, adjust_look) for the app's backend:
// the model call goes through an Ask (model.ts), the camera's capabilities come from lib/cameras.ts, and there is no
// disk: past looks and keep rates arrive in the request.
import type { CameraCaps } from "../cameras.js";
import { attributeRecipe, recipeKnowledgeContext, selectRecipeCandidates, type RecipeKnowledge } from "../recipes/library.js";
import { throwIfAborted } from "./abort.js";
import { dayConditions, geocode, noPlaceConditions } from "./conditions.js";
import { ConcisePlanError, expandConciseLook, expandConcisePlan } from "./concise.js";
import { confirmDayLooks } from "./confirmed.js";
import { expertGuidanceSignature, expertReceipt, expertSettingsSignature, photographicBrief, recipeDesign } from "./expert-metadata.js";
import { assessPolicyLook, inferPhotographicPolicy, sanitizeFactualRationale, type PhotographicPolicy } from "./expert-policy.js";
import { referenceContext, selectExpertReferences } from "./expert-references.js";
import { favoriteContext, favoriteRecipes } from "./favorite-recipes.js";
import {
  checkExposure, fallbackName, lookProblems, nameProblems, recipeLine, recipeOf, recipeProblems, slotName, tidyLook,
} from "./looks.js";
import { type Ask, type AskAnswer, defaultAsk, type Effort, MODELS } from "./model.js";
import { cameraReuse, enforcePaletteAnswer, paletteMetadata, palettePolicy, protectedSlotsFrom, removePaletteCopies } from "./palette.js";
import { adjustSchema, adjustSystem, concisePlanSchema, concisePlanSystem, planSchema, planSystem } from "./prompts.js";
import { mergeTargetedRepair, targetedRepairFor, targetedRepairSchema, targetedRepairText, type TargetedRepair } from "./repair.js";
import { assemble, finalize, type Library, putLook } from "./slots.js";
import { normalizeTaste, rateText, tasteSummary } from "./taste.js";
import { minutesOf, span, utcToday } from "./time.js";
import {
  type CallMeta, type CameraSlot, type Conditions, type DayLook, type ModelLook, type ModelPlan, type Place, type Plan,
  PlanError, type RecipeFields, type TasteSummary,
} from "./types.js";

export const MIN_LOOKS = 3;
export const MAX_LOOKS = 7;

export type Quality = "sonnet" | "opus";

const envEffort = (v: string | undefined, d: Effort): Effort =>
  (["low", "medium", "high", "xhigh", "max"] as const).includes(v as Effort) ? (v as Effort) : d;
const envMs = (v: string | undefined, d: number) => (Number(v) > 0 ? Number(v) : d);

/** Which models plan and adjust, how hard they think, and how long they get. Env overrides for tuning. */
export function modelConfig(env: NodeJS.ProcessEnv = process.env) {
  return {
    plan: {
      // Sonnet by default keeps a plan to a few cents; Opus only when the request asks and the server allows it.
      sonnet: { model: MODELS.sonnet, effort: envEffort(env.DIALIN_PLAN_EFFORT, "medium"), fallback: MODELS.haiku,
        fallbackEffort: "low" as Effort, budgetMs: envMs(env.DIALIN_PLAN_BUDGET_MS, 120_000) },
      opus: { model: MODELS.opus, effort: envEffort(env.DIALIN_OPUS_EFFORT, "medium"), fallback: MODELS.sonnet,
        fallbackEffort: "low" as Effort, budgetMs: envMs(env.DIALIN_OPUS_BUDGET_MS, 240_000) },
    },
    adjust: {
      model: env.DIALIN_ADJUST_MODEL === "sonnet" ? MODELS.sonnet : MODELS.haiku,
      effort: envEffort(env.DIALIN_ADJUST_EFFORT, "low"),
      fallback: env.DIALIN_ADJUST_MODEL === "sonnet" ? MODELS.haiku : MODELS.sonnet,
      fallbackEffort: "low" as Effort,
      budgetMs: envMs(env.DIALIN_ADJUST_BUDGET_MS, 45_000),
    },
    allowOpus: env.DIALIN_ALLOW_OPUS === "1",
  };
}

/** A second (validation) call only when this much budget is left; otherwise the first answer is salvaged. */
const RETRY_MIN_MS = 30_000;

const low = (s: unknown) => String(s ?? "").trim().toLowerCase();

/** Preserve setup checks only when their associated controls survive automatic-mode normalization. */
function automaticTip(look: Pick<DayLook, "tip" | "exposure" | "focus">, comp: string): string {
  const e = look.exposure;
  const unchanged = e.aperture === "A" && e.shutter === "A" && e.iso === "A" && e.nd === false
    && e.exp_comp === comp && look.focus !== "M";
  const exposureTip = `Let the camera choose exposure. Adjust brightness with the exposure dial${comp === "0" ? "." : ` (${comp}).`}`;
  const original = unchanged && typeof look.tip === "string" ? look.tip.trim() : "";
  if (!original || original.includes(exposureTip)) return original || exposureTip;
  return `${original}${/[.!?]$/.test(original) ? "" : "."} ${exposureTip}`;
}

// ================================================================== inputs

/** Past looks from the request (recipes from earlier plans), by lower-cased name. Invalid ones are dropped. */
export function libraryFrom(pastLooks: unknown, cam: CameraCaps): Library {
  const lib: Library = new Map();
  if (!Array.isArray(pastLooks)) return lib;
  for (const l of pastLooks.slice(0, 30)) {
    if (!l || typeof l !== "object") continue;
    const r = recipeOf(l as Record<string, unknown>);
    if (typeof r.name === "string" && r.name.trim() && !recipeProblems(r, cam).length) {
      lib.set(r.name.trim().toLowerCase(), { ...r, name: r.name.trim(), why: typeof r.why === "string" ? r.why : "" });
    }
  }
  return lib;
}

/** What's on the camera now → one entry per slot, or null when unknown. Accepts 7 names (index 0 = C1),
 *  {"C1": name, …}, {slots: [...]}, or [{slot, name, recipe?}]. A recipe comes from the input or else a past look with
 *  the same name. Missing entries are empty slots. */
export function normalizeCameraSlots(input: unknown, lib: Library, cam: CameraCaps, protectedSlots: number[] = []): CameraSlot[] | null {
  if (input === null || input === undefined) return null;
  let list: unknown[];
  if (Array.isArray(input)) list = input;
  else if (typeof input === "object") {
    const o = input as Record<string, unknown>;
    list = Array.isArray(o.slots) ? o.slots
      : Object.entries(o).map(([k, v]) => ({ slot: Number.parseInt(k.toUpperCase().replace(/^C/, ""), 10), name: v }));
  } else return null;
  const out = new Map<number, CameraSlot>();
  list.forEach((s, i) => {
    let n: number;
    let name: string;
    let recipe: Record<string, unknown> | null = null;
    if (s && typeof s === "object") {
      const o = s as Record<string, unknown>;
      n = Number(o.slot) || i + 1;
      name = String(o.name ?? "").trim();
      recipe = o.recipe && typeof o.recipe === "object" ? (o.recipe as Record<string, unknown>) : null;
    } else {
      n = i + 1;
      name = String(s ?? "").trim();
    }
    if (!(n >= 1 && n <= cam.slots)) return;
    name = slotName(name).slice(0, 40);
    let r: RecipeFields | null = recipe ? recipeOf({ ...recipe, name: (recipe.name as string) || name }) : null;
    if (r && recipeProblems(r, cam).length) r = null;
    if (!r && !protectedSlots.includes(n) && name && lib.has(name.toLowerCase())) r = lib.get(name.toLowerCase()) as RecipeFields;
    out.set(n, { slot: n, name, recipe: r ? { ...r, name, why: typeof r.why === "string" ? r.why : "" } : null });
  });
  return Array.from({ length: cam.slots }, (_, i) => out.get(i + 1) ?? { slot: i + 1, name: "", recipe: null });
}

function stopsText(stops: PlanInput["stops"]): string {
  if (!stops?.length) return "";
  const parts = stops.map((s) => {
    if (typeof s === "string") return s;
    const t = s.start ? span(s.start, s.end ?? "") : "";
    return `${s.name}${t ? ` (${t})` : ""}`;
  });
  return `Their stops, in order: ${parts.join("; ")}.`;
}

export type PlanInput = {
  said: string;
  imageBase64?: string | null;
  place?: Place | string | null;
  /** YYYY-MM-DD local to the place; null = today there. */
  date?: string | null;
  /** HH:MM local, when they're planning on the spot (with a photo). */
  now?: string | null;
  stops?: (string | { name: string; start?: string; end?: string })[] | null;
  cameraSlots?: unknown;
  cam: CameraCaps;
  taste?: unknown;
  pastLooks?: unknown;
  count?: number | null;
  protectedSlots?: number[];
  quality?: Quality;
  shootingMode?: "automatic" | "guided";
  reasoningMode?: "compact" | "detailed";
  /** Trusted rollout control; independent of the user-facing explanation depth. */
  outputMode?: "concise" | "legacy";
  /** Trusted server dependency, never parsed from an app request. */
  recipeKnowledge?: RecipeKnowledge;
  /** Local adapter hook for auditing the accepted draft; the copy cannot mutate engine state. */
  onValidatedModelPlan?: (draft: ModelPlan) => void;
  signal?: AbortSignal;
  ask?: Ask;
  conditions?: Conditions;
  budgetMs?: number;
};

export function planContent(o: {
  said: string; hasImage: boolean; now: string | null; cond: Conditions; stops: PlanInput["stops"];
  camera: CameraSlot[] | null; tasteBy: Map<string, TasteSummary>; lib: Library; count: number | null;
  learned: string[]; notes: string; cam: CameraCaps;
  protectedSlots?: number[]; blockedSlots?: number[]; fullPalette?: boolean;
}): string {
  const lines: string[] = [];
  lines.push(o.said.trim() ? `They said: "${o.said.trim()}"` : "They supplied only an image; its intended use, location and timing are unknown.");
  if (o.hasImage) lines.push("A supplied image is attached. Their description determines whether it is scene evidence or a visual reference; do not infer ownership, current location or measured light.");
  if (o.now) lines.push(`Time now: ${o.now}`);
  lines.push(stopsText(o.stops), "", "Conditions:", o.cond.text, "");
  if (o.camera === null) {
    lines.push(`Their camera's slots weren't read, so what's in C1–C${o.cam.slots} now is unknown. Leave replace empty. `
      + "You may still reuse one of their past looks below by name.", "");
  } else {
    lines.push("On their camera now:");
    for (const s of o.camera) {
      const t = s.name ? o.tasteBy.get(s.name.toLowerCase()) : undefined;
      const rate = t ? ` · ${rateText(t)}` : "";
      const recipe = s.recipe ? ` — ${recipeLine(s.recipe)}` : s.name ? " — settings unknown" : "";
      lines.push(`C${s.slot} ${s.name || "(empty)"}${recipe}${rate}`);
    }
    lines.push("");
  }
  const onCam = new Set((o.camera ?? []).filter((s) => s.name).map((s) => s.name.toLowerCase()));
  const past = [...o.tasteBy.entries()].filter(([k]) => !onCam.has(k)).sort((a, b) => b[1].hearted - a[1].hearted);
  if (past.length) {
    lines.push("Their past looks and keep rates (hearts ÷ frames shot with the look):");
    for (const [, t] of past.slice(0, 10)) {
      const l = o.lib.get(t.look.toLowerCase());
      lines.push(`- ${t.look}: ${rateText(t)}${l ? ` — ${recipeLine(l)}` : ""}`);
    }
    lines.push("");
  }
  const unrated = [...o.lib.values()].filter((r) => !o.tasteBy.has(r.name.toLowerCase()) && !onCam.has(r.name.toLowerCase()));
  if (unrated.length) {
    lines.push("Other looks they've used before (reuse by exact name if one fits):");
    for (const r of unrated.slice(0, 10)) lines.push(`- ${r.name} — ${recipeLine(r)}`);
    lines.push("");
  }
  const favs = [...o.tasteBy.values()].filter((t) => t.favorite).map((t) => t.look);
  if (favs.length) lines.push(`Looks they reuse (keep or rebuild them when they fit today): ${favs.join(", ")}.`);
  if (o.learned.length) {
    lines.push("What Claude has learned from their choices (counts are theirs):", ...o.learned.slice(0, 6).map((x) => `- ${x}`), "");
  }
  if (o.notes) lines.push(`What they told you about their taste: "${o.notes}"`, "");
  if (o.fullPalette) {
    lines.push(`Prepare the full C1–C${o.cam.slots} day palette. Each entry needs a distinct photographic purpose grounded in their intent, `
      + "subjects, skin/color priorities, actual light and taste. Different treatments of the same real scene may earn slots. "
      + "Do not invent future activities/light or fill a fixed daytime checklist. Do not copy settings under new names. Keep suitable favorites in exact slots.");
  }
  if (o.protectedSlots?.length) {
    lines.push(`Protected slots (NEVER overwrite or relocate): ${o.protectedSlots.map((s) => `C${s}`).join(", ")}.`);
    for (const slot of o.protectedSlots) {
      const known = o.camera?.find((s) => s.slot === slot);
      lines.push(known?.recipe
        ? `C${slot} "${known.name}" stays EXACTLY as it is. ${o.fullPalette ? "Include it in this palette, with a useful when/reason. " : "If useful today, reuse it. "}Set reuse to its exact name and reuse_slot to ${slot}; copy the original recipe, never rebuild it.`
        : `C${slot} is blocked: its actual recipe is unknown or empty. Omit it from looks; it remains untouched. Do not fill it or infer its recipe from a past name.`);
    }
  }
  if (o.fullPalette || o.protectedSlots?.length) lines.push("For every camera look kept, give reuse_slot as its original slot. Use 0 for a new or off-camera past look.");
  if (o.fullPalette || o.protectedSlots?.length) lines.push("The confirmed-code restrictions apply to NEW writes. A known camera look is kept exactly, even if its existing values aren't mapped for writing yet.");
  lines.push(o.count !== null ? `Make exactly ${o.count} look${o.count !== 1 ? "s" : ""}${o.blockedSlots?.length && o.fullPalette ? "; blocked slots remain honestly missing from the seven-slot palette" : ""}.`
    : `Make ${MIN_LOOKS} to ${MAX_LOOKS} looks; you choose how many.`);
  return lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

// ================================================================== checking the model's answer

/** A pure length correction does not need another model answer. All identities and collisions stay guarded. */
export function normalizeOverlengthNames(data: Pick<ModelPlan, "looks" | "primary_look">, camera: readonly Pick<CameraSlot, "name">[] | null,
  lib: Library, cam: CameraCaps, reservedNames: readonly string[] = []): string[] {
  if (!Array.isArray(data.looks)) return [];
  const looks = data.looks.filter((look) => look && typeof look === "object");
  const identities = new Set([...reservedNames, ...(camera ?? []).map((slot) => slot.name), ...lib.keys(),
    ...looks.map((look) => look.reuse)].filter(Boolean).map(low));
  const proposals: { look: ModelLook; old: string; name: string }[] = [];
  for (const look of looks) {
    const old = look.name;
    if (typeof old !== "string" || look.reuse || look.reuse_slot || identities.has(low(old))
      || looks.filter((other) => low(other.name) === low(old)).length !== 1) continue;
    const lengthProblem = `${old.trim().length} characters, max ${cam.nameMax}`;
    const naming = nameProblems(old, cam.nameMax);
    if (naming.length !== 1 || naming[0] !== lengthProblem) continue;
    const problems = lookProblems(look as unknown as Record<string, unknown>, cam);
    if (problems.length !== 1 || problems[0] !== `name "${old}": ${lengthProblem}`) continue;
    const name = fallbackName(old, look.stop, cam.nameMax);
    if (!name || nameProblems(name, cam.nameMax).length || identities.has(low(name))
      || looks.some((other) => other !== look && low(other.name) === low(name))) continue;
    proposals.push({ look, old, name });
  }
  const warnings: string[] = [];
  for (const proposal of proposals) {
    if (proposals.filter((other) => low(other.name) === low(proposal.name)).length !== 1) continue;
    proposal.look.name = proposal.name;
    if (data.primary_look === proposal.old) data.primary_look = proposal.name;
    warnings.push(`renamed "${proposal.old}" to "${proposal.name}" to fit the camera's ${cam.nameMax}-character limit`);
  }
  return warnings;
}

/** Tidy the model's plan in place → [problems worth asking again for, notes of what code fixed]. A reused look (on
 *  the camera, or a past look we have) keeps its own name and settings, so only its exposure for today is checked. */
export function checkPlan(data: ModelPlan, camera: CameraSlot[] | null, count: number | null, lib: Library, cam: CameraCaps):
  [string[], string[]] {
  const problems: string[] = [];
  const notes: string[] = [];
  if (!Array.isArray(data.looks)) data.looks = [];
  if (!Array.isArray(data.stops)) data.stops = [];
  const looks = data.looks;
  const stops = data.stops;
  const [lo, hi] = count !== null ? [count, count] : [MIN_LOOKS, MAX_LOOKS];
  if (looks.length > hi) {
    notes.push(`kept the first ${hi} of ${looks.length} looks`);
    looks.splice(hi);
  }
  if (looks.length < lo) problems.push(`${looks.length} looks; make ${lo === hi ? lo : `${lo} to ${hi}`}`);
  if (!stops.length) problems.push("no stops listed");
  const stopNames = new Set(stops.map((s) => low(s.name)));
  for (const s of stops) {
    if (minutesOf(s.start) === null || minutesOf(s.end) === null) {
      s.start = s.start || "";
      s.end = s.end || "";
      notes.push(`stop ${s.name}: times unreadable`);
    }
  }
  const camNames = new Set((camera ?? []).filter((s) => s.name).map((s) => s.name.toLowerCase()));
  const seen = new Set<string>();
  for (const look of looks) {
    notes.push(...tidyLook(look as unknown as Record<string, unknown>, cam));
    if (!stopNames.has(low(look.stop))) {
      if (stops.length === 1) look.stop = stops[0].name;
      else problems.push(`${look.name}: stop '${look.stop}' isn't one of the stops`);
    }
    const reuse = low(look.reuse);
    let k: string;
    if (reuse && (camNames.has(reuse) || lib.has(reuse))) {
      const ep = checkExposure(look.exposure, cam, cam.drMinIso[look.dynamic_range] ?? 125);
      if (ep) problems.push(`${look.name}: ${ep}`);
      k = look.reuse_slot ? `slot:${look.reuse_slot}` : reuse;
    } else {
      if (reuse) {
        notes.push(`${look.name}: reuse '${look.reuse}' matches nothing, so it's a new look`);
        look.reuse = "";
      }
      problems.push(...lookProblems(look as unknown as Record<string, unknown>, cam));
      k = low(look.name);
    }
    if (seen.has(k)) problems.push(`two looks are both called "${look.name}"`);
    seen.add(k); // a new look named like an unused camera look is a rebuild: it takes that slot
  }
  const used = new Set(looks.map((l) => low(l.stop)));
  for (const s of stops) if (!used.has(low(s.name))) problems.push(`stop '${s.name}' has no look`);
  return [problems, notes];
}

/** After the retry: make what's left usable instead of failing the whole plan. */
export function salvage(data: ModelPlan, cam: CameraCaps): string[] {
  const warnings: string[] = [];
  const looks = data.looks ?? [];
  let stops = data.stops ?? [];
  if (!stops.length) {
    stops.push({ name: "Today", start: "", end: "", light: "" });
    data.stops = stops;
  }
  const names = new Set(stops.map((s) => low(s.name)));
  const taken = new Set<string>();
  for (const look of looks) {
    if (!names.has(low(look.stop))) look.stop = stops[0].name;
    if (look.reuse) {
      taken.add(low(look.reuse));
      continue;
    }
    if (nameProblems(look.name ?? "", cam.nameMax).length || taken.has(look.name.toLowerCase())) {
      const old = look.name ?? "";
      const base = fallbackName(old, look.stop, cam.nameMax);
      let fresh = base;
      const extras = ["", ...[...slotName(look.stop).split(" ").filter(Boolean), "too", "again", "more"].map((w) => ` ${w}`)];
      for (const extra of extras) {
        const cand = (base + extra).length <= cam.nameMax ? base + extra : base.slice(0, cam.nameMax - extra.length).trimEnd() + extra;
        if (!taken.has(cand.toLowerCase()) && !/\d/.test(cand)) {
          fresh = cand;
          break;
        }
      }
      look.name = fresh;
      warnings.push(`renamed "${old}" to "${fresh}"`);
    }
    taken.add(look.name.toLowerCase());
  }
  for (const l of looks.filter((x) => recipeProblems(recipeOf(x as unknown as Record<string, unknown>), cam).length)) {
    looks.splice(looks.indexOf(l), 1);
    warnings.push(`dropped "${l.name}": its settings aren't camera values`);
  }
  const used = new Set(looks.map((l) => low(l.stop)));
  stops = stops.filter((s) => used.has(low(s.name)));
  data.stops = stops.length ? stops : (data.stops ?? []).slice(0, 1);
  return warnings;
}

const callMeta = (a: AskAnswer, task: string): CallMeta => ({
  task, ok: a.ok, model: a.model, via: a.via, ms: a.ms, error: a.code, usage: a.usage, usd: a.usd,
  requested_model: a.requestedModel, served_model: a.servedModel, usage_complete: a.usageComplete,
  reported_cost_usd: a.reportedCostUsd, tries: a.tries,
});

function intentProblems(data: ModelPlan, camera: CameraSlot[] | null, policy: PhotographicPolicy): string[] {
  const primary = low(data.primary_look || data.looks[0]?.name);
  const problems: string[] = [];
  if (data.primary_look && !data.looks.some((l) => low(l.name) === primary)) problems.push("primary_look must name a look in this answer exactly");
  for (const l of data.looks) {
    const kept = cameraReuse(l, camera)?.recipe;
    problems.push(...assessPolicyLook({ look: { ...l, status: kept ? "kept" : "new" }, policy, isPrimary: low(l.name) === primary })
      .filter((i) => i.severity === "conflict").map((i) => `${l.name}: ${i.message}`));
  }
  return problems;
}

/** Bounded fact checks, not a claim of complete semantic or photographic validation. */
function checkRationale(look: DayLook, cam: CameraCaps) {
  const checked = sanitizeFactualRationale({ recipe: look, design: look.design, reason: look.reason, exposure: look.exposure, cameraModel: cam.id });
  look.why = checked.why;
  look.reason = checked.reason ?? "";
  if (checked.design) look.design = checked.design;
  return checked.issues.map((issue) => ({ slot: look.slot, ...issue }));
}

// ================================================================== the plan

/** Raises PlanError with a plain sentence when no plan can be made. */
export async function makePlan(input: PlanInput): Promise<Plan> {
  throwIfAborted(input.signal);
  const said = (input.said ?? "").trim();
  if (!said && !input.imageBase64) throw new PlanError("Say what you're shooting, or send a photo of the scene.", "no_input", 400);
  const t0 = Date.now();
  const cam = input.cam;
  const cfg = modelConfig();
  const quality: Quality = input.quality === "opus" ? "opus" : "sonnet";
  const mc = cfg.plan[quality];
  const budget = input.budgetMs ?? mc.budgetMs;
  const ask = input.ask ?? defaultAsk();
  const count = input.count ? Math.max(1, Math.min(MAX_LOOKS, Math.trunc(input.count))) : null;
  const protectedSlots = protectedSlotsFrom(input.protectedSlots, cam);
  const lib = libraryFrom(input.pastLooks, cam);
  const strictRecipeSlots = count === cam.slots ? Array.from({ length: cam.slots }, (_, i) => i + 1) : protectedSlots;
  const camera = normalizeCameraSlots(input.cameraSlots, lib, cam, strictRecipeSlots);
  const policy = palettePolicy(count, protectedSlots, camera, cam, input.protectedSlots !== undefined);
  const usableCount = policy.full ? (count as number) - policy.blockedSlots.length : count;
  const taste = normalizeTaste(input.taste);
  const tasteBy = tasteSummary(taste.rows);
  const photographicPolicy = inferPhotographicPolicy({ said, tasteNotes: taste.notes });
  const references = selectExpertReferences({ brief: { intent: said, rendering_goal: taste.notes, subjects: [said],
    lighting: [], color_priorities: [], observations: [], uncertainties: [] }, policy: photographicPolicy, camera: cam, limit: 3 });
  const recipeRetrievalStart = Date.now();
  const recipeCandidates = input.recipeKnowledge ? selectRecipeCandidates(input.recipeKnowledge, {
    brief: { intent: said, rendering_goal: taste.notes, subjects: [said], lighting: [], color_priorities: [], observations: [], uncertainties: [] },
    camera: cam, shootingMode: input.shootingMode, policy: photographicPolicy,
  }) : [];
  const recipeContext = recipeKnowledgeContext(recipeCandidates);
  const recipeRetrievalMs = Date.now() - recipeRetrievalStart;

  let cond = input.conditions;
  if (!cond) {
    if (input.place) {
      const place = typeof input.place === "string" ? await geocode(input.place, input.signal) : input.place;
      cond = await dayConditions(place, input.date ?? null, input.signal);
    } else {
      cond = noPlaceConditions(input.date ?? utcToday());
    }
  }
  const content = planContent({ said, hasImage: Boolean(input.imageBase64), now: input.now ?? null, cond, stops: input.stops,
    camera, tasteBy, lib, count: usableCount, learned: taste.learned, notes: taste.notes, cam,
    protectedSlots, blockedSlots: policy.blockedSlots, fullPalette: policy.full })
    + `\n\nEXPLICIT INTENT SCOPE\n${JSON.stringify(photographicPolicy)}\n\n${referenceContext(references)}\n\n`
    + favoriteContext(favoriteRecipes(input.taste, cam))
    + (recipeContext ? `\n\n${recipeContext}` : "");
  const automatic = input.shootingMode === "automatic";
  const compact = input.reasoningMode === "compact";
  const outputMode = compact && (input.outputMode ?? (process.env.DIALIN_PLAN_OUTPUT === "concise" ? "concise" : "legacy")) === "concise" ? "concise" : "legacy";
  const candidateIDs = recipeCandidates.map((candidate) => candidate.recipe.id);
  const system = outputMode === "concise" ? concisePlanSystem(cam, automatic, policy.full) : planSystem(cam, automatic, policy.full, compact);
  // Unmapped values are offered only when a known camera recipe could be kept exactly; new looks use written values.
  const knownCameraRecipes = (camera ?? []).some((slot) => Boolean(slot.recipe));
  const schema = outputMode === "concise" ? concisePlanSchema(cam, policy.enabled) : planSchema(cam, policy.enabled, compact, candidateIDs, policy.enabled && knownCameraRecipes);
  const lookProperties = ((schema.properties as Record<string, { items?: { properties?: Record<string, Record<string, unknown>> } }> | undefined)?.looks?.items?.properties);
  if (automatic && lookProperties?.clarity) {
    // Offer only what automatic mode keeps, so an answer that follows the schema is never normalized into a revision.
    lookProperties.clarity.description = "Automatic shooting mode: new looks are always Clarity 0 so saving never delays the next frame; a kept camera recipe keeps its value.";
    if (!knownCameraRecipes) lookProperties.clarity.enum = [0];
    const exposure = lookProperties.exposure?.properties as Record<string, Record<string, unknown>> | undefined;
    if (exposure) for (const key of ["aperture", "shutter", "iso"]) exposure[key].enum = ["A"];
    if (exposure?.nd) exposure.nd.description = "Automatic shooting mode: false; the photographer controls the ND filter.";
    if (lookProperties.focus) lookProperties.focus.enum = ["S", "C"];
  }

  const calls: CallMeta[] = [];
  let data: ModelPlan | null = usableCount === 0 ? { summary: "Your protected looks need a camera read before the palette can be prepared.",
    count_why: "No protected recipe is known yet.", stops: [], looks: [], replace: [] } : null;
  let problems: string[] = [];
  let nameFixes: string[] = [];
  let notes: string[] = [];
  let targeted: TargetedRepair | null = null;
  for (const attempt of usableCount === 0 ? [] : [1, 2]) {
    throwIfAborted(input.signal);
    const left = budget - (Date.now() - t0);
    if (attempt === 2 && left < RETRY_MIN_MS) break; // no time for a second call: salvage the first
    const repairing = attempt === 2 ? targeted : null;
    const task = attempt === 1 ? "plan" : repairing ? "plan-repair" : "plan-retry";
    const text = attempt === 1 ? content
      : repairing ? targetedRepairText(content, data!, repairing, problems)
      : `${content}\n\nYOUR LAST ANSWER BROKE THESE RULES. Fix exactly these, keep everything else:\n`
        + `${problems.map((p) => `- ${p}`).join("\n")}\n\nYour last answer:\n${JSON.stringify(data)}`;
    const a = await ask({ task, system, text, imageBase64: input.imageBase64 ?? null,
      schema: repairing ? targetedRepairSchema(schema) : schema, model: mc.model, effort: mc.effort, fallback: mc.fallback, fallbackEffort: mc.fallbackEffort,
      timeoutMs: left, maxTokens: repairing ? Math.min(compact ? 9_000 : 16_000, repairing.count * (compact ? 2_000 : 3_500) + 500) : compact ? 9_000 : 16_000, signal: input.signal });
    throwIfAborted(input.signal);
    calls.push(callMeta(a, task));
    if (!a.ok || !a.data || typeof a.data !== "object") {
      if (data === null) {
        throw new PlanError(`Claude couldn't make the plan: ${a.error ?? "no answer"}.`, a.code ?? "model_failed",
          a.code === "timeout" ? 504 : 502, calls);
      }
      break; // keep the first answer and salvage it
    }
    let decoded: unknown = a.data;
    if (outputMode === "concise") {
      try {
        if (repairing) {
          const wire = a.data as Record<string, unknown>;
          if (!Array.isArray(wire.looks)) throw new ConcisePlanError("repair looks must be an array");
          decoded = { ...wire, looks: wire.looks.map((look) => expandConciseLook(look, candidateIDs)) };
        } else decoded = expandConcisePlan(a.data, candidateIDs);
      } catch (error) {
        if (!(error instanceof ConcisePlanError)) throw error;
        problems.push(...error.rules);
        // There is still only one validation retry. A bad patch retains the first accepted subset.
        if (repairing || attempt === 2) break;
        targeted = null;
        continue;
      }
    }
    const accepted = data;
    const beforeRepair = repairing ? { data: structuredClone(data!), problems: [...problems], notes: [...notes], nameFixes: [...nameFixes] } : null;
    const merged = repairing ? mergeTargetedRepair(data!, decoded, repairing, camera, lib, candidateIDs) : decoded as ModelPlan;
    if (!merged) {
      problems.push("targeted repair did not return only the requested new looks; accepted looks were preserved");
      break;
    }
    data = merged;
    // Bind concise rationale to the proposed settings before any tidy/substitution or automatic-mode change.
    for (const look of Array.isArray(data.looks) ? data.looks : []) {
      if (!look || typeof look !== "object" || (repairing && accepted?.looks.includes(look))) continue;
      const design = recipeDesign(look.design, cam, compact ? "compact" : "detailed");
      if (design) look.design = { ...design, settings_signature: expertSettingsSignature(look), guidance_signature: expertGuidanceSignature(look) };
      else delete look.design;
    }
    const originalLooks = Array.isArray(data.looks) ? [...data.looks] : [];
    const paletteProblems = enforcePaletteAnswer(data, camera, policy);
    const correctedNames = normalizeOverlengthNames(data, camera, lib, cam);
    nameFixes = repairing ? [...nameFixes, ...correctedNames] : correctedNames;
    [problems, notes] = checkPlan(data, camera, usableCount, lib, cam);
    problems.push(...paletteProblems);
    problems.push(...intentProblems(data, camera, photographicPolicy));
    if (beforeRepair && problems.length) {
      // A patch is all-or-nothing. Invalid additions cannot partially replace valid first-answer siblings.
      const failed = problems;
      data = beforeRepair.data;
      problems = [...beforeRepair.problems, ...failed.map((problem) => `targeted repair rejected: ${problem}`)];
      notes = beforeRepair.notes;
      nameFixes = beforeRepair.nameFixes;
      break;
    }
    if (!problems.length) break;
    targeted = targetedRepairFor(data, originalLooks, problems, usableCount, policy, cam);
  }
  throwIfAborted(input.signal);
  if (!data) throw new PlanError(`Claude's plan could not be validated: ${problems.slice(0, 3).join("; ")}`, "invalid_plan", 502, calls);
  const d = data;
  const warnings: string[] = [...nameFixes];
  if (problems.length) {
    warnings.push(...problems.map((p) => `still after the retry: ${p}`));
    warnings.push(...salvage(d, cam));
    if (!d.looks?.length && !policy.enabled) throw new PlanError(`Claude's plan had no usable looks: ${problems.slice(0, 3).join("; ")}`, "no_looks", 502, calls);
  }
  enforcePaletteAnswer(d, camera, policy);
  input.onValidatedModelPlan?.(structuredClone(d));
  const plan = assemble(said, cond, d, camera, tasteBy, lib, cam, protectedSlots);
  if (policy.enabled) plan.protected_slots = protectedSlots;
  if (automatic) {
    // A recipe write sets image rendering only. This is exposure guidance for a user-set Program AE baseline.
    for (const look of plan.day_looks) {
      const comp = cam.expComps.includes(look.exposure.exp_comp) ? look.exposure.exp_comp : "0";
      const tip = automaticTip(look, comp);
      const before = expertGuidanceSignature(look);
      look.exposure = { aperture: "A", shutter: "A", iso: "A", exp_comp: comp, nd: false };
      if (look.focus === "M") look.focus = "S";
      // The schema already offers only these values in automatic mode; name any look whose guidance was replaced.
      if (before !== expertGuidanceSignature(look)) plan.warnings.push(`"${look.name}": automatic shooting mode replaced its exposure guidance with aperture, shutter and ISO on A${comp !== "0" ? `, exposure compensation ${comp}` : ""}, focus ${look.focus}. Its exposure reasoning must describe these values.`);
      // Clarity delays every frame; the quiet companion must not slow capture for its own rendering choice.
      if (look.status === "new" && look.clarity !== 0) {
        const old = look.clarity;
        look.clarity = 0;
        // The automatic schema offers only 0; a different proposal is normalized, named, and its reasoning re-reviewed.
        plan.warnings.push(`"${look.name}": automatic shooting mode changed Clarity ${old > 0 ? "+" : ""}${old} to 0 so saving does not delay the next frame. Its reasoning was written for ${old > 0 ? "+" : ""}${old}; answer with Clarity 0, or prepare the request with guided shooting mode to keep it (needed for an exact copy of a nonzero-Clarity source).`);
      }
      look.tip = tip;
    }
    plan.shooting_mode = "automatic";
    plan.setup_scope = "Exposure guidance only. Set the physical dials to A; the uploaded slots contain color settings.";
    finalize(plan, cam);
  }
  // Only confirmed camera codes get written: stand-ins for anything else, each said in a warning line.
  const ideals = new Map(d.looks.filter((l) => !l.reuse && l.ideal_film_sim).map((l) => [low(l.name), String(l.ideal_film_sim)]));
  const mapped = confirmDayLooks(plan.day_looks, ideals, cam);
  const primaryName = low(d.primary_look || d.looks[0]?.name);
  const intentIssues = plan.day_looks.flatMap((look) => assessPolicyLook({ look, policy: photographicPolicy,
    isPrimary: low(look.name) === primaryName }).map((issue) => ({ slot: look.slot, name: look.name, ...issue })));
  const refused = new Set(intentIssues.filter((i) => i.severity === "conflict").map((i) => i.slot));
  plan.day_looks = plan.day_looks.filter((l) => !refused.has(l.slot));
  const factualIssues = plan.day_looks.flatMap((look) => checkRationale(look, cam));
  const copies = policy.enabled ? removePaletteCopies(plan, camera) : [];
  if (mapped.length || copies.length || intentIssues.length || factualIssues.length || policy.enabled) finalize(plan, cam);
  plan.warnings = [...warnings, ...mapped, ...copies,
    ...intentIssues.map((i) => `C${i.slot}: ${i.message} ${i.severity === "preserved_conflict" ? "Your existing settings stay protected." : "This conflicting suggestion was omitted."}`),
    ...factualIssues.map((i) => `C${i.slot}: part of the explanation needs review; the unsupported claim was removed. ${i.message}`), ...plan.warnings];
  paletteMetadata(plan, policy, cam);
  plan.notes = notes;
  plan.calls = calls;
  plan.learned = taste.learned;
  plan.model = [...calls].reverse().find((c) => c.ok)?.model ?? calls[calls.length - 1]?.model ?? null;
  const brief = photographicBrief(d.photographic_brief);
  if (brief) plan.photographic_brief = brief;
  plan.photographic_policy = photographicPolicy;
  plan.intent_issues = intentIssues;
  plan.intent_satisfied = intentIssues.length === 0 && !photographicPolicy.requiresReview;
  plan.primary_slot = plan.day_looks.find((l) => low(l.name) === primaryName)?.slot ?? null;
  plan.primary_selection = d.primary_look ? "declared" : "legacy_first_look";
  plan.factual_issues = factualIssues;
  plan.reference_directions = references.map(({ reference: r, matched_tags }) => ({ id: r.id, title: r.title, matched_tags,
    origin: r.origin, sources: r.sources, photographic_validation: r.photographic_validation }));
  if (input.recipeKnowledge) {
    plan.recipe_knowledge = { revision: input.recipeKnowledge.library.revision, mode: input.recipeKnowledge.mode,
      candidate_ids: recipeCandidates.map((c) => c.recipe.id), model_weights_trained: false,
      scene_judgment: "shortlist_and_reasoning", photographic_quality_verified: false,
      retrieval_ms: recipeRetrievalMs, context_characters: recipeContext.length,
      reference_evidence: recipeCandidates.map((c) => ({ record_id: c.recipe.id, evidence: c.judgment?.evidence ?? "unreviewed_named_request" })) };
    plan.recipe_references = plan.day_looks.flatMap((look) => {
      if (look.status !== "new") return [];
      const proposed = d.looks.find((l) => low(l.name) === low(look.name));
      const candidate = recipeCandidates.find((c) => c.recipe.id === proposed?.recipe_reference_id);
      return candidate ? [{ slot: look.slot, ...attributeRecipe(look, candidate) }] : [];
    });
  }
  for (const look of plan.day_looks) {
    if (look.design && (look.design.settings_signature !== expertSettingsSignature(look)
      || look.design.guidance_signature !== expertGuidanceSignature(look))) look.design.requires_review = true;
  }
  plan.expertise = expertReceipt(plan.day_looks.flatMap((l) => l.design ? [l.design] : []), Boolean(brief), plan.day_looks.length);
  plan.ms = Date.now() - t0;
  plan.reasoning_mode = compact ? "compact" : "detailed";
  plan.output_mode = outputMode;
  throwIfAborted(input.signal);
  return plan;
}

// ================================================================== adjust one look

export function adjustContent(plan: Plan, current: DayLook | null, slot: number, said: string, now: string | null): string {
  const others = (plan.camera ?? []).filter((c) => c.slot !== slot && c.name).map((c) => `C${c.slot} ${c.name}`);
  const stops = (plan.stops ?? []).map((s) => `${s.name} (${s.time || "no time"}, ${s.light || ""})`).join("; ");
  let cur: string;
  if (current) {
    cur = JSON.stringify({ ...recipeOf(current), stop: current.stop, when: current.when, based_on: current.based_on ?? "",
      reason: current.reason ?? "", exposure: current.exposure, focus: current.focus, drive: current.drive, how: current.tip });
  } else {
    const name = (plan.camera ?? []).find((c) => c.slot === slot)?.name ?? "";
    cur = `"${name}" (its settings aren't known here; design it fresh for what they say)`;
  }
  return [
    plan.photographic_brief ? `Photographic intent and scene evidence:\n${JSON.stringify(plan.photographic_brief)}` : "",
    `Conditions:\n${plan.conditions?.text ?? ""}`,
    stops ? `Today's stops: ${stops}` : "",
    now ? `Time now: ${now}` : "",
    `The look in C${slot} now: ${cur}`,
    others.length ? `The other slots (keep the name different from these): ${others.join(", ")}` : "",
    `They say: "${said.trim()}"`,
    "Rewrite only this look. Use one of today's stop names for stop.",
  ].filter((x) => x !== "").join("\n");
}

export type AdjustInput = { plan: Plan; slot: number; said: string; now?: string | null; cam: CameraCaps; ask?: Ask; budgetMs?: number; signal?: AbortSignal };

/** "less yellow" / "we're in shade now" → ONE regenerated look for ONE slot (status "new", replaces the old name,
 *  `change` says what changed). Doesn't touch the plan; putLook(plan, look) puts it in. */
export async function adjustLook(input: AdjustInput): Promise<DayLook> {
  throwIfAborted(input.signal);
  const { plan, cam } = input;
  const slot = Math.trunc(Number(input.slot));
  if (!(slot >= 1 && slot <= cam.slots)) throw new PlanError(`Pick a slot from C1 to C${cam.slots}.`, "bad_slot", 400);
  if (plan.protected_slots?.includes(slot)) throw new PlanError(`C${slot} is protected and stays as it is.`, "protected_slot", 400);
  const said = (input.said ?? "").trim();
  if (!said) throw new PlanError("Say what to change.", "no_input", 400);
  const cfg = modelConfig().adjust;
  const budget = input.budgetMs ?? cfg.budgetMs;
  const ask = input.ask ?? defaultAsk();
  const t0 = Date.now();
  const current = plan.day_looks.find((l) => l.slot === slot) ?? null;
  const intent = inferPhotographicPolicy({ said, tasteNotes: plan.said });
  const oldName = current?.name ?? (plan.camera ?? []).find((c) => c.slot === slot)?.name ?? "";
  const taken = new Set((plan.camera ?? []).filter((c) => c.slot !== slot && c.name).map((c) => c.name.toLowerCase()));
  const stopNames = new Map((plan.stops ?? []).map((s) => [low(s.name), s.name]));
  const content = adjustContent(plan, current, slot, said, input.now ?? null);
  const system = adjustSystem(cam, plan.shooting_mode === "automatic");
  const schema = adjustSchema(cam);
  const calls: CallMeta[] = [];
  let data: { look: ModelLook; change: string } | null = null;
  let problems: string[] = [];
  let nameFixes: string[] = [];
  for (const attempt of [1, 2]) {
    throwIfAborted(input.signal);
    const left = budget - (Date.now() - t0);
    if (attempt === 2 && left < 10_000) break;
    const text = attempt === 1 ? content
      : `${content}\n\nYOUR LAST ANSWER BROKE THESE RULES. Fix exactly these:\n${problems.map((p) => `- ${p}`).join("\n")}`
        + `\n\nYour last answer:\n${JSON.stringify(data)}`;
    const a = await ask({ task: attempt === 1 ? "adjust" : "adjust-retry", system, text, schema, model: cfg.model,
      effort: cfg.effort, fallback: cfg.fallback, fallbackEffort: cfg.fallbackEffort, timeoutMs: left, maxTokens: 8_000, signal: input.signal });
    throwIfAborted(input.signal);
    calls.push(callMeta(a, attempt === 1 ? "adjust" : "adjust-retry"));
    const got = a.data as { look?: unknown; change?: unknown } | null;
    if (!a.ok || !got || typeof got !== "object" || !got.look || typeof got.look !== "object") {
      if (data === null) {
        throw new PlanError(`Claude couldn't change the look: ${a.error ?? "no answer"}.`, a.code ?? "model_failed",
          a.code === "timeout" ? 504 : 502, calls);
      }
      break;
    }
    data = got as { look: ModelLook; change: string };
    const design = recipeDesign(data.look.design, cam);
    if (design) data.look.design = { ...design, settings_signature: expertSettingsSignature(data.look), guidance_signature: expertGuidanceSignature(data.look) };
    else delete data.look.design;
    tidyLook(data.look as unknown as Record<string, unknown>, cam);
    nameFixes = normalizeOverlengthNames({ looks: [data.look] }, plan.camera ?? null, new Map(), cam,
      plan.day_looks.map((look) => look.name));
    problems = lookProblems(data.look as unknown as Record<string, unknown>, cam);
    problems.push(...assessPolicyLook({ look: data.look, policy: intent, isPrimary: true }).map((i) => i.message));
    if (taken.has(low(data.look.name))) problems.push(`name "${data.look.name}" is already on another slot; pick another`);
    if (!problems.length) break;
  }
  const d = data as { look: ModelLook; change: string };
  const look = d.look;
  if (problems.length) {
    if (recipeProblems(recipeOf(look as unknown as Record<string, unknown>), cam).length
      || checkExposure(look.exposure, cam, cam.drMinIso[look.dynamic_range] ?? 125)) {
      throw new PlanError(`Claude's new look still isn't something the camera can hold: ${problems.slice(0, 3).join("; ")}`,
        "invalid_look", 502, calls);
    }
    look.name = fallbackName(look.name ?? "", look.stop ?? "", cam.nameMax);
    if (taken.has(look.name.toLowerCase())) look.name = oldName || look.name;
  }
  const stop = stopNames.get(low(look.stop)) ?? current?.stop ?? [...stopNames.values()][0] ?? "Today";
  const out: DayLook = {
    ...recipeOf(look as unknown as Record<string, unknown>), when: look.when ?? "", tip: look.how ?? "",
    exposure: look.exposure, stop, focus: look.focus, drive: look.drive, reason: look.reason ?? "",
    based_on: look.based_on || current?.based_on || "", reuse: "", slot, status: "new", replaces: oldName || null,
    recipe_known: true, taste_note: current?.taste_note ?? null, change: d.change ?? "",
    adjusted: { said, calls, ms: Date.now() - t0, warnings: [...nameFixes, ...problems.map((p) => `after the retry: ${p}`)] },
  };
  if (look.design) out.design = structuredClone(look.design);
  // Only confirmed camera codes get written (as in a plan).
  const ideal = look.ideal_film_sim ? new Map([[low(out.name), String(look.ideal_film_sim)]]) : new Map<string, string>();
  out.adjusted?.warnings.push(...confirmDayLooks([out], ideal, cam));
  if (plan.shooting_mode === "automatic") {
    const comp = cam.expComps.includes(out.exposure.exp_comp) ? out.exposure.exp_comp : "0";
    const tip = automaticTip(out, comp);
    out.exposure = { aperture: "A", shutter: "A", iso: "A", exp_comp: comp, nd: false };
    if (out.focus === "M") out.focus = "S";
    out.clarity = 0;
    out.tip = tip;
  }
  if (out.design && (out.design.settings_signature !== expertSettingsSignature(out)
    || out.design.guidance_signature !== expertGuidanceSignature(out))) out.design.requires_review = true;
  const conflicts = assessPolicyLook({ look: out, policy: intent, isPrimary: true });
  if (conflicts.length) throw new PlanError("The revised look conflicts with your stated color choice. Your existing plan is unchanged.", "intent_conflict", 502, calls);
  const factual = checkRationale(out, cam);
  out.adjusted?.warnings.push(...factual.map(() => "Part of the explanation needs review; an unsupported claim was removed."));
  throwIfAborted(input.signal);
  return out;
}

// ================================================================== a plan coming back from the app

/** A plan the app sends back for /api/adjust: checked enough to build a prompt from and re-finalize. Unknown extra
 *  fields ride along untouched; the parts the engine reads are type-checked and every look's settings validated. */
export function planFromClient(raw: unknown, cam: CameraCaps): Plan {
  const bad = (why: string) => new PlanError(`That plan can't be adjusted: ${why}.`, "bad_plan", 400);
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw bad("it isn't a plan object");
  const p = structuredClone(raw) as Plan;
  // A returned client plan cannot certify source identity, permission or attribution after editing.
  delete p.recipe_references;
  delete p.recipe_knowledge;
  if (p.protected_slots !== undefined) p.protected_slots = protectedSlotsFrom(p.protected_slots, cam);
  if (!Array.isArray(p.day_looks) || p.day_looks.length > cam.slots) throw bad("day_looks is missing or too long");
  if (!Array.isArray(p.stops) || p.stops.length > 12) throw bad("stops is missing or too long");
  if (!p.conditions || typeof p.conditions !== "object" || typeof p.conditions.text !== "string") throw bad("conditions is missing");
  p.conditions.text = p.conditions.text.slice(0, 6000);
  if (!p.plan || typeof p.plan !== "object") p.plan = { summary: "", looks: [] };
  const seen = new Set<number>();
  for (const l of p.day_looks) {
    if (!l || typeof l !== "object") throw bad("a look isn't an object");
    if (!Number.isInteger(l.slot) || (l.slot as number) < 1 || (l.slot as number) > cam.slots || seen.has(l.slot as number)) throw bad("a look has no slot");
    seen.add(l.slot as number);
    if (typeof l.name !== "string" || typeof l.stop !== "string") throw bad("a look has no name or stop");
    if (l.recipe_known !== false && recipeProblems(recipeOf(l as unknown as Record<string, unknown>), cam).length) throw bad(`C${l.slot} isn't a camera look`);
    if (checkExposure(l.exposure, cam, 0)) throw bad(`C${l.slot} has dial settings the camera doesn't have`);
    if (l.status !== "new" && l.status !== "kept") l.status = "new";
    if (p.protected_slots?.includes(l.slot as number) && l.status !== "kept") throw bad(`C${l.slot} is protected`);
    l.when = String(l.when ?? "").slice(0, 200);
    l.tip = String(l.tip ?? "").slice(0, 300);
    l.reason = String(l.reason ?? "").slice(0, 300);
    l.why = String(l.why ?? "").slice(0, 300);
    l.based_on = String(l.based_on ?? "").slice(0, 60);
    l.focus = cam.focusModes.includes(l.focus) ? l.focus : "S";
    l.drive = cam.drives.includes(l.drive) ? l.drive : "S";
    l.replaces = typeof l.replaces === "string" ? l.replaces : null;
    l.reuse = typeof l.reuse === "string" ? l.reuse : "";
    l.taste_note = typeof l.taste_note === "string" ? l.taste_note : null;
    const design = recipeDesign(l.design, cam);
    if (design) l.design = { ...design, settings_signature: expertSettingsSignature(l),
      guidance_signature: expertGuidanceSignature(l),
      requires_review: design.requires_review || l.design?.requires_review === true
        || l.design?.settings_signature !== expertSettingsSignature(l)
        || l.design?.guidance_signature !== expertGuidanceSignature(l) };
    else delete l.design;
    checkRationale(l, cam);
  }
  const brief = photographicBrief(p.photographic_brief);
  if (brief) p.photographic_brief = brief;
  else delete p.photographic_brief;
  if (!Number.isInteger(p.primary_slot) || !p.day_looks.some((l) => l.slot === p.primary_slot)) p.primary_slot = null;
  p.expertise = expertReceipt(p.day_looks.flatMap((l) => l.design ? [l.design] : []), Boolean(brief), p.day_looks.length);
  for (const s of p.stops) {
    if (!s || typeof s.name !== "string") throw bad("a stop has no name");
    s.name = s.name.slice(0, 80);
    s.time = String(s.time ?? "").slice(0, 40);
    s.light = String(s.light ?? "").slice(0, 80);
    s.start = String(s.start ?? "");
    s.end = String(s.end ?? "");
  }
  if (p.camera_before !== null && p.camera_before !== undefined) {
    if (!Array.isArray(p.camera_before) || p.camera_before.length !== cam.slots) throw bad("camera_before must list every slot");
    p.camera_before = p.camera_before.map((c, i) => ({
      slot: i + 1, name: String(c?.name ?? "").slice(0, 40),
      recipe: c?.recipe && !recipeProblems(recipeOf(c.recipe as unknown as Record<string, unknown>), cam).length ? c.recipe : null,
    }));
  } else {
    p.camera_before = null;
  }
  if (p.camera !== null && p.camera !== undefined && !Array.isArray(p.camera)) throw bad("camera must be a list");
  return p;
}

/** Adjust + put the look in, in one go (what /api/adjust does). */
export async function adjustPlan(input: AdjustInput): Promise<{ look: DayLook; plan: Plan }> {
  const look = await adjustLook(input);
  const plan = putLook(input.plan, look, input.cam);
  delete plan.recipe_references;
  delete plan.recipe_knowledge;
  plan.expertise = expertReceipt(plan.day_looks.flatMap((l) => l.design ? [l.design] : []), Boolean(plan.photographic_brief), plan.day_looks.length);
  return { look, plan };
}
