import { createHash } from "node:crypto";
import { cameraFor } from "../cameras.js";
import { recipeProblems } from "../plan/looks.js";
import { RECIPE_KEYS, type PhotographicBrief, type RecipeFields } from "../plan/types.js";
import { recipeFactSignature, type RecipeKnowledge } from "./library.js";
import { recipeUsage } from "./permissions.js";

export type TrainingRow = { messages: { role: "system" | "user" | "assistant"; content: string }[] };
const digest = (s: string) => createHash("sha256").update(s).digest("hex");

/** Fact recall is useful training material, but is never labelled as expert scene judgment. No network calls. */
export function recipeFactLessons(knowledge: RecipeKnowledge, now = Date.now()) {
  const included: { record_id: string; source_url: string; content_sha256: string; source_fact_signature: string; row: TrainingRow }[] = [];
  const excluded: { record_id: string; reason: string }[] = [];
  for (const { recipe: r } of knowledge.library.entries) {
    const access = recipeUsage(r.raw, "training", knowledge.permissions, now, knowledge.mode);
    if (!access.allowed || r.raw.status !== "public_settings" || !r.base_film_sim || !r.raw.source_url || !r.raw.content_sha256) {
      excluded.push({ record_id: r.id, reason: !access.allowed ? access.reason : "Source block or base simulation is ambiguous; review before creating a target answer." });
      continue;
    }
    included.push({ record_id: r.id, source_url: r.raw.source_url, content_sha256: r.raw.content_sha256,
      source_fact_signature: recipeFactSignature(r), row: { messages: [
      { role: "system", content: "Report the supplied public recipe setting facts. Recipe names are separate from native film simulations. Do not invent omitted native settings, claim photographic superiority or camera compatibility from an index category. These are reference examples that may be adapted for a scene." },
      { role: "user", content: JSON.stringify({ task: "recall_recipe_facts", record_id: r.id, recipe_title: r.title, source_url: r.raw.source_url, source_groups: r.source_groups }) },
      { role: "assistant", content: JSON.stringify({ record_id: r.id, base_film_sim: r.base_film_sim, settings: r.fields,
        native: r.native, unknown_app_fields: r.missing_fields, published_core_complete: r.published_core.complete,
        source_issues: r.issues.map((i) => ({ code: i.code, field: i.field })),
        native_baseline_requires_check: true, best_scene_unverified: true }) },
    ] } });
  }
  return { included, excluded, receipt: { purpose: "recipe_fact_recall", mode: knowledge.mode,
    library_revision: knowledge.library.revision, examples: included.length, excluded: excluded.length,
    human_judgment_examples: 0, fine_tune_job_started: false, model_weights_changed: false, creator_permission_inferred: false } };
}

export type ReviewedJudgmentExample = {
  id: string;
  /** Reviewer groups versions of the same recipe family together, including cross-article variants. */
  family_id: string;
  source_record_id: string;
  source_content_sha256: string;
  source_fact_signature: string;
  camera_model: string;
  brief: PhotographicBrief;
  adapted_settings: RecipeFields;
  changes: { field: string; reason: string }[];
  rationale: string;
  tradeoff: string;
  review: { reviewer: string; reviewer_kind: "human"; status: "approved"; reviewed_at: string;
    comparison_receipt: string; scene_data_authorized: true };
};

