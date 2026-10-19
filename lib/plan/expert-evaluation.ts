// Offline evaluation, never a model call or a camera write. Setting validity is machine-checkable;
// photographic judgment needs an evidence-backed human review. A reference ID or a fluent explanation
// is not proof that a recipe looks good in a photograph.
import { cameraFor, type CameraCaps, writable } from "../cameras.js";
import { expertSettingsSignature } from "./expert-metadata.js";
import { checkExposure, recipeProblems, slotName } from "./looks.js";
import { RECIPE_KEYS, type Exposure, type RecipeFields } from "./types.js";

export type ExpertPhotographicBrief = {
  intent: string;
  subjects: string[];
  lighting: string[];
  color_priorities: string[];
  rendering_goal: string;
  observations: string[];
  uncertainties: string[];
};

export type ExpertLookDesign = {
  purpose: string;
  scene_fit: string;
  choices: { setting: string; reason: string; knowledge_ids: string[] }[];
  tradeoff: string;
  alternative: string;
  uncertainty: string;
  settings_signature?: string;
  requires_review?: boolean;
  detail_level?: "compact" | "detailed";
  knowledge_ids?: string[];
};

/** Structural subset usable with raw ModelLooks, assembled DayLooks, or persisted plans. */
export type ExpertCandidateLook = RecipeFields & {
  status?: string;
  slot?: number | null;
  recipe_known?: boolean;
  reason?: string;
  exposure?: Exposure;
  focus?: string;
  drive?: string;
  design?: ExpertLookDesign;
};

export type ExpertCriterion = "intent_taste" | "subject_color" | "light_contrast" | "recipe_coherence"
  | "motion_operation" | "uncertainty" | "compatibility" | "preservation";

export type ExpertRubricItem = {
  id: ExpertCriterion;
  weight: number;
  question: string;
};

export const EXPERT_RUBRIC: readonly ExpertRubricItem[] = [
  { id: "intent_taste", weight: 20, question: "Does the recommendation serve the stated intention and taste, rather than substituting a generic aesthetic or keep-rate winner?" },
  { id: "subject_color", weight: 15, question: "Does it explain the treatment of the important subject, skin and colors without implying that one simulation suits every person or that a JPEG is colorimetrically exact?" },
  { id: "light_contrast", weight: 15, question: "Does it connect light direction, contrast and light sources to tones, dynamic range and white balance, with the subject's priority clear?" },
  { id: "recipe_coherence", weight: 15, question: "Do the simulation, tone curve, color effects, grain and detail choices work together for the rendering goal, with a meaningful tradeoff and alternative?" },
  { id: "motion_operation", weight: 10, question: "Can a photographer act on this without missing the intended moment, and does the guidance distinguish subject motion from camera shake and stored rendering from physical controls?" },
  { id: "uncertainty", weight: 10, question: "Does it separate observations, assumptions and unknowns, giving one useful verification step rather than claiming exact metering or white balance from a phone image?" },
  { id: "compatibility", weight: 10, question: "Are capabilities and writable substitutions truthful for this body and firmware, and are effects that may be inactive or overridden identified?" },
  { id: "preservation", weight: 5, question: "Are kept values, reserved slots and creative choices preserved, with suggestions clearly separate from permission to change them?" },
];

/** Same anchors for every dimension; a reviewer must cite candidate evidence, not just supply a number. */
export const EXPERT_SCORE_ANCHORS = {
  0: "Missing or contradicts the brief; harmful or unsupported advice.",
  1: "Generic labels or settings with little connection to the scene or the person's intent.",
  2: "Plausible and usable, but an important priority, interaction or tradeoff is unexplained.",
  3: "Scene-specific, coherent and practical; choices, limits and a useful alternative are explained.",
  4: "Precise judgment across competing priorities, grounded in evidence and uncertainty, without overstating what is known.",
} as const;

export type ExpertReview = {
  criterion: ExpertCriterion;
  score: 0 | 1 | 2 | 3 | 4;
  /** Quoted decision/setting or a concrete omission from the candidate, not a reference ID alone. */
  evidence: string;
  explanation: string;
};

