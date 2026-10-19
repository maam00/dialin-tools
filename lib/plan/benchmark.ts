import { createHash } from "node:crypto";
import { cameraFor, type CameraCaps } from "../cameras.js";
import { throwIfAborted } from "./abort.js";
import { recipeProblems } from "./looks.js";
import { attemptCost, makeAsk, ModelError, type Ask, type Attempt, type AttemptObservations } from "./model.js";
import type { Plan } from "./types.js";
import type { qualifyPlan } from "./qualification.js";

export type BenchmarkArm = "detailed" | "compact" | "concise";
export type BenchmarkStopReason = "completed" | "unknown_cost_receipt" | "cost_ceiling" | "call_limit";
export type BenchmarkAttempt = AttemptObservations & { index: number; arm: BenchmarkArm; fixture: string;
  requestedModel: string; effort: string; ms: number; ok: boolean; code: string | null; usd: number | null;
  systemHash: string; schemaHash: string; systemChars: number; textChars: number; maxTokens: number | null;
  tokenCapEnforced: boolean; task: string; budgetMs: number; repairRules: string[];
  rawStructuredData?: unknown; responseChars?: number; designChars?: number };
export type BenchmarkOutcome = { arm: BenchmarkArm; fixture: string; repetition: number; ms: number;
  ok: boolean; code: string | null; paletteComplete: boolean; looks: number; plan?: Plan;
  coverage?: ReturnType<typeof benchmarkPlanStatus>; qualification?: ReturnType<typeof qualifyPlan>;
  httpStatus?: number; failureBody?: unknown };
export function benchmarkOutcomeSummary(outcomes: readonly BenchmarkOutcome[]) {
  return { outcomes: outcomes.length, routeSucceeded: outcomes.filter((outcome) => outcome.ok).length,
    routeFailed: outcomes.filter((outcome) => !outcome.ok).length,
    qualificationPassed: outcomes.filter((outcome) => outcome.qualification?.objectivePass === true).length,
    qualificationFlagged: outcomes.filter((outcome) => outcome.qualification?.objectivePass === false).length,
    qualificationNotAssessed: outcomes.filter((outcome) => !outcome.qualification).length,
    fullSevenValidRecipes: outcomes.filter((outcome) => outcome.coverage?.fullSevenValidRecipes === true).length,
    photographicQualityVerified: false };
}
const digest = (value: unknown) => createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex");
export function benchmarkRepairRules(text: string): string[] {
  const section = /YOUR LAST ANSWER BROKE THESE RULES\. Fix exactly these, keep everything else:\n([\s\S]*?)\n\nYour last answer:/.exec(text)?.[1]
    ?? /YOUR LAST ANSWER BROKE THESE RULES:\n([\s\S]*?)\n\nREPAIR ONLY/.exec(text)?.[1];
  return section ? section.split("\n").map((line) => line.replace(/^- /, "")).filter(Boolean) : [];
}

/** Output completeness and declared intent are separate from photographic taste or detailed rationale. */
export function benchmarkPlanStatus(plan: Plan, camera?: CameraCaps) {
  const model = (plan.camera_info as { model?: unknown } | undefined)?.model;
  const cam = camera ?? cameraFor(typeof model === "string" ? model : null);
  const slots = plan.day_looks.map((look) => look.slot);
  const validRecipeSlots = cam ? plan.day_looks.filter((look) => look.recipe_known !== false && !recipeProblems(look, cam).length).map((look) => look.slot) : [];
  const seven = Array.from({ length: 7 }, (_, index) => index + 1);
  const primarySlot = Number.isInteger(plan.primary_slot) && slots.includes(plan.primary_slot as number) ? plan.primary_slot as number : null;
  return { slots, validRecipeSlots, missingSlots: seven.filter((slot) => !validRecipeSlots.includes(slot)),
    blockedSlots: plan.blocked_slots ?? [], fullSevenValidRecipes: slots.length === 7 && new Set(slots).size === 7 && seven.every((slot) => validRecipeSlots.includes(slot)),
    primarySlot, primarySelection: plan.primary_selection === "declared" || plan.primary_selection === "legacy_first_look" ? plan.primary_selection : "unknown",
    intentSatisfied: typeof plan.intent_satisfied === "boolean" ? plan.intent_satisfied : null,
    intentIssues: Array.isArray(plan.intent_issues) ? plan.intent_issues : [],
    factualIssues: Array.isArray(plan.factual_issues) ? plan.factual_issues : [],
    warnings: plan.warnings ?? [], normalizationNotes: plan.notes ?? [], aestheticScore: null };
}

