// Keep every look a plan proposes to write inside the camera's confirmed settings-file codes (lib/cameras.ts
// `confirmed`). The schema and the prompt already limit the model to them; this is the net under that: a look whose
// film sim, white balance, color or noise reduction isn't confirmed (a reused past look, a model that strayed from the
// schema) gets the closest confirmed value instead, and the plan says so in a plain warning line:
//   Using Reala Ace for "Soft faces"; Astia isn't mapped for your camera yet.
import { type CameraCaps, writable } from "../cameras.js";
import type { DayLook, RecipeFields } from "./types.js";

/** Closest film sims, best first, kept inside colour or B&W. The first confirmed one wins, so a sim mapped later
 *  (Provia, say) takes over from the stand-in on its own. */
export const NEAREST_SIM: Readonly<Record<string, readonly string[]>> = {
  Provia: ["Reala Ace", "Astia", "Pro Neg Std"],
  Velvia: ["Provia", "Reala Ace", "Classic Chrome"],
  Astia: ["Provia", "Reala Ace", "Pro Neg Std"],
  "Classic Chrome": ["Classic Neg", "Eterna Bleach Bypass", "Pro Neg Std"],
  "Reala Ace": ["Provia", "Pro Neg Std", "Astia"],
  "Pro Neg Hi": ["Pro Neg Std", "Reala Ace", "Provia"],
  "Pro Neg Std": ["Pro Neg Hi", "Astia", "Reala Ace"],
  "Classic Neg": ["Classic Chrome", "Nostalgic Neg", "Eterna Bleach Bypass"],
  "Nostalgic Neg": ["Classic Neg", "Classic Chrome", "Pro Neg Std"],
  Eterna: ["Pro Neg Std", "Classic Chrome", "Reala Ace"],
  "Eterna Bleach Bypass": ["Classic Chrome", "Eterna", "Classic Neg"],
  Acros: ["Acros+Ye", "Monochrome", "Acros+G"],
  "Acros+Ye": ["Acros", "Monochrome+Ye", "Acros+G"],
  "Acros+R": ["Monochrome+R", "Acros+Ye", "Acros"],
  "Acros+G": ["Monochrome+G", "Acros", "Acros+Ye"],
  Monochrome: ["Acros", "Acros+Ye", "Monochrome+Ye"],
  "Monochrome+Ye": ["Acros+Ye", "Monochrome", "Acros"],
  "Monochrome+R": ["Acros+R", "Monochrome+Ye", "Acros+Ye"],
  "Monochrome+G": ["Acros+G", "Monochrome", "Acros+Ye"],
  Sepia: ["Monochrome", "Acros", "Acros+Ye"],
};

/** Closest white balances: another mode, or Kelvin at the mode's usual temperature. */
export const NEAREST_WB: Readonly<Record<string, readonly { wb: string; kelvin?: number }[]>> = {
  Auto: [{ wb: "Auto Ambience" }, { wb: "Kelvin", kelvin: 5300 }, { wb: "Daylight" }],
  "Auto Ambience": [{ wb: "Auto" }, { wb: "Kelvin", kelvin: 4900 }, { wb: "Daylight" }],
  Daylight: [{ wb: "Kelvin", kelvin: 5300 }, { wb: "Auto" }],
  Shade: [{ wb: "Kelvin", kelvin: 7700 }, { wb: "Daylight" }, { wb: "Auto" }],
  "Fluorescent 1": [{ wb: "Kelvin", kelvin: 6500 }, { wb: "Auto" }],
  "Fluorescent 2": [{ wb: "Kelvin", kelvin: 3000 }, { wb: "Auto" }],
  "Fluorescent 3": [{ wb: "Kelvin", kelvin: 4000 }, { wb: "Auto" }],
  Incandescent: [{ wb: "Kelvin", kelvin: 3000 }, { wb: "Auto" }],
  Kelvin: [{ wb: "Auto" }],
};

export type Substitution = { field: "film_sim" | "white_balance" | "color" | "noise_reduction"; wanted: string; used: string };

const signed = (v: number) => (v > 0 ? `+${v}` : `${v}`);

/** The film sim a look gets on this camera: itself when confirmed, else the closest confirmed one of the same kind
 *  (colour or B&W). Null when the camera has no confirmed sim of that kind. */