export type ExpertScenario = {
  id: string;
  title: string;
  camera_model: string;
  firmware: string;
  said: string;
  taste: string;
  scene: { source: "description" | "phone-photo"; observations: readonly string[]; unknowns: readonly string[] };
  /** Explicit requirements, not aesthetic preferences. Fast shutter is never mandatory for intentional blur. */
  constraints?: { require_color?: boolean; freeze_min_denominator?: number };
  protected_slots?: readonly { slot: number; recipe: RecipeFields | null }[];
  review_questions: Partial<Record<ExpertCriterion, readonly string[]>>;
};

const keptPortrait: RecipeFields = {
  name: "Soft faces", film_sim: "Astia", grain: "Off", color_chrome: "Off", color_chrome_fx_blue: "Off",
  white_balance: "Shade", kelvin: 0, wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR200",
  highlight: -1, shadow: 0, color: 0, sharpness: -1, noise_reduction: 0, clarity: 0,
  why: "My familiar portrait rendering.",
};

const scene = (observations: string[], unknowns: string[] = [], source: ExpertScenario["scene"]["source"] = "description") =>
  ({ source, observations, unknowns });
const example = (value: Omit<ExpertScenario, "camera_model" | "firmware"> & Partial<Pick<ExpertScenario, "camera_model" | "firmware">>): ExpertScenario =>
  ({ camera_model: "X100VI", firmware: "1.10", ...value });

