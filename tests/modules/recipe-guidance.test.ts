// Round 2 guidance fixes: seven original scenario rules, knowledge lookups that show the selected directions and
// rules without a catalog, community practice that matches what the writer sends and states its coverage honestly,
// and "warm but not orange" kept as a warm request. No catalog, model, camera or photograph.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { X100VI } from "../../lib/cameras.js";
import { EXPERT_KNOWLEDGE_VERSION, expertKnowledge, knowledgeIDs, SETTING_KNOWLEDGE } from "../../lib/plan/expert-knowledge.js";
import { inferPhotographicPolicy } from "../../lib/plan/expert-policy.js";
import { buildPlannerKnowledgeContext, scenarioRulesFor } from "../../modules/recipes/knowledge.js";
import { inferShootIntent } from "../../modules/recipes/scenarios.js";
import { assessLookPractice, loadRecipeSpacePriors, RECIPE_SPACE_PATH } from "../../modules/recipes/space.js";

const ROOT = fileURLToPath(new URL("../../", import.meta.url));
const SCENARIO_RULES = ["wb-green-magenta", "scene-blue-hour", "scene-neon-night", "scene-backlight", "scene-bright-surfaces", "scene-overcast", "scene-tungsten-daylight"];
const look = (fields: Record<string, unknown>) => ({ slot: 3, name: "Test look", film_sim: "Reala Ace", grain: "Weak Small", color_chrome: "Weak", color_chrome_fx_blue: "Off",
  white_balance: "Auto", kelvin: 0, wb_shift_r: 1, wb_shift_b: -1, dynamic_range: "DR400", highlight: -1, shadow: 0, color: 0, sharpness: 0, noise_reduction: -4, clarity: 0, ...fields }) as never;

test("seven original scenario rules join the setting rules in the same format and reach the planner prompt", () => {
  assert.equal(SETTING_KNOWLEDGE.length, 31);
  assert.notEqual(EXPERT_KNOWLEDGE_VERSION, "x100vi-2026-10-15.1", "changed guidance changes the knowledge version");
  const prompt = expertKnowledge(X100VI);
  for (const id of SCENARIO_RULES) {
    const rule = SETTING_KNOWLEDGE.find((item) => item.id === id);
    assert.ok(rule, id);
    assert.equal(rule.kind, "design_heuristic", id);
    assert.ok(rule.sources.length >= 1 && rule.text.length > 120 && rule.text.length < 520, id);
    assert.ok(knowledgeIDs(X100VI).includes(id), `${id} is a citable knowledge_id`);
    assert.ok(prompt.includes(`[${id}] design_heuristic: ${rule.text}`), id);
    // Original guidance, not a recipe: no named recipe, creator or slot-ready settings list.
    assert.doesNotMatch(rule.text, /\brecipe\b|https?:|Grain (?:Weak|Strong)|Color Chrome (?:Weak|Strong)/i, id);
  }
  // The WB-shift directions agree with the existing rule (warmer = R up, B down): both up is magenta, both down green.
  assert.match(SETTING_KNOWLEDGE.find((r) => r.id === "wb-green-magenta")!.text, /Raising both moves the render toward magenta.*lowering both moves toward green/);
});

test("a knowledge lookup without a catalog shows the selected original directions and the scenario rules", () => {
  assert.deepEqual(scenarioRulesFor("Rainy neon signs at night, then dinner under tungsten lamps").map((rule) => rule.id), ["scene-neon-night", "scene-overcast", "scene-tungsten-daylight"]);
  assert.deepEqual(scenarioRulesFor("Portraits"), []);
  const context = buildPlannerKnowledgeContext("snow at midday, then blue hour", { knowledge: { references: [], analyses: [], articles: [] } as never, priors: null });
  assert.deepEqual(context.scenario_rules.map((rule) => rule.id), ["scene-blue-hour", "scene-bright-surfaces"]);
  assert.ok(context.original_directions.length > 0 && context.original_directions.every((direction) => /^ref-/.test(direction.id) && direction.film_sim));
  assert.match(context.context, /Scenario rules for the light this brief names .*: \[scene-blue-hour\], \[scene-bright-surfaces\]\./);

  const result = spawnSync(process.execPath, [`${ROOT}scripts/dialin.mjs`, "recipes", "knowledge", "--query", "hard midday sun on white sand"],
    { cwd: ROOT, env: { ...process.env, DIALIN_RECIPE_CATALOG: "none" }, encoding: "utf8", timeout: 60000 });
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout).planner_context;
  assert.equal(output.matches.length, 0);
  assert.equal(output.original_directions.length, output.retrieval.selected_original_directions);
  assert.ok(output.original_directions.length > 0, "the selected directions are shown, not only counted");
  assert.deepEqual(output.scenario_rules.map((rule: { id: string }) => rule.id), ["scene-bright-surfaces"]);
});

test("community practice leaves out controls a monochrome write does not send", () => {
  const priors = loadRecipeSpacePriors(RECIPE_SPACE_PATH)!;
  const acros = assessLookPractice(look({ film_sim: "Acros+Ye", wb_shift_r: 0, wb_shift_b: 0, color: 0 }), priors);
  assert.ok(acros.group?.startsWith("Acros"));
  assert.ok(!acros.unusual_settings.some((item) => /^wb_shift|^color/.test(item.setting)), JSON.stringify(acros.unusual_settings));
  assert.match(acros.note, /not written for a monochrome look, so they are not compared/);
  // The same neutral shift on a color simulation is still compared.
  const color = assessLookPractice(look({ wb_shift_r: 0, wb_shift_b: 0 }), priors);
  assert.doesNotMatch(color.note, /not compared/);
});

test("a setting outside the published figures is described as such, never as absent from every recipe", () => {
  const priors = loadRecipeSpacePriors(RECIPE_SPACE_PATH)!;
  const result = assessLookPractice(look({ grain: "Off" }), priors);
  const grain = result.unusual_settings.find((item) => item.setting === "grain");
  assert.ok(grain, "grain Off is outside the published Reala Ace grain figures");
  assert.equal(grain.share, 0);
  assert.match(result.note, /grain Off \(not in the published Reala Ace figures, which count \d+ recipes for this setting\)/);
  assert.doesNotMatch(result.note, /not among/);
  const shared = assessLookPractice(look({ highlight: 4, shadow: 4, color: 4 }), priors);
  assert.ok(!/% of Reala Ace recipes\)/.test(shared.note), "a share names the recipes it was counted over");
});

test("'warm but not orange' keeps the warm intent and notes the limit; 'no orange skin' still avoids warmth", () => {
  for (const brief of ["Birthday party under tungsten lamps, warm but not orange faces.", "Dinner by candlelight: warmth, but not too yellow.", "Keep it warm without going orange."]) {
    const intent = inferShootIntent(brief);
    assert.equal(intent.avoid_added_warmth, false, brief);
    assert.ok(intent.priorities.includes("warm_color"), brief);
    assert.ok(intent.review_notes.some((note) => /keep the warmth .* keep faces from turning orange/.test(note)), brief);
    const policy = inferPhotographicPolicy({ said: brief });
    assert.equal(policy.preserveWarmth, true, brief);
    assert.equal(policy.avoidWarmCast, false, brief);
    assert.equal(policy.requiresReview, false, `${brief}: a request the agent can satisfy is not an unresolvable conflict`);
  }
  assert.equal(inferShootIntent("Dinner, no orange skin please").avoid_added_warmth, true);
  assert.equal(inferShootIntent("Natural faces, not orange").avoid_added_warmth, true);
});
