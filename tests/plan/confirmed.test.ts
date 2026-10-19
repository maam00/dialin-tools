// Only confirmed settings-file codes get proposed: the table (lib/cameras.ts) and its mirrors, the stand-ins, the
// prompt, the plan and adjust paths, and merging a `dialin-cam map-codes` result. No model call, no camera.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { beforeEach, describe, test } from "node:test";
import { type CameraCaps, type ConfirmedCodes, X100VI, X100VI_CONFIRMED, writable } from "../../lib/cameras.js";
import { confirmLook, isWritable, nearestSim } from "../../lib/plan/confirmed.js";
import { adjustLook, makePlan } from "../../lib/plan/engine.js";
import { adjustSchema, planSchema, planSystem } from "../../lib/plan/prompts.js";
import type { Plan, RecipeFields } from "../../lib/plan/types.js";
import {
  applyToMap, check, type CodeMapReport, mapProblems, merge, PATHS, renderSwift, renderTs, ROOT, type SlotMap,
} from "../../scripts/codes.js";
import { answer, FakeAsk, FakeNet, look, DAY_NAMES, PAST, recipe, TASTE } from "./fixtures.js";

beforeEach(() => { new FakeNet().install(); });

const SEVEN = ["Velvia", "Classic Chrome", "Reala Ace", "Pro Neg Std", "Nostalgic Neg", "Acros+Ye", "Acros+R"];

/** Only what the 10/9 USB session proved. The tests below run on it, so they still hold after
 *  `npm run codes -- merge` adds codes to the real table. */
const only10_9 = <T extends { seen: string }>(r: Readonly<Record<string, T>>) =>
  Object.fromEntries(Object.entries(r).filter(([, v]) => v.seen.startsWith("usb-2026-10-09")));
const OCT9_CODES: ConfirmedCodes = {
  ...X100VI_CONFIRMED,
  sources: { "usb-2026-10-09": X100VI_CONFIRMED.sources["usb-2026-10-09"] },
  filmSims: only10_9(X100VI_CONFIRMED.filmSims), whiteBalances: only10_9(X100VI_CONFIRMED.whiteBalances),
  color: only10_9(X100VI_CONFIRMED.color), noiseReduction: only10_9(X100VI_CONFIRMED.noiseReduction),
};
const OCT9: CameraCaps = { ...X100VI, confirmed: OCT9_CODES };

/** OCT9 with Provia confirmed too (what a map-codes run would add). */
const withProvia: CameraCaps = {
  ...OCT9,
  confirmed: { ...OCT9_CODES, filmSims: { ...OCT9_CODES.filmSims, Provia: { code: 1, seen: "test" } } },
};

describe("the confirmed list", () => {
  test("lib/cameras.ts, ConfirmedCodes.swift and ble/maps/x100vi-fw110.json agree (npm run codes -- check)", () => {
    assert.deepEqual(check(), []);
  });

  test("the 10/9 sims and values are confirmed (more may be merged later), each with evidence", () => {
    const ok = writable(OCT9);
    assert.deepEqual(ok.filmSims, SEVEN);
    assert.deepEqual(ok.whiteBalances, ["Auto", "Daylight", "Kelvin"]);
    assert.deepEqual(ok.color, [-1, 0, 1, 2, 3]);
    assert.deepEqual(ok.noiseReduction, [-4]);
    const real = writable(X100VI);
    for (const s of SEVEN) assert.ok(real.filmSims.includes(s), s);
    for (const w of ok.whiteBalances) assert.ok(real.whiteBalances.includes(w), w);
    const all = [...Object.values(X100VI_CONFIRMED.filmSims), ...Object.values(X100VI_CONFIRMED.whiteBalances),
      ...Object.values(X100VI_CONFIRMED.color), ...Object.values(X100VI_CONFIRMED.noiseReduction)];
    for (const c of all) assert.ok(Object.keys(X100VI_CONFIRMED.sources).some((k) => c.seen.startsWith(k)), c.seen);
    for (const f of ["grain", "color_chrome", "color_chrome_fx_blue", "dynamic_range", "highlight", "shadow", "sharpness", "clarity", "kelvin", "wb_shift"]) {
      assert.ok(X100VI_CONFIRMED.wholeRange[f], f);
    }
  });

  test("the 10/9 codes match the slot map's PTP-truth table byte for byte", () => {
    const m = JSON.parse(readFileSync(join(ROOT, PATHS.map), "utf8")) as SlotMap;
    const want = { 20: 18, 5: 13, 2: 4, 11: 15, 19: 17, 14: 23, 13: 24 };
    for (const [ptp, code] of Object.entries(want)) assert.equal(m.fields.film_sim.encoding.map?.[ptp], code, `PTP ${ptp}`);
    assert.deepEqual(Object.fromEntries(Object.entries(OCT9_CODES.filmSims).map(([k, v]) => [k, v.code])),
      { Velvia: 4, "Classic Chrome": 15, "Reala Ace": 18, "Pro Neg Std": 13, "Nostalgic Neg": 17, "Acros+Ye": 24, "Acros+R": 23 });
  });
});

