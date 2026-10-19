// The confirmed settings-file codes (lib/cameras.ts `X100VI_CONFIRMED`, the single source of truth) and the two
// places that must agree with it: the Swift mirror (DialInCamera ConfirmedCodes.swift, rendered from it) and the slot
// map the Python writer reads (ble/maps/x100vi-fw110.json). Never touches a camera.
//
//   npm run codes -- check                     exit 1 when the Swift block or the slot map disagree with lib/cameras.ts
//   npm run codes -- render                    rewrite both rendered blocks from lib/cameras.ts (after a hand edit)
//   npm run codes -- merge <codes.json>        show what a `dialin-cam map-codes` result would add (changes nothing)
//   npm run codes -- merge <codes.json> --write   add it to lib/cameras.ts, ConfirmedCodes.swift and the slot map, and
//                                              regenerate the Swift patcher's golden vectors from the Python writer
//
// `check` also runs inside `npm run test:plan` (tests/plan/confirmed.test.ts).
import { spawnSync } from "node:child_process";
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type ConfirmedCodes, type SeenCode, X100VI, X100VI_CONFIRMED } from "../lib/cameras.js";
import { FILM_SIMS, WHITE_BALANCES } from "../lib/fuji/recipe.js";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const PATHS = {
  ts: "lib/cameras.ts",
  swift: "ios/DialInCamera/Sources/DialInCamera/SettingsFile/ConfirmedCodes.swift",
  map: "ble/maps/x100vi-fw110.json",
  vectors: "ios/DialInCamera/Tests/make-look-patch-vectors.py",
  vectorsOut: "ios/DialInCamera/Tests/DialInCameraTests/Fixtures/look-patch-vectors.json",
};
const MODEL = "X100VI";
const SETTINGS_SIZE = 70524;
const OPEN = `// <codes:${MODEL}>`;
const CLOSE = `// </codes:${MODEL}>`;

const simOrder = Object.keys(FILM_SIMS);
const wbOrder = Object.keys(WHITE_BALANCES);
const byOrder = (order: string[]) => (a: string, b: string) => order.indexOf(a) - order.indexOf(b);
const byNumber = (a: string, b: string) => Number(a) - Number(b);
const ptpSim = (name: string) => (FILM_SIMS as Record<string, number>)[name];
const ptpWB = (name: string) => (WHITE_BALANCES as Record<string, number>)[name];
/** Python's str(float(v)): the slot map's key for a Color value. */
const pyFloat = (v: number) => (Number.isInteger(v) ? v.toFixed(1) : String(v));

// ================================================================== rendering

const q = (s: string) => JSON.stringify(s);
const swiftString = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;

/** The Swift block: ConfirmedCodes.x100vi, codes only (the evidence stays in lib/cameras.ts). */
export function renderSwift(c: ConfirmedCodes): string {
  const sims = Object.keys(c.filmSims).sort(byOrder(simOrder));
  const wbs = Object.keys(c.whiteBalances).sort(byOrder(wbOrder));
  const dict = (lines: string[]) => (lines.length ? `[\n${lines.map((l) => `            ${l},`).join("\n")}\n        ]` : "[:]");
  const flat = (rec: Readonly<Record<string, SeenCode>>) => {
    const keys = Object.keys(rec).sort(byNumber);
    return keys.length ? `[${keys.map((k) => `${Number(k)}: ${rec[k].code}`).join(", ")}]` : "[:]";
  };
  return [
    `${OPEN} rendered from lib/cameras.ts X100VI_CONFIRMED by \`npm run codes -- render\`. Don't edit by hand.`,
    "extension ConfirmedCodes {",
    `    /// ${c.layout}. The evidence for every code is in lib/cameras.ts.`,
    "    public static let x100vi = ConfirmedCodes(",
    `        model: ${swiftString(MODEL)},`,
    `        layout: ${swiftString(c.layout)},`,
    `        firmware: [${c.firmware.map(swiftString).join(", ")}],`,
    `        filmSims: ${dict(sims.map((s) => `${swiftString(s)}: ${c.filmSims[s].code}`))},`,
    `        whiteBalances: ${dict(wbs.map((w) => `${swiftString(w)}: WB(code: ${c.whiteBalances[w].code}, shiftEntry: ${c.whiteBalances[w].shiftEntry})`))},`,
    `        colors: ${flat(c.color)},`,
    `        noiseReductions: ${flat(c.noiseReduction)}`,
    "    )",
    "}",
    CLOSE,
  ].join("\n");
}

