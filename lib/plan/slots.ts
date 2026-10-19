// From the model's answer to a Plan: which looks are kept, which slot each new look goes into, what gets written and
// the cheat sheet. Ported from studio/plan.py (_assemble, assign_slots, _slot_report, finalize, _file_look, put_look).
import type { CameraCaps } from "../cameras.js";
import { cheatSheet, onCamera } from "./cheatsheet.js";
import { expertGuidanceSignature, expertSettingsSignature, recipeDesign } from "./expert-metadata.js";
import { recipeOf, recipeProblems, sameRecipe } from "./looks.js";
import { cameraReuse } from "./palette.js";
import { minutesOf, span } from "./time.js";
import {
  type CameraSlot, type Conditions, type DayLook, type FileLook, type ModelPlan, type ModelStop, type Plan, PlanError,
  type RecipeFields, type SlotLine, type TasteSummary, type Write,
} from "./types.js";

export const KIND = "dialin.plan/1";

/** Past looks the request carried, by lower-cased name. */
export type Library = Map<string, RecipeFields>;

const low = (s: string | null | undefined) => (s ?? "").trim().toLowerCase();

function dayOrder(stops: ModelStop[]): ModelStop[] {
  if (stops.length && stops.every((s) => minutesOf(s.start) !== null)) {
    return [...stops].sort((a, b) => (minutesOf(a.start) as number) - (minutesOf(b.start) as number));
  }
  return [...stops];
}

export function assemble(
  said: string, cond: Conditions, data: ModelPlan, camera: CameraSlot[] | null, tasteBy: Map<string, TasteSummary>,
  lib: Library, cam: CameraCaps,
  protectedSlots: number[] = [],
): Plan {
  const stops = dayOrder(data.stops ?? []);
  const order = new Map(stops.map((s, i) => [low(s.name), i]));
  const looks = [...data.looks].sort((a, b) => (order.get(low(a.stop)) ?? 99) - (order.get(low(b.stop)) ?? 99));
  const camBy = new Map((camera ?? []).filter((s) => s.name).map((s) => [s.name.toLowerCase(), s]));
  const dayLooks: DayLook[] = [];
  for (const l of looks) {
    let rk = low(l.reuse);
    const same = camBy.get(low(l.name));
    if (!rk && same?.recipe && sameRecipe(same.recipe, l)) rk = same.name.toLowerCase(); // a copy of a camera look: kept
    const entry: DayLook = {
      ...recipeOf(l), when: l.when ?? "", tip: l.how ?? "", exposure: l.exposure, stop: l.stop, focus: l.focus,
      drive: l.drive, reason: l.reason ?? "", based_on: (l.based_on ?? "").trim(), reuse: "", slot: null, status: "new",
      replaces: null, recipe_known: true, taste_note: null,
    };
    const design = recipeDesign(l.design, cam);
    if (design) entry.design = { ...design, settings_signature: l.design?.settings_signature ?? expertSettingsSignature(l),
      guidance_signature: l.design?.guidance_signature ?? expertGuidanceSignature(l),
      requires_review: design.requires_review || l.design?.requires_review === true };
    const onCam = rk ? (l.reuse_slot ? cameraReuse(l, camera) : camBy.get(rk)) : undefined;
    if (onCam) { // on the camera: stays in its slot, never written
      Object.assign(entry, { name: onCam.name, reuse: onCam.name, slot: onCam.slot, status: "kept" });
      if (onCam.recipe) {
        const { why, ...rest } = onCam.recipe;
        Object.assign(entry, rest);
        entry.why = why || entry.why;
      } else {
        entry.recipe_known = false;
      }
    } else if (rk && lib.has(rk)) { // a past look, not on the camera: written again as it was
      const r = lib.get(rk) as RecipeFields;
      Object.assign(entry, r, { reuse: r.name, name: r.name });
    }
    const quoteFrom = tasteBy.get(low(entry.reuse || entry.name)) ?? tasteBy.get(low(entry.based_on));
    entry.taste_note = quoteFrom ? quoteFrom.quote : null;
    dayLooks.push(entry);
  }

  const [report, warnings] = assignSlots(dayLooks, camera, tasteBy, data.replace ?? [], protectedSlots);
  const plan: Plan = {
    kind: KIND,
    created_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    said: said.trim(),
    conditions: cond,
    plan: { summary: data.summary ?? "", looks: [] },
    model: null,
    ms: 0,
    count_why: data.count_why ?? "",
    stops: stops.map((s) => ({ name: s.name, start: s.start ?? "", end: s.end ?? "", time: span(s.start ?? "", s.end ?? ""),
      light: s.light ?? "" })),
    day_looks: dayLooks,
    camera: null,
    camera_before: camera,
    slots: report,
    replace_why: Object.fromEntries((data.replace ?? []).filter((r) => r && typeof r === "object").map((r) => [r.name ?? "", r.why ?? ""])),
    taste: [...tasteBy.values()].map((t) => ({ look: t.look, hearted: t.hearted, shot: t.shot, rate: t.rate,
      favorite: t.favorite, quote: t.quote, where: t.where })),
    warnings,
    ...(protectedSlots.length ? { protected_slots: [...protectedSlots] } : {}),
    write: emptyWrite(),
    cheat_sheet: { title: "", stops: [], light_changes: [], footer: "", text: "", chars: 0, fits: true },
  };
  return finalize(plan, cam);
}

