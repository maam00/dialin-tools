import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { benchmarkOutcomeSummary, benchmarkPlanStatus, benchmarkRepairRules, planningComparison, type BenchmarkOutcome } from "../../lib/plan/benchmark.js";
import { ModelError, MODELS, type AskRequest } from "../../lib/plan/model.js";
import type { Plan } from "../../lib/plan/types.js";
import { answer, FakeAsk, look } from "./fixtures.js";
import { QUALIFICATION_SCENARIOS, qualificationBody, qualificationPairs, qualifyPlan, runQualificationHTTP } from "../../lib/plan/qualification.js";
import { parsePlanRequest } from "../../lib/plan/http.js";

test("full seven settings, declared primary, intent and explanations have independent receipts", () => {
  const plan = { day_looks: Array.from({ length: 7 }, (_, index) => ({ ...look(`Synthetic ${index + 1}`, "Beach"), slot: index + 1,
    recipe_known: true, status: "new", design: { detail_level: "compact", choices: [] } })), primary_slot: 6, primary_selection: "declared",
    palette_complete: true, intent_satisfied: false, intent_issues: [{ code: "conflict" }], factual_issues: [{ code: "review" }],
    warnings: ["Normalization was disclosed"], notes: ["Settings note"] } as unknown as Plan;
  const status = benchmarkPlanStatus(plan, X100VI);
  assert.equal(status.fullSevenValidRecipes, true);
  assert.equal(status.primarySlot, 6);
  assert.equal(status.primarySelection, "declared");
  assert.equal(status.intentSatisfied, false);
  assert.equal(status.factualIssues.length, 1);
  assert.equal(status.aestheticScore, null);
  plan.day_looks[4].recipe_known = false;
  assert.equal(benchmarkPlanStatus(plan, X100VI).fullSevenValidRecipes, false);
  assert.deepEqual(benchmarkPlanStatus(plan, X100VI).missingSlots, [5]);
});

test("comparison counts actual fallback starts, retains failures and cannot exceed twelve fake transports", async () => {
  let calls = 0;
  const result = await planningComparison({ fixtures: ["one", "two", "three"], via: "fake", maxCalls: 12,
    attempt: async () => { calls += 1; throw new Error("fixture failure"); },
    runPlan: async (_arm, _fixture, ask) => {
      const request: AskRequest = { task: "test", text: "synthetic", system: "stable", schema: {}, model: MODELS.sonnet,
        fallback: MODELS.haiku, effort: "medium", timeoutMs: 30_000 };
      const response = await ask(request);
      if (!response.ok) throw new Error("no usable plan");
      return {} as Plan;
    } });
  assert.equal(calls, 12);
  assert.equal(result.transportCalls, 12);
  assert.equal(result.stopReason, "call_limit");
  assert.equal(result.costCeilingReached, false);
  assert.ok(result.outcomes.length > 0 && result.outcomes.every((o) => !o.ok));
  assert.equal(result.latencyTargetsAchieved, false);
  assert.equal(result.photographicQualityVerified, false);
});

test("missing live cost receipt stops separately from the known cost ceiling without another transport start", async () => {
  let starts = 0;
  const result = await planningComparison({ fixtures: ["one", "two", "three"], repetitions: 1, via: "cli", maxUsd: 5,
    attempt: async () => {
      starts += 1;
      if (starts === 3) throw new ModelError("The fallback timed out without a receipt", "timeout");
      return { data: {}, model: "sonnet", usage: null, reportedCostUsd: 0.1 };
    }, runPlan: async (_arm, _fixture, ask) => {
      const answer = await ask({ task: "test", system: "stable", text: "synthetic", schema: {}, model: MODELS.sonnet,
        fallback: MODELS.haiku, effort: "medium", timeoutMs: 30_000 });
      if (!answer.ok) throw new ModelError("No usable plan", answer.code ?? "failed");
      return { day_looks: [], palette_complete: false } as unknown as Plan;
    } });
  assert.equal(starts, 3);
  assert.equal(result.outcomes.length, 3);
  assert.equal(result.stopReason, "unknown_cost_receipt");
  assert.equal(result.knownCostUsd, 0.2);
  assert.equal(result.costComplete, false);
  assert.equal(result.costCeilingReached, false);
  assert.equal(result.callLimitReached, false);
});