/** Benchmark briefs, not golden recipes. Counterfactual pairs deliberately share light but change intent. */
export const EXPERT_SCENARIOS: readonly ExpertScenario[] = [
  example({ id: "natural-faces", title: "Natural faces in hard afternoon light",
    said: "Photograph my friends at the beach. Keep every person's skin believable and the red swimsuit distinct; no orange vintage cast.",
    taste: "Usually likes restrained documentary color. A highly saturated favorite had more keepers, but I asked for natural faces today.",
    scene: scene(["Hard side light", "Bright sand", "Several skin tones", "Red swimsuit against blue water"]), constraints: { require_color: true },
    review_questions: { intent_taste: ["Does today's explicit request take precedence over historical keep rates?"], subject_color: ["How are skin, the red garment and blue water prioritized without stereotyping skin tones?"], light_contrast: ["How are bright sand and facial shadows balanced?"], recipe_coherence: ["Are warm shifts, color compression and texture justified for believable faces?"] } }),
  example({ id: "warm-editorial-faces", title: "Warm editorial faces in the same light",
    said: "Same beach and people, but this time I want warm nostalgic editorial color. Let the warmth show while keeping faces usable.",
    taste: "Enjoys amber warmth and visible grain; does not want a neutral correction as the default.",
    scene: scene(["Hard side light", "Bright sand", "Several skin tones", "Red swimsuit against blue water"]), constraints: { require_color: true },
    review_questions: { intent_taste: ["Does it change its rendering rationale from natural-faces without overriding the requested warmth?"], subject_color: ["Does it acknowledge the chosen color cast on faces and garments?"], recipe_coherence: ["Is the balance of warmth, saturation and texture deliberate rather than a renamed generic recipe?"] } }),
  example({ id: "backlit-face", title: "A face against a bright window",
    said: "I want to see my father's expression, with a gentle face and some detail outside the window.", taste: "Soft color, no crunchy shadows.",
    scene: scene(["Face in shade", "Bright window behind", "High scene contrast"], ["Actual highlight clipping and metered exposure"]),
    review_questions: { light_contrast: ["Is the face priority explicit, and is preserving every window highlight treated as a tradeoff rather than guaranteed?", "Does it distinguish exposure, DR capture headroom and JPEG highlight/shadow rendering?"], subject_color: ["Will the proposed contrast retain facial detail?"], uncertainty: ["What should the photographer inspect before committing?"] } }),
  example({ id: "graphic-silhouette", title: "A deliberate silhouette at that window",
    said: "Use that bright window to make a graphic silhouette. I do not want the face lifted.", taste: "Deep shapes and crisp structure; black and white is welcome.",
    scene: scene(["Face in shade", "Bright window behind", "High scene contrast"]),
    review_questions: { intent_taste: ["Does it preserve intentional shadow instead of applying the backlit-face solution?"], light_contrast: ["Are sky/window exposure and silhouette tones coherent?"], recipe_coherence: ["Is a color or monochrome solution justified without declaring either mandatory?"] } }),
  example({ id: "mixed-market", title: "Skin, fish and signs under mixed market light",
    said: "Document the fish market. Keep the vendor's face believable but let the fluorescent and daylight atmosphere remain.", taste: "Muted documentary color, no green faces, not sterile neutral light.",
    scene: scene(["Window daylight", "Fluorescent overhead light", "Skin", "Silver fish", "Colored signage"], ["Lamp spectra", "Whether the face receives one or both sources"]), constraints: { require_color: true },
    review_questions: { light_contrast: ["Does it select a subject/source priority and admit a single WB cannot neutralize different sources everywhere?"], subject_color: ["Do fish highlights and signs retain useful separation while skin is protected?"], uncertainty: ["Is there a test-frame or subject-position step instead of promising perfect mixed-light correction?"] } }),
  example({ id: "candle-and-flash", title: "Warm dinner with a possible flash",
    said: "Candlelit dinner portraits, with warmth left in the room. I may add a small flash if people move.", taste: "Warm, intimate faces; subtle texture.",
    scene: scene(["Warm candles", "Moving people", "Possible flash"], ["Flash use and color", "Actual ambient level", "Skin illumination"]),
    review_questions: { light_contrast: ["Does it distinguish ambient warmth from flash-lit skin and explain the WB compromise?"], motion_operation: ["Is flash a conditional option rather than an assumed active control?"], uncertainty: ["Is a precise Kelvin number presented as a starting rendering choice, not measured illumination?"] } }),
  example({ id: "freeze-children", title: "Children running in dim indoor light",
    said: "Freeze my children running toward me indoors, using at least 1/500. Sharp moments matter more than clean low-ISO files.", taste: "Color, natural faces. Do not trade away motion for fine texture.",
    scene: scene(["Running children", "Indoor window and LED light"], ["Metered light level", "LED flicker behavior"]), constraints: { require_color: true, freeze_min_denominator: 500 },
    review_questions: { motion_operation: ["Does the shutter/Auto ISO guidance protect subject motion and allow higher ISO when required?", "Are focus/drive, clarity processing and potential electronic-shutter/LED problems addressed appropriately?"], recipe_coherence: ["Do texture and noise choices support responsiveness rather than promise noise-free action?"] } }),
  example({ id: "intentional-pan", title: "Deliberate motion on a bright street",
    said: "A cyclist crossing the street: I want a flowing pan with streaks, not a frozen sports frame.", taste: "Graphic motion, color or black and white both welcome.",
    scene: scene(["Cyclist moving across frame", "Bright daylight"], ["Panning speed", "Exposure at chosen slow shutter"]),
    review_questions: { intent_taste: ["Does explicit blur intent override the usual fast-motion default?"], motion_operation: ["Is slow shutter, panning technique and a bright-light ND option explained as an experiment?"], light_contrast: ["Are ND and aperture used to make the intentional slow shutter feasible without inventing control automation?"] } }),
  example({ id: "phone-neon", title: "A phone image makes a dark street look bright",
    said: "Use this phone scene photo for portraits outside a neon bar. Keep colored signs and atmosphere, with faces still readable.", taste: "Moody color rather than a daylight-looking street.",
    scene: scene(["Neon signs", "Dark sky", "Face near a storefront", "Phone HDR lifts the shadows"], ["Metered light level", "Phone processing", "Exact light color", "Subject movement"], "phone-photo"), constraints: { require_color: true },
    review_questions: { uncertainty: ["Are visible scene cues separated from phone auto-exposure, HDR and color processing?", "Does it avoid exact EV/Kelvin or guaranteed shutter claims from image brightness alone?"], light_contrast: ["Are sign highlights and facial exposure explicitly traded off?"], motion_operation: ["Does the practical check adapt to whether the person is moving?"] } }),
  example({ id: "red-product", title: "Saturated red fabric with texture",
    said: "Photograph this red jacket for a casual shop listing. Red hue and fabric texture matter more than a fashionable film look.", taste: "Clean, believable product color; no monochrome.",
    scene: scene(["Saturated red fabric", "Soft window light", "White wall"], ["Display color management", "Exact fabric color"]), constraints: { require_color: true },
    review_questions: { subject_color: ["Are saturation, hue and texture distinct priorities, and is exact color accuracy kept outside an uncalibrated JPEG promise?"], recipe_coherence: ["Is Color Chrome considered for useful separation without implying it fixes clipping or universally improves skin?"], compatibility: ["Are inactive monochrome color controls or irrelevant blue effects avoided or explained?"] } }),
  example({ id: "protected-favorite", title: "A familiar portrait bank stays exactly yours",
    said: "Build today's market and dinner looks, but leave C3 Soft faces exactly as it is even if you prefer another portrait recipe.", taste: "My familiar C3 look is protected. Suggestions are welcome in other slots only.",
    scene: scene(["Daylight market", "Warm dinner"]), protected_slots: [{ slot: 3, recipe: keptPortrait }],
    review_questions: { preservation: ["Is C3 kept in place without any setting/name substitution or write target?"], compatibility: ["Does it distinguish an existing valid but unmapped Astia/Shade/NR0 look from a new writable recipe?", "Are unrepresented kept states such as D Range Priority, Smooth Skin or monochrome toning treated as unknown where relevant, rather than inferred from this recipe snapshot?"], intent_taste: ["Are alternatives offered without overriding the protected preference?"] } }),
  example({ id: "unknown-protected", title: "An unread reserved bank is not an invitation to invent",
    said: "Prepare the day, but C5 is mine. Its name is known and its actual recipe has not been read.", taste: "Keep C5 untouched until I decide otherwise.",
    scene: scene(["Seven-bank day palette requested"], ["Actual C5 recipe"]), protected_slots: [{ slot: 5, recipe: null }],
    review_questions: { preservation: ["Does it leave C5 explicitly unresolved rather than infer a recipe from its name or mark the entire palette ready?"], uncertainty: ["Is a fresh read request the next step for the unknown protected bank?"] } }),
  example({ id: "unsupported-body", title: "A similar Fujifilm body is still unsupported",
    camera_model: "X100V", said: "Make these looks for my X100V and load them wirelessly.", taste: "Warm documentary color.",
    scene: scene(["User names X100V"], ["Settings-file layout and accepted writes"]),
    review_questions: { compatibility: ["Does it refuse to borrow the X100VI layout or claim tested wireless loading merely because the bodies share simulations?"], uncertainty: ["Are any general rendering ideas clearly separated from a supported camera preparation claim?"] } }),
];

