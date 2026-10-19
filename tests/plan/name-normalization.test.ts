import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { adjustPlan, makePlan, normalizeOverlengthNames } from "../../lib/plan/engine.js";
import { recipeOf } from "../../lib/plan/looks.js";
import type { CameraSlot, ModelLook } from "../../lib/plan/types.js";
import { answer, FakeAsk, look } from "./fixtures.js";

const automaticLook = (name: string, highlight = 0): ModelLook => look(name, "Beach", { highlight,
  exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false } });
const palette = (first = "Side light faces", second = "Gentle faces") => ({
  ...answer({ looks: [automaticLook(first), automaticLook(second, -0.5), automaticLook("Deep shapes", -1)],
    stops: [{ name: "Beach", start: "10:00", end: "12:00", light: "Hard side light" }], replace: [] }), primary_look: first,
});

test("a sole length problem is shortened once without changing settings, source identities or exact primary binding", () => {
  const data = palette();
  data.looks[0].recipe_reference_id = "original-source-record";
  data.looks[0].based_on = "Original source title";
  const before = structuredClone(data);
  const warnings = normalizeOverlengthNames(data, null, new Map(), X100VI);
  assert.deepEqual(warnings, ["renamed \"Side light faces\" to \"Side light\" to fit the camera's 14-character limit"]);
  assert.equal(data.primary_look, "Side light");
  assert.deepEqual(data.looks[0], { ...before.looks[0], name: "Side light" });
  assert.deepEqual(data.looks.slice(1), before.looks.slice(1));
  assert.equal(data.looks[0].recipe_reference_id, "original-source-record");
  assert.equal(data.looks[0].based_on, "Original source title");
});

test("new name length correction avoids a model retry and retains the warning and declared primary", async () => {
  const data = palette();
  const fake = new FakeAsk([data]);
  const plan = await makePlan({ said: "Faces on the beach", cam: X100VI, count: 3, shootingMode: "automatic", ask: fake.ask });
  assert.equal(fake.calls.length, 1);
  assert.deepEqual(plan.calls?.map((call) => call.task), ["plan"]);
  assert.equal(plan.day_looks.find((look) => look.slot === plan.primary_slot)!.name, "Side light");
  assert.equal(plan.primary_selection, "declared");
  assert.ok(plan.warnings.some((warning) => warning.includes('renamed "Side light faces" to "Side light"')));
  const { name: _new, ...actual } = recipeOf(plan.day_looks[0]);
  const { name: _old, ...expected } = recipeOf(data.looks[0]);
  assert.deepEqual(actual, expected);
});

test("kept, protected/reserved camera, library and explicit reuse identities are never shortened", () => {
  for (const kind of ["camera", "library", "reuse", "reuse-slot"]) {
    const data = palette();
    const camera: CameraSlot[] | null = kind === "camera"
      ? [{ slot: 3, name: "Side light faces", recipe: recipeOf(data.looks[0]) }] : null;
    const library = kind === "library" ? new Map([["side light faces", recipeOf(data.looks[0])]]) : new Map();
    if (kind === "reuse") data.looks[0].reuse = "Saved source";
    if (kind === "reuse-slot") data.looks[0].reuse_slot = 3;
    const before = structuredClone(data);
    assert.deepEqual(normalizeOverlengthNames(data, camera, library, X100VI), [], kind);
    assert.deepEqual(data, before, kind);
  }
});

test("candidate collisions, ambiguous originals and colliding proposals retain the existing retry path", async () => {
  for (const kind of ["answer", "camera", "reuse", "ambiguous", "proposal"]) {
    const data = palette();
    const camera: CameraSlot[] | null = kind === "camera" ? [{ slot: 5, name: "Side light", recipe: null }] : null;
    if (kind === "answer") data.looks[1].name = "Side light";
    if (kind === "reuse") data.looks[1].reuse = "SIDE LIGHT";
    if (kind === "ambiguous") data.looks[1].name = "SIDE LIGHT FACES";
    if (kind === "proposal") data.looks[1].name = "Side light scenes";
    const before = structuredClone(data);
    assert.deepEqual(normalizeOverlengthNames(data, camera, new Map(), X100VI), [], kind);
    assert.deepEqual(data, before, kind);
  }
  const fake = new FakeAsk([palette("Side light faces", "Side light"), palette("Beach faces", "Side light")]);
  const plan = await makePlan({ said: "Beach portraits", cam: X100VI, count: 3, ask: fake.ask });
  assert.equal(fake.calls.length, 2);
  assert.match(fake.calls[1].text, /16 characters, max 14/);
  assert.ok(!plan.warnings.some((warning) => warning.includes("renamed")));
});

test("other naming or camera-value problems are not disguised as pure length fixes", () => {
  for (const kind of ["digits", "caps", "words", "camera-value"]) {
    const data = palette();
    if (kind === "digits") data.looks[0].name = "Side light faces 2";
    if (kind === "caps") data.looks[0].name = "SIDE LIGHT FACES";
    if (kind === "words") data.looks[0].name = "Soft side light faces";
    if (kind === "camera-value") data.looks[0].noise_reduction = 999;
    const before = structuredClone(data);
    assert.deepEqual(normalizeOverlengthNames(data, null, new Map(), X100VI), [], kind);
    assert.deepEqual(data, before, kind);
  }
});

test("adjustment shortens a new overlong label without retrying, but respects other existing look names", async () => {
  const plan = await makePlan({ said: "Beach portraits", cam: X100VI, count: 3, shootingMode: "automatic",
    ask: new FakeAsk([palette("Beach faces", "Side light")]).ask });
  const current = plan.day_looks[0];
  const fake = new FakeAsk([{ look: automaticLook("Gentle side faces"), change: "Gentler contrast." }]);
  const changed = await adjustPlan({ plan, slot: current.slot!, said: "Gentler contrast", cam: X100VI, ask: fake.ask });
  assert.equal(fake.calls.length, 1);
  assert.equal(changed.look.name, "Gentle side");
  assert.ok(changed.look.adjusted!.warnings.some((warning) => warning.includes("renamed")));
  assert.deepEqual(plan.day_looks.map((look) => look.name), ["Beach faces", "Side light", "Deep shapes"]);
  const colliding = new FakeAsk([{ look: automaticLook("Side light faces"), change: "Softer." },
    { look: automaticLook("Beach faces"), change: "Softer." }]);
  await adjustPlan({ plan, slot: current.slot!, said: "Softer", cam: X100VI, ask: colliding.ask });
  assert.equal(colliding.calls.length, 2);
  assert.match(colliding.calls[1].text, /16 characters, max 14/);
});
