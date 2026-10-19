// The plan engine with a fake model and a fake network: no model call, no request, no camera.
//   node --import tsx --test tests/plan/*.test.ts
import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { TEXT_MAX } from "../../lib/plan/cheatsheet.js";
import { dayConditions, NOMINATIM, sunTimes } from "../../lib/plan/conditions.js";
import { adjustLook, adjustPlan, makePlan, normalizeCameraSlots, libraryFrom, type PlanInput, planFromClient } from "../../lib/plan/engine.js";
import { nameProblems } from "../../lib/plan/looks.js";
import { putLook } from "../../lib/plan/slots.js";
import { normalizeTaste, tasteSummary } from "../../lib/plan/taste.js";
import { minutesOf } from "../../lib/plan/time.js";
import { PlanError, type Plan } from "../../lib/plan/types.js";
import { answer, FakeAsk, FakeNet, look, mirrorLoadParse, DAY, DAY_LOOKS, DAY_NAMES, PAST, TASTE } from "./fixtures.js";

let net: FakeNet;
beforeEach(() => { net = new FakeNet().install(); });

async function plan(answers: unknown[] = [answer()], kw: Partial<PlanInput> = {}): Promise<[Plan, FakeAsk]> {
  const fake = new FakeAsk(answers);
  const p = await makePlan({
    said: "beach, fish market and dinner", place: "Example Point", date: "2026-10-11", cameraSlots: DAY_NAMES, taste: TASTE,
    pastLooks: PAST, cam: X100VI, ask: fake.ask, ...kw,
  });
  return [p, fake];
}

const byName = (p: Plan) => Object.fromEntries(p.day_looks.map((l) => [l.name, l]));

describe("inputs", () => {
  test("sun times match an independent NOAA computation within two minutes", () => {
    // The synthetic day (release/fixtures/synthetic-day.json): an open-water point, an invented date, and sun times
    // computed separately with the NOAA solar equations (05:50 / 19:54 EDT).
    const { lat, lon } = DAY.conditions.place;
    const [rise, set] = sunTimes(lat, lon, DAY.conditions.date, -4 * 3600) as [string, string];
    assert.ok(Math.abs((minutesOf(rise) as number) - (minutesOf(DAY.conditions.sunrise) as number)) <= 2, rise);
    assert.ok(Math.abs((minutesOf(set) as number) - (minutesOf(DAY.conditions.sunset) as number)) <= 2, set);
  });

  test("taste: favorites and quotes", () => {
    const s = tasteSummary(normalizeTaste(TASTE).rows);
    const favs = new Set([...s.values()].filter((t) => t.favorite).map((t) => t.look));
    assert.deepEqual(favs, new Set(["Old fisherman", "Hard noon B&W"]));
    assert.equal(s.get("old fisherman")?.quote, "You hearted 9 of 20 in Old fisherman");
  });

  test("taste: every accepted form", () => {
    const a = normalizeTaste({ "Old fisherman": [9, 20], "Gritty B&W": "4/30", "Faded dock": { kept: 2, frames: 15 } });
    assert.deepEqual(new Set(a.rows.map((r) => `${r.look} ${r.hearted}/${r.shot}`)),
      new Set(["Old fisherman 9/20", "Gritty B&W 4/30", "Faded dock 2/15"]));
    assert.equal(normalizeTaste([{ name: "C4 Old fisherman", hearts: 9, total: 20 }]).rows[0].look, "Old fisherman");
    const app = normalizeTaste({ keep_rates: [{ look: "Old fisherman", hearted: 9, shot: 20 }], learned: ["likes grain (4 of 5)"], notes: "warm, grainy" });
    assert.deepEqual([app.rows.length, app.learned, app.notes], [1, ["likes grain (4 of 5)"], "warm, grainy"]);
    assert.deepEqual(normalizeTaste(null).rows, []);
  });

  test("camera slot forms", () => {
    const lib = libraryFrom(PAST, X100VI);
    const names = normalizeCameraSlots(DAY_NAMES, lib, X100VI);
    assert.deepEqual(names?.map((s) => s.name), DAY_NAMES);
    assert.ok(names?.every((s) => s.recipe));
    const d = normalizeCameraSlots({ C2: "Sunny faces", C7: "HARD COURT MONO" }, lib, X100VI) ?? [];
    assert.deepEqual([d[1].name, Boolean(d[1].recipe), d[6].recipe, d[0].name], ["Sunny faces", true, null, ""]);
    const objs = normalizeCameraSlots([{ slot: 3, name: "Mine", recipe: { ...PAST[0], name: "Mine" } }], lib, X100VI) ?? [];
    assert.equal(objs[2].recipe?.film_sim, "Reala Ace");
    assert.equal(normalizeCameraSlots(null, lib, X100VI), null);
  });

  test("geocode is cached and polite", async () => {
    await plan();
    await plan();
    assert.equal(net.urls.filter((u) => u.startsWith(NOMINATIM)).length, 1);
  });

  test("no forecast falls back to computed sun", async () => {
    net.failForecast = true;
    const c = await dayConditions({ name: "Example Point", lat: 40.25, lon: -70.5 }, "2026-12-30");
    assert.equal(c.source, "computed");
    assert.ok(c.sunset?.startsWith("16:"), c.sunset ?? ""); // late December, Eastern time
    assert.match(c.text, /No forecast/);
  });
});