export type ExpertIssue = { code: string; message: string; look_index?: number; slot?: number };
export type ExpertEvaluation = {
  scenario_id: string;
  /** A compatible recommendation is not physical camera acceptance or photographic taste proof. */
  objective_pass: boolean;
  violations: ExpertIssue[];
  explanation_gaps: ExpertIssue[];
  reviewer_questions: { criterion: ExpertCriterion; weight: number; questions: string[] }[];
  review_errors: string[];
  reviewed_dimensions: number;
  /** Null until all eight dimensions have one valid, evidence-backed human review. */
  human_score: number | null;
  verdict: "blocked" | "needs_explanation" | "needs_review" | "revise" | "review_pass";
};

export type ExpertEvaluationInput = {
  scenario: ExpertScenario | string;
  /** Omission resolves the scenario model; explicit null represents unsupported capability. */
  camera?: CameraCaps | null;
  looks: readonly ExpertCandidateLook[];
  photographic_brief?: ExpertPhotographicBrief;
  /** The actual assembled write intent, when evaluating a complete plan. */
  write_slots?: readonly number[];
  /** Explicit scope for this benchmark. Default retains the historical strict all-look evaluation. */
  constraint_scope?: "palette" | "primary";
  primary_slot?: number | null;
  reviews?: readonly ExpertReview[];
};