describe("stand-ins", () => {
  test("closest confirmed sim, never crossing colour and B&W", () => {
    assert.equal(nearestSim("Astia", OCT9), "Reala Ace");
    assert.equal(nearestSim("Astia", withProvia), "Provia", "Provia once it's mapped");
    assert.equal(nearestSim("Provia", OCT9), "Reala Ace");
    assert.equal(nearestSim("Classic Neg", OCT9), "Classic Chrome");
    assert.equal(nearestSim("Pro Neg Hi", OCT9), "Pro Neg Std");
    assert.equal(nearestSim("Eterna", OCT9), "Pro Neg Std");
    assert.equal(nearestSim("Eterna Bleach Bypass", OCT9), "Classic Chrome");
    assert.equal(nearestSim("Acros", OCT9), "Acros+Ye");
    assert.equal(nearestSim("Monochrome+R", OCT9), "Acros+R");
    assert.equal(nearestSim("Sepia", OCT9), "Acros+Ye");
    for (const s of OCT9.filmSims) {
      const n = nearestSim(s, OCT9) as string;
      assert.ok(SEVEN.includes(n), s);
      assert.equal(OCT9.monoSims.has(n), OCT9.monoSims.has(s), s);
    }
  });

  test("white balance, color and NR go to the closest confirmed value", () => {
    const r = recipe("Soft shade", { film_sim: "Astia", white_balance: "Shade", color: 4, noise_reduction: -2 });
    const subs = confirmLook(r, OCT9);
    assert.deepEqual(subs.map((s) => [s.field, s.wanted, s.used]), [
      ["film_sim", "Astia", "Reala Ace"], ["white_balance", "Shade", "Kelvin 7700K"], ["color", "+4", "+3"],
      ["noise_reduction", "-2", "-4"],
    ]);
    assert.deepEqual([r.film_sim, r.white_balance, r.kelvin, r.color, r.noise_reduction], ["Reala Ace", "Kelvin", 7700, 3, -4]);
    assert.ok(isWritable(r, OCT9));
    const b = recipe("Night B&W", { film_sim: "Acros", color: 0, white_balance: "Incandescent" });
    confirmLook(b, OCT9);
    assert.deepEqual([b.film_sim, b.white_balance, b.kelvin], ["Acros+Ye", "Kelvin", 3000]);
  });
});

describe("the prompt and schema", () => {
  test("the model is told the allowed list and what isn't mapped", () => {
    const s = planSystem(OCT9);
    const allowedLine = s.split("\n").find((line) => line.includes("Film sims you can use on this camera (ONLY these):"))!;
    assert.ok(allowedLine.includes("Velvia") && allowedLine.includes("Classic Chrome"));
    assert.doesNotMatch(allowedLine, /Provia|Astia|Pro Neg Hi|Classic Neg/);
    assert.match(s, /Not available yet \(their camera codes aren't mapped, so they can't be written\): Provia, Astia, Pro Neg Hi, Classic Neg/);
    assert.match(s, /White balance: Auto, Daylight, Kelvin only/);
    assert.match(s, /Color -1 to \+3 \(0 for B&W\)\. Noise reduction -4 \(the only value mapped\)/);
    assert.doesNotMatch(s, /Astia soft, skin/);
  });

  test("plan and adjust schemas only offer confirmed values; ideal_film_sim may name any", () => {
    for (const schema of [planSchema(OCT9), adjustSchema(OCT9)]) {
      const props = "looks" in (schema.properties as object)
        ? (schema.properties as { looks: { items: { properties: Record<string, { enum?: unknown[] }>; required: string[] } } }).looks.items
        : (schema.properties as { look: { properties: Record<string, { enum?: unknown[] }>; required: string[] } }).look;
      assert.deepEqual(props.properties.film_sim.enum, SEVEN);
      assert.deepEqual(props.properties.white_balance.enum, ["Auto", "Daylight", "Kelvin"]);
      assert.deepEqual(props.properties.noise_reduction.enum, [-4]);
      assert.deepEqual(props.properties.ideal_film_sim.enum, [...OCT9.filmSims]);
      assert.ok(props.required.includes("ideal_film_sim"));
    }
  });
});

