// Shared fakes for the plan engine tests: the synthetic day (release/fixtures/synthetic-day.json), a fake Ask (no model
// call), a fake network. Every place, date and count here is invented for tests.
import { readFileSync } from "node:fs";
import { setGetJson, clearCaches, NOMINATIM, OPEN_METEO } from "../../lib/plan/conditions.js";
import { recipeOf } from "../../lib/plan/looks.js";
import type { Ask, AskAnswer, AskRequest } from "../../lib/plan/model.js";
import type { ModelLook, ModelPlan, RecipeFields } from "../../lib/plan/types.js";

export const DAY = JSON.parse(readFileSync(new URL("../../release/fixtures/synthetic-day.json", import.meta.url), "utf8"));
export const DAY_LOOKS: Record<string, RecipeFields & Record<string, unknown>> = Object.fromEntries(
  DAY.plan.looks.map((l: RecipeFields) => [l.name, l]));
export const DAY_NAMES: string[] = DAY.plan.looks.map((l: RecipeFields) => l.name); // C1 Harbor color … C7 Gritty B&W
/** Past looks as the app would send them (past_looks). */
export const PAST: RecipeFields[] = DAY.plan.looks.map((l: Record<string, unknown>) => recipeOf(l));
/** Invented keep rates (hearted of shot) for the synthetic day. Favorites by taste.ts's rule: Old fisherman (score) and
 *  Hard noon B&W (a third of all hearts); Harbor color has 5+ hearts but neither. */
const SYNTHETIC_RATES: [string, number, number][] = [["Hard noon B&W", 12, 40], ["Gritty B&W", 4, 30], ["Harbor color", 6, 50],
  ["Old fisherman", 9, 20], ["Deep blue sea", 3, 18], ["Faded dock", 2, 15], ["Sunny faces", 1, 6]];
export const TASTE = { keep_rates: SYNTHETIC_RATES.map(([look, hearted, shot]) => ({ look, hearted, shot, date: DAY.conditions.date,
  place: DAY.conditions.place.name })) };

export function recipe(name: string, kw: Partial<RecipeFields> = {}): RecipeFields {
  return {
    name, film_sim: "Classic Chrome", grain: "Weak Small", color_chrome: "Weak", color_chrome_fx_blue: "Weak",
    white_balance: "Auto", kelvin: 0, wb_shift_r: 1, wb_shift_b: -1, dynamic_range: "DR200", highlight: 0.5, shadow: 1,
    color: 1, sharpness: -1, noise_reduction: -4, clarity: 0, why: "Bite for a flat day.", ...kw,
  };
}

type LookOpts = Partial<RecipeFields> & { reuse?: string; based_on?: string; exposure?: ModelLook["exposure"]; focus?: string; drive?: string };

export function look(name: string, stop: string, o: LookOpts = {}): ModelLook {
  const { reuse = "", based_on = "", exposure, focus = "S", drive = "S", ...kw } = o;
  const base = reuse && DAY_LOOKS[reuse] ? recipeOf(DAY_LOOKS[reuse]) : recipe(name, kw);
  return {
    ...base, name: reuse ? reuse : name, stop, when: `${stop}, in the day`, reuse, based_on, reason: "Because.",
    exposure: exposure ?? { aperture: "f/8", shutter: "1/500", iso: "A", exp_comp: "+⅓", nd: false },
    focus, drive, how: "Shoot it like this.",
  };
}

export function answer(o: { looks?: ModelLook[]; stops?: ModelPlan["stops"]; replace?: ModelPlan["replace"] } = {}): ModelPlan {
  const stops = o.stops ?? [
    { name: "The beach", start: "11:00", end: "14:00", light: "grey, flat" },
    { name: "Fish market", start: "15:00", end: "16:00", light: "indoors, mixed" },
    { name: "Dinner", start: "19:00", end: "21:00", light: "candles" },
  ];
  const looks = o.looks ?? [
    look("Grey beach", "The beach"),
    look("Cloudy B&W", "The beach", { based_on: "Hard noon B&W", film_sim: "Acros+R", color: 0, color_chrome: "Off", color_chrome_fx_blue: "Off" }),
    look("Old fisherman", "Fish market", { reuse: "Old fisherman", exposure: { aperture: "f/4", shutter: "1/250", iso: "A", exp_comp: "-⅓", nd: false } }),
    look("Warm dinner", "Dinner", { film_sim: "Nostalgic Neg", dynamic_range: "DR100", exposure: { aperture: "f/2", shutter: "1/60", iso: "A", exp_comp: "-⅓", nd: false } }),
  ];
  return {
    summary: "Grey all day, so the looks add contrast.", count_why: "Three stops, one alternate.", stops, looks,
    replace: o.replace ?? [{ name: "Sunny faces", why: "used once" }, { name: "Deep blue sea", why: "no blue today" },
      { name: "Harbor color", why: "flat day" }],
  };
}