test("known dollar ceiling, transport limit and completed schedule have distinct stop reasons", async () => {
  for (const [maxUsd, maxCalls, expected] of [[0.05, 12, "cost_ceiling"], [5, 1, "call_limit"], [5, 2, "completed"]] as const) {
    const result = await planningComparison({ fixtures: ["one"], repetitions: 1, via: "cli", maxUsd, maxCalls,
      attempt: async () => ({ data: {}, model: "sonnet", usage: null, reportedCostUsd: 0.1 }),
      runPlan: async (_arm, _fixture, ask) => {
        await ask({ task: "test", system: "stable", text: "synthetic", schema: {}, model: MODELS.sonnet,
          effort: "medium", timeoutMs: 30_000 });
        return { day_looks: [], palette_complete: false } as unknown as Plan;
      } });
    assert.equal(result.stopReason, expected);
    assert.equal(result.costCeilingReached, expected === "cost_ceiling");
    assert.equal(result.costComplete, true);
  }
});

test("synthetic-only comparison refuses image attempts and prevents hidden provider fallback", async () => {
  let calls = 0;
  await planningComparison({ fixtures: ["one"], via: "fake", repetitions: 1,
    attempt: async (req) => { calls += 1; assert.equal(req.serverFallback, false); return { data: {}, model: MODELS.sonnet, usage: null }; },
    runPlan: async (_arm, _fixture, ask) => {
      await ask({ task: "test", text: "synthetic", system: "stable", schema: {}, model: MODELS.sonnet,
        effort: "medium", timeoutMs: 30_000, imageBase64: "not-an-approved-photo" });
      throw new Error("not a valid plan");
    } });
  assert.equal(calls, 0);
  await planningComparison({ fixtures: ["one"], via: "fake", repetitions: 1,
    attempt: async (req) => { calls += 1; assert.equal(req.serverFallback, false); return { data: {}, model: MODELS.sonnet, usage: null }; },
    runPlan: async (_arm, _fixture, ask) => {
      await ask({ task: "test", text: "synthetic", system: "stable", schema: {}, model: MODELS.sonnet, effort: "medium", timeoutMs: 30_000 });
      return { day_looks: [], palette_complete: false } as unknown as Plan;
    } });
  assert.equal(calls, 2);
});

test("qualification fixtures are app-compatible full-seven synthetic requests with an identical-scene taste pair", () => {
  assert.equal(QUALIFICATION_SCENARIOS.length, 8);
  for (const scenario of QUALIFICATION_SCENARIOS) {
    for (const arm of ["compact", "concise"] as const) {
      const body = qualificationBody(scenario, arm);
      const parsed = parsePlanRequest(body, false);
      assert.equal(parsed.count, 7);
      assert.equal(parsed.reasoningMode, "compact");
      assert.equal(parsed.shootingMode, "automatic");
      assert.equal(parsed.place, null);
      assert.equal(parsed.image, null);
      assert.equal("output_mode" in body, false, "the experiment is a trusted server override, not client input");
    }
  }
  const pair = QUALIFICATION_SCENARIOS.filter((scenario) => scenario.pair);
  assert.deepEqual(pair[0].scene.observations, pair[1].scene.observations);
  assert.notEqual(pair[0].said, pair[1].said);
});

test("concise comparisons retain their distinct arm and the same provider-call limit", async () => {
  let starts = 0;
  const result = await planningComparison({ fixtures: ["one"], arms: ["compact", "concise"], repetitions: 2,
    via: "fake", maxCalls: 3, attempt: async () => {
      starts += 1; return { data: {}, model: MODELS.sonnet, usage: null, reportedCostUsd: 0.1 };
    }, runPlan: async (_arm, _fixture, ask) => {
      await ask({ task: "plan", text: "synthetic", system: "stable", schema: {}, model: MODELS.sonnet,
        effort: "medium", timeoutMs: 30_000 });
      return { day_looks: [], palette_complete: false } as unknown as Plan;
    } });
  assert.equal(starts, 3);
  assert.equal(result.stopReason, "call_limit");
  assert.deepEqual(result.attempts.map((attempt) => attempt.arm), ["compact", "concise", "concise"]);
  assert.equal(result.photographicQualityVerified, false);
});

test("focused repair measurements retain exact rules without copying the accepted plan into labels", () => {
  const rules = ["6 looks; make 7", "Dinner glow: repeats the settings of Beach memory; give each new look a distinct rendering purpose"];
  const text = `synthetic brief\n\nYOUR LAST ANSWER BROKE THESE RULES:\n${rules.map((rule) => `- ${rule}`).join("\n")}\n\nREPAIR ONLY 1 NEW LOOK. Accepted plan stays unchanged.`;
  assert.deepEqual(benchmarkRepairRules(text), rules);
  assert.deepEqual(benchmarkRepairRules("ordinary prompt"), []);
});

