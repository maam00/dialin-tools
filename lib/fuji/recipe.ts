// A "look" in human terms (what the AI writes and what the camera menu shows),
// plus the mapping to FilmKit's preset values that get encoded into D18E–D1A5.
import { FilmSim, GrainEffect, MONOCHROME_SIMS, WBMode } from "./vendor/enums.js";
import type { PresetUIValues } from "./vendor/preset-translate.js";

export const FILM_SIMS = {
  Provia: FilmSim.Provia,
  Velvia: FilmSim.Velvia,
  Astia: FilmSim.Astia,
  "Classic Chrome": FilmSim.ClassicChrome,
  "Reala Ace": FilmSim.RealaAce,
  "Pro Neg Hi": FilmSim.ProNegHi,
  "Pro Neg Std": FilmSim.ProNegStd,
  "Classic Neg": FilmSim.ClassicNeg,
  "Nostalgic Neg": FilmSim.NostalgicNeg,
  Eterna: FilmSim.Eterna,
  "Eterna Bleach Bypass": FilmSim.EternaBleach,
  Acros: FilmSim.Acros,
  "Acros+Ye": FilmSim.AcrosYe,
  "Acros+R": FilmSim.AcrosR,
  "Acros+G": FilmSim.AcrosG,
  Monochrome: FilmSim.Monochrome,
  "Monochrome+Ye": FilmSim.MonochromeYe,
  "Monochrome+R": FilmSim.MonochromeR,
  "Monochrome+G": FilmSim.MonochromeG,
  Sepia: FilmSim.Sepia,
} as const;

export const WHITE_BALANCES = {
  Auto: WBMode.Auto,
  "Auto Ambience": WBMode.AmbiencePriority,
  Daylight: WBMode.Daylight,
  Shade: WBMode.Shade,
  "Fluorescent 1": WBMode.Fluorescent1,
  "Fluorescent 2": WBMode.Fluorescent2,
  "Fluorescent 3": WBMode.Fluorescent3,
  Incandescent: WBMode.Incandescent,
  Kelvin: WBMode.ColorTemp,
} as const;

export const GRAINS = {
  Off: GrainEffect.Off,
  "Weak Small": GrainEffect.WeakSmall,
  "Strong Small": GrainEffect.StrongSmall,
  "Weak Large": GrainEffect.WeakLarge,
  "Strong Large": GrainEffect.StrongLarge,
} as const;

export const EFFECTS = { Off: 0, Weak: 1, Strong: 2 } as const;
export const DYNAMIC_RANGES = { DR100: 1, DR200: 2, DR400: 3 } as const;
export const DR_MIN_ISO = { DR100: 125, DR200: 250, DR400: 500 } as const;
export const KELVINS = [0, 2500, 2800, 3000, 3200, 3500, 3800, 4000, 4300, 4500, 4900, 5000, 5300, 5600, 5900, 6300, 6500, 6700, 7100, 7700, 8300, 9100, 10000];

const range = (lo: number, hi: number, step = 1) =>
  Array.from({ length: Math.round((hi - lo) / step) + 1 }, (_, i) => Math.round((lo + i * step) * 10) / 10);
export const TONES = range(-2, 4, 0.5);
export const SHIFTS = range(-9, 9);
export const PLUS4 = range(-4, 4);
export const PLUS5 = range(-5, 5);

export type Recipe = {
  name: string;
  film_sim: keyof typeof FILM_SIMS;
  grain: keyof typeof GRAINS;
  color_chrome: keyof typeof EFFECTS;
  color_chrome_fx_blue: keyof typeof EFFECTS;
  white_balance: keyof typeof WHITE_BALANCES;
  kelvin: number;
  wb_shift_r: number;
  wb_shift_b: number;
  dynamic_range: keyof typeof DYNAMIC_RANGES;
  highlight: number;
  shadow: number;
  color: number;
  sharpness: number;
  noise_reduction: number;
  clarity: number;
  why: string;
};

