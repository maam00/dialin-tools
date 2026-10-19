// Validation and tidying of one look, for one camera. Ported from studio/plan.py (recipe_problems, name_problems,
// _fallback_name, check_exposure, fix_leaf_shutter, normalize_exposure, tidy_look, look_problems), which ported
// lib/fuji/recipe.ts and lib/exposure.ts. Everything camera-specific comes from the CameraCaps entry.
import type { CameraCaps } from "../cameras.js";
import { type Exposure, RECIPE_KEYS, type RecipeFields } from "./types.js";

type AnyLook = Record<string, unknown> & { exposure?: Partial<Exposure> };

/** The recipe part of any look-shaped object. */
export function recipeOf(d: Record<string, unknown>): RecipeFields {
  const out: Record<string, unknown> = {};
  for (const k of RECIPE_KEYS) if (k in d) out[k] = d[k];
  return out as RecipeFields;
}

/** Camera-safe: NFKD, printable ASCII, whitespace collapsed, trimmed (recipe.ts slotName, without the cut). */
export function slotName(name: string): string {
  const s = (name ?? "").normalize("NFKD").replace(/[^\x20-\x7e]/g, "");
  return s.replace(/\s+/g, " ").trim();
}

const numIn = (v: unknown, allowed: readonly number[]) =>
  typeof v === "number" && Number.isFinite(v) && allowed.some((a) => Math.abs(v - a) < 1e-9);

const squash = (value: string) => value.toLowerCase().replace(/[^a-z0-9+]/g, "");
/** The allowed value a near-miss most likely meant ("Classic Negative" → "Classic Neg", "weak small" → "Weak Small"). */
export function nearestValue(value: unknown, allowed: readonly string[]): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  const v = squash(value);
  const exact = allowed.find((a) => squash(a) === v);
  if (exact) return exact;
  const prefixed = allowed.filter((a) => squash(a).length >= 4 && (v.startsWith(squash(a)) || squash(a).startsWith(v)));
  return prefixed.length === 1 ? prefixed[0] : null; // two candidates ("Weak" → Weak Small/Large) is a guess, not a hint
}
/** "-2 to +2 in steps of 0.5" for an even ladder, else the list. */
export function describeNumbers(allowed: readonly number[]): string {
  const values = [...allowed].sort((a, b) => a - b);
  const steps = values.slice(1).map((v, i) => Math.round((v - values[i]) * 1000) / 1000);
  const fmt = (v: number) => (v > 0 ? `+${v}` : `${v}`);
  if (values.length > 3 && steps.every((step) => step === steps[0])) return `${fmt(values[0])} to ${fmt(values[values.length - 1])} in steps of ${steps[0]}`;
  return values.map((v) => String(v)).join(", ");
}

/** Hard problems: any value the camera can't hold. Each names what the field accepts. */
export function recipeProblems(r: Record<string, unknown>, cam: CameraCaps): string[] {
  const p: string[] = [];
  const enums: [string, readonly string[]][] = [
    ["film_sim", cam.filmSims], ["grain", cam.grains], ["color_chrome", cam.effects],
    ["color_chrome_fx_blue", cam.effects], ["white_balance", cam.whiteBalances], ["dynamic_range", cam.dynamicRanges],
  ];
  for (const [k, allowed] of enums) {
    if (allowed.includes(r[k] as string)) continue;
    const near = nearestValue(r[k], allowed);
    p.push(`${k} ${JSON.stringify(r[k] ?? null)} isn't a camera value${near ? `; did you mean "${near}"?` : "."} Allowed: ${allowed.join(", ")}.`);
  }
  const nums: [string, readonly number[]][] = [
    ["kelvin", cam.kelvins], ["wb_shift_r", cam.shifts], ["wb_shift_b", cam.shifts], ["highlight", cam.tones],
    ["shadow", cam.tones], ["color", cam.color], ["sharpness", cam.sharpness], ["noise_reduction", cam.noiseReduction],
    ["clarity", cam.clarity],
  ];
  for (const [k, allowed] of nums) {
    if (!numIn(r[k], allowed)) p.push(`${k} ${JSON.stringify(r[k] ?? null)} is out of range. Allowed: ${describeNumbers(allowed)}${k === "kelvin" ? " (0 when white_balance is not Kelvin)" : ""}.`);
  }
  if (typeof r.name !== "string" || !r.name.trim()) p.push("a look has no name");
  return p;
}

const SIM_WORDS = ["provia", "velvia", "astia", "classic chrome", "chrome", "reala", "pro neg", "classic neg",
  "nostalgic neg", "eterna", "bleach", "acros", "monochrome", "sepia"];
const GENERIC = new Set(["look", "slot", "custom", "preset", "recipe", "setting", "settings", "sim", "film"]);
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const isUpper = (s: string) => /[A-Za-z]/.test(s) && s === s.toUpperCase();

