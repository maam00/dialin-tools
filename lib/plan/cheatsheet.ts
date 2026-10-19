// The cheat sheet: per stop in the order of the day, which C to pick, what to set by hand, how to shoot it and when
// the light changes, plus the same in one phone text. Slots hold the look only; exposure, ISO, focus and drive are
// dials, so this is where the person learns what to turn. Ported from studio/plan.py (on_camera … _sms).
import type { CameraCaps } from "../cameras.js";
import { clock, h12, hhmm, minutesOf, shortDate } from "./time.js";
import type { CheatRow, CheatSheet, CheatStop, Conditions, DayLook, Plan } from "./types.js";

export const TEXT_MAX = 420; // "Text me this": one phone screen, one bubble

const WORDS: Record<number, string> = { 1: "one", 2: "two", 3: "three" };
const FOCUS: Record<string, string> = { S: "S, for still things", C: "C, for moving things", M: "M, zone focus by hand" };
const DRIVE: Record<string, string> = { S: "S, single shots", CL: "CL, slow burst", CH: "CH, fast burst" };

/** "+1⅔" → 5 (thirds of a stop). */
export function thirds(comp: string): number {
  const s = comp.replace(/−/g, "-");
  const sign = s.startsWith("-") ? -1 : 1;
  let whole = 0;
  let frac = 0;
  for (const ch of s.replace(/^[+-]+/, "")) {
    if (/\d/.test(ch)) whole = whole * 10 + Number(ch);
    else if (ch === "⅓") frac = 1;
    else if (ch === "⅔") frac = 2;
  }
  return sign * (whole * 3 + frac);
}

const comp = (c: string) => c.replace(/-/g, "−");

type LookLike = Pick<DayLook, "exposure"> & { focus?: string; drive?: string };

/** What to set by hand for this look, naming the camera's real controls. With prev (the look before it in the day),
 *  the ND line also says when to turn it back off. */
export function onCamera(look: LookLike, cam: CameraCaps, prev: LookLike | null = null): string[] {
  const L = cam.labels;
  const e = look.exposure;
  const t = thirds(e.exp_comp);
  let dial: string;
  if (t === 0) {
    dial = `${L.expDial}: 0`;
  } else {
    const n = Math.abs(t);
    dial = `${L.expDial}: ${comp(e.exp_comp)} (${WORDS[n] ?? String(n)} click${n > 1 ? "s" : ""} ${t > 0 ? "above" : "below"} 0)`;
  }
  if (e.aperture !== "A" && e.shutter !== "A" && e.iso !== "A") dial += ", full manual";
  const lines = [
    dial,
    `${L.aperture}: ${e.aperture !== "A" ? e.aperture : "A (the camera picks)"}`,
    `${L.shutter}: ${e.shutter !== "A" ? e.shutter : "A (the camera picks)"}`,
    `${L.iso}: ${e.iso !== "A" ? e.iso : "A (check your Auto ISO limits)"}`,
    `${L.focus}: ${FOCUS[look.focus ?? "S"] ?? FOCUS.S}`,
    `${L.drive}: ${DRIVE[look.drive ?? "S"] ?? DRIVE.S}`,
  ];
  if (e.nd) lines.push(`${L.nd}: ON (bright light at a wide aperture)`);
  else if (prev?.exposure.nd) lines.push(`${L.nd}: OFF again`);
  return lines;
}

/** The one line: "Exposure dial +⅔ · f/8 · 1/500 · ISO A" (+ ND, focus, drive when not the default). */
export function dialLine(look: LookLike, cam: CameraCaps): string {
  const e = look.exposure;
  const bits = [`${cam.labels.expDial} ${comp(e.exp_comp)}`, e.aperture !== "A" ? e.aperture : "aperture A",
    e.shutter !== "A" ? e.shutter : "shutter A", `ISO ${e.iso}`];
  if (e.nd) bits.push("ND on");
  if (look.focus === "C" || look.focus === "M") bits.push(`focus ${look.focus}`);
  if (look.drive === "CL" || look.drive === "CH") bits.push(`${look.drive} burst`);
  return bits.join(" · ");
}

function smsSettings(look: LookLike, isoAllAuto: boolean): string {
  const e = look.exposure;
  const bits = [`Exp ${comp(e.exp_comp)}`, e.aperture !== "A" ? e.aperture : "aperture A",
    e.shutter !== "A" ? e.shutter : "shutter A"];
  if (!isoAllAuto) bits.push(`ISO ${e.iso}`);
  if (e.nd) bits.push("ND on");
  if (look.focus === "C" || look.focus === "M") bits.push(`focus ${look.focus}`);
  if (look.drive === "CL" || look.drive === "CH") bits.push(look.drive);
  return bits.join(", ");
}