/** The lib/cameras.ts block, in the canonical form `merge --write` writes. */
export function renderTs(c: ConfirmedCodes): string {
  const rec = (name: string, keys: string[], line: (k: string) => string) =>
    keys.length ? [`  ${name}: {`, ...keys.map((k) => `    ${q(k)}: ${line(k)},`), "  },"] : [`  ${name}: {},`];
  return [
    `${OPEN} \`npm run codes -- merge <codes.json> --write\` re-renders this block. Hand edits are fine; keep the shape.`,
    `export const ${MODEL}_CONFIRMED: ConfirmedCodes = {`,
    `  layout: ${q(c.layout)},`,
    `  firmware: [${c.firmware.map(q).join(", ")}],`,
    ...rec("sources", Object.keys(c.sources), (k) => q(c.sources[k])),
    ...rec("filmSims", Object.keys(c.filmSims).sort(byOrder(simOrder)),
      (k) => `{ code: ${c.filmSims[k].code}, seen: ${q(c.filmSims[k].seen)} }`),
    ...rec("whiteBalances", Object.keys(c.whiteBalances).sort(byOrder(wbOrder)),
      (k) => `{ code: ${c.whiteBalances[k].code}, shiftEntry: ${c.whiteBalances[k].shiftEntry}, seen: ${q(c.whiteBalances[k].seen)} }`),
    ...rec("color", Object.keys(c.color).sort(byNumber), (k) => `{ code: ${c.color[k].code}, seen: ${q(c.color[k].seen)} }`),
    ...rec("noiseReduction", Object.keys(c.noiseReduction).sort(byNumber),
      (k) => `{ code: ${c.noiseReduction[k].code}, seen: ${q(c.noiseReduction[k].seen)} }`),
    ...rec("wholeRange", Object.keys(c.wholeRange), (k) => q(c.wholeRange[k])),
    "};",
    CLOSE,
  ].join("\n");
}

/** The block between the markers (inclusive), or null when the file has none. */
export function block(text: string): string | null {
  const lines = text.split("\n");
  const a = lines.findIndex((l) => l.startsWith(OPEN));
  const b = lines.findIndex((l, i) => i > a && l.startsWith(CLOSE));
  return a < 0 || b < 0 ? null : lines.slice(a, b + 1).join("\n");
}

export function replaceBlock(text: string, next: string): string {
  const cur = block(text);
  if (cur === null) throw new Error(`no ${OPEN} … ${CLOSE} block`);
  return text.replace(cur, next);
}

// ================================================================== the slot map (ble/maps/x100vi-fw110.json)

type Enc = Record<string, unknown> & {
  map?: Record<string, number>;
  inferred?: Record<string, number>;
  index_by_ptp?: Record<string, number>;
  index_by_raw?: Record<string, number>;
  observed_indices?: number[];
};
type MapField = Record<string, unknown> & { encoding: Enc; observed_values?: Record<string, number>; evidence?: string };
export type SlotMap = Record<string, unknown> & { fields: Record<string, MapField> };

const sameRecord = (a: Record<string, number> = {}, b: Record<string, number> = {}) =>
  Object.keys(a).length === Object.keys(b).length && Object.entries(a).every(([k, v]) => b[k] === v);
const show = (r: Record<string, number> = {}) => JSON.stringify(Object.fromEntries(Object.entries(r).sort()));