describe("makePlan", () => {
  test("one call, the content carries the camera, taste and sun", async () => {
    const [p, fake] = await plan();
    assert.equal(fake.calls.length, 1);
    const c = fake.calls[0];
    assert.deepEqual([c.task, c.model, c.fallback, c.effort], ["plan", "claude-sonnet-5-5", "claude-haiku-5-5", "medium"]);
    assert.match(c.text, /Old fisherman/);
    assert.match(c.text, /you hearted 9 of 20 \(45%\), Example Shoals May 16/);
    assert.match(c.text, /Looks they reuse/);
    assert.match(c.text, /Sunrise 6:55, sunset 6:13/);
    assert.match(c.system, /Fujifilm X100VI/);
    assert.doesNotMatch(c.system, /friend the photographer|the photographer shoots|\bhis camera\b/);
    assert.deepEqual(p.conditions.place, { name: "Example Point", lat: 40.25, lon: -70.5 });
    assert.equal(p.conditions.sunset, "18:13");
    assert.equal(p.model, "claude-sonnet-5-5");
    assert.equal(p.calls?.length, 1);
    assert.equal(p.calls?.[0].usd, 0.04);
  });

  test("opus when asked", async () => {
    const [, fake] = await plan([answer()], { quality: "opus" });
    assert.deepEqual([fake.calls[0].model, fake.calls[0].fallback], ["claude-opus-5-5", "claude-sonnet-5-5"]);
  });

  test("slots keep favorites and fill C1 up", async () => {
    const [p] = await plan();
    const by = byName(p);
    assert.deepEqual([by["Old fisherman"].slot, by["Old fisherman"].status], [4, "kept"]);
    assert.deepEqual(["Grey beach", "Cloudy B&W", "Warm dinner"].map((n) => [by[n].slot, by[n].replaces]),
      [[1, "Harbor color"], [2, "Sunny faces"], [3, "Deep blue sea"]]);
    const lines = p.slots.map((r) => r.line);
    assert.ok(lines.includes("C3 Warm dinner: new, replaces C3 'Deep blue sea'"));
    assert.ok(lines.includes("C4 Old fisherman: yours, kept"));
    assert.equal(by["Old fisherman"].taste_note, "You hearted 9 of 20 in Old fisherman");
    assert.equal(by["Cloudy B&W"].taste_note, "You hearted 12 of 40 in Hard noon B&W");
    assert.equal(by["Old fisherman"].film_sim, "Classic Chrome"); // the camera's own recipe, not the model's copy
    assert.deepEqual([p.write.mode, p.write.slots, p.write.rewrites_unchanged], ["load", [1, 2, 3], []]);
    assert.deepEqual(p.plan.looks.map((l) => l.name), ["Grey beach", "Cloudy B&W", "Warm dinner"]);
    assert.deepEqual(p.camera?.map((c) => c.status), ["new", "new", "new", "kept", "untouched", "untouched", "untouched"]);
  });

  test("a favorite is protected even if the model offers it", async () => {
    const a = answer({ replace: [{ name: "Hard noon B&W", why: "no sun" }, { name: "Gritty B&W", why: "x" },
      { name: "Faded dock", why: "x" }, { name: "Sunny faces", why: "x" }] });
    const [p] = await plan([a]);
    const replaced = new Set(p.day_looks.filter((l) => l.status === "new").map((l) => l.replaces));
    assert.ok(!replaced.has("Hard noon B&W"));
    assert.deepEqual(replaced, new Set(["Gritty B&W", "Faded dock", "Sunny faces"]));
    assert.deepEqual([p.write.mode, p.write.slots], ["load", [2, 5, 7]]); // not a prefix: one load rewrites the rest
    assert.deepEqual(p.write.rewrites_unchanged, ["C1 Harbor color", "C3 Deep blue sea", "C4 Old fisherman", "C6 Hard noon B&W"]);
    assert.deepEqual(p.plan.looks.map((l) => l.slot), [1, 2, 3, 4, 5, 6, 7]);
    assert.equal(p.plan.looks[3].film_sim, DAY_LOOKS["Old fisherman"].film_sim);
  });

  test("unknown settings in the way means per slot", async () => {
    const camera = ["SUNLIT CLAY", "Sunny faces", "MARINE LAYER", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W"];
    const a = answer({ replace: [{ name: "Sunny faces", why: "x" }, { name: "Faded dock", why: "x" }, { name: "Gritty B&W", why: "x" }] });
    const [p] = await plan([a], { cameraSlots: camera });
    assert.deepEqual([p.write.mode, p.write.slots], ["per_slot", [2, 5, 7]]);
    assert.deepEqual(p.plan.looks, []); // a stray `dialin-cam load` refuses instead of writing C1…
    assert.match(p.write.why, /SUNLIT CLAY/);
  });

  test("no camera read fills C1 onwards", async () => {
    const [p, fake] = await plan([answer()], { cameraSlots: null });
    assert.match(fake.calls[0].text, /weren't read/);
    assert.deepEqual(p.plan.looks.map((l) => [l.slot, l.name]), [[1, "Grey beach"], [2, "Cloudy B&W"], [3, "Old fisherman"], [4, "Warm dinner"]]);
    assert.ok(p.slots.every((r) => r.replaces === null));
    assert.equal(p.plan.looks[2].film_sim, "Classic Chrome"); // a past look, written again from past_looks
    assert.equal(p.camera_before, null);
  });

  test("a rebuild with the same name takes that slot", async () => {
    const a = answer();
    a.looks[0] = look("Faded dock", "The beach", { film_sim: "Classic Neg" });
    const [p] = await plan([a]);
    const fd = byName(p)["Faded dock"];
    assert.deepEqual([fd.slot, fd.replaces, fd.status], [5, "Faded dock", "new"]);
  });

  test("a copy of a camera look is kept, not rewritten", async () => {
    const a = answer();
    a.looks[2].reuse = "";
    const [p] = await plan([a]);
    const of = byName(p)["Old fisherman"];
    assert.deepEqual([of.status, of.slot], ["kept", 4]);
  });

  test("retries once on a bad name", async () => {
    const bad = answer();
    bad.looks[0].name = "BEACH NOON +2/3";
    const [p, fake] = await plan([bad, answer()]);
    assert.equal(fake.calls.length, 2);
    assert.match(fake.calls[1].text, /BROKE THESE RULES/);
    assert.match(fake.calls[1].text, /no ALL CAPS/);
    assert.deepEqual(p.calls?.map((c) => c.task), ["plan", "plan-retry"]);
    assert.ok(p.day_looks.some((l) => l.name === "Grey beach"));
    assert.deepEqual(p.warnings, []);
  });

  test("still bad after the retry is salvaged", async () => {
    const bad = answer();
    bad.looks[0].name = "BEACH NOON +2/3";
    const [p, fake] = await plan([bad, structuredClone(bad)]);
    assert.equal(fake.calls.length, 2);
    assert.ok(p.day_looks.every((l) => !nameProblems(l.name, 14).length), p.day_looks.map((l) => l.name).join());
    assert.ok(p.warnings.some((w) => w.includes("renamed")));
  });

  test("no retry when the budget is spent: the first answer is salvaged", async () => {
    const bad = answer();
    bad.looks[0].name = "BEACH NOON +2/3";
    const [p, fake] = await plan([bad, answer()], { budgetMs: 20_000 });
    assert.equal(fake.calls.length, 1);
    assert.ok(p.warnings.some((w) => w.includes("renamed")));
  });

  test("too few looks retries; an exact count is asked for", async () => {
    const few = answer({ looks: [look("Grey beach", "The beach")], stops: [{ name: "The beach", start: "11:00", end: "14:00", light: "grey" }] });
    const [, fake] = await plan([few, answer()]);
    assert.match(fake.calls[1].text, /1 looks; make 3 to 7/);
    const [, fake2] = await plan([answer()], { count: 4 });
    assert.match(fake2.calls[0].text, /Make exactly 4 looks/);
  });

  test("more than seven is cut", async () => {
    const many = answer({ looks: ["Sand one", "Sand two", "Sand three", "Sea", "Surf", "Dunes", "Shells", "Gulls"].map((n) => look(n, "The beach")),
      stops: [{ name: "The beach", start: "11:00", end: "14:00", light: "grey" }], replace: [] });
    const [p] = await plan([many]);
    assert.equal(p.day_looks.length, 7);
  });

  test("a model failure is a PlanError; no words and no photo is a 400", async () => {
    await assert.rejects(makePlan({ said: "beach", place: "Example Point", date: "2026-10-11", cam: X100VI, ask: new FakeAsk([], true).ask }),
      (e: unknown) => e instanceof PlanError && e.status === 502);
    await assert.rejects(makePlan({ said: "  ", cam: X100VI, ask: new FakeAsk([answer()]).ask }),
      (e: unknown) => e instanceof PlanError && e.status === 400);
  });

  test("no place means no lookup", async () => {
    const [p, fake] = await plan([answer()], { place: null });
    assert.deepEqual(net.urls, []);
    assert.match(fake.calls[0].text, /No place given/);
    assert.equal(p.conditions.place, null);
  });

  test("place as coordinates skips the geocoder; a null date asks for today there", async () => {
    await plan([answer()], { place: { name: "Example Point", lat: 40.25, lon: -70.5 }, date: null });
    assert.equal(net.urls.filter((u) => u.startsWith(NOMINATIM)).length, 0);
    assert.ok(net.urls.some((u) => u.includes("forecast_days=1")));
  });

  test("a scene photo goes to the model with the rules for reading it", async () => {
    const [, fake] = await plan([answer()], { said: "", imageBase64: "/9j/AAAA", now: "14:05" });
    const c = fake.calls[0];
    assert.equal(c.imageBase64, "/9j/AAAA");
    assert.match(c.text, /supplied only an image/);
    assert.match(c.text, /Time now: 14:05/);
    assert.match(c.system, /SUPPLIED IMAGE/);
    assert.match(c.system, /From the supplied image:/);
    assert.match(c.system, /Never assume they took it/);
    assert.match(c.system, /Do not invent a current itinerary/);
  });
});

describe("cheat sheet", () => {
  test("per stop, in day order, naming the controls", async () => {
    const [p] = await plan();
    const cs = p.cheat_sheet;
    assert.deepEqual(cs.stops.map((s) => s.name), ["The beach", "Fish market", "Dinner"]);
    const first = cs.stops[0].looks[0];
    assert.deepEqual([first.c, first.saved], ["C1", "Saved to C1"]);
    const joined = first.change.join(" | ");
    for (const control of ["Exposure dial: +⅓ (one click above 0)", "Aperture ring: f/8", "Shutter dial: 1/500",
      "ISO (lift the shutter dial ring): A", "Focus switch: S", "Drive: S"]) assert.ok(joined.includes(control), control);
    const market = cs.stops[1].looks[0];
    assert.equal(market.saved, "Already in C4");
    assert.ok(market.change.includes("Exposure dial: −⅓ (one click below 0)"));
    assert.equal(first.dial_line, "Exposure dial +⅓ · f/8 · 1/500 · ISO A");
    assert.ok(cs.stops[2].light_changes.includes("Sunset 6:13")); // between the market (ends 4pm) and dinner (7pm)
  });

  test("the text fits one phone text", async () => {
    const [p] = await plan();
    const t = p.cheat_sheet.text;
    assert.ok(t.length <= TEXT_MAX);
    assert.ok(t.startsWith("Sun Oct 11 · Example Point"), t);
    assert.ok(t.includes("The beach 11am–2pm: C1 Grey beach. Exp +⅓, f/8, 1/500."), t);
    assert.ok(t.includes("Or C2 Cloudy B&W."), t);
    assert.ok(t.includes("Fish market 3–4pm: C4 Old fisherman. Exp −⅓, f/4, 1/250."), t);
    assert.ok(t.includes("ISO A all day."), t);
  });

  test("a long day is shortened to fit", async () => {
    const stops = ["one", "two", "three", "four", "five", "six", "seven"].map((w, i) => ({ name: `Stop ${w}`, start: `${8 + 2 * i}:00`, end: `${9 + 2 * i}:00`, light: "sun" }));
    const names = ["Early sand", "Late sand", "Market ice", "Harbor rope", "Golden faces", "After sunset", "Candle table"];
    const looks = names.map((n, i) => look(n, stops[i].name, { focus: "C", drive: "CH", exposure: { aperture: "f/2", shutter: "1/1000", iso: "A", exp_comp: "+1⅔", nd: true } }));
    const [p] = await plan([answer({ looks, stops, replace: [] })]);
    assert.ok(p.cheat_sheet.chars <= TEXT_MAX);
    assert.ok(p.cheat_sheet.fits);
  });

  test("ND and burst show up, and the ND goes off again", async () => {
    const a = answer();
    Object.assign(a.looks[0], { focus: "C", drive: "CH", exposure: { aperture: "f/2", shutter: "1/1000", iso: "A", exp_comp: "+⅔", nd: true } });
    const [p] = await plan([a]);
    const beach = p.cheat_sheet.stops[0].looks[0];
    assert.ok(beach.change.includes("ND filter: ON (bright light at a wide aperture)"));
    assert.ok(beach.change.includes("Focus switch: C, for moving things"));
    assert.ok(beach.change.includes("Drive: CH, fast burst"));
    assert.ok(p.cheat_sheet.stops[1].looks[0].change.includes("ND filter: OFF again"));
    assert.ok(p.cheat_sheet.text.includes("ND on, focus C, CH"));
  });

  test("the leaf shutter is fixed by code: ND on, four stops slower", async () => {
    const a = answer();
    a.looks[0].exposure = { aperture: "f/2", shutter: "1/4000", iso: "A", exp_comp: "+⅔", nd: false };
    const [p, fake] = await plan([a]);
    assert.equal(fake.calls.length, 1);
    const g = byName(p)["Grey beach"];
    assert.deepEqual([g.exposure.nd, g.exposure.shutter], [true, "1/250"]);
    assert.ok(p.notes?.some((n) => n.includes("ND on")));
  });
});

describe("the plan file", () => {
  test("keeps the synthetic day's shape and parses like dialin-cam load", async () => {
    const [p] = await plan();
    const d = JSON.parse(JSON.stringify(p));
    for (const k of ["conditions", "plan", "model", "ms"]) assert.ok(k in d, k);
    for (const k of Object.keys(DAY.conditions)) assert.ok(k in d.conditions, k);
    for (const l of d.plan.looks) {
      for (const [k, v] of Object.entries(DAY.plan.looks[0])) {
        assert.ok(k in l, k);
        assert.equal(typeof l[k], typeof v, k);
      }
    }
    assert.deepEqual(mirrorLoadParse(d), [{ slot: 1, name: "Grey beach" }, { slot: 2, name: "Cloudy B&W" }, { slot: 3, name: "Warm dinner" }]);
    assert.deepEqual(mirrorLoadParse(DAY).map((x) => x.name), DAY_NAMES);
    assert.deepEqual([d.write.argv, d.write.per_slot, d.write.live], [null, [], []]);
    assert.equal(d.kind, "dialin.plan/1");
  });
});

describe("adjust", () => {
  const fresh = (name: string, stop: string, kw = {}) => {
    const { reuse: _r, ...l } = look(name, stop, kw);
    return l;
  };

  test("one look for one slot, on Haiku, then put in", async () => {
    const [p] = await plan();
    const fake = new FakeAsk([{ look: fresh("Grey beach", "The beach", { wb_shift_r: -1, wb_shift_b: 2 }), change: "Cooler: less yellow in the sand." }]);
    const l = await adjustLook({ plan: p, slot: 1, said: "less yellow", cam: X100VI, ask: fake.ask });
    const c = fake.calls[0];
    assert.deepEqual([c.task, c.model, c.fallback], ["adjust", "claude-haiku-5-5", "claude-sonnet-5-5"]);
    assert.match(c.text, /They say: "less yellow"/);
    assert.match(c.text, /C4 Old fisherman/);
    assert.deepEqual([l.slot, l.replaces, l.wb_shift_b, l.status], [1, "Grey beach", 2, "new"]);
    assert.equal(l.change, "Cooler: less yellow in the sand.");
    assert.deepEqual(p.write.slots, [1, 2, 3]); // the original plan is untouched
  });

  test("a name clash retries", async () => {
    const [p] = await plan();
    const fake = new FakeAsk([{ look: fresh("Old fisherman", "The beach"), change: "x" }, { look: fresh("Shade sand", "The beach"), change: "Softer for shade." }]);
    const l = await adjustLook({ plan: p, slot: 1, said: "we're in shade now", cam: X100VI, ask: fake.ask });
    assert.equal(fake.calls.length, 2);
    assert.equal(l.name, "Shade sand");
  });

  test("a bad slot is a 400", async () => {
    const [p] = await plan();
    await assert.rejects(adjustLook({ plan: p, slot: 9, said: "x", cam: X100VI, ask: new FakeAsk().ask }),
      (e: unknown) => e instanceof PlanError && e.status === 400);
  });

  test("put the look in: statuses stay relative to the camera before the plan", async () => {
    const [p] = await plan();
    const l = await adjustLook({ plan: p, slot: 3, said: "less yellow", cam: X100VI,
      ask: new FakeAsk([{ look: fresh("Rainy dinner", "Dinner", { wb_shift_b: 2 }), change: "Cooler." }]).ask });
    assert.equal(l.replaces, "Warm dinner");
    const q = putLook(p, l, X100VI);
    const c3 = q.day_looks.find((x) => x.slot === 3);
    assert.deepEqual([c3?.name, c3?.status, c3?.replaces], ["Rainy dinner", "new", "Deep blue sea"]);
    assert.deepEqual([q.write.mode, q.write.slots], ["load", [1, 2, 3]]);
    assert.deepEqual(q.adjustments?.at(-1), { slot: 3, said: "less yellow", change: "Cooler.", was: "Warm dinner", name: "Rainy dinner" });
    assert.ok(q.cheat_sheet.text.includes("C3 Rainy dinner"));
  });

  test("a plan round-trips through JSON and the client check", async () => {
    const [p] = await plan();
    const back = planFromClient(JSON.parse(JSON.stringify(p)), X100VI);
    const out = await adjustPlan({ plan: back, slot: 1, said: "warmer", cam: X100VI,
      ask: new FakeAsk([{ look: fresh("Warm sand", "The beach", { wb_shift_r: 3 }), change: "Warmer." }]).ask });
    assert.equal(out.plan.day_looks.find((l) => l.slot === 1)?.name, "Warm sand");
    assert.throws(() => planFromClient({ ...JSON.parse(JSON.stringify(p)), day_looks: [{ ...p.day_looks[0], film_sim: "Kodachrome" }] }, X100VI),
      (e: unknown) => e instanceof PlanError && e.status === 400);
    assert.throws(() => planFromClient("nope", X100VI), PlanError);
  });
});

