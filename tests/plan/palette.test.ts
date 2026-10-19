import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { adjustPlan, makePlan, planFromClient } from "../../lib/plan/engine.js";
import { parsePlanRequest, planHandler } from "../../lib/plan/http.js";
import { recipeOf } from "../../lib/plan/looks.js";
import { putLook } from "../../lib/plan/slots.js";
import type { CameraSlot, ModelLook, Plan } from "../../lib/plan/types.js";
import { answer, FakeAsk, FakeNet, look, PAST, recipe } from "./fixtures.js";

beforeEach(() => { new FakeNet().install(); });

const names = ["Open shade", "Warm faces", "Hard sunlight", "Cool interiors", "Golden light", "After dark", "Quiet streets"];
function fresh(n: number): ModelLook[] {
  return names.slice(0, n).map((name, i) => look(name, "Today", { wb_shift_r: i - 3, wb_shift_b: 3 - i }));
}
const today = [{ name: "Today", start: "08:00", end: "22:00", light: "Changing daylight and indoors" }];
const model = (looks: ModelLook[]) => answer({ looks, stops: today, replace: [] });
const camera = (): CameraSlot[] => PAST.map((r, i) => ({ slot: i + 1, name: r.name, recipe: structuredClone(r) }));
function reuse(slot: CameraSlot): ModelLook {
  return { ...look(slot.name, "Today"), ...slot.recipe!, reuse: slot.name, reuse_slot: slot.slot,
    when: "When this familiar color fits", reason: "Keep your familiar treatment available as the day's light changes." };
}

test("full palette includes exact protected recipes at fixed slots, never writes/replays them", async () => {
  const slots = camera();
  slots[1].recipe = recipe(slots[1].name, { film_sim: "Astia", white_balance: "Shade", color: 3, noise_reduction: 0, clarity: 2 });
  const data = model([...fresh(5), reuse(slots[1]), reuse(slots[5])]);
  // Even a model copy that differs cannot change an explicitly reused camera recipe.
  data.looks[5].film_sim = "Classic Chrome";
  const fake = new FakeAsk([data]);
  const plan = await makePlan({ said: "family by the sea, indoors later", cam: X100VI, count: 7,
    cameraSlots: slots, protectedSlots: [6, 2], shootingMode: "automatic", ask: fake.ask });
  assert.equal(fake.calls.length, 1);
  assert.match(fake.calls[0].system, /complete C1–C7 day palette/);
  assert.match(fake.calls[0].text, /Protected slots \(NEVER overwrite or relocate\): C2, C6/);
  assert.equal(plan.day_looks.length, 7);
  assert.deepEqual(plan.day_looks.map((l) => l.slot).sort(), [1, 2, 3, 4, 5, 6, 7]);
  for (const index of [1, 5]) {
    const item = plan.day_looks.find((l) => l.slot === index + 1)!;
    assert.equal(item.status, "kept");
    assert.deepEqual(recipeOf(item), slots[index].recipe);
    assert.ok(item.when && item.reason);
    assert.ok(!plan.write.slots.includes(index + 1));
  }
  assert.deepEqual(plan.protected_slots, [2, 6]);
  assert.deepEqual([plan.palette_complete, plan.blocked_slots, plan.missing_slots, plan.requested_count], [true, [], [], 7]);
  assert.equal(plan.write.mode, "per_slot");
  assert.deepEqual(plan.plan.looks, []); // a positional CLI load cannot replay a protected record
  assert.deepEqual(plan.write.rewrites_unchanged, []);
  assert.ok(plan.day_looks.every((l) => l.exposure.aperture === "A" && l.exposure.shutter === "A" && l.exposure.iso === "A"));
});

