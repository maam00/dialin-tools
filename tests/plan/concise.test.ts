import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { ConcisePlanError, expandConciseLook, expandConcisePlan, type ConciseLook, type ConcisePlan } from "../../lib/plan/concise.js";
import { recipeDesign } from "../../lib/plan/expert-metadata.js";
import { concisePlanSchema, concisePlanSystem, planSchema, planSystem } from "../../lib/plan/prompts.js";
import { RECIPE_KEYS } from "../../lib/plan/types.js";
import { look } from "./fixtures.js";

function conciseLook(name = "Moving faces", index = 0): ConciseLook {
  const { why: _why, reason: _reason, ...original } = look(name, "Home", { highlight: -index / 2,
    exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "+⅓", nd: false }, focus: "C", drive: "CH" });
  return { ...original, ideal_film_sim: original.film_sim, recipe_reference_id: null, reuse_slot: 0,
    when: "When children run across the room",
    how: "Set focus C and drive CH; check Auto ISO minimum shutter is 1/500 or faster.",
    design: { purpose: "Clear faces with restrained color", scene_fit: "A gentle rendering for their moving faces in window light.",
      tradeoff: "High ISO may soften fine detail.", alternative: "Try monochrome when color distracts.",
      uncertainty: "Check actual exposure and Auto ISO limits.", knowledge_ids: ["taste-intent"] } };
}

function conciseAnswer(): ConcisePlan {
  return { photographic_brief: { intent: "Photograph children playing indoors", subjects: ["Children"], lighting: ["Window light (supplied)"],
    color_priorities: ["Natural skin"], rendering_goal: "Restrained color", observations: ["They said children are running"],
    uncertainties: ["Actual shutter and Auto ISO limits"] },
    primary_look: "Moving faces", summary: "Seven distinct treatments for the children and their surroundings.",
    count_why: "Prepare all seven camera slots.", stops: [{ name: "Home", start: "10:00", end: "12:00", light: "Supplied window light" }],
    looks: ["Moving faces", "Quiet faces", "Soft room", "Deep room", "Window color", "Small details", "Pale walls"].map(conciseLook),
    replace: [{ name: "Old daylight", why: "Does not cover this indoor subject." }, { name: "Old shapes", why: "A less useful duplicate." }] };
}

test("concise expansion preserves seven complete rendering recipes and all physical guidance", () => {
  const wire = conciseAnswer();
  const expanded = expandConcisePlan(wire);
  assert.equal(expanded.looks.length, 7);
  assert.equal(expanded.primary_look, wire.primary_look);
  assert.deepEqual(expanded.photographic_brief, wire.photographic_brief);
  assert.deepEqual(expanded.stops, wire.stops);
  assert.deepEqual(expanded.replace, wire.replace);
  assert.equal(expanded.count_why, wire.count_why);
  for (const [i, item] of expanded.looks.entries()) {
    for (const key of RECIPE_KEYS.filter((key) => key !== "why")) assert.equal(item[key], wire.looks[i][key], key);
    for (const key of ["ideal_film_sim", "stop", "when", "reuse", "reuse_slot", "based_on", "focus", "drive", "how", "recipe_reference_id"] as const) {
      assert.equal(item[key], wire.looks[i][key], key);
    }
    assert.deepEqual(item.exposure, wire.looks[i].exposure);
    assert.match(item.how, /1\/500/);
    assert.equal(item.why, wire.looks[i].design.purpose);
    assert.equal(item.reason, wire.looks[i].design.scene_fit);
  }
});

test("design aliases remain authored text and do not invent independently reasoned setting explanations", () => {
  const wire = conciseLook();
  const expanded = expandConciseLook(wire);
  assert.deepEqual(expanded.design, { ...wire.design, choices: [], detail_level: "compact" });
  assert.equal(recipeDesign(expanded.design, X100VI)?.requires_review, false);
  assert.equal(expanded.why, wire.design.purpose);
  assert.equal(expanded.reason, wire.design.scene_fit);
  assert.equal(expanded.design?.settings_signature, undefined);
  assert.equal(expanded.design?.guidance_signature, undefined);
  assert.equal(expanded.design?.requires_review, undefined);
});

test("concise expansion keeps protected reuse identities and exact source references without renaming", () => {
  const wire = conciseLook("My Saved Look");
  wire.reuse = "My Saved Look";
  wire.reuse_slot = 5;
  wire.based_on = "Source Title";
  wire.recipe_reference_id = "published:exact-id";
  const expanded = expandConciseLook(wire, ["published:exact-id"]);
  assert.deepEqual([expanded.name, expanded.reuse, expanded.reuse_slot, expanded.based_on, expanded.recipe_reference_id],
    ["My Saved Look", "My Saved Look", 5, "Source Title", "published:exact-id"]);
  assert.throws(() => expandConciseLook(wire), ConcisePlanError);
  assert.throws(() => expandConciseLook(wire, ["Published:exact-id"]), /exact ID/);
  delete (wire as Partial<ConciseLook>).recipe_reference_id;
  assert.throws(() => expandConciseLook(wire), /exact ID/);
});

