import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { makePlan, adjustPlan } from "../../lib/plan/engine.js";
import { parsePlanRequest, planHandler } from "../../lib/plan/http.js";
import { onCamera } from "../../lib/plan/cheatsheet.js";
import type { ModelLook, Plan } from "../../lib/plan/types.js";
import { answer, FakeAsk, FakeNet, look, DAY_NAMES, PAST } from "./fixtures.js";

beforeEach(() => { new FakeNet().install(); });

test("phone automatic mode prepares exposure guidance and preserves existing color recipes", async () => {
  const data = answer();
  data.looks[0].clarity = 2;
  const fake = new FakeAsk([data]);
  const plan = await makePlan({ said: "beach then dinner", cam: X100VI, cameraSlots: DAY_NAMES,
    pastLooks: PAST, shootingMode: "automatic", ask: fake.ask });
  assert.match(fake.calls[0].system, /aperture A, shutter A, ISO A for EVERY look/);
  assert.equal(plan.shooting_mode, "automatic");
  assert.match(String(plan.setup_scope), /Exposure guidance only/);
  for (const item of plan.day_looks) {
    assert.deepEqual([item.exposure.aperture, item.exposure.shutter, item.exposure.iso, item.exposure.nd], ["A", "A", "A", false]);
    if (item.status === "new") assert.equal(item.clarity, 0);
  }
  const kept = plan.day_looks.find((l) => l.status === "kept")!;
  const old = PAST.find((l) => l.name === kept.name)!;
  assert.equal(kept.clarity, old.clarity);
  assert.ok(!plan.write.slots.includes(kept.slot!));
  assert.ok(plan.cheat_sheet.stops.flatMap((s) => s.looks).every((l) => !l.dial_line.includes("f/")));
});

test("a later color adjustment keeps the phone's automatic exposure workflow", async () => {
  const plan = await makePlan({ said: "beach", cam: X100VI, shootingMode: "automatic", ask: new FakeAsk([answer()]).ask });
  const current = plan.day_looks[0];
  const next = look(current.name, current.stop, { clarity: 3, focus: "M" });
  const changed = await adjustPlan({ plan, slot: current.slot!, said: "less yellow", cam: X100VI,
    ask: new FakeAsk([{ look: next, change: "Cooler white balance." }]).ask });
  assert.deepEqual([changed.look.exposure.aperture, changed.look.exposure.shutter, changed.look.exposure.iso], ["A", "A", "A"]);
  assert.equal(changed.look.clarity, 0);
  assert.equal(changed.look.focus, "S");
});

test("legacy clients retain guided exposure, invalid modes are refused", async () => {
  const parsed = parsePlanRequest({ said: "beach", camera: { model: "X100VI" } }, false);
  assert.equal(parsed.shootingMode, "guided");
  assert.throws(() => parsePlanRequest({ said: "beach", shooting_mode: "pretend-auto" }, false));
  const plan = await makePlan({ said: "beach", cam: X100VI, ask: new FakeAsk([answer()]).ask });
  assert.ok(plan.day_looks.some((l) => l.exposure.aperture !== "A"));
});

const motionLook = (name = "Running kids", highlight = 0): ModelLook => ({
  ...look(name, "Dim room", { highlight, focus: "C", drive: "CH",
    exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false } }),
  how: "Set focus C and drive CH; check Auto ISO minimum shutter is 1/500 or faster.",
});
const motionAnswer = () => ({ ...answer({ looks: [motionLook(), motionLook("Window faces", -0.5), motionLook("Quiet color", -1)],
  stops: [{ name: "Dim room", start: "", end: "", light: "Window and LED light" }], replace: [] }), primary_look: "Running kids" });

test("automatic makePlan and actual handler retain an unchanged motion setup check in shooting guidance", async () => {
  const input = { said: "Children running indoors; check Auto ISO minimum shutter 1/500", cam: X100VI,
    shootingMode: "automatic" as const, count: 3 };
  const direct = await makePlan({ ...input, ask: new FakeAsk([motionAnswer()]).ask });
  const handler = planHandler({ ask: new FakeAsk([motionAnswer()]).ask, env: {}, log: () => {} });
  const response = await handler(new Request("http://synthetic.local/api/plan", { method: "POST",
    headers: { "content-type": "application/json" }, body: JSON.stringify({ said: input.said, camera: { model: "X100VI" },
      shooting_mode: "automatic", count: 3 }) }));
  assert.equal(response.status, 200);
  const throughHTTP = await response.json() as Plan;
  for (const plan of [direct, throughHTTP]) {
    assert.match(plan.day_looks[0].tip, /check Auto ISO minimum shutter is 1\/500/);
    assert.match(plan.day_looks[0].tip, /Adjust brightness with the exposure dial/);
    assert.match(plan.cheat_sheet.stops[0].looks[0].how, /1\/500/);
    const isoLine = plan.cheat_sheet.stops[0].looks[0].change.find((line) => line.includes("Auto ISO limits"));
    assert.ok(isoLine);
    assert.ok(!plan.cheat_sheet.stops[0].looks[0].change.some((line) => /6400/.test(line)));
  }
});

test("automatic adjustment preserves valid minimum-shutter checks but discards changed manual/ND/focus instructions", async () => {
  const plan = await makePlan({ said: "Children running indoors", cam: X100VI, shootingMode: "automatic", count: 3,
    ask: new FakeAsk([motionAnswer()]).ask });
  const current = plan.day_looks[0];
  const revised = await adjustPlan({ plan, slot: current.slot!, said: "Keep action setup; soften contrast", cam: X100VI,
    ask: new FakeAsk([{ look: motionLook(current.name, -0.5), change: "Softer highlights." }]).ask });
  assert.match(revised.look.tip, /1\/500/);
  assert.match(revised.plan.cheat_sheet.stops[0].looks.find((look) => look.slot === current.slot)!.how, /1\/500/);
  for (const changed of [
    { ...motionLook(current.name), exposure: { aperture: "f/4", shutter: "1/125", iso: "A", exp_comp: "0", nd: false } },
    { ...motionLook(current.name), exposure: { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: true } },
    { ...motionLook(current.name), focus: "M" },
  ]) {
    changed.how = "Use manual setup and trust this stale 1/125 instruction.";
    const adjustment = await adjustPlan({ plan, slot: current.slot!, said: "Softer color", cam: X100VI,
      ask: new FakeAsk([{ look: changed, change: "Softer color." }]).ask });
    assert.doesNotMatch(adjustment.look.tip, /manual setup|1\/125/);
    assert.match(adjustment.look.tip, /Let the camera choose exposure/);
  }
});

test("automatic planning discards old shooting instructions when manual exposure changes", async () => {
  const data = motionAnswer();
  for (const item of data.looks) {
    item.exposure = { aperture: "f/4", shutter: "1/125", iso: "A", exp_comp: "0", nd: false };
    item.how = "Use f/4 and 1/125 manually.";
  }
  const plan = await makePlan({ said: "Indoor portraits", cam: X100VI, shootingMode: "automatic", count: 3,
    ask: new FakeAsk([data]).ask });
  assert.ok(plan.day_looks.every((item) => !/1\/125|f\/4/.test(item.tip)));
});

test("ISO A instructions require checking real limits and never invent a ceiling from a static label", () => {
  const item = motionLook();
  const lines = onCamera(item, X100VI);
  assert.ok(lines.includes(`${X100VI.labels.iso}: A (check your Auto ISO limits)`));
  assert.ok(!lines.some((line) => line.includes("6400")));
  item.exposure.iso = "800";
  assert.ok(onCamera(item, X100VI).includes(`${X100VI.labels.iso}: 800`));
});
