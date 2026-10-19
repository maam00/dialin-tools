// What each Fujifilm body can hold in a custom slot, what its dials can do, and how the cheat sheet names its
// controls. Everything camera-specific in the plan engine (prompts, JSON schemas, validation, the cheat sheet) reads
// from the entry for the request's camera, so a new body is one new entry here plus a check of its facts.
//
// Only the X100VI is filled in and verified (lib/camera.ts, lib/fuji/recipe.ts, docs/FUJI_PROTOCOL.md §6–§7, §15).
//
// Adding another body (X100V, X-T5, X-S20, X-M5 …): start from its owner's read-only `camera report` and the draft
// profile it produces (docs/ADD-YOUR-CAMERA.md); the USB writer's per-body map and write gate live in
// modules/camera/profiles.ts. Then, for planning:
//   1. Copy X100VI below, set id/name/aliases, and fix every table against that body's manual: film sims (the X100V
//      has no Reala Ace or Nostalgic Neg), white balances, dial positions, Auto ISO ceiling.
//   2. leafShutter: null for a focal-plane body (then only the shutter list limits speed). ndStops: 0 when there is
//      no built-in ND (the engine then reports a too-fast shutter instead of switching the ND on).
//   3. Rewrite facts/controls/labels for its real controls (a PASM or command-dial body has no "lift the shutter
//      dial ring"), and the slot count and name length its menu allows.
//   4. Add a test in tests/plan/ that a plan for it validates, and list it in docs/APP-API.md.
//   5. `confirmed`: only codes seen in that body's own settings file (see ConfirmedCodes). The planner proposes only
//      those, so an empty table means no plan can be written; map them with `dialin-cam map-codes` first.
import { APERTURES, EXP_COMPS, ISOS, SHUTTERS } from "./camera.js";
import { X100VI_FACTS } from "./fuji/camera-facts.js";
import {
  DR_MIN_ISO, DYNAMIC_RANGES, EFFECTS, FILM_SIMS, GRAINS, KELVINS, PLUS4, PLUS5, SHIFTS, TONES, WHITE_BALANCES,
} from "./fuji/recipe.js";

/** One settings-file code seen on a real camera: the byte the camera stored, and the source that proved it. */
export type SeenCode = { code: number; seen: string };

/**
 * Which look values have CONFIRMED codes in the camera's settings file: the file the app's Bluetooth writer patches
 * (ios/DialInCamera SettingsLookPatch.swift, ble/fuji_ble correlate.apply_plan). A value is confirmed only when a real
 * file from this body showed the byte it is stored as. The planner proposes only confirmed values, and the app refuses
 * any other before a write. Codes not listed here are inferred (from the X-T5) and never written by default.
 *
 * This is the single source of truth. Mirrors that must agree (`npm run codes -- check`, run by `npm run test:plan`):
 * the Swift block in ios/DialInCamera/Sources/DialInCamera/SettingsFile/ConfirmedCodes.swift (rendered from here) and
 * the slot map ble/maps/x100vi-fw110.json. New codes from `dialin-cam map-codes` go in with
 * `npm run codes -- merge <codes.json> --write`, which updates all three.
 */
export type ConfirmedCodes = {
  /** The settings-file layout the codes are for. */
  layout: string;
  /** Firmware whose settings file has this layout. */
  firmware: readonly string[];
  /** What each `seen` key refers to. */
  sources: Readonly<Record<string, string>>;
  /** Film simulation name → its byte at slot + 0x64. */
  filmSims: Readonly<Record<string, SeenCode>>;
  /** White balance name → its byte at slot − 0x0F, and the entry of the per-mode WB-shift table its shift lives in. */
  whiteBalances: Readonly<Record<string, SeenCode & { shiftEntry: number }>>;
  /** Color (−4…+4, as a string key) → its byte at slot + 0x77. */
  color: Readonly<Record<string, SeenCode>>;
  /** High ISO NR (−4…+4, as a string key) → its byte at slot + 0x2B. */
  noiseReduction: Readonly<Record<string, SeenCode>>;
  /** Fields whose every value is confirmed: a linear encoding seen at enough values to pin it. Field → evidence. */
  wholeRange: Readonly<Record<string, string>>;
};

