import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { expertSettingsSignature } from "../../lib/plan/expert-metadata.js";
import {
  evaluateExpertRecommendation, EXPERT_RUBRIC, EXPERT_SCENARIOS,
  type ExpertCandidateLook, type ExpertEvaluationInput, type ExpertPhotographicBrief,
  type ExpertReview, type ExpertScenario,
} from "../../lib/plan/expert-evaluation.js";
import { recipe } from "./fixtures.js";

function scenario(id = "natural-faces"): ExpertScenario {
  const found = EXPERT_SCENARIOS.find((s) => s.id === id);
  assert.ok(found, id);
  return found;
}

function candidate(over: Partial<ExpertCandidateLook> = {}): ExpertCandidateLook {
  return {
    ...recipe("Quiet faces", { film_sim: "Pro Neg Std", highlight: -1, shadow: 0, color: 0, wb_shift_r: 0, wb_shift_b: 0 }),
    slot: 1, status: "new", reason: "Keep facial contrast gentle in bright sand.",
    exposure: { aperture: "f/4", shutter: "1/500", iso: "A", exp_comp: "0", nd: false },
    focus: "S", drive: "S",
    design: {
      purpose: "Faces and red fabric in hard light.", scene_fit: "Prioritize believable faces over nostalgic warmth.",
      choices: [
        { setting: "film_sim", reason: "A restrained rendering supports the person's natural-color request.", knowledge_ids: ["sim-pro-neg-std", "taste-intent"] },
        { setting: "tone_curve", reason: "A gentler JPEG highlight curve reduces the hard-light appearance; it does not recover clipped capture data.", knowledge_ids: ["tone-curve"] },
      ],
      tradeoff: "Less punch in the water than a landscape treatment.",
      alternative: "A slightly stronger color treatment if the subject prefers it after a test frame.",
      uncertainty: "Check face exposure and important highlights on a test frame; this is not a meter reading.",
    },
    ...over,
  };
}

function brief(s: ExpertScenario): ExpertPhotographicBrief {
  return { intent: s.said, rendering_goal: s.taste, subjects: ["The stated subject"], lighting: [s.scene.observations[0]],
    color_priorities: ["Preserve the subject's important colors"], observations: [...s.scene.observations], uncertainties: [...s.scene.unknowns] };
}

function input(id = "natural-faces", looks: ExpertCandidateLook[] = [candidate()]): ExpertEvaluationInput {
  const s = scenario(id);
  return { scenario: s, looks, photographic_brief: brief(s) };
}

function reviews(score: ExpertReview["score"] = 3): ExpertReview[] {
  return EXPERT_RUBRIC.map((item) => ({ criterion: item.id, score,
    evidence: "Pro Neg Std, highlight -1, neutral shifts, Auto ISO; the candidate names face priority and a test-frame check.",
    explanation: `Reviewer assessed ${item.id} against the scenario-specific question; this fixture tests aggregation, not actual photographic quality.` }));
}

const codes = (value: ReturnType<typeof evaluateExpertRecommendation>) => value.violations.map((issue) => issue.code);

describe("expert benchmark briefs", () => {
  test("covers different intent/taste in the same light, uncertainty, kept values and an unsupported body", () => {
    assert.equal(new Set(EXPERT_SCENARIOS.map((s) => s.id)).size, EXPERT_SCENARIOS.length);
    assert.equal(EXPERT_RUBRIC.reduce((sum, item) => sum + item.weight, 0), 100);
    assert.deepEqual(scenario("natural-faces").scene.observations, scenario("warm-editorial-faces").scene.observations);
    assert.notEqual(scenario("natural-faces").taste, scenario("warm-editorial-faces").taste);
    assert.deepEqual(scenario("backlit-face").scene.observations, scenario("graphic-silhouette").scene.observations);
    assert.equal(scenario("phone-neon").scene.source, "phone-photo");
    assert.ok(scenario("mixed-market").review_questions.light_contrast?.some((q) => q.includes("single WB")));
    assert.ok(scenario("candle-and-flash").review_questions.light_contrast?.some((q) => q.includes("flash")));
    assert.ok(scenario("red-product").constraints?.require_color);
    assert.ok(scenario("freeze-children").constraints?.freeze_min_denominator);
    assert.equal(scenario("intentional-pan").constraints?.freeze_min_denominator, undefined);
    assert.equal(scenario("unknown-protected").protected_slots?.[0].recipe, null);
    assert.equal(scenario("unsupported-body").camera_model, "X100V");
  });

  test("accepts multiple compatible aesthetic solutions without picking a golden film simulation", () => {
    const restrained = evaluateExpertRecommendation(input());
    const stronger = evaluateExpertRecommendation(input("natural-faces", [candidate({ film_sim: "Reala Ace", shadow: 0.5, color: 1 })]));
    assert.equal(restrained.objective_pass, true);
    assert.equal(stronger.objective_pass, true);
    assert.equal(restrained.verdict, "needs_review");
    assert.equal(stronger.verdict, "needs_review");
    assert.equal(restrained.human_score, null);
    assert.equal(stronger.human_score, null);
  });

  test("adds scene-specific questions without using their keywords as a taste score", () => {
    const value = evaluateExpertRecommendation(input("phone-neon"));
    assert.equal(value.human_score, null);
    assert.ok(value.reviewer_questions.find((q) => q.criterion === "uncertainty")?.questions.some((q) => q.includes("HDR")));
    assert.ok(value.reviewer_questions.find((q) => q.criterion === "light_contrast")?.questions.some((q) => q.includes("facial exposure")));
    assert.throws(() => evaluateExpertRecommendation({ scenario: "invented-case", looks: [] }), /Unknown expert scenario/);
  });
});