test("an unknown protected recipe is blocked even when past_looks has the same name", async () => {
  const slots = camera();
  slots[2].recipe = null;
  const plan = await makePlan({ said: "a varied family day", cam: X100VI, count: 7, cameraSlots: slots,
    protectedSlots: [3], pastLooks: PAST, ask: new FakeAsk([model(fresh(6))]).ask });
  assert.equal(plan.day_looks.length, 6);
  assert.ok(!plan.day_looks.some((l) => l.slot === 3));
  assert.deepEqual([plan.palette_complete, plan.blocked_slots, plan.missing_slots], [false, [3], [3]]);
  assert.ok(!plan.write.slots.includes(3));
  assert.match(plan.warnings.join(" "), /actual recipe wasn't read/);
  assert.equal(plan.camera_before?.[2].recipe, null);
});

test("unread slots and empty protected slots stay honestly missing", async () => {
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: null,
    protectedSlots: [2, 6], ask: new FakeAsk([model(fresh(5))]).ask });
  assert.deepEqual(plan.write.slots, [1, 3, 4, 5, 7]);
  assert.deepEqual([plan.blocked_slots, plan.missing_slots, plan.palette_complete], [[2, 6], [2, 6], false]);
  assert.equal(plan.write.mode, "per_slot");
  const slots = camera();
  slots[6].name = "";
  const empty = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: slots,
    protectedSlots: [7], ask: new FakeAsk([model(fresh(6))]).ask });
  assert.deepEqual(empty.blocked_slots, [7]);
  assert.ok(!empty.write.slots.includes(7));
});

test("all unknown protected slots produce an incomplete read request without asking a model", async () => {
  const fake = new FakeAsk();
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7,
    protectedSlots: [1, 2, 3, 4, 5, 6, 7], ask: fake.ask });
  assert.equal(fake.calls.length, 0);
  assert.equal(plan.palette_complete, false);
  assert.deepEqual(plan.day_looks, []);
  assert.deepEqual(plan.missing_slots, [1, 2, 3, 4, 5, 6, 7]);
  assert.equal(plan.write.mode, "none");
});

test("omitted protected entries trigger a retry, then stay missing if the model still omits them", async () => {
  const slots = camera();
  const valid = model([...fresh(5), reuse(slots[1]), reuse(slots[5])]);
  const fake = new FakeAsk([model(fresh(7)), valid]);
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: slots,
    protectedSlots: [2, 6], ask: fake.ask });
  assert.equal(fake.calls.length, 2);
  assert.match(fake.calls[1].text, /include its protected look unchanged/);
  assert.equal(plan.palette_complete, true);
  const partial = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: slots,
    protectedSlots: [2, 6], ask: new FakeAsk([model(fresh(7)), model(fresh(7))]).ask });
  assert.equal(partial.palette_complete, false);
  assert.deepEqual(partial.missing_slots, [2, 6]);
  assert.equal(partial.day_looks.length, 5);
  assert.ok(partial.write.slots.every((s) => s !== 2 && s !== 6));
});

test("a renamed copy is kept in its actual camera slot, never presented as an AI-new recipe", async () => {
  const slots = camera();
  const renamed = { ...reuse(slots[3]), name: "New nostalgia", reuse: "", reuse_slot: 0 };
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: slots,
    ask: new FakeAsk([model([renamed, ...fresh(6)])]).ask });
  const kept = plan.day_looks.find((l) => l.slot === 4)!;
  assert.deepEqual([kept.name, kept.status], [slots[3].name, "kept"]);
  assert.ok(!plan.write.slots.includes(4));
  assert.ok(!plan.day_looks.some((l) => l.name === "New nostalgia"));
  assert.equal(plan.palette_complete, true);
});

test("a full palette cannot be manufactured from renamed identical new recipes", async () => {
  const copies = names.map((name) => look(name, "Today"));
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7,
    ask: new FakeAsk([model(copies), model(copies)]).ask });
  assert.equal(plan.day_looks.length, 1);
  assert.equal(plan.palette_complete, false);
  assert.equal(plan.missing_slots?.length, 6);
  assert.match(plan.warnings.join(" "), /distinct rendering purpose/);
  assert.equal(plan.slots.length, 1);
});