function syntheticPalette(scenarioID: string) {
  const scenario = QUALIFICATION_SCENARIOS.find((candidate) => candidate.id === scenarioID)!;
  const freshCount = 7 - (scenario.protected_slots?.length ?? 0);
  const names = ["Clear daylight", "Warm memory", "Quiet faces", "Soft light", "Deep shapes", "Color details", "Evening color"];
  const looks = names.slice(0, freshCount).map((name, index) => look(name, "Today", {
    reuse: "", wb_shift_r: index - 3, highlight: index * 0.5 - 1, clarity: 0,
    ...(scenario.requireAllNew === "monochrome" ? { film_sim: "Acros+R", color: 0, color_chrome: "Off", color_chrome_fx_blue: "Off" } : {}),
    exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false } }));
  for (const protectedSlot of scenario.protected_slots ?? []) if (protectedSlot.recipe) looks.push({ ...look(protectedSlot.recipe.name, "Today"),
    ...protectedSlot.recipe, reuse: protectedSlot.recipe.name, reuse_slot: protectedSlot.slot,
    exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false } });
  return { ...answer({ looks, stops: [{ name: "Today", start: "09:00", end: "21:00", light: "Synthetic described light" }], replace: [] }), primary_look: looks[0].name };
}

test("qualification invokes the actual handler; full known palette and safe unread/monochrome exceptions stay distinct", async () => {
  for (const id of ["natural-faces", "mono-protected", "unknown-protected"]) {
    const scenario = QUALIFICATION_SCENARIOS.find((candidate) => candidate.id === id)!;
    const fake = new FakeAsk([syntheticPalette(id)]);
    const receipts: { status: number; requestID: string }[] = [];
    const plan = await runQualificationHTTP({ scenario, arm: "compact", ask: fake.ask, onReceipt: (receipt) => receipts.push(receipt) });
    const checked = qualifyPlan(plan, scenario);
    assert.deepEqual(checked.failures, [], id);
    assert.equal(checked.objectivePass, true);
    assert.equal(checked.manualReviewRequired, true);
    assert.equal(checked.aestheticScore, null);
    assert.equal(fake.calls.length, 1);
    assert.equal(receipts[0].status, 200);
    assert.match(receipts[0].requestID, /^[a-f0-9-]{36}$/);
  }
});

test("private benchmark keeps exact repair rules and a raw structured answer before engine mutation", async () => {
  const rules = ["C4 duplicates the active settings of C1", "primary_look must name a look in this answer exactly"];
  const text = `Synthetic scene\n\nYOUR LAST ANSWER BROKE THESE RULES. Fix exactly these, keep everything else:\n${rules.map((rule) => `- ${rule}`).join("\n")}\n\nYour last answer:\n{}`;
  assert.deepEqual(benchmarkRepairRules(text), rules);
  const result = await planningComparison({ fixtures: ["one"], arms: ["compact"], repetitions: 1, via: "fake",
    attempt: async () => ({ data: { looks: [{ name: "Original", design: { purpose: "Synthetic reason" } }] }, model: MODELS.sonnet, usage: null }),
    runPlan: async (_arm, _fixture, ask) => {
      const response = await ask({ task: "plan-retry", system: "stable", text, schema: {}, model: MODELS.sonnet, effort: "medium", timeoutMs: 30_000 });
      (response.data as { looks: { name: string }[] }).looks[0].name = "Mutated downstream";
      return { day_looks: [], palette_complete: false } as unknown as Plan;
    } });
  const attempt = result.attempts[0];
  assert.deepEqual(attempt.repairRules, rules);
  assert.equal((attempt.rawStructuredData as { looks: { name: string }[] }).looks[0].name, "Original");
  assert.equal(attempt.task, "plan-retry");
  assert.ok(attempt.designChars! > 0 && attempt.responseChars! > attempt.designChars!);
});