/** Stands in for the model: returns queued answers in order and records every request. */
export class FakeAsk {
  calls: AskRequest[] = [];
  answers: unknown[];
  constructor(answers: unknown[] = [], public fail = false) {
    this.answers = [...answers];
  }
  ask: Ask = async (req) => {
    this.calls.push(req);
    if (this.fail || !this.answers.length) {
      return { ok: false, data: null, model: req.model, via: "fake", ms: 1, error: "offline", code: "connection", usage: null, usd: null, tries: [] };
    }
    const a: AskAnswer = {
      ok: true, data: structuredClone(this.answers.shift()), model: req.model, via: "fake", ms: 1234, error: null, code: null,
      usage: { input_tokens: 5000, output_tokens: 3000, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
      usd: 0.04, tries: [],
    };
    return a;
  };
}

export function forecast(date = "2026-10-11", cloud = 95, rain = 0, code = 3) {
  const hours = Array.from({ length: 24 }, (_, h) => `${date}T${String(h).padStart(2, "0")}:00`);
  const fill = (v: number) => Array(24).fill(v);
  return {
    timezone: "America/New_York", utc_offset_seconds: -14400,
    daily: { time: [date], sunrise: [`${date}T06:55`], sunset: [`${date}T18:13`], uv_index_max: [2.0],
      temperature_2m_max: [66.0], temperature_2m_min: [57.0] },
    hourly: { time: hours, cloud_cover: fill(cloud), precipitation_probability: fill(rain), temperature_2m: fill(61.0),
      weather_code: fill(code), wind_speed_10m: fill(9.0) },
  };
}

/** Replaces the network for conditions.ts. */
export class FakeNet {
  urls: string[] = [];
  failForecast = false;
  constructor(public fc = forecast()) {}
  install() {
    clearCaches();
    setGetJson(async (url) => {
      this.urls.push(url);
      if (url.startsWith(NOMINATIM)) return [{ lat: "40.2500", lon: "-70.5000", display_name: "Example Point, Example County" }];
      if (url.startsWith(OPEN_METEO)) {
        if (this.failForecast && url.includes("start_date")) throw new Error("400 out of range");
        return this.fc;
      }
      throw new Error(`unexpected ${url}`);
    });
    return this;
  }
}

/** What `dialin-cam load` would do with a plan file, by its own rules (ios/DialInCamera main.swift `load`):
 *  plan.looks, the first 7, each decoded as a Recipe (every key but why present, right types), into C1, C2, … */
export function mirrorLoadParse(d: { plan?: { looks?: Record<string, unknown>[] } }): { slot: number; name: string }[] {
  const looks = (d.plan?.looks ?? []).slice(0, 7);
  if (!looks.length) throw new Error("plan has no looks");
  const ints = ["kelvin", "wb_shift_r", "wb_shift_b", "color", "sharpness", "noise_reduction", "clarity"];
  const strs = ["name", "film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "dynamic_range"];
  return looks.map((l, i) => {
    for (const k of ints) if (!Number.isInteger(l[k])) throw new Error(`C${i + 1}: ${k} must be an Int`);
    for (const k of ["highlight", "shadow"]) if (typeof l[k] !== "number") throw new Error(`C${i + 1}: ${k} must be a Double`);
    for (const k of strs) if (typeof l[k] !== "string") throw new Error(`C${i + 1}: ${k} must be a String`);
    if (l.slot !== undefined && l.slot !== i + 1) throw new Error(`C${i + 1}: look says slot ${l.slot}`);
    return { slot: i + 1, name: String(l.name).slice(0, 14) };
  });
}
