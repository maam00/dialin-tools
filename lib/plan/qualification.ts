// Synthetic request fixtures and objective checks. No model call, photograph, live forecast or camera operation.
import { randomUUID } from "node:crypto";
import { X100VI } from "../cameras.js";
import type { RecipeKnowledge } from "../recipes/library.js";
import { EXPERT_SCENARIOS, type ExpertScenario } from "./expert-evaluation.js";
import { expertSettingsSignature } from "./expert-metadata.js";
import { effectiveRecipeSignature } from "./expert-policy.js";
import { planHandler } from "./http.js";
import { recipeProblems } from "./looks.js";
import type { Ask } from "./model.js";
import type { Plan, RecipeFields } from "./types.js";
import type { BenchmarkArm, BenchmarkOutcome } from "./benchmark.js";

const recipe = (name: string, index = 0): RecipeFields => ({ name, film_sim: "Classic Chrome", grain: "Weak Small",
  color_chrome: "Weak", color_chrome_fx_blue: "Off", white_balance: "Auto", kelvin: 0, wb_shift_r: index - 3,
  wb_shift_b: 3 - index, dynamic_range: "DR200", highlight: 0, shadow: 1, color: 0, sharpness: -1, noise_reduction: -4,
  clarity: 0, why: "Synthetic known camera tuple for the qualification fixture." });
const slots = () => Array.from({ length: 7 }, (_, index) => ({ slot: index + 1, name: `Familiar ${index + 1}`, recipe: recipe(`Familiar ${index + 1}`, index) }));
const existing = (id: string) => structuredClone(EXPERT_SCENARIOS.find((scenario) => scenario.id === id)!);