/** What the slot map must say for these codes: `map` = exactly the confirmed codes, keyed as correlate.py keys them. */
export function expectedMapCodes(c: ConfirmedCodes) {
  return {
    film_sim: Object.fromEntries(Object.entries(c.filmSims).map(([s, v]) => [String(ptpSim(s)), v.code])),
    white_balance: Object.fromEntries(Object.entries(c.whiteBalances).map(([w, v]) => [String(ptpWB(w)), v.code])),
    shift_entries: Object.fromEntries(Object.entries(c.whiteBalances).map(([w, v]) => [String(ptpWB(w)), v.shiftEntry])),
    color: Object.fromEntries(Object.entries(c.color).map(([k, v]) => [pyFloat(Number(k)), v.code])),
    nr: Object.fromEntries(Object.entries(c.noiseReduction).map(([k, v]) => [String(Number(k)), v.code])),
  };
}

/** Disagreements between the confirmed codes and the slot map, in words. Empty = they agree. */
export function mapProblems(c: ConfirmedCodes, m: SlotMap): string[] {
  const p: string[] = [];
  const e = expectedMapCodes(c);
  const f = m.fields;
  if (!sameRecord(f.film_sim?.encoding.map, e.film_sim)) p.push(`film_sim map ${show(f.film_sim?.encoding.map)} ≠ confirmed ${show(e.film_sim)}`);
  if (!sameRecord(f.white_balance?.encoding.map, e.white_balance)) {
    p.push(`white_balance map ${show(f.white_balance?.encoding.map)} ≠ confirmed ${show(e.white_balance)}`);
  }
  for (const k of ["wb_shift_r", "wb_shift_b"]) {
    const enc = f[k]?.encoding ?? {};
    const seen = [...(enc.observed_indices ?? [])].sort((a, b) => a - b);
    const want = [...new Set(Object.values(e.shift_entries))].sort((a, b) => a - b);
    if (JSON.stringify(seen) !== JSON.stringify(want)) p.push(`${k} observed_indices ${JSON.stringify(seen)} ≠ confirmed entries ${JSON.stringify(want)}`);
    for (const [ptp, entry] of Object.entries(e.shift_entries)) {
      if (enc.index_by_ptp?.[ptp] !== entry) p.push(`${k} index_by_ptp[${ptp}] = ${enc.index_by_ptp?.[ptp]}, confirmed entry ${entry}`);
    }
  }
  if (!sameRecord(f.color?.encoding.map, e.color)) p.push(`color map ${show(f.color?.encoding.map)} ≠ confirmed ${show(e.color)}`);
  if (!sameRecord(f.nr?.observed_values, e.nr)) p.push(`nr observed_values ${show(f.nr?.observed_values)} ≠ confirmed ${show(e.nr)}`);
  for (const [v, s] of Object.entries(c.noiseReduction)) {
    if (s.code !== Number(v) + 4) p.push(`noise reduction ${v} has code ${s.code}, but the writer's encoding is raw = value + 4`);
  }
  return p;
}

/** Bring the slot map in line with the confirmed codes (in place): confirmed → `map`, out of `inferred` (with any
 *  inferred entry claiming the same byte), WB entries into the shift table, NR into observed_values. */
export function applyToMap(c: ConfirmedCodes, m: SlotMap, note: string | null): void {
  const e = expectedMapCodes(c);
  const f = m.fields;
  const setEnum = (field: MapField, want: Record<string, number>) => {
    field.encoding.map = { ...want };
    const taken = new Set(Object.values(want));
    field.encoding.inferred = Object.fromEntries(Object.entries(field.encoding.inferred ?? {})
      .filter(([k, v]) => !(k in want) && !taken.has(v)));
  };
  setEnum(f.film_sim, e.film_sim);
  setEnum(f.white_balance, e.white_balance);
  setEnum(f.color, e.color);
  for (const k of ["wb_shift_r", "wb_shift_b"]) {
    const enc = f[k].encoding;
    enc.index_by_ptp = { ...(enc.index_by_ptp ?? {}), ...e.shift_entries };
    enc.index_by_raw = { ...(enc.index_by_raw ?? {}), ...Object.fromEntries(Object.values(c.whiteBalances).map((w) => [String(w.code), w.shiftEntry])) };
    enc.observed_indices = [...new Set(Object.values(e.shift_entries))].sort((a, b) => a - b);
  }
  f.nr.observed_values = { ...e.nr };
  if (note) {
    for (const k of ["film_sim", "white_balance", "color", "nr", "wb_shift_r", "wb_shift_b"]) {
      f[k].evidence = `${f[k].evidence ?? ""} | ${note}`.replace(/^ \| /, "");
    }
  }
}