export const RECIPE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "name", "film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "kelvin",
    "wb_shift_r", "wb_shift_b", "dynamic_range", "highlight", "shadow", "color", "sharpness",
    "noise_reduction", "clarity", "why",
  ],
  properties: {
    name: { type: "string", description: "Short slot name the camera shows, max 14 plain ASCII characters." },
    film_sim: { type: "string", enum: Object.keys(FILM_SIMS) },
    grain: { type: "string", enum: Object.keys(GRAINS) },
    color_chrome: { type: "string", enum: Object.keys(EFFECTS) },
    color_chrome_fx_blue: { type: "string", enum: Object.keys(EFFECTS) },
    white_balance: { type: "string", enum: Object.keys(WHITE_BALANCES) },
    kelvin: { type: "integer", enum: KELVINS, description: "Only used when white_balance is Kelvin; otherwise 0." },
    wb_shift_r: { type: "integer", enum: SHIFTS },
    wb_shift_b: { type: "integer", enum: SHIFTS },
    dynamic_range: { type: "string", enum: Object.keys(DYNAMIC_RANGES) },
    highlight: { type: "number", enum: TONES },
    shadow: { type: "number", enum: TONES },
    color: { type: "integer", enum: PLUS4, description: "Ignored for B&W film sims; use 0." },
    sharpness: { type: "integer", enum: PLUS4 },
    noise_reduction: { type: "integer", enum: PLUS4 },
    clarity: { type: "integer", enum: PLUS5 },
    why: { type: "string", description: "What this look does to this shot, max 12 words." },
  },
} as const;

/** Camera-safe slot name: ASCII only, max 14 chars. */
export function slotName(name: string): string {
  return name.normalize("NFKD").replace(/[^\x20-\x7e]/g, "").trim().slice(0, 14) || "AI Look";
}

export function recipeToPresetValues(r: Recipe): PresetUIValues {
  const filmSimulation = FILM_SIMS[r.film_sim];
  const mono = MONOCHROME_SIMS.has(filmSimulation);
  const whiteBalance = WHITE_BALANCES[r.white_balance];
  return {
    filmSimulation,
    dynamicRange: DYNAMIC_RANGES[r.dynamic_range],
    grainEffect: GRAINS[r.grain],
    smoothSkin: 0,
    colorChrome: EFFECTS[r.color_chrome],
    colorChromeFxBlue: EFFECTS[r.color_chrome_fx_blue],
    whiteBalance,
    wbShiftR: r.wb_shift_r,
    wbShiftB: r.wb_shift_b,
    wbColorTemp: whiteBalance === WBMode.ColorTemp ? r.kelvin || 5500 : 0,
    highlightTone: r.highlight,
    shadowTone: r.shadow,
    color: mono ? 0 : r.color,
    sharpness: r.sharpness,
    noiseReduction: r.noise_reduction,
    clarity: r.clarity,
    exposure: 0,
    dRangePriority: 0,
    monoWC: 0,
    monoMG: 0,
  };
}

const invert = <T extends Record<string, number>>(m: T) =>
  Object.fromEntries(Object.entries(m).map(([k, v]) => [v, k])) as Record<number, keyof T>;
const SIM_NAMES = invert(FILM_SIMS);
const WB_NAMES = invert(WHITE_BALANCES);
const GRAIN_NAMES = invert(GRAINS);
const EFFECT_NAMES = invert(EFFECTS);
const DR_NAMES = invert(DYNAMIC_RANGES);

/** For printing what's in a slot (backup / read-back). */
export function presetValuesToText(v: PresetUIValues): string {
  const wb = WB_NAMES[v.whiteBalance] ?? `WB 0x${v.whiteBalance.toString(16)}`;
  const kelvin = v.whiteBalance === WBMode.ColorTemp ? ` ${v.wbColorTemp}K` : "";
  return [
    SIM_NAMES[v.filmSimulation] ?? `sim ${v.filmSimulation}`,
    `${DR_NAMES[v.dynamicRange] ?? "DR?"}`,
    `grain ${GRAIN_NAMES[v.grainEffect] ?? v.grainEffect}`,
    `CC ${EFFECT_NAMES[v.colorChrome]}/${EFFECT_NAMES[v.colorChromeFxBlue]}`,
    `${wb}${kelvin} R${v.wbShiftR} B${v.wbShiftB}`,
    `H${v.highlightTone} S${v.shadowTone} C${v.color} Sh${v.sharpness} NR${v.noiseReduction} Cl${v.clarity}`,
  ].join(" · ");
}