export function nearestSim(sim: string, cam: CameraCaps): string | null {
  const ok = writable(cam).filmSims;
  if (ok.includes(sim)) return sim;
  const mono = cam.monoSims.has(sim);
  const sameKind = ok.filter((s) => cam.monoSims.has(s) === mono);
  return (NEAREST_SIM[sim] ?? []).find((s) => sameKind.includes(s)) ?? sameKind[0] ?? null;
}

function nearestNumber(v: number, allowed: number[]): number | null {
  if (!allowed.length) return null;
  return [...allowed].sort((a, b) => Math.abs(a - v) - Math.abs(b - v) || Math.abs(a) - Math.abs(b))[0];
}

/** Put a look (in place) inside the confirmed codes. Returns what changed; empty when it already was. Only the
 *  values the settings file stores per code are touched: film sim, white balance (+ Kelvin), color, NR. */
export function confirmLook(look: RecipeFields, cam: CameraCaps): Substitution[] {
  const ok = writable(cam);
  const out: Substitution[] = [];
  if (!ok.filmSims.includes(look.film_sim)) {
    const sim = nearestSim(look.film_sim, cam);
    if (sim) {
      out.push({ field: "film_sim", wanted: look.film_sim, used: sim });
      look.film_sim = sim;
    }
  }
  if (!ok.whiteBalances.includes(look.white_balance)) {
    const pick = (NEAREST_WB[look.white_balance] ?? []).find((c) => ok.whiteBalances.includes(c.wb))
      ?? (ok.whiteBalances.length ? { wb: ok.whiteBalances[0] } : null);
    if (pick) {
      const kelvin = pick.wb === "Kelvin" ? (pick.kelvin ?? 5300) : 0;
      out.push({ field: "white_balance", wanted: look.white_balance, used: pick.wb === "Kelvin" ? `Kelvin ${kelvin}K` : pick.wb });
      look.white_balance = pick.wb;
      look.kelvin = kelvin;
    }
  }
  const mono = cam.monoSims.has(look.film_sim);
  if (!mono && !ok.color.includes(look.color)) {
    const c = nearestNumber(look.color, ok.color);
    if (c !== null) {
      out.push({ field: "color", wanted: signed(look.color), used: signed(c) });
      look.color = c;
    }
  }
  if (!ok.noiseReduction.includes(look.noise_reduction)) {
    const nr = nearestNumber(look.noise_reduction, ok.noiseReduction);
    if (nr !== null) {
      out.push({ field: "noise_reduction", wanted: signed(look.noise_reduction), used: signed(nr) });
      look.noise_reduction = nr;
    }
  }
  return out;
}

/** The warning line for one substitution. */
export function substitutionLine(s: Substitution, name: string): string {
  const who = `"${name}"`;
  switch (s.field) {
    case "film_sim": return `Using ${s.used} for ${who}; ${s.wanted} isn't mapped for your camera yet.`;
    case "white_balance": return `Using ${s.used} white balance for ${who}; ${s.wanted} white balance isn't mapped for your camera yet.`;
    case "color": return `Using color ${s.used} for ${who}; color ${s.wanted} isn't mapped for your camera yet.`;
    case "noise_reduction": return `Using noise reduction ${s.used} for ${who}; ${s.wanted} isn't mapped for your camera yet.`;
  }
}

/** The look's settings use only confirmed codes (what the app's writer accepts without the developer switch). */
export function isWritable(look: RecipeFields, cam: CameraCaps): boolean {
  return confirmLook({ ...look }, cam).length === 0;
}

/** Every look the plan writes (status "new") inside the confirmed codes, in place, plus a line when the model wanted
 *  an unconfirmed sim and chose a stand-in itself (`ideals`: lower-cased look name → ideal_film_sim). Kept looks are
 *  never written, so they're left alone. Returns the warning lines (the caller re-finalizes when there are any). */
export function confirmDayLooks(looks: DayLook[], ideals: Map<string, string>, cam: CameraCaps): string[] {
  const lines: string[] = [];
  const ok = writable(cam).filmSims;
  for (const l of looks) {
    if (l.status !== "new") continue;
    const subs = confirmLook(l, cam);
    lines.push(...subs.map((s) => substitutionLine(s, l.name)));
    const ideal = ideals.get(l.name.trim().toLowerCase());
    if (!subs.some((s) => s.field === "film_sim") && ideal && ideal !== l.film_sim && !ok.includes(ideal)) {
      lines.push(substitutionLine({ field: "film_sim", wanted: ideal, used: l.film_sim }, l.name));
    }
  }
  return [...new Set(lines)];
}