// ================================================================== check

export function readText(rel: string): string {
  return readFileSync(join(ROOT, rel), "utf8");
}

/** Everything that disagrees with lib/cameras.ts, in words. Empty = all three agree. */
export function check(c: ConfirmedCodes = X100VI_CONFIRMED): string[] {
  const p: string[] = [];
  const swift = block(readText(PATHS.swift));
  if (swift === null) p.push(`${PATHS.swift}: no ${OPEN} block`);
  else if (swift !== renderSwift(c)) p.push(`${PATHS.swift} is out of date with lib/cameras.ts: run \`npm run codes -- render\``);
  const ts = block(readText(PATHS.ts));
  if (ts !== renderTs(c)) p.push(`${PATHS.ts}: the ${MODEL}_CONFIRMED block isn't in canonical form: run \`npm run codes -- render\``);
  p.push(...mapProblems(c, JSON.parse(readText(PATHS.map)) as SlotMap).map((x) => `${PATHS.map}: ${x}`));
  for (const s of Object.keys(c.filmSims)) if (!X100VI.filmSims.includes(s)) p.push(`confirmed film sim "${s}" isn't one the ${MODEL} has`);
  for (const w of Object.keys(c.whiteBalances)) if (!X100VI.whiteBalances.includes(w)) p.push(`confirmed white balance "${w}" isn't one the ${MODEL} has`);
  return p;
}

// ================================================================== merge (dialin-cam map-codes output)

/** What `dialin-cam map-codes` writes (DialInCamera CodeMap.Report). */
export type CodeMapReport = {
  kind: string;
  tool?: string;
  model: string;
  firmware: string;
  settings_size: number;
  slot: number;
  at: string;
  rehearsal: boolean;
  backups?: { slots?: string; settings?: string };
  codes: { field: string; value: string; ptp?: number | null; file?: number | null; shift_entry?: number | null;
    inferred?: number | null; agrees?: boolean | null; write: string; changed?: string[] }[];
  skipped?: { field: string; value: string; why: string }[];
  restore?: { verdict?: string; ptp?: string; settings_file?: string };
};

export type MergeResult = { next: ConfirmedCodes; added: string[]; already: string[]; skipped: string[]; conflicts: string[] };