export type CameraCaps = {
  /** Canonical model id, also what the response echoes. */
  id: string;
  /** "Fujifilm X100VI", used in the prompts. */
  name: string;
  /** Model strings that resolve to this entry, compared after lower-casing and removing spaces, dashes and "fujifilm". */
  aliases: string[];
  /** Firmware the slot writer has been checked against, and the oldest the tables are right for (null = any). */
  firmware: { tested: string[]; minimum: string | null };
  slots: number;
  /** Longest slot name we write (the camera allows more; short names read on the screen). */
  nameMax: number;

  // ---- what a custom slot holds (recipe values)
  filmSims: readonly string[];
  monoSims: ReadonlySet<string>;
  whiteBalances: readonly string[];
  grains: readonly string[];
  effects: readonly string[];
  dynamicRanges: readonly string[];
  drMinIso: Readonly<Record<string, number>>;
  kelvins: readonly number[];
  tones: readonly number[];
  shifts: readonly number[];
  color: readonly number[];
  sharpness: readonly number[];
  noiseReduction: readonly number[];
  clarity: readonly number[];

  // ---- the dials (never stored in a slot; the cheat sheet tells the person what to turn)
  apertures: readonly string[];
  shutters: readonly string[];
  isos: readonly string[];
  expComps: readonly string[];
  focusModes: readonly string[];
  drives: readonly string[];
  /** Mechanical leaf-shutter limit by aperture: the fastest speed for f-numbers below maxF. null = no leaf shutter. */
  leafShutter: { maxF: number; fastest: number }[] | null;
  /** Built-in ND filter strength in stops; 0 = none. */
  ndStops: number;
  /** The Auto ISO ceiling the cheat sheet quotes. */
  autoIsoMax: number;

  // ---- what can be written safely
  /** Look values whose settings-file codes are confirmed on this body (see ConfirmedCodes). */
  confirmed: ConfirmedCodes;

  // ---- words
  /** What the user can physically set, for the system prompt. */
  facts: string;
  /** The controls the cheat sheet names, for the system prompt. */
  controls: string;
  /** How the cheat sheet names each control. */
  labels: {
    expDial: string;
    aperture: string;
    shutter: string;
    iso: string;
    isoAuto: string;
    focus: string;
    drive: string;
    nd: string;
    pickSlot: string;
  };
};

const MONO = new Set([
  "Acros", "Acros+Ye", "Acros+R", "Acros+G", "Monochrome", "Monochrome+Ye", "Monochrome+R", "Monochrome+G", "Sepia",
]);



const X100VI_CONTROLS = `
THE CONTROLS THEY TOUCH (the cheat sheet names these; there is no mode dial and no zoom)
- Exposure dial (top right): -3 to +3 in thirds.
- Aperture ring (on the lens): f/2 to f/16, or A.
- Shutter dial (top): A or a speed. ISO lives in the same dial: lift its outer ring and turn.
- Focus switch (side of the body): S for still things, C for moving things, M for manual / zone focus.
- Drive button: S single, CL slow burst, CH fast burst (kids, sport, pets, waves).
- ND filter: built-in 4 stops, on a Fn button. For f/2–f/4 in bright sun.
- Q button: pick C1–C7.
`.trim();

// <codes:X100VI> `npm run codes -- merge <codes.json> --write` re-renders this block. Hand edits are fine; keep the shape.
export const X100VI_CONFIRMED: ConfirmedCodes = {
  layout: "X100VI fw 1.10 settings file (70,524 bytes)",
  firmware: ["1.10"],
  sources: {
    "usb-2026-10-09": "Seven looks written into C1–C7 over USB (PTP slot props, dialin-cam load), 7/7 read back clean and checked on the camera by the photographer; then the settings file was downloaded over USB (.dialin/test-fixtures/settings.dat, private: 70,524 bytes, sha256 94174d96…26f9db53) and decoded with ble/maps/x100vi-fw110.json. Every code re-read from that file on 2026-10-11.",
  },
  filmSims: {
    "Velvia": { code: 4, seen: "usb-2026-10-09 C3 Deep blue sea" },
    "Classic Chrome": { code: 15, seen: "usb-2026-10-09 C4 Old fisherman" },
    "Reala Ace": { code: 18, seen: "usb-2026-10-09 C1 Harbor color" },
    "Pro Neg Std": { code: 13, seen: "usb-2026-10-09 C2 Sunny faces" },
    "Nostalgic Neg": { code: 17, seen: "usb-2026-10-09 C5 Faded dock" },
    "Acros+Ye": { code: 24, seen: "usb-2026-10-09 C7 Gritty B&W" },
    "Acros+R": { code: 23, seen: "usb-2026-10-09 C6 Hard noon B&W" },
  },
  whiteBalances: {
    "Auto": { code: 0, shiftEntry: 0, seen: "usb-2026-10-09 C1, C2 (shift R+1 B-1 in entry 0), C6, C7" },
    "Daylight": { code: 3, shiftEntry: 7, seen: "usb-2026-10-09 C3 (B+1 in entry 7), C4 (R+2 B-5 in entry 7)" },
    "Kelvin": { code: 10, shiftEntry: 6, seen: "usb-2026-10-09 C5 6300K (R+1 B-3 in entry 6)" },
  },
  color: {
    "-1": { code: 8, seen: "usb-2026-10-09 C5" },
    "0": { code: 0, seen: "usb-2026-10-09 C2, C3" },
    "1": { code: 6, seen: "usb-2026-10-09 C1" },
    "2": { code: 5, seen: "usb-2026-10-09 C4" },
    "3": { code: 4, seen: "usb-2026-10-09 C7 (kept under its B&W look; PTP reads +3)" },
  },
  noiseReduction: {
    "-4": { code: 0, seen: "usb-2026-10-09 C1-C7" },
  },
  wholeRange: {
    "grain": "usb-2026-10-09: Off, Weak Small, Strong Small, Weak Large, Strong Large all seen (strength raw 2/1/0, size raw 0/1)",
    "color_chrome": "usb-2026-10-09: Weak (C1, C2, C5), Strong (C3, C4), Off (C7, kept); value = raw",
    "color_chrome_fx_blue": "usb-2026-10-09: Off (C5), Weak (C1, C2, C4), Strong (C3); value = raw",
    "dynamic_range": "usb-2026-10-09: DR100 (C7), DR200 (C4, C6), DR400 (C1, C2, C3, C5) as raw 1/2/3",
    "highlight": "usb-2026-10-09: -1.5, -1, 0.5, 1, 2 seen; value = raw / 2 - 2",
    "shadow": "usb-2026-10-09: -1, 0, 0.5, 1.5, 2.5, 3 seen; value = raw / 2 - 2",
    "sharpness": "usb-2026-10-09: -2, -1, 0, +1 seen; value = 4 - raw",
    "clarity": "usb-2026-10-09: -2, 0, +1, +2 seen; value = raw - 6",
    "kelvin": "usb-2026-10-09: 4350, 5200, 6300 seen as plain u16 Kelvin",
    "wb_shift": "usb-2026-10-09: value = 9 - raw, in the entry of the look's WB mode (entries 0, 6, 7 seen; other modes' entries only once their WB is confirmed)",
  },
};
// </codes:X100VI>