/** Limits actual transport starts, including validation repairs and client fallbacks. No photograph input. */
export async function planningComparison(options: {
  fixtures: string[]; attempt: Attempt; via: "api" | "cli" | "fake";
  runPlan: (arm: BenchmarkArm, fixture: string, ask: Ask) => Promise<Plan>;
  repetitions?: number; maxCalls?: number; maxUsd?: number; signal?: AbortSignal; camera?: CameraCaps;
  arms?: readonly BenchmarkArm[]; requestPath?: "engine" | "http";
  assess?: (plan: Plan, fixture: string) => ReturnType<typeof qualifyPlan>;
  /** Called after each finished outcome so a long comparison can preserve earlier results. */
  onOutcome?: (outcome: BenchmarkOutcome, attempts: readonly BenchmarkAttempt[]) => void;
}) {
  const maxCalls = options.maxCalls ?? 12;
  const repetitions = options.repetitions ?? 2;
  const maxUsd = options.maxUsd ?? 5;
  const arms = options.arms ?? ["detailed", "compact"];
  if (!Number.isInteger(maxCalls) || maxCalls < 1 || maxCalls > 12 || !Number.isInteger(repetitions) || repetitions < 1
      || repetitions > 3 || !Number.isFinite(maxUsd) || maxUsd <= 0 || !options.fixtures.length || options.fixtures.length > 8
      || !arms.length || arms.length > 3 || new Set(arms).size !== arms.length || arms.some((arm) => !["compact", "detailed", "concise"].includes(arm))) {
    throw new Error("Choose one to eight synthetic fixtures and at most twelve transport calls with a positive cost ceiling.");
  }
  const attempts: BenchmarkAttempt[] = [];
  const outcomes: BenchmarkOutcome[] = [];
  let knownCost = 0;
  let unknownCost = false;
  let stopReason: BenchmarkStopReason = "completed";
  const bound = (): Exclude<BenchmarkStopReason, "completed"> | null => knownCost >= maxUsd ? "cost_ceiling"
    : unknownCost && options.via !== "fake" ? "unknown_cost_receipt" : attempts.length >= maxCalls ? "call_limit" : null;
  let arm: BenchmarkArm = "detailed";
  let fixture = "";
  const ask = makeAsk(async (request, model, effort, budget) => {
    throwIfAborted(options.signal);
    if (request.imageBase64) throw new ModelError("This comparison accepts synthetic text only", "benchmark_image", true);
    const stopped = bound();
    if (stopped) {
      stopReason = stopped;
      throw new ModelError("The comparison reached its bound", "benchmark_limit", true);
    }
    const record: BenchmarkAttempt = { index: attempts.length + 1, arm, fixture, requestedModel: model, effort,
      ms: 0, ok: false, code: null, usd: null, systemHash: digest(request.system), schemaHash: digest(request.schema),
      systemChars: request.system.length, textChars: request.text.length, maxTokens: request.maxTokens ?? null,
      tokenCapEnforced: options.via === "api", task: request.task, budgetMs: budget, repairRules: benchmarkRepairRules(request.text) };
    attempts.push(record);
    const start = Date.now();
    try {
      const signals = [options.signal, request.signal].filter((signal): signal is AbortSignal => Boolean(signal));
      const signal = signals.length > 1 ? AbortSignal.any(signals) : signals[0];
      const result = await options.attempt({ ...request, signal, serverFallback: false }, model, effort, budget);
      const { data: _data, model: _model, ...observations } = result;
      const raw = structuredClone(result.data);
      const looks = raw && typeof raw === "object" && "looks" in raw && Array.isArray(raw.looks) ? raw.looks : [];
      Object.assign(record, observations, { ok: true, rawStructuredData: raw, responseChars: JSON.stringify(raw)?.length ?? 0,
        designChars: looks.reduce((sum, look) => sum + (JSON.stringify(look?.design)?.length ?? 0), 0) });
      throwIfAborted(signal);
      return result;
    } catch (error) {
      record.ok = false;
      if (error instanceof ModelError) Object.assign(record, error.observations, { code: error.code });
      else record.code = error instanceof Error && error.name === "AbortError" ? "cancelled" : "unknown";
      throw error;
    } finally {
      record.ms = Date.now() - start;
      record.usd = attemptCost(record);
      const cost = record.reportedCostUsd ?? record.usd;
      if (cost === null || cost === undefined) unknownCost = true;
      else knownCost += cost;
    }
  }, `benchmark-${options.via}`);
  outer: for (let repetition = 1; repetition <= repetitions; repetition++) {
    for (fixture of options.fixtures) {
      // Alternate arm order between repetitions to reduce a consistent warm-cache advantage.
      for (arm of repetition % 2 ? arms : [...arms].reverse()) {
        throwIfAborted(options.signal);
        const stopped = bound();
        if (stopped) { stopReason = stopped; break outer; }
        const start = Date.now();
        try {
          const plan = await options.runPlan(arm, fixture, ask);
          throwIfAborted(options.signal);
          outcomes.push({ arm, fixture, repetition, ms: Date.now() - start, ok: true, code: null,
            paletteComplete: plan.palette_complete === true, looks: plan.day_looks.length, plan,
            coverage: benchmarkPlanStatus(plan, options.camera), qualification: options.assess?.(plan, fixture),
            httpStatus: options.requestPath === "http" ? 200 : undefined });
        } catch (error) {
          throwIfAborted(options.signal);
          const code = error instanceof ModelError ? error.code : error && typeof error === "object" && "code" in error
            ? String(error.code) : "unknown";
          outcomes.push({ arm, fixture, repetition, ms: Date.now() - start, ok: false, code, paletteComplete: false, looks: 0,
            httpStatus: error && typeof error === "object" && "status" in error && typeof error.status === "number" ? error.status : undefined,
            failureBody: error && typeof error === "object" && "body" in error ? structuredClone(error.body) : undefined });
        }
        options.onOutcome?.(outcomes[outcomes.length - 1], attempts);
      }
    }
  }
  return { maxCalls, transportCalls: attempts.length, attempts, outcomes, outcomeSummary: benchmarkOutcomeSummary(outcomes), knownCostUsd: knownCost, requestPath: options.requestPath ?? "engine",
    costComplete: !unknownCost, costCeilingReached: knownCost >= maxUsd, callLimitReached: attempts.length >= maxCalls,
    stopReason, maxUsd,
    costBound: "Receipt-based stop before the next call; an in-flight call may exceed the cost threshold.",
    providerCallsInsideCLI: options.via === "cli" ? "not exposed; bound counts CLI invocations" : null,
    latencyTargetsAchieved: false, photographicQualityVerified: false };
}