export type QualificationScenario = ExpertScenario & {
  pair?: string;
  requireAllNew?: "color" | "monochrome";
  expectedMissing?: number[];
  expectedIntent?: boolean;
  expectedStops?: string[];
  primaryFocus?: string;
};
export const QUALIFICATION_SCENARIOS: readonly QualificationScenario[] = [
  { ...existing("natural-faces"), pair: "same-beach-different-taste", expectedIntent: true },
  { ...existing("warm-editorial-faces"), pair: "same-beach-different-taste", expectedIntent: true },
  { ...existing("mixed-market"), expectedIntent: true },
  { id: "food-color", title: "Food and product hue under a window and warm lamps", camera_model: "X100VI", firmware: "1.10",
    said: "Photograph tomatoes, green herbs and a red packaged product beside a restaurant window. Keep the whole palette color-only. Believable food and product hue matter more than a nostalgic cast; preserve the atmosphere of the warm room without pretending every light can be neutralized.",
    taste: "Restrained documentary color. Today accurate-looking subject color takes priority over my warm-memory favorites.",
    scene: { source: "description", observations: ["Window daylight on food", "Warm overhead lamps", "Saturated red packaging", "Green herbs", "White plate"], unknowns: ["Lamp spectra", "Actual subject colors and exposure", "Which source dominates each surface"] },
    constraints: { require_color: true }, requireAllNew: "color", expectedIntent: true,
    review_questions: { subject_color: ["Are hue fidelity, saturation and texture distinguished without claiming calibration?"], uncertainty: ["Does a single WB admit its mixed-light compromise?"], intent_taste: ["Does food-color priority override a nostalgic default?"] } },
  { ...existing("freeze-children"), id: "motion-auto", primaryFocus: "C", expectedIntent: true,
    said: "Children running toward me in a dim room. I want believable color and frozen faces at 1/500 or faster. Recommend AF-C for the main action look. Prepare the full seven-slot palette in automatic mode, but tell me which physical/Auto ISO minimum-shutter setup I must check; Program AE and rendering settings alone cannot guarantee the shutter.",
    review_questions: { motion_operation: ["Does the primary action look use the requested AF-C guidance?", "Is the 1/500 minimum a user setup/check, rather than a claim the app set Auto ISO or can guarantee light?"], compatibility: ["Does stored rendering stay separate from physical dials and AF?"] } },
  { id: "multi-stop", title: "A real outing with three declared stops", camera_model: "X100VI", firmware: "1.10",
    said: "Prepare all seven looks for this outing: Beach 10:00-12:00 with friends in hard sun; Market 13:00-14:30 under daylight and fluorescent lamps; Dinner 19:00-21:00 with moving people and warm bulbs. Give useful choices for these actual subjects, not a fixed daytime checklist. Keep color available for faces and food; an optional monochrome alternative is welcome.",
    taste: "Believable color with a separate deliberate nostalgic alternative, not seven nearly identical names.",
    scene: { source: "description", observations: ["Beach: bright sand and faces", "Market: reflective fish and mixed sources", "Dinner: warm bulbs and moving people"], unknowns: ["Actual metering at each stop", "Weather", "Lamp spectra"] },
    expectedStops: ["Beach", "Market", "Dinner"], expectedIntent: true,
    review_questions: { recipe_coherence: ["Do seven distinct recipes have useful roles across the supplied three stops?"], uncertainty: ["Does it avoid inventing forecast or metered exposure?"], motion_operation: ["Are dinner motion limits and any AF/drive exceptions visible?"] } },
  { id: "mono-protected", title: "Monochrome request with a protected color exception", camera_model: "X100VI", firmware: "1.10",
    said: "I want all seven looks in monochrome for a graphic architecture walk. C3 is my existing color favorite and must stay exactly as it is, even when that conflicts with the monochrome request. Keep C3 in C3, make all new looks monochrome, and clearly disclose that exception instead of claiming the entire palette satisfies the request.",
    taste: "Deep forms, but distinct gentle and hard tonal alternatives. C3 is protected; its current color is not overwrite permission.",
    scene: { source: "description", observations: ["Concrete forms", "Bright sky", "Deep doorway shadows"], unknowns: ["Actual clipping", "Desired strength of monochrome contrast"] },
    protected_slots: [{ slot: 3, recipe: recipe("Familiar 3", 2) }], requireAllNew: "monochrome", expectedIntent: false,
    review_questions: { preservation: ["Does C3 remain exact and unwritten while the protected color conflict is disclosed?"], recipe_coherence: ["Are monochrome filters and tones chosen for forms rather than counting inactive color values as diversity?"] } },
  { id: "unknown-protected", title: "A protected but unread bank stays unresolved", camera_model: "X100VI", firmware: "1.10",
    said: "Prepare my seven-slot day palette for daylight portraits and dinner, but C5 is reserved. I know its name, not its actual settings. Never infer its recipe from the name, rewrite it or claim all seven banks are ready. Give me the six safe candidates and ask for a fresh read of C5.",
    taste: "Natural color and reviewable choices. A reserved name is not a recipe snapshot.",
    scene: { source: "description", observations: ["Faces in daylight", "Warm dinner later", "C5 recipe unread"], unknowns: ["Actual C5 settings", "Actual dinner lighting"] },
    protected_slots: [{ slot: 5, recipe: null }], expectedMissing: [5], expectedIntent: true,
    review_questions: { preservation: ["Is C5 left unresolved and excluded from writes?"], uncertainty: ["Does the result withhold full palette readiness without inventing the reserved recipe?"] } },
];

export function qualificationBody(scenario: QualificationScenario, reasoningMode: BenchmarkArm) {
  const cameraSlots: { slot: number; name: string; recipe: RecipeFields | null }[] = slots();
  for (const protectedSlot of scenario.protected_slots ?? []) {
    cameraSlots[protectedSlot.slot - 1] = { slot: protectedSlot.slot, name: protectedSlot.recipe?.name ?? "Reserved unread", recipe: protectedSlot.recipe };
  }
  return { said: `${scenario.said}\nSynthetic scene observations: ${scenario.scene.observations.join("; ")}. Unknown: ${scenario.scene.unknowns.join("; ")}.`,
    camera: { model: scenario.camera_model, firmware: scenario.firmware, slots: cameraSlots },
    taste: { notes: scenario.taste }, count: 7, protected_slots: (scenario.protected_slots ?? []).map((slot) => slot.slot),
    shooting_mode: "automatic", reasoning_mode: reasoningMode === "concise" ? "compact" : reasoningMode };
}