/** Fold a map-codes result into the confirmed codes. Pure: returns the new table and what happened, line by line. */
export function merge(c: ConfirmedCodes, r: CodeMapReport, opts: { allowRehearsal?: boolean } = {}): MergeResult {
  if (r.kind !== "dialin.codemap/1") throw new Error(`not a dialin-cam map-codes result (kind ${JSON.stringify(r.kind)})`);
  if (r.model !== MODEL) throw new Error(`these codes are from a ${r.model}; this table is the ${MODEL}'s`);
  if (r.settings_size !== SETTINGS_SIZE) throw new Error(`settings file of ${r.settings_size} bytes; the table is for the ${SETTINGS_SIZE}-byte layout`);
  if (!c.firmware.includes(r.firmware)) throw new Error(`firmware ${r.firmware}; the table is for ${c.firmware.join(", ")}`);
  if (r.rehearsal && !opts.allowRehearsal) throw new Error("this came from the pretend camera (--rehearse); real codes only");
  const day = r.at.slice(0, 10);
  let key = `map-codes-${day}`;
  for (let i = 2; key in c.sources; i++) key = `map-codes-${day}-${i}`;
  const sources: Record<string, string> = { ...c.sources };
  const next: ConfirmedCodes = {
    ...c,
    sources,
    filmSims: { ...c.filmSims },
    whiteBalances: { ...c.whiteBalances },
    color: { ...c.color },
    noiseReduction: { ...c.noiseReduction },
  };
  const out: MergeResult = { next, added: [], already: [], skipped: [], conflicts: [] };
  const seen = `${key} C${r.slot}`;
  for (const x of r.codes) {
    const label = `${x.field} ${x.value}`;
    if (typeof x.file !== "number") { out.skipped.push(`${label}: no code read`); continue; }
    if (x.write !== "clean") { out.skipped.push(`${label}: the write wasn't clean (${x.write})`); continue; }
    const put = <T extends SeenCode>(rec: Record<string, T>, k: string, v: T, same: (a: T) => boolean) => {
      const cur = rec[k];
      if (cur && same(cur)) { out.already.push(`${label}: already confirmed as ${cur.code}`); return; }
      if (cur) { out.conflicts.push(`${label}: measured ${v.code}, but confirmed as ${cur.code} (${cur.seen})`); return; }
      rec[k] = v;
      out.added.push(`${label} → ${v.code}${"shiftEntry" in v ? ` (shift entry ${(v as unknown as { shiftEntry: number }).shiftEntry})` : ""}`
        + (typeof x.inferred === "number" ? (x.inferred === v.code ? " (the X-T5 guess was right)" : ` (the X-T5 guess said ${x.inferred})`) : ""));
    };
    switch (x.field) {
      case "film_sim":
        if (ptpSim(x.value) === undefined) { out.skipped.push(`${label}: not a film sim name`); break; }
        put(next.filmSims as Record<string, SeenCode>, x.value, { code: x.file, seen }, (a) => a.code === x.file);
        break;
      case "white_balance":
        if (ptpWB(x.value) === undefined) { out.skipped.push(`${label}: not a white balance name`); break; }
        if (typeof x.shift_entry !== "number") { out.skipped.push(`${label}: its WB-shift entry wasn't found`); break; }
        put(next.whiteBalances as Record<string, SeenCode & { shiftEntry: number }>, x.value,
          { code: x.file, shiftEntry: x.shift_entry, seen }, (a) => a.code === x.file && a.shiftEntry === x.shift_entry);
        break;
      case "color":
        put(next.color as Record<string, SeenCode>, String(Number(x.value)), { code: x.file, seen }, (a) => a.code === x.file);
        break;
      case "noise_reduction":
        if (x.file !== Number(x.value) + 4) {
          out.skipped.push(`${label}: code ${x.file} doesn't fit the writer's encoding (raw = value + 4); SettingsLookPatch.swift needs a change first`);
          break;
        }
        put(next.noiseReduction as Record<string, SeenCode>, String(Number(x.value)), { code: x.file, seen }, (a) => a.code === x.file);
        break;
      default:
        out.skipped.push(`${label}: unknown field`);
    }
  }
  const restore = r.restore?.verdict ?? "not reported";
  if (out.added.length) {
    sources[key] = `dialin-cam map-codes on C${r.slot}, ${r.at}: each value written over USB (PTP slot props) and read back, `
      + `then the settings file downloaded and the slot's byte read. Backups: ${r.backups?.slots ?? "?"}, ${r.backups?.settings ?? "?"}. `
      + `Slot restored: ${restore}.`;
  }
  return out;
}

// ================================================================== CLI