test("missing settings, wrong scalar types and missing guidance are rejected rather than defaulted", () => {
  for (const key of ["clarity", "kelvin", "film_sim", "reuse", "how", "focus", "drive"] as const) {
    const wire = conciseLook();
    delete (wire as Partial<ConciseLook>)[key];
    assert.throws(() => expandConciseLook(wire), ConcisePlanError, key);
  }
  for (const value of [undefined, "false", 0]) {
    const wire = conciseLook();
    (wire.exposure as unknown as Record<string, unknown>).nd = value;
    assert.throws(() => expandConciseLook(wire), /explicit boolean/);
  }
  const wire = conciseLook();
  (wire as unknown as Record<string, unknown>).highlight = "0";
  assert.throws(() => expandConciseLook(wire), /finite number/);
});

test("the adapter does not silently clamp unsupported values before the camera validator can inspect them", () => {
  const wire = conciseLook();
  wire.noise_reduction = 999;
  wire.exposure.shutter = "unsupported";
  const expanded = expandConciseLook(wire);
  assert.equal(expanded.noise_reduction, 999);
  assert.equal(expanded.exposure.shutter, "unsupported");
});

test("primary and stop bindings require exact unique names rather than case folding or first-look fallback", () => {
  for (const kind of ["primary-case", "primary-missing", "primary-duplicate", "stop-case", "stop-duplicate"]) {
    const wire = conciseAnswer();
    if (kind === "primary-case") wire.primary_look = "MOVING FACES";
    if (kind === "primary-missing") wire.primary_look = "Imaginary faces";
    if (kind === "primary-duplicate") wire.looks[1].name = wire.primary_look;
    if (kind === "stop-case") wire.looks[0].stop = "HOME";
    if (kind === "stop-duplicate") wire.stops.push({ ...wire.stops[0] });
    assert.throws(() => expandConcisePlan(wire), /exactly name one unique/, kind);
  }
});

test("wire data cannot set local verification metadata, and expanded data shares no mutable arrays", () => {
  const wire = conciseAnswer();
  Object.assign(wire.looks[0].design, { settings_signature: "made-up", guidance_signature: "made-up", requires_review: false,
    detail_level: "detailed", choices: [{ setting: "film_sim", reason: "Claimed independent reasoning", knowledge_ids: [] }] });
  const expanded = expandConcisePlan(wire);
  assert.equal(expanded.looks[0].design?.settings_signature, undefined);
  assert.deepEqual(expanded.looks[0].design?.choices, []);
  expanded.looks[0].design!.knowledge_ids!.push("changed");
  expanded.photographic_brief!.subjects.push("changed");
  expanded.looks[0].exposure.iso = "800";
  assert.deepEqual(wire.looks[0].design.knowledge_ids, ["taste-intent"]);
  assert.deepEqual(wire.photographic_brief.subjects, ["Children"]);
  assert.equal(wire.looks[0].exposure.iso, "A");
  assert.throws(() => expandConciseLook({ ...wire.looks[0], why: "Conflicting extra description" }), /not separate why\/reason/);
});

test("concise schema removes only duplicated prose and keeps a stable nullable source-reference shape", () => {
  const legacy = planSchema(X100VI, true, true, ["one-source"]);
  const concise = concisePlanSchema(X100VI, true);
  type Schema = { properties: Record<string, Schema>; items?: Schema; required?: string[]; enum?: unknown[]; type?: unknown };
  const oldLook = (legacy as Schema).properties.looks.items!;
  const newLook = (concise as Schema).properties.looks.items!;
  for (const key of Object.keys(oldLook.properties).filter((key) => !["why", "reason", "design", "recipe_reference_id"].includes(key))) {
    assert.deepEqual(newLook.properties[key], oldLook.properties[key], key);
  }
  assert.ok(!newLook.required!.includes("why"));
  assert.ok(!newLook.required!.includes("reason"));
  assert.ok(newLook.required!.includes("recipe_reference_id"));
  assert.equal(newLook.properties.recipe_reference_id.enum, undefined);
  assert.deepEqual(newLook.properties.recipe_reference_id.type, ["string", "null"]);
  for (const key of ["photographic_brief", "primary_look", "summary", "count_why", "stops", "replace"]) {
    assert.deepEqual((concise as Schema).properties[key], (legacy as Schema).properties[key], key);
  }
  assert.ok((planSchema(X100VI, true, true) as Schema).properties.looks.items!.required!.includes("why"));
});

test("compact prompts retain every reviewed fact and remove conflicting seven-group explanation instructions", () => {
  const detailed = planSystem(X100VI, true, true, false);
  const compact = planSystem(X100VI, true, true, true);
  const concise = concisePlanSystem(X100VI, true, true);
  const factLines = (text: string) => text.split("\n").filter((line) => line.startsWith("["));
  assert.deepEqual(factLines(compact), factLines(detailed));
  assert.deepEqual(factLines(concise), factLines(detailed));
  assert.match(detailed, /give reasons of at most 12 words each for film_sim/);
  for (const prompt of [compact, concise]) assert.doesNotMatch(prompt, /give reasons of at most 12 words each for film_sim/);
  assert.match(concise, /look's design.scene_fit with "From the supplied image:"/);
  assert.match(concise, /never shorten away a needed minimum-shutter/);
  assert.match(concise, /There are no separate why or reason fields/);
  assert.match(concise, /complete C1–C7 day palette/);
});