export function qualifyPlan(plan: Plan, scenario: QualificationScenario) {
  const failures: string[] = [];
  const check = (ok: boolean, code: string) => { if (!ok) failures.push(code); };
  const expectedMissing = scenario.expectedMissing ?? [];
  const known = plan.day_looks.filter((look) => look.recipe_known !== false);
  check(plan.requested_count === 7, "requested_count_seven");
  check(plan.palette_complete === (expectedMissing.length === 0), "honest_palette_completeness");
  check(known.length === 7 - expectedMissing.length, "expected_known_recipe_count");
  check(new Set(known.map((look) => look.slot)).size === known.length && known.every((look) => Number.isInteger(look.slot) && look.slot! >= 1 && look.slot! <= 7), "unique_legal_slots");
  check(known.every((look) => recipeProblems(look, X100VI).length === 0), "all_known_recipes_camera_valid");
  check(JSON.stringify([...(plan.missing_slots ?? [])].sort()) === JSON.stringify([...expectedMissing].sort()), "honest_missing_slots");
  check(plan.primary_selection === "declared" && known.some((look) => look.slot === plan.primary_slot), "declared_existing_primary");
  check(plan.intent_satisfied === (scenario.expectedIntent ?? true), "honest_intent_status");
  check(!Array.isArray(plan.factual_issues) || !plan.factual_issues.length, "no_known_factual_issues");
  const fresh = known.filter((look) => look.status === "new");
  check(new Set(fresh.map(effectiveRecipeSignature)).size === fresh.length, "distinct_active_new_recipes");
  check(fresh.every((look) => look.clarity === 0), "automatic_new_clarity_zero");
  check(known.every((look) => look.exposure.aperture === "A" && look.exposure.shutter === "A" && look.exposure.iso === "A"), "automatic_exposure_guidance");
  const writeSlots = plan.write.slots;
  check(new Set(writeSlots).size === writeSlots.length && writeSlots.every((slot) => fresh.some((look) => look.slot === slot)), "writes_only_new_unique_slots");
  for (const protectedSlot of scenario.protected_slots ?? []) {
    check(!writeSlots.includes(protectedSlot.slot), `protected_C${protectedSlot.slot}_unwritten`);
    const actual = known.find((look) => look.slot === protectedSlot.slot);
    if (protectedSlot.recipe) check(!!actual && actual.status === "kept" && actual.name === protectedSlot.recipe.name
      && expertSettingsSignature(actual) === expertSettingsSignature(protectedSlot.recipe), `protected_C${protectedSlot.slot}_exact`);
    else check(!actual && (plan.blocked_slots ?? []).includes(protectedSlot.slot), `unread_C${protectedSlot.slot}_withheld`);
  }
  if (scenario.requireAllNew) check(fresh.every((look) => X100VI.monoSims.has(look.film_sim) === (scenario.requireAllNew === "monochrome")), "all_new_rendering_intent");
  if (scenario.primaryFocus) check(known.find((look) => look.slot === plan.primary_slot)?.focus === scenario.primaryFocus, "requested_primary_focus_guidance");
  if (scenario.primaryFocus && scenario.constraints?.freeze_min_denominator) {
    const minimum = `1/${scenario.constraints.freeze_min_denominator}`;
    check(known.find((look) => look.slot === plan.primary_slot)?.tip.includes(minimum) === true
      && plan.cheat_sheet.stops.flatMap((stop) => stop.looks).some((look) => look.slot === plan.primary_slot && look.how.includes(minimum)),
    "requested_minimum_shutter_check_visible");
  }
  if (scenario.expectedStops) for (const name of scenario.expectedStops) check(plan.stops.some((stop) => stop.name.toLowerCase().includes(name.toLowerCase())
    && /^\d{2}:\d{2}$/.test(stop.start) && /^\d{2}:\d{2}$/.test(stop.end)), `declared_stop_${name.toLowerCase()}`);
  return { objectivePass: failures.length === 0, failures, manualReviewRequired: true, aestheticScore: null,
    reviewQuestions: scenario.review_questions,
    limitations: ["Menu-valid settings are not physical camera acceptance.", "Regex/structure checks cannot establish photographic taste or that physical setup occurred."] };
}

