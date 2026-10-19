// Shapes of the plan engine (a port of studio/plan.py). The Plan IS the plan file: plan.looks is what
// `dialin-cam load` writes positionally into C1…Ck and what the app's slot writer reads (Recipe + DayLook fields).

export type Exposure = { aperture: string; shutter: string; iso: string; exp_comp: string; nd: boolean };

export type PhotographicBrief = {
  intent: string; subjects: string[]; lighting: string[]; color_priorities: string[]; rendering_goal: string;
  observations: string[]; uncertainties: string[];
};

export type RecipeDesign = {
  purpose: string; scene_fit: string;
  choices: { setting: "film_sim" | "white_balance" | "dynamic_range" | "tone_curve" | "color" | "texture" | "exposure";
    reason: string; knowledge_ids: string[] }[];
  tradeoff: string; alternative: string; uncertainty: string;
  detail_level?: "compact" | "detailed";
  knowledge_ids?: string[];
  /** Local validation fields; model answers cannot set these. Rationale is never a device verification. */
  settings_signature?: string;
  guidance_signature?: string;
  requires_review?: boolean;
};

/** One look as the camera holds it: lib/fuji/recipe.ts `Recipe`, Swift `Recipe` (snake_case, same enum strings). */
export type RecipeFields = {
  name: string;
  film_sim: string;
  grain: string;
  color_chrome: string;
  color_chrome_fx_blue: string;
  white_balance: string;
  kelvin: number;
  wb_shift_r: number;
  wb_shift_b: number;
  dynamic_range: string;
  highlight: number;
  shadow: number;
  color: number;
  sharpness: number;
  noise_reduction: number;
  clarity: number;
  why: string;
};

export const RECIPE_KEYS = [
  "name", "film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "kelvin", "wb_shift_r",
  "wb_shift_b", "dynamic_range", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity", "why",
] as const;

/** A look in the model's answer (PLAN_SCHEMA / ADJUST_SCHEMA). */
export type ModelLook = RecipeFields & {
  /** Optional reference chosen from a server-supplied shortlist; final attribution is computed locally. */
  recipe_reference_id?: string | null;
  design?: RecipeDesign;
  /** The sim the model would have picked if every one were available (prompts.ts); never written. */
  ideal_film_sim?: string;
  stop: string;
  when: string;
  reuse?: string;
  /** Exact camera slot for reuse, when the planner is preparing a full palette. 0 means a new/past look. */
  reuse_slot?: number;
  based_on: string;
  reason: string;
  exposure: Exposure;
  focus: string;
  drive: string;
  how: string;
};

export type ModelStop = { name: string; start: string; end: string; light: string };

export type ModelPlan = {
  photographic_brief?: PhotographicBrief;
  primary_look?: string;
  summary: string;
  count_why: string;
  stops: ModelStop[];
  looks: ModelLook[];
  replace: { name: string; why: string }[];
};

export type LookStatus = "new" | "kept";

/** A look of the day after assembly: Recipe + DayLook (when, tip, exposure) + where it goes. */
export type DayLook = RecipeFields & {
  design?: RecipeDesign;
  when: string;
  tip: string;
  exposure: Exposure;
  stop: string;
  focus: string;
  drive: string;
  reason: string;
  based_on: string;
  reuse: string;
  slot: number | null;
  status: LookStatus;
  replaces: string | null;
  recipe_known: boolean;
  taste_note: string | null;
  change?: string;
  adjusted?: { said: string; calls: CallMeta[]; ms: number; warnings: string[] };
};

/** One slot of the camera before the plan: name, and the recipe when known. */
export type CameraSlot = { slot: number; name: string; recipe: RecipeFields | null };

export type Place = { name: string; lat: number; lon: number };

export type HourSky = { h: number; cloud: number; rain: number; temp: number; code: number; wind: number };

export type Block = { label: string; hours: string; cloud: number; rain: number; sky: string };