export const X100VI: CameraCaps = {
  id: "X100VI",
  name: "Fujifilm X100VI",
  aliases: ["x100vi"],
  firmware: { tested: ["1.10"], minimum: null },
  slots: 7,
  nameMax: 14,
  filmSims: Object.keys(FILM_SIMS),
  monoSims: MONO,
  whiteBalances: Object.keys(WHITE_BALANCES),
  grains: Object.keys(GRAINS),
  effects: Object.keys(EFFECTS),
  dynamicRanges: Object.keys(DYNAMIC_RANGES),
  drMinIso: DR_MIN_ISO,
  kelvins: KELVINS,
  tones: TONES,
  shifts: SHIFTS,
  color: PLUS4,
  sharpness: PLUS4,
  noiseReduction: PLUS4,
  clarity: PLUS5,
  apertures: APERTURES,
  shutters: SHUTTERS,
  isos: ISOS,
  expComps: EXP_COMPS,
  focusModes: ["S", "C", "M"],
  drives: ["S", "CL", "CH"],
  // Owner's manual: "from 1/2000 s at f/2 to 1/4000 s at f/4.5"; values in between aren't published (lib/exposure.ts).
  leafShutter: [
    { maxF: 4.5, fastest: 2000 },
    { maxF: Infinity, fastest: 4000 },
  ],
  ndStops: 4,
  autoIsoMax: 6400,
  confirmed: X100VI_CONFIRMED,
  facts: X100VI_FACTS,
  controls: X100VI_CONTROLS,
  labels: {
    expDial: "Exposure dial",
    aperture: "Aperture ring",
    shutter: "Shutter dial",
    iso: "ISO (lift the shutter dial ring)",
    isoAuto: "A, auto up to 6400",
    focus: "Focus switch",
    drive: "Drive",
    nd: "ND filter",
    pickSlot: "Q button to pick the C.",
  },
};

/** Every supported body. Add new entries here (see the steps at the top). */
export const CAMERAS: readonly CameraCaps[] = [X100VI];

/** The look values a plan may put in a slot on this body: what it can hold, cut to the confirmed settings-file codes.
 *  Fields in `confirmed.wholeRange` (grain, color chrome, DR, tones, sharpness, clarity, Kelvin, shifts) keep their
 *  whole range. */
export type WritableValues = {
  filmSims: string[];
  whiteBalances: string[];
  color: number[];
  noiseReduction: number[];
};

export function writable(cam: CameraCaps): WritableValues {
  const c = cam.confirmed;
  return {
    filmSims: cam.filmSims.filter((s) => s in c.filmSims),
    whiteBalances: cam.whiteBalances.filter((w) => w in c.whiteBalances),
    color: cam.color.filter((v) => String(v) in c.color),
    noiseReduction: cam.noiseReduction.filter((v) => String(v) in c.noiseReduction),
  };
}

const key = (s: string) => s.toLowerCase().replace(/fujifilm|fuji/g, "").replace(/[\s_-]+/g, "");

/** The capability entry for a model string ("X100VI", "FUJIFILM X100VI", "x100vi"), or null when unsupported. */
export function cameraFor(model: string | null | undefined): CameraCaps | null {
  if (!model) return null;
  const k = key(model);
  return CAMERAS.find((c) => key(c.id) === k || c.aliases.includes(k)) ?? null;
}

/** "1.10" < "1.2" < "2.0", numerically per part. */
export function firmwareAtLeast(have: string, min: string): boolean {
  const a = have.split(".").map((n) => Number.parseInt(n, 10) || 0);
  const b = min.split(".").map((n) => Number.parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  }
  return true;
}