const emptyWrite = (): Write => ({ mode: "none", slots: [], rewrites_unchanged: [], why: "", argv: null, per_slot: [], live: [] });

/** Give every new look a slot, in place. Kept looks already have theirs. → (report lines, warnings).
 *
 *  With the camera known: a new look named like a look on the camera replaces that one; the others go into the slots
 *  the model said it's fine to overwrite (least useful first), then the lowest keep rates. Looks they reuse (taste
 *  favorites) are taken last. When the model's choices allow it, the written slots are kept to C1…Ck so one
 *  `dialin-cam load` writes them with nothing rewritten. New looks fill their slots in the order of the day.
 *  Without the camera: C1…CN in the order of the day. */
export function assignSlots(
  dayLooks: DayLook[], camera: CameraSlot[] | null, tasteBy: Map<string, TasteSummary>,
  replacePref: { name?: string; why?: string }[],
  protectedSlots: number[] = [],
): [SlotLine[], string[]] {
  const warnings: string[] = [];
  const fresh = dayLooks.filter((l) => l.status === "new");
  if (camera === null) {
    const available = Array.from({ length: 7 }, (_, i) => i + 1).filter((s) => !protectedSlots.includes(s));
    if (fresh.length > available.length) throw new PlanError("The new looks don't fit beside your protected slots.", "no_room", 502);
    fresh.forEach((l, i) => { l.slot = available[i]; });
    return [slotReport(dayLooks, null), warnings];
  }
  const keptSlots = new Set(dayLooks.filter((l) => l.status === "kept").map((l) => l.slot as number));
  const byName = new Map(camera.filter((s) => s.name).map((s) => [s.name.toLowerCase(), s]));
  const pinned = new Map<number, DayLook>();
  for (const l of fresh) {
    const s = byName.get(l.name.toLowerCase());
    if (s && !protectedSlots.includes(s.slot) && !keptSlots.has(s.slot) && !pinned.has(s.slot)) pinned.set(s.slot, l);
  }
  const pinnedLooks = new Set(pinned.values());
  const rest = fresh.filter((l) => !pinnedLooks.has(l));
  const free = camera.filter((s) => !protectedSlots.includes(s.slot) && !keptSlots.has(s.slot) && !pinned.has(s.slot));

  const fav = (s: CameraSlot) => Boolean(s.name && tasteBy.get(s.name.toLowerCase())?.favorite);
  const score = (s: CameraSlot) => (s.name ? tasteBy.get(s.name.toLowerCase())?.score ?? 0.16 : -1);
  const byScore = (a: CameraSlot, b: CameraSlot) => score(a) - score(b) || a.slot - b.slot;

  const pref = replacePref.filter((r) => r && typeof r === "object").map((r) => low(String(r.name ?? "")));
  const approved = free.filter((s) => s.name && pref.includes(s.name.toLowerCase()) && !fav(s))
    .sort((a, b) => pref.indexOf(a.name.toLowerCase()) - pref.indexOf(b.name.toLowerCase()));
  const empties = free.filter((s) => !s.name);
  const inA = new Set(approved.map((s) => s.slot));
  const inE = new Set(empties.map((s) => s.slot));
  const others = free.filter((s) => !inA.has(s.slot) && !inE.has(s.slot) && !fav(s)).sort(byScore);
  const favs = free.filter(fav).sort(byScore);
  const ranked = [...empties, ...approved, ...others, ...favs];
  const need = rest.length;
  if (need > ranked.length) {
    throw new PlanError(`${fresh.length} new looks don't fit beside the ${keptSlots.size} kept ones.`, "no_room", 502);
  }
  let chosen = ranked.slice(0, need);

  // Prefer C1…Ck (one `load`, nothing rewritten) when that only uses slots that are empty, model-approved or already
  // chosen, and keeps every kept look and every pinned rebuild inside or above it as it should.
  const total = need + pinned.size;
  const prefix = new Set(Array.from({ length: total }, (_, i) => i + 1));
  const okPool = new Set([...empties, ...approved, ...chosen].map((s) => s.slot));
  const pinnedInPrefix = [...pinned.keys()].every((k) => prefix.has(k));
  const keptInPrefix = [...prefix].some((k) => keptSlots.has(k));
  const restOfPrefix = [...prefix].filter((k) => !pinned.has(k));
  if (pinnedInPrefix && !keptInPrefix && restOfPrefix.every((k) => okPool.has(k))) {
    chosen = camera.filter((s) => restOfPrefix.includes(s.slot));
  }
  const favSlots = new Set(favs.map((s) => s.slot));
  if (favs.length && chosen.some((s) => favSlots.has(s.slot))) {
    warnings.push(`not enough room, so a look you reuse gets replaced: ${chosen.filter((s) => favSlots.has(s.slot)).map((s) => s.name).join(", ")}`);
  }
  const sorted = [...chosen].sort((a, b) => a.slot - b.slot);
  rest.forEach((l, i) => {
    const s = sorted[i];
    if (!s) return;
    l.slot = s.slot;
    l.replaces = s.name || null;
  });
  for (const [slot, l] of pinned) {
    l.slot = slot;
    l.replaces = camera[slot - 1].name;
  }
  return [slotReport(dayLooks, camera), warnings];
}