/** Why a name wouldn't read like a person wrote it for this day (LOOK_CRAFT's naming rules). */
export function nameProblems(name: string, nameMax: number): string[] {
  const n = name ?? "";
  const p: string[] = [];
  if (slotName(n) !== n.trim()) p.push("use plain ASCII only");
  if (n.trim().length > nameMax) p.push(`${n.trim().length} characters, max ${nameMax}`);
  if (/\d/.test(n)) p.push("no numbers");
  if (/[+/=%#@_|<>[\]{}]|\bf\/|\b(ISO|DR|EV|C[1-7])\b/i.test(n)) p.push("no settings or codes");
  const letters = n.replace(/B&W/g, "").replace(/[^A-Za-z]/g, "");
  if (letters.length >= 3 && isUpper(letters)) p.push("no ALL CAPS");
  const low = n.toLowerCase();
  if (SIM_WORDS.some((w) => new RegExp(`\\b${esc(w)}\\b`).test(low))) p.push("no film-sim names");
  const words = n.trim().split(/\s+/).filter(Boolean);
  if (words.length > 3) p.push("1 to 3 words");
  if ((words.length && words.every((w) => GENERIC.has(w.toLowerCase().replace(/[^a-z]/g, ""))))
    || (words.length && GENERIC.has(words[0].toLowerCase()) && words.length <= 2)) {
    p.push("say when or what it's for, not 'Look'");
  }
  return p;
}

const capitalize = (w: string) => w.slice(0, 1).toUpperCase() + w.slice(1).toLowerCase();

/** Last resort after the retry: strip what breaks the rules and cut at a word boundary. */
export function fallbackName(name: string, stop: string, nameMax: number): string {
  let s = slotName(name);
  s = s.replace(/\d+|[+/=%#@_|<>[\]{}]/g, " ");
  s = s.replace(/\b(ISO|DR|EV|f)\b/g, " ");
  for (const w of SIM_WORDS) s = s.replace(new RegExp(`\\b${esc(w)}\\b`, "gi"), " ");
  let words = s.split(/\s+/).filter(Boolean);
  if (words.length && isUpper(words.join("").replace(/B&W/g, ""))) {
    words = words.map((w) => (w === "B&W" ? w : capitalize(w)));
    words = [words[0], ...words.slice(1).map((w) => (w === "B&W" ? w : w.toLowerCase()))];
  }
  let out = "";
  for (const w of words.slice(0, 3)) {
    if (`${out} ${w}`.trim().length > nameMax) break;
    out = `${out} ${w}`.trim();
  }
  if (!out) out = (slotName(stop).split(" ").filter(Boolean)[0] ?? "Today").slice(0, nameMax);
  return out.slice(0, 1).toUpperCase() + out.slice(1);
}

/** Fastest mechanical speed (the 1/x denominator) at this aperture, or Infinity without a leaf shutter. */
export function leafFastest(aperture: string, cam: CameraCaps): number {
  if (!cam.leafShutter) return Number.POSITIVE_INFINITY;
  const f = Number(aperture.slice(2));
  return (cam.leafShutter.find((l) => f < l.maxF) ?? cam.leafShutter[cam.leafShutter.length - 1]).fastest;
}

/** lib/exposure.ts checkExposure: a problem sentence, or null if the camera can physically do it. */
export function checkExposure(e: Partial<Exposure> | null | undefined, cam: CameraCaps, minIso = 125): string | null {
  const x = (e ?? {}) as Record<string, unknown>;
  const enums: [string, readonly string[]][] = [
    ["aperture", cam.apertures], ["shutter", cam.shutters], ["iso", cam.isos], ["exp_comp", cam.expComps],
  ];
  for (const [k, allowed] of enums) {
    if (!allowed.includes(x[k] as string)) return `${k} ${JSON.stringify(x[k] ?? null)} is not on the camera`;
  }
  if (typeof x.nd !== "boolean") return "nd must be true or false";
  if (x.nd && cam.ndStops <= 0) return "this camera has no built-in ND filter";
  if (x.iso !== "A" && Number(x.iso) < minIso) {
    return `ISO ${x.iso} is below this look's minimum of ISO ${minIso}. Raise ISO and use the ND if it's bright.`;
  }
  const shutter = x.shutter as string;
  if (x.aperture !== "A" && shutter.startsWith("1/")) {
    const fastest = leafFastest(x.aperture as string, cam);
    if (Number(shutter.slice(2)) > fastest) {
      return `${shutter} at ${x.aperture} is faster than the leaf shutter allows (max 1/${fastest}). `
        + "Use the ND or a smaller aperture.";
    }
  }
  return null;
}

/** lib/exposure.ts fixLeafShutter: too fast for the leaf shutter → ND on and ndStops slower (same exposure). */
export function fixLeafShutter(e: Exposure, cam: CameraCaps): boolean {
  if (!e.aperture || e.aperture === "A" || !String(e.shutter ?? "").startsWith("1/") || e.nd || cam.ndStops <= 0) {
    return false;
  }
  if (Number(e.shutter.slice(2)) <= leafFastest(e.aperture, cam)) return false;
  const i = cam.shutters.indexOf(e.shutter);
  e.shutter = cam.shutters[Math.min(cam.shutters.length - 1, i + cam.ndStops)];
  e.nd = true;
  return true;
}

/** Exposure comp does nothing in full manual. */
export function normalizeExposure<T extends Partial<Exposure>>(e: T): T {
  if (e.aperture !== "A" && e.shutter !== "A" && e.iso !== "A") e.exp_comp = "0";
  return e;
}

function tone(v: unknown): unknown {
  const f = Number(v);
  if (v === null || v === "" || typeof v === "boolean" || !Number.isFinite(f)) return v;
  return Math.round(f * 2) / 2;
}

function int(v: unknown): unknown {
  const f = Number(v);
  if (v === null || v === "" || typeof v === "boolean" || !Number.isFinite(f)) return v;
  return Number.isInteger(f) ? f : v;
}

/** Fix in place what code can fix without asking again; returns plain notes of what changed.
 *  (DR vs a fixed ISO, leaf shutter → ND, comp in full manual, kelvin, B&W color, clarity in burst, number types.) */
export function tidyLook(look: AnyLook, cam: CameraCaps): string[] {
  const notes: string[] = [];
  look.name = slotName(String(look.name ?? ""));
  for (const k of ["kelvin", "wb_shift_r", "wb_shift_b", "color", "sharpness", "noise_reduction", "clarity"]) {
    look[k] = int(look[k]);
  }
  for (const k of ["highlight", "shadow"]) look[k] = tone(look[k]);
  if (look.white_balance !== "Kelvin" && look.kelvin) look.kelvin = 0;
  if (look.white_balance === "Kelvin" && !look.kelvin) {
    look.kelvin = 5600;
    notes.push(`${look.name}: Kelvin white balance had no temperature, set 5600K`);
  }
  if (cam.monoSims.has(look.film_sim as string)) {
    if (look.color) look.color = 0;
    look.color_chrome = "Off";
    look.color_chrome_fx_blue = "Off";
  }
  if (!look.exposure || typeof look.exposure !== "object") look.exposure = {};
  const e = look.exposure as Exposure;
  if (typeof e.exp_comp === "string") {
    e.exp_comp = e.exp_comp.replace(/−/g, "-").replace(/–/g, "-").trim();
    if (["+0", "-0", "±0"].includes(e.exp_comp)) e.exp_comp = "0";
  }
  const dr = look.dynamic_range as string;
  if (e.iso && e.iso !== "A" && dr in cam.drMinIso && /^\d+$/.test(String(e.iso))) {
    const iso = Number(e.iso);
    if (iso < cam.drMinIso[dr]) {
      look.dynamic_range = iso >= (cam.drMinIso.DR200 ?? 250) ? "DR200" : "DR100";
      notes.push(`${look.name}: dynamic range stepped down to ${look.dynamic_range} for ISO ${iso}`);
    }
  }
  if (cam.apertures.includes(e.aperture) && cam.shutters.includes(e.shutter) && fixLeafShutter(e, cam)) {
    notes.push(`${look.name}: ND on and shutter ${e.shutter} (the leaf shutter can't go faster at ${e.aperture})`);
  }
  normalizeExposure(e);
  if ((look.drive === "CH" || look.drive === "CL") && look.clarity) {
    look.clarity = 0;
    notes.push(`${look.name}: clarity 0 (it pauses after every shot, which kills a burst)`);
  }
  if (!cam.focusModes.includes(look.focus as string)) look.focus = "S";
  if (!cam.drives.includes(look.drive as string)) look.drive = "S";
  return notes;
}

/** Everything still wrong with a new look after tidying: values, name and exposure. */
export function lookProblems(look: AnyLook, cam: CameraCaps): string[] {
  const nm = (look.name as string) || "a look";
  const p = recipeProblems(recipeOf(look), cam).map((x) => `${nm}: ${x}`);
  p.push(...nameProblems(String(look.name ?? ""), cam.nameMax).map((x) => `name "${nm}": ${x}`));
  const ep = checkExposure(look.exposure, cam, cam.drMinIso[look.dynamic_range as string] ?? 125);
  if (ep) p.push(`${nm}: ${ep}`);
  return p;
}

/** Same settings (name and why aside). */
export function sameRecipe(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  return RECIPE_KEYS.filter((k) => k !== "name" && k !== "why").every((k) =>
    typeof a[k] === "number" ? numIn(a[k], [b[k] as number]) : a[k] === b[k]);
}

/** "Classic Neg, DR200, grain Weak Small, CC Weak/Weak, WB Auto R1 B-1, H0.5 S1 C1 Sh-1 NR-4 Cl0". */
export function recipeLine(r: RecipeFields): string {
  const wb = r.white_balance + (r.white_balance === "Kelvin" ? ` ${r.kelvin}K` : "");
  return `${r.film_sim}, ${r.dynamic_range}, grain ${r.grain}, CC ${r.color_chrome}/${r.color_chrome_fx_blue}, WB ${wb} `
    + `R${r.wb_shift_r} B${r.wb_shift_b}, H${r.highlight} S${r.shadow} C${r.color} Sh${r.sharpness} `
    + `NR${r.noise_reduction} Cl${r.clarity}`;
}