/** A changed intention should be inspected against the same observations. Difference is not taste proof. */
export function qualificationPairs(outcomes: readonly BenchmarkOutcome[]) {
  const pairs = new Map<string, QualificationScenario[]>();
  for (const scenario of QUALIFICATION_SCENARIOS) if (scenario.pair) {
    pairs.set(scenario.pair, [...(pairs.get(scenario.pair) ?? []), scenario]);
  }
  const groups = new Map<string, { arm: BenchmarkArm; repetition: number }>();
  for (const outcome of outcomes) groups.set(`${outcome.arm}:${outcome.repetition}`, { arm: outcome.arm, repetition: outcome.repetition });
  return [...groups.values()].flatMap(({ arm, repetition }) => [...pairs].map(([pair, scenarios]) => {
    const matching = scenarios.map((scenario) => outcomes.find((outcome) => outcome.fixture === scenario.id && outcome.arm === arm && outcome.repetition === repetition));
    const primaries = matching.map((outcome) => outcome?.ok && outcome.plan?.primary_selection === "declared"
      ? outcome.plan.day_looks.find((look) => look.slot === outcome.plan!.primary_slot && look.recipe_known !== false) : undefined);
    const available = primaries.every(Boolean);
    const settingsDiffer = available ? new Set(primaries.map((look) => effectiveRecipeSignature(look!))).size > 1 : null;
    return { pair, arm, repetition, fixtures: scenarios.map((scenario) => scenario.id),
      status: matching.some((outcome) => !outcome) ? "incomplete" : !available ? "unavailable" : "ready_for_review",
      declaredPrimarySlots: matching.map((outcome) => outcome?.plan?.primary_selection === "declared" ? outcome.plan.primary_slot : null),
      activePrimarySettingsDiffer: settingsDiffer,
      reviewFlags: settingsDiffer === false ? ["same_scene_primary_settings_unchanged"] : [],
      manualReviewRequired: true, aestheticScore: null,
      limitation: "Different settings do not establish that either rendering matches the intended taste; unchanged settings need review, not an invented quality score." };
  }));
}

export class QualificationHTTPError extends Error {
  constructor(public status: number, public code: string, public body: unknown) { super(`Synthetic plan handler returned ${status} (${code})`); }
}
export async function runQualificationHTTP(input: { scenario: QualificationScenario; arm: BenchmarkArm; ask: Ask;
  knowledge?: RecipeKnowledge; signal?: AbortSignal; onReceipt?: (receipt: { requestID: string; status: number; body: unknown; logs: unknown[] }) => void }) {
  const logs: unknown[] = [];
  const handler = planHandler({ ask: input.ask, env: {}, recipeKnowledge: input.knowledge,
    outputMode: input.arm === "concise" ? "concise" : "legacy", log: (line) => logs.push(line) });
  const requestID = randomUUID();
  const response = await handler(new Request("http://synthetic.local/api/plan", { method: "POST", signal: input.signal,
    headers: { "content-type": "application/json", "x-device-id": "synthetic-qualification-device", "x-request-id": requestID },
    body: JSON.stringify(qualificationBody(input.scenario, input.arm)) }));
  const body = await response.json();
  input.onReceipt?.({ requestID, status: response.status, body, logs });
  if (response.status !== 200) throw new QualificationHTTPError(response.status, typeof body.code === "string" ? body.code : "http_error", body);
  return body as Plan;
}