/** One line per slot that matters today: new ones (what they replace) and kept ones. */
export function slotReport(dayLooks: DayLook[], camera: CameraSlot[] | null): SlotLine[] {
  return [...dayLooks].sort((a, b) => (a.slot ?? 9) - (b.slot ?? 9)).map((l) => {
    const c = `C${l.slot}`;
    let line: string;
    if (l.status === "kept") line = `${c} ${l.name}: yours, kept`;
    else if (camera === null) line = `${c} ${l.name}: new (what's in ${c} now is backed up first)`;
    else if (l.replaces && l.replaces.toLowerCase() === l.name.toLowerCase()) line = `${c} ${l.name}: rebuilt for today, replaces ${c} '${l.replaces}'`;
    else if (l.replaces) line = `${c} ${l.name}: new, replaces ${c} '${l.replaces}'`;
    else line = `${c} ${l.name}: new, into the empty ${c}`;
    return { slot: l.slot, name: l.name, status: l.status, replaces: l.replaces, line };
  });
}

/** One look as the plan file carries it: Recipe + DayLook (when, tip, exposure) + extras. */
export function fileLook(l: DayLook, slot: number, cam: CameraCaps): FileLook {
  return {
    ...recipeOf(l), when: l.when, tip: l.tip, exposure: { ...l.exposure }, slot, status: l.status,
    replaces: l.replaces ?? null, stop: l.stop, focus: l.focus, drive: l.drive, on_camera: onCamera(l, cam),
    reason: l.reason ?? "", based_on: l.based_on ?? "", taste_note: l.taste_note ?? null,
  };
}

const AUTO_EXPOSURE = { aperture: "A", shutter: "A", iso: "A", exp_comp: "0", nd: false };

/** Derive everything from plan.day_looks (the one source of truth): plan.looks (what `dialin-cam load` writes,
 *  C1…Ck in slot order), camera (C1–C7 after writing), write (mode + slots) and cheat_sheet.
 *  onlySlots limits the write to those slots (an adjustment writes one). */