function lightEvents(cond: Conditions): [number, string][] {
  const ev: [number | null, string][] = [];
  const hours = new Map((cond.hours ?? []).map((h) => [h.h, h]));
  if (cond.sunrise) ev.push([minutesOf(cond.sunrise), `Sunrise ${h12(cond.sunrise)}`]);
  if (cond.sunset) {
    const ss = minutesOf(cond.sunset) as number;
    const golden = hours.get(Math.floor((ss - 60) / 60));
    const glow = golden && golden.cloud >= 80 ? "Light fades from" : "Golden light from"; // no gold under full cloud
    ev.push([ss - 60, `${glow} ${h12(hhmm(ss - 60))}`], [ss, `Sunset ${h12(cond.sunset)}`],
      [ss + 30, `Dark by ${h12(hhmm(ss + 30))}`]);
  }
  let prevRain = false;
  for (const h of cond.hours ?? []) {
    const wet = h.rain >= 50 || ((h.code ?? 0) >= 51 && h.rain >= 30);
    if (wet && !prevRain && h.h >= 6 && h.h <= 22) ev.push([h.h * 60, `Rain likely from ${clock(hhmm(h.h * 60))}`]);
    else if (prevRain && !wet && h.h >= 6 && h.h <= 22) ev.push([h.h * 60, `Rain eases by ${clock(hhmm(h.h * 60))}`]);
    prevRain = wet;
  }
  return (ev.filter((e) => e[0] !== null) as [number, string][])
    .sort((a, b) => a[0] - b[0] || (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
}

export function cheatSheet(plan: Pick<Plan, "conditions" | "stops" | "day_looks">, cam: CameraCaps): CheatSheet {
  const cond = plan.conditions ?? ({} as Conditions);
  const stops = plan.stops ?? [];
  const looks = plan.day_looks;
  const events = lightEvents(cond);
  const spans = stops.map((s) => [minutesOf(s.start), minutesOf(s.end)] as const);
  const timed = stops.length > 0 && spans.every(([a, b]) => a !== null && b !== null);
  const used = new Set<number>();
  const outStops: CheatStop[] = [];
  let prevLook: DayLook | null = null;
  stops.forEach((s, i) => {
    const changes: string[] = [];
    if (timed) {
      const [a, b] = spans[i] as [number, number];
      const prevEnd = i ? (spans[i - 1][1] as number) : a - 60; // anything since the last stop is news at this one
      events.forEach(([t, label], j) => {
        if (!used.has(j) && prevEnd < t && t <= b) {
          changes.push(label);
          used.add(j);
        }
      });
    }
    const mine = looks.filter((l) => l.stop.trim().toLowerCase() === s.name.trim().toLowerCase());
    // Looks at one stop are alternatives, so "ND off again" is against the last stop's main look.
    const rows: CheatRow[] = mine.map((l) => ({
      slot: l.slot as number, c: `C${l.slot}`, name: l.name, status: l.status,
      saved: l.status === "new" ? `Saved to C${l.slot}` : `Already in C${l.slot}`, replaces: l.replaces ?? null,
      change: onCamera(l, cam, prevLook), dial_line: dialLine(l, cam), how: l.tip, when: l.when, reason: l.reason ?? "",
      taste_note: l.taste_note ?? null,
    }));
    prevLook = mine[0] ?? prevLook;
    outStops.push({ name: s.name, time: s.time ?? "", light: s.light ?? "", light_changes: changes, looks: rows });
  });
  const tail = !timed && cond.sunset ? [`Sunset ${h12(cond.sunset)}`] : [];
  const isoAuto = looks.every((l) => l.exposure.iso === "A");
  const footer = `${isoAuto ? "ISO A all day. " : ""}${cam.labels.pickSlot}`;
  const t = title(cond);
  const text = sms(t, outStops, tail, isoAuto, looks);
  return { title: t, stops: outStops, light_changes: tail, footer, text, chars: text.length, fits: text.length <= TEXT_MAX };
}

function title(cond: Partial<Conditions>): string {
  const day = shortDate(cond.date ?? "") ?? "Today";
  const place = (cond.place?.name ?? "").split(",")[0].trim();
  return place ? `${day} · ${place}` : day;
}

/** The one-text version, shortened step by step until it fits. */
function sms(t: string, stops: CheatStop[], tail: string[], isoAuto: boolean, looks: DayLook[]): string {
  const bySlot = new Map(looks.map((l) => [l.slot, l]));
  const render = (level: number) => {
    const lines = [t];
    for (const s of stops) {
      const chs = s.light_changes.filter((ch) => level < 2 || ch.startsWith("Sunset") || ch.startsWith("Rain"));
      if (chs.length) lines.push(`${[chs[0], ...chs.slice(1).map((c) => c.slice(0, 1).toLowerCase() + c.slice(1))].join(", ")}.`);
      const head = s.name + (s.time && level < 1 ? ` ${s.time}` : "");
      s.looks.forEach((r, i) => {
        const l = bySlot.get(r.slot) as DayLook;
        const settings = smsSettings(l, isoAuto);
        if (i === 0) {
          lines.push(level < 4 ? `${head}: ${r.c} ${r.name}. ${settings}.` : `${head}: ${r.c} ${r.name} ${settings.replace("Exp ", "")}`);
        } else if (level >= 3) {
          lines.push(`Or ${r.c} ${r.name}.`);
        } else {
          lines.push(`Or ${r.c} ${r.name}. ${settings}.`);
        }
      });
    }
    if (level < 2) lines.push(...tail.map((x) => `${x}.`));
    if (isoAuto) lines.push("ISO A all day.");
    return lines.join("\n");
  };
  let text = render(0);
  for (let level = 1; level < 5; level++) {
    if (text.length <= TEXT_MAX) break;
    text = render(level);
  }
  if (text.length > TEXT_MAX) {
    const cut = text.slice(0, TEXT_MAX - 1);
    const nl = cut.lastIndexOf("\n");
    text = `${nl >= 0 ? cut.slice(0, nl) : cut}\n…`;
  }
  return text;
}