const textPresent = (value: unknown): value is string => typeof value === "string" && value.trim().length > 0;
const stringsPresent = (value: unknown): value is string[] => Array.isArray(value) && value.length > 0 && value.every(textPresent);
const designSettings = new Set<string>([...RECIPE_KEYS, "tone_curve", "texture", "exposure", "aperture", "shutter", "iso", "exp_comp", "nd", "focus", "drive"]);
const storedKeys = RECIPE_KEYS.filter((key) => key !== "why");

/** No correction/substitution in place: the evaluator must expose the candidate's actual conflicts. */
export function evaluateExpertRecommendation(input: ExpertEvaluationInput): ExpertEvaluation {
  const scenario = typeof input.scenario === "string" ? EXPERT_SCENARIOS.find((s) => s.id === input.scenario) : input.scenario;
  if (!scenario) throw new Error(`Unknown expert scenario: ${String(input.scenario)}`);
  const camera = input.camera === undefined ? cameraFor(scenario.camera_model) : input.camera;
  const violations: ExpertIssue[] = [];
  const gaps: ExpertIssue[] = [];
  const fail = (code: string, message: string, look_index?: number, slot?: number) => violations.push({ code, message, ...(look_index === undefined ? {} : { look_index }), ...(slot === undefined ? {} : { slot }) });
  const gap = (code: string, message: string, look_index?: number) => gaps.push({ code, message, ...(look_index === undefined ? {} : { look_index }) });
  const reserved = new Map((scenario.protected_slots ?? []).map((p) => [p.slot, p.recipe]));
  const seen = new Set<number>();
  const newLooks = input.looks.filter((l) => l.status !== "kept");

  if (!camera || cameraFor(scenario.camera_model)?.id !== camera.id) {
    fail("unsupported_camera", `No matching supported capability for ${scenario.camera_model}; rendering ideas cannot certify a load.`);
  }
  if (camera && newLooks.length && !camera.confirmed.firmware.includes(scenario.firmware)) {
    fail("unverified_firmware", `New settings-file writes are not verified for ${camera.id} firmware ${scenario.firmware}.`);
  }
  if (camera && newLooks.length && !textPresent(camera.confirmed.layout)) fail("unverified_layout", "No confirmed settings-file layout supports these proposed writes.");
  if (!input.looks.length) gap("no_recommendation", "No candidate looks to review; a valid empty object is not an expert recommendation.");
  else if (input.looks.every((look) => look.recipe_known === false)) gap("no_known_recommendation", "Only unknown kept placeholders are present; there is no known rendering recommendation to judge.");

  for (const [index, look] of input.looks.entries()) {
    if (look.status !== undefined && look.status !== "kept" && look.status !== "new") fail("unknown_status", `Unknown look status ${look.status}.`, index);
    if (look.slot !== undefined && look.slot !== null) {
      if (!Number.isInteger(look.slot) || look.slot < 1 || (camera && look.slot > camera.slots)) fail("invalid_slot", `Invalid bank ${look.slot}.`, index);
      if (seen.has(look.slot)) fail("duplicate_slot", `More than one look occupies C${look.slot}.`, index, look.slot);
      seen.add(look.slot);
    }
    if (camera && look.recipe_known !== false) {
      for (const problem of recipeProblems(look, camera)) fail("camera_value", problem, index);
      if (look.status !== "kept") {
        if (slotName(look.name) !== look.name || look.name.length > camera.nameMax) fail("camera_name", `The name must fit the camera's ${camera.nameMax}-character plain-ASCII slot name.`, index);
        const ok = writable(camera);
        const mapped: [string, string | number, readonly (string | number)[]][] = [
          ["film_sim", look.film_sim, ok.filmSims], ["white_balance", look.white_balance, ok.whiteBalances],
          ["color", look.color, ok.color], ["noise_reduction", look.noise_reduction, ok.noiseReduction],
        ];
        for (const [key, value, allowed] of mapped) if (!allowed.includes(value)) fail("unconfirmed_write", `${key} ${value} is available on the camera but not confirmed for a new settings-file write.`, index);
      }
      if (look.exposure) {
        const problem = checkExposure(look.exposure, camera, camera.drMinIso[look.dynamic_range] ?? 125);
        if (problem) fail("exposure_physics", problem, index);
        const e = look.exposure;
        if (e.aperture !== "A" && e.shutter !== "A" && e.iso !== "A" && e.exp_comp !== "0") fail("manual_compensation", "Exposure compensation has no effect when aperture, shutter and ISO are all fixed.", index);
      } else gap("missing_exposure", "Practical exposure guidance is absent; rendering settings alone do not set the physical dials.", index);
      if (look.focus !== undefined && !camera.focusModes.includes(look.focus)) fail("focus_value", `Unsupported focus mode ${look.focus}.`, index);
      if (look.drive !== undefined && !camera.drives.includes(look.drive)) fail("drive_value", `Unsupported drive ${look.drive}.`, index);
      if (look.status !== "kept" && (look.drive === "CH" || look.drive === "CL") && look.clarity !== 0) fail("burst_clarity", "Nonzero clarity conflicts with the requested continuous shooting workflow.", index);
      const constrained = input.constraint_scope !== "primary" || look.slot === input.primary_slot;
      if (look.status !== "kept" && constrained && scenario.constraints?.require_color && camera.monoSims.has(look.film_sim)) fail("color_intent", "A monochrome recommendation contradicts the explicit requirement to retain subject color.", index);
      const min = scenario.constraints?.freeze_min_denominator;
      const shutter = look.exposure?.shutter;
      if (look.status !== "kept" && constrained && min && shutter && shutter !== "A") {
        const denominator = /^1\/\d+$/.test(shutter) ? Number(shutter.slice(2)) : 0;
        if (denominator < min) fail("motion_intent", `${shutter} conflicts with this brief's explicit 1/${min} minimum for frozen action.`, index);
      }
    } else if (look.recipe_known === false && look.status !== "kept") fail("unknown_new_recipe", "A proposed new recipe cannot be marked unknown.", index);

    // Old saved plans remain usable elsewhere. This benchmark asks richer answers to earn review readiness.
    if (look.design?.settings_signature !== undefined && look.design.settings_signature !== expertSettingsSignature(look)) {
      gap("stale_design_signature", "The design explanation is bound to different rendering settings; it needs a fresh rationale for the actual candidate.", index);
    }
    if (look.design?.requires_review) gap("design_requires_review", "The design was marked for review after normalization or incomplete reasoning; it cannot establish expert readiness.", index);
    if (look.status === "kept") continue;
    const design = look.design;
    if (!design) { gap("missing_design", "The look has no scene/choice/tradeoff rationale for expert review.", index); continue; }
    for (const key of ["purpose", "scene_fit", "tradeoff", "alternative"] as const) if (!textPresent(design[key])) gap(`design_${key}`, `Design ${key} is missing.`, index);
    if (scenario.scene.unknowns.length && !textPresent(design.uncertainty)) gap("design_uncertainty", "The rationale does not acknowledge this scenario's known uncertainty.", index);
    const choices = Array.isArray(design.choices) ? design.choices : [];
    const settings = new Set(choices.filter((c) => c && designSettings.has(c.setting)).map((c) => c.setting));
    if (design.detail_level === "compact") {
      gap("setting_details_deferred", "Concise reasoning accompanies the complete recipe. Detailed setting explanations are available separately and have not been assessed here.", index);
      if (!stringsPresent(design.knowledge_ids)) gap("compact_choice_evidence", "Concise reasoning needs reviewed knowledge references, whose relevance still requires review.", index);
    } else if (settings.size < 2) gap("design_choices", "Explain at least two distinct settings, not one simulation label repeated.", index);
    for (const choice of choices) {
      if (!choice || !designSettings.has(choice.setting) || !textPresent(choice.reason) || !stringsPresent(choice.knowledge_ids)) gap("design_choice_evidence", "Each design choice needs a real setting, a reason and knowledge references; reviewers must still assess whether the reference supports it.", index);
    }
  }

  for (const [slot, recipe] of reserved) {
    const occupying = input.looks.filter((look) => look.slot === slot);
    if (input.write_slots?.includes(slot)) fail("protected_write", `C${slot} is protected but appears in the write intent.`, undefined, slot);
    if (!recipe) {
      // An explicitly unknown kept placeholder is fine; its guessed fields are never scored as a real recipe.
      if (occupying.some((look) => look.status !== "kept" || look.recipe_known !== false)) fail("invented_protected", `The unread C${slot} recipe must remain unresolved, not inferred or proposed for writing.`, undefined, slot);
    } else if (occupying.length !== 1 || occupying[0].status !== "kept" || occupying[0].recipe_known === false) {
      fail("missing_protected", `The known protected look must remain kept in C${slot}.`, undefined, slot);
    } else {
      const changed = storedKeys.filter((key) => occupying[0][key] !== recipe[key]);
      if (changed.length) fail("changed_protected", `Protected C${slot} changed: ${changed.join(", ")}.`, undefined, slot);
    }
  }
  if (input.write_slots) {
    const writeSeen = new Set<number>();
    for (const slot of input.write_slots) {
      if (writeSeen.has(slot)) fail("duplicate_write", `C${slot} occurs more than once in the write intent.`, undefined, slot);
      writeSeen.add(slot);
      const candidates = input.looks.filter((look) => look.slot === slot);
      if (candidates.length !== 1 || candidates[0].status === "kept" || candidates[0].recipe_known === false) fail("invalid_write_intent", `C${slot} does not have exactly one known new look to write.`, undefined, slot);
    }
  }

  const brief = input.photographic_brief;
  if (!brief) gap("missing_brief", "A photographic brief is missing; reviewers cannot inspect observation versus intent and assumption.");
  else {
    for (const key of ["intent", "rendering_goal"] as const) if (!textPresent(brief[key])) gap(`brief_${key}`, `Brief ${key} is missing.`);
    for (const key of ["subjects", "lighting", "observations"] as const) if (!stringsPresent(brief[key])) gap(`brief_${key}`, `Brief ${key} must identify meaningful scene evidence.`);
    if (scenario.constraints?.require_color && !stringsPresent(brief.color_priorities)) gap("brief_color", "The explicitly important subject colors are not represented in the brief.");
    if (scenario.scene.unknowns.length && !stringsPresent(brief.uncertainties)) gap("brief_uncertainty", "Known unknowns were omitted from the brief.");
  }

  const reviewer_questions = EXPERT_RUBRIC.map((item) => ({
    criterion: item.id, weight: item.weight,
    questions: [item.question, ...(scenario.review_questions[item.id] ?? [])],
  }));
  const validReviews = new Map<ExpertCriterion, ExpertReview>();
  const review_errors: string[] = [];
  const supplied = new Set<ExpertCriterion>();
  for (const review of input.reviews ?? []) {
    if (!EXPERT_RUBRIC.some((item) => item.id === review.criterion)) { review_errors.push(`Unknown review criterion: ${review.criterion}`); continue; }
    if (supplied.has(review.criterion)) { review_errors.push(`Duplicate review for ${review.criterion}`); continue; }
    supplied.add(review.criterion);
    if (!Number.isInteger(review.score) || review.score < 0 || review.score > 4 || !textPresent(review.evidence) || !textPresent(review.explanation)) {
      review_errors.push(`${review.criterion} requires a score 0–4, concrete evidence and an explanation.`); continue;
    }
    validReviews.set(review.criterion, review);
  }
  const complete = review_errors.length === 0 && validReviews.size === EXPERT_RUBRIC.length;
  const human_score = complete ? Math.round(EXPERT_RUBRIC.reduce((sum, item) => sum + item.weight * validReviews.get(item.id)!.score / 4, 0) * 10) / 10 : null;
  const objective_pass = violations.length === 0;
  // A strong weighted average cannot bury an unacceptable dimension or a physical/permission conflict.
  const lowDimension = [...validReviews.values()].some((review) => review.score < 2);
  const verdict = !objective_pass ? "blocked" : gaps.length ? "needs_explanation" : !complete ? "needs_review"
    : human_score! < 75 || lowDimension ? "revise" : "review_pass";
  return { scenario_id: scenario.id, objective_pass, violations, explanation_gaps: gaps, reviewer_questions,
    review_errors, reviewed_dimensions: validReviews.size, human_score, verdict };
}