async function planWith(looks: ReturnType<typeof look>[], kw: Record<string, unknown> = {}): Promise<Plan> {
  return makePlan({
    said: "beach, fish market and dinner", place: "Example Point", date: "2026-10-11", cameraSlots: DAY_NAMES, taste: TASTE,
    pastLooks: PAST, cam: OCT9, ask: new FakeAsk([answer({ looks })]).ask, ...kw,
  });
}

const writes = (p: Plan) => p.day_looks.filter((l) => l.status === "new");

describe("plans only write confirmed values", () => {
  test("a look the model sent outside the schema gets the closest sim, said in a warning", async () => {
    const p = await planWith([
      look("Soft beach", "The beach", { film_sim: "Astia" }),
      look("Market grit", "Fish market", { film_sim: "Classic Neg", white_balance: "Shade" }),
      look("Warm dinner", "Dinner", { film_sim: "Nostalgic Neg", dynamic_range: "DR100", noise_reduction: 0,
        exposure: { aperture: "f/2", shutter: "1/60", iso: "A", exp_comp: "-⅓", nd: false } }),
    ]);
    const by = Object.fromEntries(p.day_looks.map((l) => [l.name, l]));
    assert.equal(by["Soft beach"].film_sim, "Reala Ace");
    assert.deepEqual([by["Market grit"].film_sim, by["Market grit"].white_balance, by["Market grit"].kelvin], ["Classic Chrome", "Kelvin", 7700]);
    assert.equal(by["Warm dinner"].noise_reduction, -4);
    assert.ok(p.warnings.includes(`Using Reala Ace for "Soft beach"; Astia isn't mapped for your camera yet.`), p.warnings.join("\n"));
    assert.ok(p.warnings.includes(`Using Classic Chrome for "Market grit"; Classic Neg isn't mapped for your camera yet.`));
    assert.ok(p.warnings.includes(`Using Kelvin 7700K white balance for "Market grit"; Shade white balance isn't mapped for your camera yet.`));
    for (const l of [...writes(p), ...p.plan.looks]) assert.ok(isWritable(l as RecipeFields, OCT9), l.name);
    // the file `dialin-cam load` reads and the cheat sheet follow the stand-ins
    assert.equal(p.plan.looks.find((l) => l.name === "Soft beach")?.film_sim, "Reala Ace");
  });

  test("the model's own stand-in (ideal_film_sim) is said too", async () => {
    const p = await planWith([
      { ...look("Soft beach", "The beach", { film_sim: "Reala Ace" }), ideal_film_sim: "Astia" },
      { ...look("Market light", "Fish market"), ideal_film_sim: "Classic Chrome" },
      { ...look("Warm dinner", "Dinner", { film_sim: "Nostalgic Neg" }), ideal_film_sim: "Nostalgic Neg" },
    ]);
    assert.deepEqual(p.warnings.filter((w) => w.includes("isn't mapped")),
      [`Using Reala Ace for "Soft beach"; Astia isn't mapped for your camera yet.`]);
  });

  test("a reused past look with an unmapped sim is written with a stand-in", async () => {
    const past = [...PAST, recipe("Neg street", { film_sim: "Classic Neg" })];
    const p = await planWith([
      look("Grey beach", "The beach"),
      { ...look("Neg street", "Fish market", { film_sim: "Classic Neg" }), reuse: "Neg street" },
      look("Warm dinner", "Dinner", { film_sim: "Nostalgic Neg" }),
    ], { pastLooks: past });
    const l = p.day_looks.find((x) => x.name === "Neg street");
    assert.equal(l?.status, "new");
    assert.equal(l?.film_sim, "Classic Chrome");
    assert.ok(p.warnings.includes(`Using Classic Chrome for "Neg street"; Classic Neg isn't mapped for your camera yet.`));
  });

  test("kept looks on the camera are never touched (they aren't written)", async () => {
    const p = await planWith(answer().looks);
    const kept = p.day_looks.filter((l) => l.status === "kept");
    assert.ok(kept.length >= 1);
    assert.deepEqual(p.warnings.filter((w) => w.includes("isn't mapped")), []);
  });

  test("adjust: a stray sim gets a stand-in and a warning", async () => {
    const p = await planWith(answer().looks);
    const { reuse: _r, ...fresh } = look("Rainy beach", "The beach", { film_sim: "Eterna" });
    const l = await adjustLook({ plan: p, slot: 1, said: "make it moodier", cam: OCT9,
      ask: new FakeAsk([{ look: fresh, change: "Flatter, moodier." }]).ask });
    assert.equal(l.film_sim, "Pro Neg Std");
    assert.ok(l.adjusted?.warnings.includes(`Using Pro Neg Std for "Rainy beach"; Eterna isn't mapped for your camera yet.`));
  });
});