function main(argv: string[]): number {
  const [cmd, ...rest] = argv;
  if (cmd === "check") {
    const p = check();
    for (const x of p) console.log(`✗ ${x}`);
    console.log(p.length ? `${p.length} problem(s)` : "lib/cameras.ts, ConfirmedCodes.swift and the slot map agree");
    return p.length ? 1 : 0;
  }
  if (cmd === "render") {
    writeFileSync(join(ROOT, PATHS.ts), replaceBlock(readText(PATHS.ts), renderTs(X100VI_CONFIRMED)));
    writeFileSync(join(ROOT, PATHS.swift), replaceBlock(readText(PATHS.swift), renderSwift(X100VI_CONFIRMED)));
    console.log(`rendered ${PATHS.ts} and ${PATHS.swift}`);
    const p = mapProblems(X100VI_CONFIRMED, JSON.parse(readText(PATHS.map)) as SlotMap);
    for (const x of p) console.log(`✗ ${PATHS.map}: ${x}`);
    return p.length ? 1 : 0;
  }
  if (cmd === "merge") {
    const known = new Set(["--write", "--allow-rehearsal"]);
    const flags = rest.filter((a) => a.startsWith("--"));
    const bad = flags.filter((f) => !known.has(f));
    const files = rest.filter((a) => !a.startsWith("--"));
    if (bad.length || files.length !== 1) {
      console.error(`usage: npm run codes -- merge <codes.json> [--write]${bad.length ? ` (unknown: ${bad.join(" ")})` : ""}`);
      return 2;
    }
    const report = JSON.parse(readFileSync(files[0], "utf8")) as CodeMapReport;
    const r = merge(X100VI_CONFIRMED, report, { allowRehearsal: flags.includes("--allow-rehearsal") });
    for (const x of r.added) console.log(`+ ${x}`);
    for (const x of r.already) console.log(`= ${x}`);
    for (const x of r.skipped) console.log(`- ${x}`);
    for (const x of r.conflicts) console.log(`! ${x}`);
    if (r.conflicts.length) { console.log("conflicts: nothing written. Check the camera session before trusting either code."); return 1; }
    if (!r.added.length) { console.log("nothing new to add"); return 0; }
    if (!flags.includes("--write")) { console.log(`\n${r.added.length} new code(s). Re-run with --write to add them.`); return 0; }
    writeFileSync(join(ROOT, PATHS.ts), replaceBlock(readText(PATHS.ts), renderTs(r.next)));
    writeFileSync(join(ROOT, PATHS.swift), replaceBlock(readText(PATHS.swift), renderSwift(r.next)));
    const m = JSON.parse(readText(PATHS.map)) as SlotMap;
    applyToMap(r.next, m, `confirmed by dialin-cam map-codes ${report.at} (C${report.slot})`);
    writeFileSync(join(ROOT, PATHS.map), `${JSON.stringify(m, null, 2)}\n`);
    console.log(`\nwrote ${PATHS.ts}, ${PATHS.swift}, ${PATHS.map}.`);
    // The Swift patcher's golden vectors come from the Python writer with this map: regenerate them.
    const gen = spawnSync("python3", ["-I", PATHS.vectors], { cwd: ROOT, encoding: "utf8" });
    if (gen.status === 0) console.log(`regenerated ${PATHS.vectorsOut} (${gen.stdout.trim().split("\n").pop() ?? "ok"})`);
    else console.log(`couldn't regenerate the look-patch vectors; run: python3 -I ${PATHS.vectors}\n${gen.stderr ?? ""}`);
    console.log("Now: npm run test:plan, swift test (ios/DialInCamera), restart the backend, rebuild the app, commit.");
    return 0;
  }
  console.log("usage: npm run codes -- check | render | merge <codes.json> [--write]");
  return 2;
}

if (process.argv[1] && (() => { // Same file even through a symlinked path (macOS /tmp), case-insensitive on Windows.
  try { const a = realpathSync.native(process.argv[1]), b = realpathSync.native(fileURLToPath(import.meta.url)); return process.platform === "win32" ? a.toLowerCase() === b.toLowerCase() : a === b; }
  catch { return false; } })()) {
  try {
    process.exit(main(process.argv.slice(2)));
  } catch (e) {
    console.error(`error: ${e instanceof Error ? e.message : e}`);
    process.exit(1);
  }
}
