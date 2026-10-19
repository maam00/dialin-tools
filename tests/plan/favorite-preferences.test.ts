import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { makePlan } from "../../lib/plan/engine.js";
import { noPlaceConditions } from "../../lib/plan/conditions.js";
import { favoriteContext, favoriteRecipes } from "../../lib/plan/favorite-recipes.js";
import { recipeOf } from "../../lib/plan/looks.js";
import { answer, FakeAsk, look, PAST, recipe } from "./fixtures.js";

const entry = (id: string, settings = recipe("Saved faces"), preference?: unknown) => ({ recipe_id: id.repeat(64), recipe: settings,
  purpose: "Faces in daylight", note: "The skin was too warm for my usual taste", ...(preference === undefined ? {} : { preference }) });

test("legacy favorite preference remains positive; explicit avoid is normalized and never inferred from hearts", () => {
  const values = favoriteRecipes({ favorites: [entry("a"), entry("b", recipe("Saved warm"), " AVOID ")] }, X100VI);
  assert.deepEqual(values.map((value) => value.preference), ["favorite", "avoid"]);
  assert.equal(values[1].note, "The skin was too warm for my usual taste");
  assert.deepEqual(favoriteRecipes({ keep_rates: [{ look: "Saved faces", hearted: 0, shot: 40 }] }, X100VI), []);
});

test("invalid explicit preferences and invalid recipes do not turn into favorites", () => {
  const values = favoriteRecipes({ favorites: [entry("a", recipe("Valid"), "liked"), entry("b", recipe("Valid"), null),
    entry("c", recipe("Valid"), false), entry("d", recipe("Valid"), ""), entry("e", recipe("Bad", { film_sim: "Invented" }), "avoid"),
    entry("f", recipe("Valid"), "FAVORITE")] }, X100VI);
  assert.deepEqual(values.map((value) => [value.recipe.name, value.preference]), [["Valid", "favorite"]]);
});

test("same-name recipe versions remain distinct; renamed duplicate preferences deduplicate; explicit conflicts remain reviewable", () => {
  const original = recipe("Same name");
  const values = favoriteRecipes({ favorites: [entry("a", original, "avoid"), entry("b", { ...original, name: "Renamed" }, "avoid"),
    entry("c", { ...original, wb_shift_r: 2 }, "avoid"), entry("d", original, "favorite")] }, X100VI);
  assert.deepEqual(values.map((value) => [value.recipe.wb_shift_r, value.preference]), [[1, "avoid"], [2, "avoid"], [1, "favorite"]]);
  const context = favoriteContext(values);
  assert.match(context, /FAVORITE EXACT VERSIONS/);
  assert.match(context, /AVOIDED EXACT VERSIONS/);
  assert.match(context, /both favorite and avoid, explain the ambiguity/);
  assert.match(context, /do not invent confidence/);
});

test("negative taste guidance is bounded, exact-version context and current explicit intent takes priority", () => {
  const context = favoriteContext(favoriteRecipes({ favorites: [entry("a", recipe("Saved faces"), "avoid")] }, X100VI));
  assert.match(context, /"preference":"avoid"/);
  assert.match(context, /current explicit words take priority over saved favorites and avoids/);
  assert.match(context, /strong, reviewable negative taste context/);
  assert.match(context, /do not turn it into a blanket hard exclusion/);
  assert.match(context, /honor the current intent and disclose the saved preference conflict/);
  assert.match(context, /Neither preference grants permission to overwrite, relocate, remove or change a camera slot/);
  assert.match(context, /Never infer an avoid from hearts/);
  assert.equal(favoriteContext([]), "");
});

test("planner receives avoids separately while an avoided protected recipe remains exact and unwritten", async () => {
  const camera = PAST.map((value, index) => ({ slot: index + 1, name: value.name, recipe: structuredClone(value) }));
  const looks = camera.map((value) => ({ ...look(value.name, "Today"), ...value.recipe, reuse: value.name, reuse_slot: value.slot,
    when: "When this familiar rendering suits the scene", reason: "Keep this exact familiar version available." }));
  const fake = new FakeAsk([answer({ looks, stops: [{ name: "Today", start: "08:00", end: "22:00", light: "Described changing light" }], replace: [] })]);
  const avoided = entry("a", camera[2].recipe, "avoid");
  const plan = await makePlan({ said: `Prepare my familiar palette. I explicitly want ${camera[2].name} today; leave C3 exactly as it is.`,
    cam: X100VI, count: 7, cameraSlots: camera, protectedSlots: [3], taste: { favorites: [avoided] }, ask: fake.ask,
    conditions: noPlaceConditions("2026-10-14") });
  assert.equal(fake.calls.length, 1);
  assert.match(fake.calls[0].text, /AVOIDED EXACT VERSIONS/);
  assert.match(fake.calls[0].text, /honor the current intent and disclose the saved preference conflict/);
  const kept = plan.day_looks.find((value) => value.slot === 3)!;
  assert.equal(kept.status, "kept");
  assert.deepEqual(recipeOf(kept), camera[2].recipe);
  assert.ok(!plan.write.slots.includes(3));
  assert.equal(plan.palette_complete, true);
});