export function finalize(plan: Plan, cam: CameraCaps, onlySlots: number[] | null = null): Plan {
  const day = plan.day_looks;
  const before = plan.camera_before;
  if (day.some((l) => l.status === "new" && plan.protected_slots?.includes(l.slot as number))) {
    throw new PlanError("A protected slot cannot be written.", "protected_slot", 400);
  }
  plan.slots = slotReport(day, before);
  const bySlot = new Map(day.filter((l) => l.slot).map((l) => [l.slot as number, l]));
  const written = [...bySlot.entries()]
    .filter(([s, l]) => l.status === "new" && (onlySlots === null || onlySlots.includes(s)))
    .map(([s]) => s).sort((a, b) => a - b);
  const k = written.length ? Math.max(...written) : 0;

  const looks: FileLook[] = [];
  const rewrites: string[] = [];
  const unknown: string[] = [];
  const protectedInPrefix = (plan.protected_slots ?? []).filter((s) => s <= k);
  for (let s = 1; s <= k; s++) {
    const l = bySlot.get(s);
    if (l && written.includes(s)) {
      looks.push(fileLook(l, s, cam));
      continue;
    }
    const name = l ? l.name : before ? before[s - 1].name : "";
    const recipe = l ? (l.recipe_known ? recipeOf(l) : null) : before ? before[s - 1].recipe : null;
    if (recipe && !recipeProblems(recipe, cam).length) {
      looks.push({
        ...recipe, name, when: l ? l.when : "Stays as it is", tip: l ? l.tip : "", exposure: l ? l.exposure : { ...AUTO_EXPOSURE },
        slot: s, status: "unchanged", rewrite: true,
      });
      rewrites.push(`C${s} ${name}`);
    } else {
      unknown.push(`C${s} ${name || "(empty)"}`);
    }
  }
  const mode: Write["mode"] = !written.length ? "none" : unknown.length || protectedInPrefix.length || onlySlots !== null ? "per_slot" : "load";
  // plan.looks is what `dialin-cam load` would write, C1…Ck. When a slot in that range can't be rewritten (settings
  // unknown) it is empty, so a stray `load` refuses ("plan has no looks") instead of writing the wrong slots.
  plan.plan.looks = unknown.length || protectedInPrefix.length ? [] : looks;
  plan.write = {
    mode, slots: written, rewrites_unchanged: mode === "load" ? rewrites : [],
    why: mode !== "per_slot" ? ""
      : onlySlots !== null ? "one slot at a time"
      : protectedInPrefix.length ? `Only new slots change; ${protectedInPrefix.map((s) => `C${s}`).join(", ")} ${protectedInPrefix.length === 1 ? "stays" : "stay"} protected. A positional load is unavailable.`
      : `dialin-cam load writes C1 onwards, and ${unknown.join(", ")} can't be rewritten (its settings aren't known), so `
        + "each new look is written into its own slot",
    argv: null, per_slot: [], live: [],
  };
  plan.camera = Array.from({ length: cam.slots }, (_, i) => {
    const s = i + 1;
    const l = bySlot.get(s);
    return l ? { slot: s, name: l.name, status: l.status as string } : { slot: s, name: before ? before[s - 1]?.name ?? "" : "", status: "untouched" };
  });
  plan.cheat_sheet = cheatSheet(plan, cam);
  return plan;
}

/** A copy of the plan with `look` (from adjustLook) in its slot, before or after the plan was written. Every status
 *  stays relative to the camera as it was before this plan touched it (camera_before), so the look replaces the
 *  slot's original look and "put the old ones back" still means the originals. The cheat sheet is re-rendered. */
export function putLook(plan: Plan, look: DayLook, cam: CameraCaps): Plan {
  const next = structuredClone(plan);
  const slot = Number(look.slot);
  if (next.protected_slots?.includes(slot)) throw new PlanError(`C${slot} is protected and stays as it is.`, "protected_slot", 400);
  const before = next.camera_before;
  const put: DayLook = { ...structuredClone(look), status: "new", replaces: before ? before[slot - 1].name || null : null, reuse: "" };
  const old = next.day_looks.find((l) => l.slot === slot);
  next.day_looks = [...next.day_looks.filter((l) => l.slot !== slot), put];
  const order = new Map((next.stops ?? []).map((s, i) => [low(s.name), i]));
  next.day_looks.sort((a, b) => (order.get(low(a.stop)) ?? 99) - (order.get(low(b.stop)) ?? 99) || (a.slot ?? 9) - (b.slot ?? 9));
  next.slots = slotReport(next.day_looks, before);
  next.adjustments = [...(next.adjustments ?? []), { slot, said: look.adjusted?.said ?? null, change: look.change ?? null,
    was: old ? old.name : null, name: put.name }];
  return finalize(next, cam);
}