describe("objective conflicts remain separate from judgment", () => {
  test("unsupported model, mismatched capabilities and unverified firmware cannot earn a preparation pass", () => {
    for (const extra of [{}, { camera: X100VI }]) {
      const value = evaluateExpertRecommendation({ ...input("unsupported-body"), ...extra, reviews: reviews(4) });
      assert.ok(codes(value).includes("unsupported_camera"));
      assert.equal(value.verdict, "blocked");
    }
    const value = evaluateExpertRecommendation({ ...input(), scenario: { ...scenario(), firmware: "9.99" } });
    assert.ok(codes(value).includes("unverified_firmware"));
    assert.ok(codes(evaluateExpertRecommendation({ ...input(), camera: null })).includes("unsupported_camera"));
    const noLayout = { ...X100VI, confirmed: { ...X100VI.confirmed, layout: "" } };
    assert.ok(codes(evaluateExpertRecommendation({ ...input(), camera: noLayout })).includes("unverified_layout"));
  });

  test("new writes distinguish available simulations from confirmed encodings", () => {
    const unmapped = evaluateExpertRecommendation(input("natural-faces", [candidate({ film_sim: "Astia" })]));
    assert.ok(codes(unmapped).includes("unconfirmed_write"));
    const invalid = evaluateExpertRecommendation(input("natural-faces", [candidate({ film_sim: "Invented Film", highlight: 0.25 })]));
    assert.ok(codes(invalid).includes("camera_value"));
    const badName = evaluateExpertRecommendation(input("natural-faces", [candidate({ name: "A portrait name that cannot fit" })]));
    assert.ok(codes(badName).includes("camera_name"));
  });

  test("checks DR ISO floors, the leaf shutter and ineffective manual compensation", () => {
    const tooFast = candidate({ exposure: { aperture: "f/2", shutter: "1/4000", iso: "A", exp_comp: "0", nd: true } });
    assert.ok(codes(evaluateExpertRecommendation(input("natural-faces", [tooFast]))).includes("exposure_physics"));
    const lowIso = candidate({ dynamic_range: "DR400", exposure: { aperture: "f/8", shutter: "1/500", iso: "125", exp_comp: "+⅓", nd: false } });
    const value = evaluateExpertRecommendation(input("natural-faces", [lowIso]));
    assert.ok(codes(value).includes("exposure_physics"));
    assert.ok(codes(value).includes("manual_compensation"));
  });

  test("respects color intent without demanding a preferred color aesthetic", () => {
    const mono = candidate({ film_sim: "Acros+Ye", color: 0, color_chrome: "Off", color_chrome_fx_blue: "Off" });
    assert.ok(codes(evaluateExpertRecommendation(input("red-product", [mono]))).includes("color_intent"));
    assert.equal(evaluateExpertRecommendation(input("graphic-silhouette", [mono])).objective_pass, true);
  });

  test("protects explicit freeze speed but allows intentional blur and does not invent Auto ISO policy", () => {
    const slow = candidate({ exposure: { aperture: "f/8", shutter: "1/15", iso: "A", exp_comp: "0", nd: true } });
    assert.ok(codes(evaluateExpertRecommendation(input("freeze-children", [slow]))).includes("motion_intent"));
    assert.equal(evaluateExpertRecommendation(input("intentional-pan", [slow])).objective_pass, true);
    const automatic = candidate({ exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false } });
    const value = evaluateExpertRecommendation(input("freeze-children", [automatic]));
    assert.equal(value.objective_pass, true);
    assert.equal(value.human_score, null);
    assert.ok(value.reviewer_questions.find((q) => q.criterion === "motion_operation")?.questions.some((q) => q.includes("Auto ISO")));
  });

  test("continuous shooting clarity, invalid focus/drive and unknown recipes are visible", () => {
    assert.ok(codes(evaluateExpertRecommendation(input("freeze-children", [candidate({ drive: "CH", clarity: 2 })]))).includes("burst_clarity"));
    const invalid = evaluateExpertRecommendation(input("natural-faces", [candidate({ focus: "tracking", drive: "infinite" })]));
    assert.ok(codes(invalid).includes("focus_value"));
    assert.ok(codes(invalid).includes("drive_value"));
    assert.ok(codes(evaluateExpertRecommendation(input("natural-faces", [candidate({ recipe_known: false })]))).includes("unknown_new_recipe"));
  });

  test("preserves the exact protected snapshot even when its values are not mapped for new writes", () => {
    const s = scenario("protected-favorite");
    const original = s.protected_slots![0].recipe!;
    const kept = candidate({ ...original, slot: 3, status: "kept", design: undefined });
    const good = evaluateExpertRecommendation({ ...input(s.id, [candidate(), kept]), write_slots: [1] });
    assert.equal(good.objective_pass, true);
    assert.equal(codes(good).includes("unconfirmed_write"), false);
    const changed = candidate({ ...kept, white_balance: "Auto" });
    assert.ok(codes(evaluateExpertRecommendation(input(s.id, [candidate(), changed]))).includes("changed_protected"));
    const renamed = candidate({ ...kept, name: "Better faces" });
    assert.ok(codes(evaluateExpertRecommendation(input(s.id, [candidate(), renamed]))).includes("changed_protected"));
    assert.ok(codes(evaluateExpertRecommendation({ ...input(s.id, [candidate(), kept]), write_slots: [3] })).includes("protected_write"));
    assert.ok(codes(evaluateExpertRecommendation(input(s.id))).includes("missing_protected"));
  });

  test("an unknown protected recipe stays unknown, including in a full-palette placeholder", () => {
    const empty = evaluateExpertRecommendation({ ...input("unknown-protected"), write_slots: [1] });
    assert.equal(empty.objective_pass, true);
    const placeholder = candidate({ slot: 5, status: "kept", recipe_known: false, design: undefined });
    assert.equal(evaluateExpertRecommendation(input("unknown-protected", [candidate(), placeholder])).objective_pass, true);
    const invented = candidate({ slot: 5, status: "kept" });
    assert.ok(codes(evaluateExpertRecommendation(input("unknown-protected", [candidate(), invented]))).includes("invented_protected"));
    assert.ok(codes(evaluateExpertRecommendation({ ...input("unknown-protected"), write_slots: [5] })).includes("protected_write"));
  });

  test("write intent cannot duplicate, replay kept values or target a nonexistent candidate", () => {
    const value = evaluateExpertRecommendation({ ...input(), write_slots: [1, 1, 2] });
    assert.ok(codes(value).includes("duplicate_write"));
    assert.ok(codes(value).includes("invalid_write_intent"));
    const two = evaluateExpertRecommendation(input("natural-faces", [candidate(), candidate()]));
    assert.ok(codes(two).includes("duplicate_slot"));
    assert.ok(codes(evaluateExpertRecommendation(input("natural-faces", [candidate({ slot: 8 })]))).includes("invalid_slot"));
  });

  test("evaluation never normalizes or mutates the candidate and scenario", () => {
    const value = { ...input(), looks: [candidate({ film_sim: "Astia", color: 4 })], reviews: reviews() };
    const before = JSON.stringify(value);
    evaluateExpertRecommendation(value);
    assert.equal(JSON.stringify(value), before);
  });
});