describe("merging a map-codes result", () => {
  const report = (codes: CodeMapReport["codes"], kw: Partial<CodeMapReport> = {}): CodeMapReport => ({
    kind: "dialin.codemap/1", tool: "dialin-cam map-codes", model: "X100VI", firmware: "1.10", settings_size: 70524,
    slot: 7, at: "2026-10-11T15:04:05Z", rehearsal: false,
    backups: { slots: "backups/slots-x.json", settings: "backups/settings-x.dat" }, codes,
    restore: { verdict: "C7 restored: identical" }, ...kw,
  });

  test("new codes go into the table, the Swift block and the slot map, which then agree", () => {
    const r = merge(OCT9_CODES, report([
      { field: "film_sim", value: "Provia", ptp: 1, file: 1, inferred: 1, agrees: true, write: "clean" },
      { field: "film_sim", value: "Astia", ptp: 3, file: 7, inferred: 2, agrees: false, write: "clean" },
      { field: "film_sim", value: "Velvia", ptp: 2, file: 4, write: "clean" },
      { field: "white_balance", value: "Shade", ptp: 32774, file: 4, shift_entry: 8, write: "clean" },
      { field: "color", value: "-2", file: 9, write: "clean" },
      { field: "noise_reduction", value: "-3", file: 1, write: "clean" },
      { field: "noise_reduction", value: "0", file: 9, write: "clean" },
      { field: "film_sim", value: "Sepia", file: null, write: "refused" },
    ]));
    assert.deepEqual(r.conflicts, []);
    assert.equal(r.added.length, 5);
    assert.ok(r.added.some((x) => x.startsWith("film_sim Astia → 7") && x.includes("guess said 2")));
    assert.ok(r.already.some((x) => x.startsWith("film_sim Velvia")));
    assert.ok(r.skipped.some((x) => x.startsWith("noise_reduction 0") && x.includes("raw = value + 4")));
    assert.ok(r.skipped.some((x) => x.startsWith("film_sim Sepia")));
    assert.deepEqual(r.next.filmSims.Astia, { code: 7, seen: "map-codes-2026-10-11 C7" });
    assert.deepEqual(r.next.whiteBalances.Shade, { code: 4, shiftEntry: 8, seen: "map-codes-2026-10-11 C7" });
    assert.match(r.next.sources["map-codes-2026-10-11"], /restored: identical/);
    assert.match(renderSwift(r.next), /"Astia": 7,/);
    assert.match(renderSwift(r.next), /"Shade": WB\(code: 4, shiftEntry: 8\)/);
    assert.match(renderTs(r.next), /"Provia": \{ code: 1, seen: "map-codes-2026-10-11 C7" \}/);
    const m = JSON.parse(readFileSync(join(ROOT, PATHS.map), "utf8")) as SlotMap;
    assert.ok(mapProblems(r.next, m).length > 0, "the old map no longer agrees");
    applyToMap(r.next, m, "test");
    assert.deepEqual(mapProblems(r.next, m), []);
    assert.equal(m.fields.film_sim.encoding.map?.["3"], 7);
    assert.equal(m.fields.film_sim.encoding.inferred?.["3"], undefined);
    assert.equal(m.fields.wb_shift_r.encoding.index_by_ptp?.["32774"], 8);
    assert.deepEqual(m.fields.nr.observed_values, { "-4": 0, "-3": 1 });
    // the table the planner reads widens with it
    assert.ok(writable({ ...OCT9, confirmed: r.next }).filmSims.includes("Astia"));
  });

  test("a code that contradicts a confirmed one is a conflict; rehearsal and other layouts are refused", () => {
    const r = merge(OCT9_CODES, report([{ field: "film_sim", value: "Velvia", file: 9, write: "clean" }]));
    assert.equal(r.conflicts.length, 1);
    assert.throws(() => merge(OCT9_CODES, report([], { rehearsal: true })), /pretend camera/);
    assert.throws(() => merge(OCT9_CODES, report([], { firmware: "1.20" })), /firmware 1.20/);
    assert.throws(() => merge(OCT9_CODES, report([], { settings_size: 71548 })), /71548/);
    assert.ok(merge(OCT9_CODES, report([], { rehearsal: true }), { allowRehearsal: true }));
  });
});
