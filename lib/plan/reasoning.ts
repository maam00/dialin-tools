// Optional explanation of one exact, already validated recipe. Never returns a replacement recipe.
import { createHash } from "node:crypto";
import type { CameraCaps } from "../cameras.js";
import { throwIfAborted } from "./abort.js";
import { expertKnowledge, EXPERT_KNOWLEDGE_VERSION } from "./expert-knowledge.js";
import { expertGuidanceSignature, expertReceipt, expertSettingsSignature, recipeDesign } from "./expert-metadata.js";
import { sanitizeFactualRationale } from "./expert-policy.js";
import { recipeOf, recipeProblems } from "./looks.js";
import { defaultAsk, MODELS, type Ask } from "./model.js";
import { designSchema } from "./prompts.js";
import { type CallMeta, type Plan, PlanError } from "./types.js";

export async function explainRecipe(input: { plan: Plan; slot: number; cam: CameraCaps; ask?: Ask; signal?: AbortSignal; budgetMs?: number }) {
  throwIfAborted(input.signal);
  const started = Date.now();
  const look = input.plan.day_looks.find((l) => l.slot === input.slot);
  if (!look || look.recipe_known === false || recipeProblems(look, input.cam).length) {
    throw new PlanError("That look needs a complete recipe before its settings can be explained.", "unknown_recipe", 400);
  }
  const settings = expertSettingsSignature(look);
  const guidance = expertGuidanceSignature(look);
  const context = { camera: input.cam.id, knowledge_version: EXPERT_KNOWLEDGE_VERSION, said: input.plan.said,
    brief: input.plan.photographic_brief, recipe: recipeOf(look), exposure: look.exposure, focus: look.focus,
    drive: look.drive, when: look.when, purpose: look.reason };
  const requestBinding = createHash("sha256").update(JSON.stringify(context)).digest("hex");
  const answer = await (input.ask ?? defaultAsk())({ task: "recipe-reasoning", model: MODELS.sonnet, effort: "low",
    system: `Explain the supplied Fujifilm recipe in plain words for its actual subject, light and stated intention. The supplied recipe is fixed. Explain what its values do, where they fit, and one honest limitation. Do not rationalize a mismatch: state it in uncertainty. Never claim photographic or camera verification. Never claim a reference ID proves the prose. Give one concise explanation per setting group. Never return or change settings.\n\n${expertKnowledge(input.cam)}`,
    text: JSON.stringify(context), schema: { type: "object", additionalProperties: false, required: ["design"],
      properties: { design: designSchema(input.cam) } }, timeoutMs: input.budgetMs ?? 45_000, maxTokens: 2500, signal: input.signal });
  const calls: CallMeta[] = [{ task: "recipe-reasoning", ok: answer.ok, model: answer.model, via: answer.via, ms: answer.ms,
    error: answer.code, usage: answer.usage, usd: answer.usd, requested_model: answer.requestedModel,
    served_model: answer.servedModel, usage_complete: answer.usageComplete, reported_cost_usd: answer.reportedCostUsd, tries: answer.tries }];
  throwIfAborted(input.signal);
  if (!answer.ok || !answer.data || typeof answer.data !== "object") {
    throw new PlanError("The detailed explanation could not be completed. Your recipes are unchanged.", answer.code ?? "reasoning_failed", answer.code === "timeout" ? 504 : 502, calls);
  }
  const design = recipeDesign((answer.data as Record<string, unknown>).design, input.cam, "detailed");
  if (!design) throw new PlanError("The explanation was incomplete. Your recipes are unchanged.", "incomplete_reasoning", 502, calls);
  design.settings_signature = settings;
  design.guidance_signature = guidance;
  const checked = sanitizeFactualRationale({ recipe: look, design, reason: look.reason, exposure: look.exposure, cameraModel: input.cam.id });
  if (!checked.design || checked.design.requires_review) {
    throw new PlanError("That explanation needs another review. Your recipes are unchanged.", "reasoning_review", 502, calls);
  }
  return { slot: input.slot, design: checked.design, expertise: expertReceipt([checked.design], Boolean(input.plan.photographic_brief), 1),
    request_binding: requestBinding, calls, ms: Date.now() - started };
}