/** Photographic preferences require actual reviewed comparisons. Synthetic labels cannot certify the best look. */
export function recipeJudgmentLessons(knowledge: RecipeKnowledge, examples: readonly ReviewedJudgmentExample[], now = Date.now()) {
  const train: TrainingRow[] = [], evaluation: TrainingRow[] = [];
  const excluded: { id: string; reason: string }[] = [];
  const accepted: { id: string; family_id: string; record_id: string; split: "train" | "evaluation" }[] = [];
  const familyByArticle = new Map<string, string>();
  const conflictingArticles = new Set<string>();
  const byID = new Map(knowledge.library.entries.map((e) => [e.recipe.id, e.recipe]));
  const ids = new Set<string>();
  for (const example of examples) {
    const source = byID.get(example.source_record_id)?.raw.source_url;
    if (!source) continue;
    const existing = familyByArticle.get(source);
    if (existing && existing !== example.family_id) conflictingArticles.add(source);
    familyByArticle.set(source, example.family_id);
  }
  for (const e of examples) {
    const r = byID.get(e.source_record_id);
    const reviewed = Date.parse(e.review?.reviewed_at);
    let reason = "";
    if (!e.id || ids.has(e.id)) reason = "Missing or duplicate example ID.";
    else if (!r || !r.raw.source_url || !r.raw.content_sha256 || r.raw.status !== "public_settings"
      || r.raw.content_sha256 !== e.source_content_sha256 || recipeFactSignature(r) !== e.source_fact_signature) reason = "Source fact revision mismatch.";
    else if (!recipeUsage(r.raw, "training", knowledge.permissions, now, knowledge.mode).allowed) reason = "Source training use not enabled.";
    else if (!e.family_id?.trim() || conflictingArticles.has(r.raw.source_url!)) reason = "Unresolved family split; variants could leak into evaluation.";
    else if (e.review?.reviewer_kind !== "human" || e.review.status !== "approved" || !e.review.reviewer?.trim()
      || !Number.isFinite(reviewed) || reviewed > now || !e.review.comparison_receipt?.trim() || e.review.scene_data_authorized !== true) {
      reason = "A human-approved, authorized comparison receipt is required for a photographic preference label.";
    } else if (!e.camera_model?.trim() || !e.rationale?.trim() || !e.tradeoff?.trim() || !e.brief?.intent?.trim()
      || !e.adapted_settings || !Array.isArray(e.changes) || e.changes.some((c) => !c.field?.trim() || !c.reason?.trim())) {
      reason = "Incomplete scene, adaptation or tradeoff evidence.";
    }
    if (!reason && r) {
      const camera = cameraFor(e.camera_model);
      if (!camera || recipeProblems(e.adapted_settings, camera).length
        || Object.keys(e.adapted_settings).some((key) => !RECIPE_KEYS.includes(key as keyof RecipeFields))
        || RECIPE_KEYS.some((key) => !Object.hasOwn(e.adapted_settings, key))
        || typeof e.adapted_settings.why !== "string"
        || e.changes.some((change) => !RECIPE_KEYS.includes(change.field as keyof RecipeFields) || ["name", "why"].includes(change.field))) {
        reason = "Adaptation is not a complete, valid recipe for the reviewed camera.";
      }
      else {
        const changed = Object.keys(e.adapted_settings).filter((k) => k !== "name" && k !== "why")
          .filter((k) => r.fields[k as keyof RecipeFields] !== e.adapted_settings[k as keyof RecipeFields]);
        if (changed.some((field) => !e.changes.some((change) => change.field === field))) reason = "Every changed or newly supplied setting needs a reason.";
        else if (e.changes.some((change) => !changed.includes(change.field))) reason = "A claimed change is absent from the actual settings difference.";
      }
    }
    ids.add(e.id);
    if (reason || !r) { excluded.push({ id: e.id, reason }); continue; }
    const split = Number.parseInt(digest(e.family_id).slice(0, 8), 16) % 5 === 0 ? "evaluation" : "train";
    const row: TrainingRow = { messages: [
      { role: "system", content: "Adapt a Fujifilm recipe to the supplied photographic intention, subjects, illumination, contrast and texture. Explain changes and tradeoffs. Never promise that camera settings were applied or that a subjective preference is universal." },
      { role: "user", content: JSON.stringify({ task: "adapt_recipe", camera_model: e.camera_model, brief: e.brief,
        reference: { id: r.id, settings: r.fields, native: r.native } }) },
      { role: "assistant", content: JSON.stringify({ recipe: e.adapted_settings, changes: e.changes, rationale: e.rationale, tradeoff: e.tradeoff }) },
    ] };
    (split === "train" ? train : evaluation).push(row);
    accepted.push({ id: e.id, family_id: e.family_id, record_id: r.id, split });
  }
  return { train, evaluation, accepted, excluded, receipt: { purpose: "reviewed_photographic_judgment", mode: knowledge.mode,
    library_revision: knowledge.library.revision, split_unit: "reviewer_assigned_recipe_family", model_weights_changed: false } };
}