test("qualification retains HTTP failures and objective failures without manufacturing success", async () => {
  const scenario = QUALIFICATION_SCENARIOS[0];
  const result = await planningComparison({ fixtures: [scenario.id], arms: ["compact"], repetitions: 1, requestPath: "http", via: "fake", maxCalls: 1,
    attempt: async () => { throw new ModelError("Synthetic refusal", "refused", true); },
    runPlan: (arm, _id, ask) => runQualificationHTTP({ scenario, arm, ask }) });
  assert.equal(result.outcomes[0].ok, false);
  assert.equal(result.outcomes[0].httpStatus, 502);
  assert.equal((result.outcomes[0].failureBody as { code: string }).code, "refused");
  const fake = new FakeAsk([syntheticPalette(scenario.id)]);
  const plan = await runQualificationHTTP({ scenario, arm: "compact", ask: fake.ask });
  const motion = QUALIFICATION_SCENARIOS.find((candidate) => candidate.id === "motion-auto")!;
  const original = qualifyPlan(plan, motion);
  assert.ok(original.failures.includes("requested_primary_focus_guidance"));
  assert.ok(original.failures.includes("requested_minimum_shutter_check_visible"));
  const primary = plan.day_looks.find((look) => look.slot === plan.primary_slot)!;
  primary.focus = "C";
  primary.tip = "Check Auto ISO minimum shutter is 1/500 or faster.";
  // A check hidden from the quick shooting row is still an actionable-guidance gap.
  assert.ok(qualifyPlan(plan, motion).failures.includes("requested_minimum_shutter_check_visible"));
  plan.cheat_sheet.stops.flatMap((stop) => stop.looks).find((look) => look.slot === plan.primary_slot)!.how = primary.tip;
  assert.ok(!qualifyPlan(plan, motion).failures.includes("requested_minimum_shutter_check_visible"));
});

test("successful route with flagged explanation remains distinct from failed transport or incomplete recipe", async () => {
  const scenario = QUALIFICATION_SCENARIOS[0];
  const plan = await runQualificationHTTP({ scenario, arm: "compact", ask: new FakeAsk([syntheticPalette(scenario.id)]).ask });
  plan.factual_issues = [{ slot: 2, code: "wb_cast_certainty", path: "design.scene_fit", claim: "Synthetic unsupported claim",
    message: "Synthetic review reason", knowledge_ids: ["wb-mixed"] }];
  const outcome: BenchmarkOutcome = { arm: "compact", fixture: scenario.id, repetition: 1, ms: 1, ok: true,
    code: null, httpStatus: 200, paletteComplete: true, looks: 7, plan, coverage: benchmarkPlanStatus(plan, X100VI), qualification: qualifyPlan(plan, scenario) };
  assert.deepEqual(benchmarkOutcomeSummary([outcome]), { outcomes: 1, routeSucceeded: 1, routeFailed: 0,
    qualificationPassed: 0, qualificationFlagged: 1, qualificationNotAssessed: 0, fullSevenValidRecipes: 1, photographicQualityVerified: false });
  assert.deepEqual(outcome.qualification!.failures, ["no_known_factual_issues"]);
});

test("qualification validates every known tuple instead of trusting seven represented names", async () => {
  const scenario = QUALIFICATION_SCENARIOS[0];
  const plan = await runQualificationHTTP({ scenario, arm: "compact", ask: new FakeAsk([syntheticPalette(scenario.id)]).ask });
  plan.day_looks[4].noise_reduction = 999;
  assert.ok(qualifyPlan(plan, scenario).failures.includes("all_known_recipes_camera_valid"));
  assert.equal(benchmarkPlanStatus(plan, X100VI).fullSevenValidRecipes, false);
});

test("same-scene taste comparison inspects declared primary settings and retains missing pair members honestly", async () => {
  const scenario = QUALIFICATION_SCENARIOS[0];
  const first = await runQualificationHTTP({ scenario, arm: "compact", ask: new FakeAsk([syntheticPalette(scenario.id)]).ask });
  first.primary_slot = 6;
  const second = structuredClone(first);
  second.day_looks[0].wb_shift_r += 1; // An unrelated first array entry cannot stand in for the declared primary.
  const outcome = (fixture: string, plan: Plan): BenchmarkOutcome => ({ arm: "compact", fixture, repetition: 1,
    ms: 1, ok: true, code: null, httpStatus: 200, paletteComplete: true, looks: 7, plan });
  const pair = [outcome("natural-faces", first), outcome("warm-editorial-faces", second)];
  assert.equal(qualificationPairs(pair)[0].activePrimarySettingsDiffer, false);
  assert.deepEqual(qualificationPairs(pair)[0].reviewFlags, ["same_scene_primary_settings_unchanged"]);
  assert.deepEqual(qualificationPairs(pair)[0].declaredPrimarySlots, [6, 6]);
  second.day_looks.find((look) => look.slot === 6)!.wb_shift_r += 1;
  assert.equal(qualificationPairs(pair)[0].activePrimarySettingsDiffer, true);
  assert.equal(qualificationPairs(pair)[0].aestheticScore, null);
  assert.equal(qualificationPairs([pair[0]])[0].status, "incomplete");
  assert.equal(qualificationPairs([pair[0]])[0].activePrimarySettingsDiffer, null);
});