describe("expert explanation and review", () => {
  test("legacy plans are inspectable but missing rationale cannot earn an expert-ready verdict", () => {
    const value = evaluateExpertRecommendation({ ...input(), photographic_brief: undefined, looks: [candidate({ design: undefined })], reviews: reviews(4) });
    assert.equal(value.objective_pass, true);
    assert.ok(value.explanation_gaps.some((gap) => gap.code === "missing_design"));
    assert.ok(value.explanation_gaps.some((gap) => gap.code === "missing_brief"));
    assert.equal(value.verdict, "needs_explanation");
    assert.equal(value.human_score, 100);
  });

  test("phone-image uncertainty must have a place in both brief and look rationale", () => {
    const value = input("phone-neon");
    value.photographic_brief!.uncertainties = [];
    value.looks[0].design!.uncertainty = "";
    const result = evaluateExpertRecommendation(value);
    assert.ok(result.explanation_gaps.some((gap) => gap.code === "brief_uncertainty"));
    assert.ok(result.explanation_gaps.some((gap) => gap.code === "design_uncertainty"));
    assert.equal(result.human_score, null);
  });

  test("two distinct settings with reasons/references are required, but references do not produce a score", () => {
    const value = input();
    value.looks[0].design!.choices = [
      { setting: "film_sim", reason: "Skin color mixed light motion natural taste expert.", knowledge_ids: ["sim-pro-neg-std"] },
      { setting: "film_sim", reason: "Repeat keywords.", knowledge_ids: ["taste-intent"] },
    ];
    const result = evaluateExpertRecommendation(value);
    assert.ok(result.explanation_gaps.some((gap) => gap.code === "design_choices"));
    assert.equal(result.human_score, null);
    value.looks[0].design!.choices[1] = { setting: "fictional_control", reason: "", knowledge_ids: [] };
    assert.ok(evaluateExpertRecommendation(value).explanation_gaps.some((gap) => gap.code === "design_choice_evidence"));
  });

  test("stale design signatures and normalization review flags cannot earn an expert-ready verdict", () => {
    const value = input();
    value.looks[0].design!.settings_signature = expertSettingsSignature(value.looks[0]);
    assert.equal(evaluateExpertRecommendation({ ...value, reviews: reviews() }).verdict, "review_pass");
    value.looks[0].color = 1;
    const stale = evaluateExpertRecommendation({ ...value, reviews: reviews(4) });
    assert.equal(stale.objective_pass, true);
    assert.equal(stale.verdict, "needs_explanation");
    assert.ok(stale.explanation_gaps.some((gap) => gap.code === "stale_design_signature"));
    value.looks[0].design!.settings_signature = expertSettingsSignature(value.looks[0]);
    value.looks[0].design!.requires_review = true;
    assert.ok(evaluateExpertRecommendation(value).explanation_gaps.some((gap) => gap.code === "design_requires_review"));
    value.looks[0].design!.requires_review = false;
    value.looks[0].design!.settings_signature = "malformed";
    assert.ok(evaluateExpertRecommendation(value).explanation_gaps.some((gap) => gap.code === "stale_design_signature"));
  });

  test("human review scores are weighted, complete, evidence-backed and never override objective conflicts", () => {
    const good = evaluateExpertRecommendation({ ...input(), reviews: reviews(3) });
    assert.equal(good.human_score, 75);
    assert.equal(good.verdict, "review_pass");
    const partial = evaluateExpertRecommendation({ ...input(), reviews: reviews(4).slice(0, 7) });
    assert.equal(partial.reviewed_dimensions, 7);
    assert.equal(partial.human_score, null);
    assert.equal(partial.verdict, "needs_review");
    const blocked = evaluateExpertRecommendation({ ...input("natural-faces", [candidate({ film_sim: "Astia" })]), reviews: reviews(4) });
    assert.equal(blocked.human_score, 100);
    assert.equal(blocked.verdict, "blocked");
  });

  test("an unacceptable dimension cannot hide behind a high average or fluent metadata", () => {
    const ratings = reviews(4);
    ratings.find((r) => r.criterion === "uncertainty")!.score = 0;
    ratings.find((r) => r.criterion === "uncertainty")!.evidence = "Candidate claims a phone photo proves exact EV and calibrated Kelvin.";
    const result = evaluateExpertRecommendation({ ...input("phone-neon"), reviews: ratings });
    assert.equal(result.human_score, 90);
    assert.equal(result.verdict, "revise");
  });

  test("duplicate, out-of-range or unsupported human reviews cannot fabricate a complete score", () => {
    const duplicate = evaluateExpertRecommendation({ ...input(), reviews: [...reviews(), reviews()[0]] });
    assert.equal(duplicate.human_score, null);
    assert.ok(duplicate.review_errors.some((error) => error.includes("Duplicate")));
    const malformed = reviews();
    malformed[0].score = 9 as ExpertReview["score"];
    malformed[1].evidence = "  ";
    const result = evaluateExpertRecommendation({ ...input(), reviews: malformed });
    assert.equal(result.reviewed_dimensions, 6);
    assert.equal(result.human_score, null);
    assert.equal(result.review_errors.length, 2);
    const unknown = reviews();
    unknown[0].criterion = "perfect-image" as ExpertReview["criterion"];
    assert.ok(evaluateExpertRecommendation({ ...input(), reviews: unknown }).review_errors.some((error) => error.includes("Unknown")));
  });
});