/** lib/dayplan.ts DayConditions plus timezone, temps, chip, hours and source (studio/plan.py day_conditions). */
export type Conditions = {
  place: Place | null;
  date: string;
  sunrise: string | null;
  sunset: string | null;
  goldenEvening: string | null;
  blueHour: string | null;
  uvMax: number | null;
  blocks: Block[];
  text: string;
  timezone: string;
  temps: string | null;
  hours: HourSky[];
  chip: string;
  source: "open-meteo" | "computed" | "none";
};

export type TasteRow = { look: string; hearted: number; shot: number; date: string; place: string };

export type TasteSummary = {
  look: string;
  hearted: number;
  shot: number;
  dates: string[];
  where: string[];
  rate: number;
  score: number;
  favorite: boolean;
  quote: string;
};

export type Usage = {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_creation_input_tokens: number;
};

export type CallMeta = {
  task: string;
  ok: boolean;
  model: string;
  via: string;
  ms: number;
  error: string | null;
  usage: Usage | null;
  usd: number | null;
  requested_model?: string;
  served_model?: string | null;
  usage_complete?: boolean;
  reported_cost_usd?: number | null;
  tries?: unknown[];
};

export type SlotLine = { slot: number | null; name: string; status: LookStatus; replaces: string | null; line: string };

/** One look as the plan file carries it (plan.looks): Recipe + DayLook + Studio extras. */
export type FileLook = RecipeFields & {
  when: string;
  tip: string;
  exposure: Exposure;
  slot: number;
  status: string;
  replaces?: string | null;
  stop?: string;
  focus?: string;
  drive?: string;
  on_camera?: string[];
  reason?: string;
  based_on?: string;
  taste_note?: string | null;
  rewrite?: boolean;
};

export type Write = {
  /** "load": `dialin-cam load` can write plan.looks into C1…Ck as is. "per_slot": write each slot in `slots` on
   *  its own (a slot in the way can't be rewritten). "none": nothing to write. */
  mode: "load" | "per_slot" | "none";
  slots: number[];
  rewrites_unchanged: string[];
  why: string;
  argv: null;
  per_slot: [];
  live: [];
};

export type CheatRow = {
  slot: number;
  c: string;
  name: string;
  status: LookStatus;
  saved: string;
  replaces: string | null;
  change: string[];
  dial_line: string;
  how: string;
  when: string;
  reason: string;
  taste_note: string | null;
};

export type CheatStop = { name: string; time: string; light: string; light_changes: string[]; looks: CheatRow[] };

export type CheatSheet = {
  title: string;
  stops: CheatStop[];
  light_changes: string[];
  footer: string;
  text: string;
  chars: number;
  fits: boolean;
};

export type PlanStop = { name: string; start: string; end: string; time: string; light: string };

export type Plan = {
  photographic_brief?: PhotographicBrief;
  primary_slot?: number | null;
  kind: string;
  created_at: string;
  said: string;
  conditions: Conditions;
  plan: { summary: string; looks: FileLook[] };
  model: string | null;
  ms: number;
  count_why: string;
  stops: PlanStop[];
  day_looks: DayLook[];
  camera: { slot: number; name: string; status: string }[] | null;
  camera_before: CameraSlot[] | null;
  slots: SlotLine[];
  replace_why: Record<string, string>;
  taste: Omit<TasteSummary, "dates" | "score">[];
  warnings: string[];
  write: Write;
  cheat_sheet: CheatSheet;
  notes?: string[];
  calls?: CallMeta[];
  learned?: string[];
  adjustments?: { slot: number; said: string | null; change: string | null; was: string | null; name: string }[];
  protected_slots?: number[];
  requested_count?: number;
  palette_complete?: boolean;
  blocked_slots?: number[];
  missing_slots?: number[];
  [extra: string]: unknown;
};

/** A plain sentence for the person, plus a code that is safe to log (the message may quote their words). */
export class PlanError extends Error {
  calls?: CallMeta[];
  constructor(
    message: string,
    public code: string = "plan_failed",
    public status: number = 502,
    calls?: CallMeta[],
  ) {
    super(message);
    this.name = "PlanError";
    this.calls = calls;
  }
}