test("new recipes that collapse to one mapped rendering leave an honest missing slot", async () => {
  const distinct = fresh(7);
  distinct[0].film_sim = "Astia";
  distinct[1] = { ...distinct[0], name: names[1], film_sim: "Reala Ace" };
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7,
    ask: new FakeAsk([model(distinct)]).ask });
  assert.equal(plan.day_looks.length, 6);
  assert.equal(plan.palette_complete, false);
  assert.match(plan.warnings.join(" "), /no filler look was added/);
  assert.equal(plan.slots.length, 6);
});

test("duplicate camera names stay in their exact slots when reuse_slot is supplied", async () => {
  const slots = camera();
  slots[1].name = slots[0].name;
  slots[1].recipe!.name = slots[0].name;
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: slots,
    protectedSlots: [1, 2], ask: new FakeAsk([model([reuse(slots[0]), reuse(slots[1]), ...fresh(5)])]).ask });
  assert.equal(plan.palette_complete, true);
  for (const index of [0, 1]) assert.deepEqual(recipeOf(plan.day_looks.find((l) => l.slot === index + 1)!), slots[index].recipe);
  assert.ok(plan.write.slots.every((slot) => slot > 2));
});

test("automatic-mode normalization cannot disguise a copy of an unused camera look as AI-new", async () => {
  const slots = camera();
  slots[3] = { slot: 4, name: "Familiar shade", recipe: recipe("Familiar shade", { wb_shift_r: -3, wb_shift_b: 3 }) };
  const suggestions = fresh(7);
  suggestions[0].clarity = 2; // normalization makes this exactly the existing C4 recipe
  const plan = await makePlan({ said: "family day", cam: X100VI, count: 7, cameraSlots: slots, shootingMode: "automatic",
    ask: new FakeAsk([model(suggestions)]).ask });
  assert.equal(plan.palette_complete, false);
  assert.ok(!plan.day_looks.some((l) => l.name === names[0]));
  assert.match(plan.warnings.join(" "), /your existing C4/);
});

test("protected-slot input is explicit and validated; old clients retain guided defaults", () => {
  const base = { said: "family day", camera: { model: "X100VI" } };
  assert.equal(parsePlanRequest(base, false).protectedSlots, undefined);
  assert.equal(parsePlanRequest(base, false).shootingMode, "guided");
  assert.deepEqual(parsePlanRequest({ ...base, count: 7, protected_slots: [7, 1] }, false).protectedSlots, [1, 7]);
  for (const invalid of [[1, 1], [0], [8], [1.5], ["2"], "2", null]) {
    assert.throws(() => parsePlanRequest({ ...base, protected_slots: invalid }, false), { code: "bad_protected_slots" });
  }
  for (const slots of [[{ slot: 1, name: "Mine" }, { slot: 1, name: "Other" }], [{ slot: 0, name: "Mine" }],
    [{ slot: 1.5, name: "Mine" }], [{ slot: "2", name: "Mine" }]]) {
    assert.throws(() => parsePlanRequest({ ...base, camera: { model: "X100VI", slots }, count: 7 }, false),
      { code: "bad_camera_slots" });
  }
});

test("HTTP forwards full-palette safety fields; adjustments cannot regenerate protected looks", async () => {
  const slots = camera();
  const fake = new FakeAsk([model([...fresh(6), reuse(slots[6])])]);
  const response = await planHandler({ ask: fake.ask, env: {}, log: () => {} })(new Request("http://localhost/api/plan", {
    method: "POST", body: JSON.stringify({ said: "family day", count: 7, shooting_mode: "automatic", protected_slots: [7],
      camera: { model: "X100VI", firmware: "1.10", slots } }),
  }));
  assert.equal(response.status, 200);
  const plan = await response.json() as Plan;
  assert.equal(plan.palette_complete, true);
  assert.deepEqual(plan.protected_slots, [7]);
  const checked = planFromClient(plan, X100VI);
  const noModel = new FakeAsk();
  await assert.rejects(() => adjustPlan({ plan: checked, slot: 7, said: "change color", cam: X100VI, ask: noModel.ask }),
    { code: "protected_slot" });
  assert.equal(noModel.calls.length, 0);
  assert.throws(() => putLook(checked, { ...checked.day_looks[0], slot: 7 }, X100VI), { code: "protected_slot" });
});
