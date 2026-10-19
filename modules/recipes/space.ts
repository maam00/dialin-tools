/** Community-practice priors: aggregate statistics computed privately from a recipe catalog and safe to publish.
 *  Every published count covers at least k records; there is no recipe, name, URL, identifier or per-record row.
 *  A conservative check proves that the published figures cannot reconstruct any catalog recipe. */
import { existsSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { RecipeKnowledge, RecipeReference } from "./knowledge.js";
import type { RecipeFields } from "../../lib/plan/types.js";

export const RECIPE_SPACE_SCHEMA = "dialin.recipe-space.v1";
export const RECIPE_SPACE_PATH = fileURLToPath(new URL("../../data/recipe-space/priors.json", import.meta.url));
/** Minimum records behind any published figure. */
export const RECIPE_SPACE_K = 5;
/** For every record, at least this many of its known settings must stay underivable from the published figures. */
export const MIN_UNRESOLVED_SETTINGS = 3;
/** A setting is unusual when fewer than this share of the group's community recipes use its value. */
export const UNUSUAL_SHARE = 0.1;

type FieldName = "grain" | "color_chrome" | "color_chrome_fx_blue" | "white_balance" | "dynamic_range" | "kelvin"
  | "wb_shift_r" | "wb_shift_b" | "highlight" | "shadow" | "color" | "sharpness" | "noise_reduction" | "clarity";
type JointName = "tone" | "wb_shift";
/** [values, count] for categories; [low, high, count] for an inclusive numeric range of observed values. */
export type CategoryBin = [string[], number];
export type RangeBin = [number, number, number];
export type SpaceGroup = {
  group: string;
  /** Every simulation the group stands for, by definition (not only those observed). */
  sims: string[];
  fields: Partial<Record<FieldName, CategoryBin[] | RangeBin[]>>;
  joint: Partial<Record<JointName, CategoryBin[]>>;
};
export type RecipeSpacePriors = {
  schema_version: typeof RECIPE_SPACE_SCHEMA;
  about: string;
  k: number;
  min_unresolved_settings: number;
  unusual_share: number;
  classes: { tone: string; wb_shift: string };
  groups: SpaceGroup[];
};

const ORDER: Partial<Record<FieldName, readonly string[]>> = {
  grain: ["Off", "Weak Small", "Weak Large", "Strong Small", "Strong Large"],
  color_chrome: ["Off", "Weak", "Strong"], color_chrome_fx_blue: ["Off", "Weak", "Strong"],
  dynamic_range: ["DR100", "DR200", "DR400", "Auto"],
};
const NUMERIC: readonly FieldName[] = ["kelvin", "wb_shift_r", "wb_shift_b", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity"];
const CATEGORICAL: readonly FieldName[] = ["grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "dynamic_range"];
const FIELDS: readonly FieldName[] = ["grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "kelvin", "wb_shift_r", "wb_shift_b",
  "dynamic_range", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity"];
const COLOR_ONLY: readonly FieldName[] = ["color", "color_chrome", "color_chrome_fx_blue"];
const FAMILIES: { group: string; sims: string[]; mono: boolean }[] = [
  { group: "Acros (any filter)", sims: ["Acros", "Acros+Ye", "Acros+R", "Acros+G"], mono: true },
  { group: "Monochrome (any filter)", sims: ["Monochrome", "Monochrome+Ye", "Monochrome+R", "Monochrome+G"], mono: true },
];
const COLOR_SIMS = ["Provia", "Velvia", "Astia", "Classic Chrome", "Reala Ace", "Pro Neg Hi", "Pro Neg Std", "Classic Neg", "Nostalgic Neg", "Eterna", "Eterna Bleach Bypass"];
const isMono = (sim: string) => /^(?:Acros|Monochrome)(?:\+|$)|^Sepia$/.test(sim);
const toneClass = (value: number) => value <= -1 ? "soft" : value >= 1 ? "hard" : "mid";
/** Direction of the white-balance shift: warm adds red or removes blue; cool the reverse. */
function shiftClass(red: number, blue: number) {
  if (red === 0 && blue === 0) return "neutral";
  if (red >= 0 && blue <= 0) return "warm";
  if (red <= 0 && blue >= 0) return "cool";
  return red > 0 ? "magenta" : "green";
}
const CLASSES = {
  tone: "highlight/shadow class: soft <= -1, mid -0.5..+0.5, hard >= +1",
  wb_shift: "WB shift direction: neutral (R0 B0), warm (R>=0, B<=0), cool (R<=0, B>=0), magenta (R>0, B>0), green (R<0, B<0)",
};

type Row = { sim: string; values: Partial<Record<FieldName, string | number>> };
/** Records with published settings; a field counts only when the source published it without an open issue. */
function usableRows(knowledge: RecipeKnowledge): Row[] {
  return knowledge.references.flatMap((reference: RecipeReference) => {
    const facts = reference.source_facts;
    const unresolved = new Set(facts.issues.map((issue) => issue.field));
    const sim = facts.fields.film_sim;
    if (reference.source_record_status !== "public_settings" || !sim || unresolved.has("film_sim")) return [];
    const values: Row["values"] = {};
    for (const field of FIELDS) {
      const value = (facts.fields as Record<string, unknown>)[field];
      if (value === undefined || unresolved.has(field) || (isMono(sim) && COLOR_ONLY.includes(field))) continue;
      if (field === "kelvin" && facts.fields.white_balance !== "Kelvin") continue;
      if (typeof value === "string" || typeof value === "number") values[field] = value;
    }
    return [{ sim, values }];
  });
}

/** Greedy adjacent merging over an ordered list: every bin reaches k; a short tail joins the previous bin. */
function mergeOrdered<T>(items: [T, number][], k: number): [T[], number][] {
  const bins: [T[], number][] = [];
  let open: [T[], number] = [[], 0];
  for (const [value, count] of items) {
    open[0].push(value); open[1] += count;
    if (open[1] >= k) { bins.push(open); open = [[], 0]; }
  }
  if (open[1] > 0) {
    if (!bins.length) return [];
    const last = bins[bins.length - 1];
    last[0].push(...open[0]); last[1] += open[1];
  }
  return bins;
}
const tally = <T>(values: T[]) => { const counts = new Map<T, number>(); for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1); return counts; };
const byFrequency = (counts: Map<string, number>): [string, number][] => [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));

function categoryBins(field: FieldName, values: string[], k: number): CategoryBin[] {
  const counts = tally(values);
  const order = ORDER[field];
  const items: [string, number][] = order ? [...order.filter((value) => counts.has(value)).map((value) => [value, counts.get(value)!] as [string, number]),
    ...byFrequency(new Map([...counts].filter(([value]) => !order.includes(value))))] : byFrequency(counts);
  return mergeOrdered(items, k);
}
function rangeBins(values: number[], k: number): RangeBin[] {
  const items = [...tally(values)].sort((a, b) => a[0] - b[0]);
  return mergeOrdered(items, k).map(([members, count]) => [Math.min(...members), Math.max(...members), count]);
}
function jointBins(labels: string[], k: number): CategoryBin[] { return mergeOrdered(byFrequency(tally(labels)), k); }

type Built = { group: SpaceGroup; rows: Row[] };
function buildGroup(name: string, sims: string[], rows: Row[], k: number): Built {
  const group: SpaceGroup = { group: name, sims, fields: {}, joint: {} };
  for (const field of FIELDS) {
    const values = rows.map((row) => row.values[field]).filter((value) => value !== undefined);
    if (values.length < k) continue;
    const bins = NUMERIC.includes(field) ? rangeBins(values as number[], k) : categoryBins(field, values as string[], k);
    if (bins.length) group.fields[field] = bins;
  }
  const tone = rows.filter((row) => typeof row.values.highlight === "number" && typeof row.values.shadow === "number")
    .map((row) => `${toneClass(row.values.highlight as number)}/${toneClass(row.values.shadow as number)}`);
  const shift = rows.filter((row) => typeof row.values.wb_shift_r === "number" && typeof row.values.wb_shift_b === "number")
    .map((row) => shiftClass(row.values.wb_shift_r as number, row.values.wb_shift_b as number));
  if (tone.length >= k) group.joint.tone = jointBins(tone, k);
  if (shift.length >= k) group.joint.wb_shift = jointBins(shift, k);
  for (const key of Object.keys(group.joint) as JointName[]) if (!group.joint[key]!.length) delete group.joint[key];
  return { group, rows };
}

/** Coarsen one group: merge the most concentrated exact bin with its neighbour (or drop a field that is one exact bin). */
function coarsen(group: SpaceGroup): boolean {
  let best: { field: FieldName; index: number; count: number } | null = null;
  for (const [field, bins] of Object.entries(group.fields) as [FieldName, (CategoryBin | RangeBin)[]][]) {
    bins.forEach((bin, index) => {
      const exact = bin.length === 2 ? bin[0].length === 1 : bin[0] === bin[1];
      const count = bin.length === 2 ? bin[1] : bin[2];
      if (exact && (!best || count > best.count || (count === best.count && field < best.field))) best = { field, index, count };
    });
  }
  if (!best) {
    // Joint tables can still narrow ranges to single values: drop them next, then the finest remaining field.
    const joint = (Object.keys(group.joint) as JointName[])[0];
    if (joint) { delete group.joint[joint]; return true; }
    const finest = (Object.entries(group.fields) as [FieldName, unknown[]][]).sort((x, y) => y[1].length - x[1].length || x[0].localeCompare(y[0]))[0];
    if (!finest) return false;
    delete group.fields[finest[0]];
    return true;
  }
  const { field, index } = best as { field: FieldName; index: number };
  const bins = group.fields[field]! as (CategoryBin | RangeBin)[];
  if (bins.length === 1) { delete group.fields[field]; return true; }
  const other = index + 1 < bins.length ? index + 1 : index - 1;
  const [a, b] = [Math.min(index, other), Math.max(index, other)];
  const merged = bins[a].length === 2
    ? [[...(bins[a] as CategoryBin)[0], ...(bins[b] as CategoryBin)[0]], (bins[a] as CategoryBin)[1] + (bins[b] as CategoryBin)[1]] as CategoryBin
    : [(bins[a] as RangeBin)[0], (bins[b] as RangeBin)[1], (bins[a] as RangeBin)[2] + (bins[b] as RangeBin)[2]] as RangeBin;
  bins.splice(a, 2, merged as never);
  return true;
}

export type PrivacyFinding = { group: string; rule: "small-cell" | "reconstructable-record"; detail: string };
/** Conservative privacy check against the source catalog. It reports group-level findings only, never values. */
export function checkRecipeSpacePrivacy(priors: RecipeSpacePriors, knowledge: RecipeKnowledge): { passed: boolean; checked_records: number; worst_unresolved: number | null; findings: PrivacyFinding[] } {
  const findings: PrivacyFinding[] = [];
  const k = priors.k;
  for (const group of priors.groups) {
    const counts = [...Object.values(group.fields).flatMap((bins) => (bins as (CategoryBin | RangeBin)[]).map((bin) => bin.length === 2 ? bin[1] : bin[2])),
      ...Object.values(group.joint).flatMap((bins) => bins!.map((bin) => bin[1]))];
    if (counts.some((count) => count < k)) findings.push({ group: group.group, rule: "small-cell", detail: `a published count is below k=${k}` });
  }
  const rows = usableRows(knowledge);
  // The attacker is assumed to know every value that occurs anywhere in the catalog (more than the camera grid tells them).
  const observed = new Map<FieldName, Set<string | number>>();
  for (const row of rows) for (const [field, value] of Object.entries(row.values) as [FieldName, string | number][]) {
    if (!observed.has(field)) observed.set(field, new Set()); observed.get(field)!.add(value);
  }
  const observedSims = new Set(rows.map((row) => row.sim));
  let checked = 0, worst: number | null = null;
  for (const group of priors.groups) {
    const members = rows.filter((row) => group.sims.includes(row.sim));
    const n = members.length; // The true group size, although it is never published.
    // A family group that only one catalog simulation occupies names that simulation.
    const simDerivable = group.sims.filter((sim) => observedSims.has(sim)).length === 1;
    for (const row of members) {
      checked++;
      const known = Object.keys(row.values).length + 1; // + film simulation
      // For each published field: the observed values the record's bin admits, and how many records are known to be in it.
      const view = new Map<FieldName, { candidates: (string | number)[]; lower: number; count: number }>();
      for (const [field, value] of Object.entries(row.values) as [FieldName, string | number][]) {
        const bins = group.fields[field] as (CategoryBin | RangeBin)[] | undefined;
        const bin = bins?.find((item) => item.length === 2 ? item[0].includes(value as string) : (value as number) >= item[0] && (value as number) <= item[1]);
        if (!bin) continue;
        const count = bin.length === 2 ? bin[1] : bin[2];
        const candidates = [...observed.get(field)!].filter((candidate) => bin.length === 2 ? bin[0].includes(candidate as string) : (candidate as number) >= bin[0] && (candidate as number) <= bin[1]);
        view.set(field, { candidates, lower: count, count });
      }
      // A joint class table narrows both axes together; its cell count bounds a narrowed set from below (Fréchet).
      const joints: [JointName, FieldName, FieldName, (a: number, b: number) => string][] = [
        ["tone", "highlight", "shadow", (a, b) => `${toneClass(a)}/${toneClass(b)}`], ["wb_shift", "wb_shift_r", "wb_shift_b", shiftClass]];
      for (const [joint, fa, fb, label] of joints) {
        const bins = group.joint[joint];
        if (!bins || typeof row.values[fa] !== "number" || typeof row.values[fb] !== "number") continue;
        // A setting whose own figures were dropped is still narrowed by the class: treat it as one bin holding the whole group.
        for (const field of [fa, fb]) if (!view.has(field)) view.set(field, { candidates: [...observed.get(field)!], lower: 0, count: n });
        const a = view.get(fa)!, b = view.get(fb)!;
        const cell = bins.find((item) => item[0].includes(label(row.values[fa] as number, row.values[fb] as number)));
        if (!cell) continue;
        for (let round = 0; round < 3; round++) {
          const nextA = a.candidates.filter((x) => b.candidates.some((y) => cell[0].includes(label(x as number, y as number))));
          const nextB = b.candidates.filter((y) => nextA.some((x) => cell[0].includes(label(x as number, y as number))));
          if (nextA.length < a.candidates.length) { a.candidates = nextA; a.lower = Math.max(0, a.count + cell[1] - n); }
          if (nextB.length < b.candidates.length) { b.candidates = nextB; b.lower = Math.max(0, b.count + cell[1] - n); }
        }
        // A single candidate needs no narrowing: every record in the cell holds it.
        for (const item of [a, b]) if (item.candidates.length === 1) item.lower = Math.max(item.lower, item.count + cell[1] - n);
      }
      const pinned: number[] = simDerivable ? [n] : []; // records sharing each derivable exact value
      for (const item of view.values()) if (item.candidates.length === 1 && item.lower > 0) pinned.push(item.lower);
      // Largest set of exact values an attacker can prove some single record holds together: |∩| >= Σc − (m−1)n.
      pinned.sort((a, b) => b - a);
      let uncertainty = 0, derivable = 0;
      for (const count of pinned) { if (uncertainty + (n - count) > n - 1) break; uncertainty += n - count; derivable++; }
      const unresolved = known - derivable;
      worst = worst === null ? unresolved : Math.min(worst, unresolved);
      if (unresolved < priors.min_unresolved_settings) {
        findings.push({ group: group.group, rule: "reconstructable-record", detail: `a record would keep only ${unresolved} of ${known} settings underivable` });
      }
    }
  }
  const unique = new Map(findings.map((finding) => [`${finding.group}|${finding.rule}|${finding.detail}`, finding]));
  return { passed: findings.length === 0, checked_records: checked, worst_unresolved: worst, findings: [...unique.values()] };
}

/** Build the priors from a catalog, coarsening any group until the privacy check passes. Deterministic. */
export function buildRecipeSpacePriors(knowledge: RecipeKnowledge, options: { k?: number; minUnresolved?: number } = {}): RecipeSpacePriors {
  const k = options.k ?? RECIPE_SPACE_K;
  const rows = usableRows(knowledge);
  const bySim = tally(rows.map((row) => row.sim));
  const plan: { group: string; sims: string[] }[] = [];
  for (const sim of COLOR_SIMS) if ((bySim.get(sim) ?? 0) >= k) plan.push({ group: sim, sims: [sim] });
  const leftover = COLOR_SIMS.filter((sim) => (bySim.get(sim) ?? 0) < k);
  if (leftover.reduce((sum, sim) => sum + (bySim.get(sim) ?? 0), 0) >= k) plan.push({ group: "Other color simulations", sims: leftover });
  for (const family of FAMILIES) if (family.sims.reduce((sum, sim) => sum + (bySim.get(sim) ?? 0), 0) >= k) plan.push({ group: family.group, sims: family.sims });
  if ((bySim.get("Sepia") ?? 0) >= k) plan.push({ group: "Sepia", sims: ["Sepia"] });
  const priors: RecipeSpacePriors = {
    schema_version: RECIPE_SPACE_SCHEMA,
    about: "Aggregate statistics of how widely shared community film-simulation recipes set each control, per simulation. Every count covers at least k recipes; no recipe, name, link or identifier is included. Counts describe common practice, not photographic quality.",
    k, min_unresolved_settings: options.minUnresolved ?? MIN_UNRESOLVED_SETTINGS, unusual_share: UNUSUAL_SHARE, classes: CLASSES,
    groups: plan.map(({ group, sims }) => buildGroup(group, sims, rows.filter((row) => sims.includes(row.sim)), k).group),
  };
  for (const group of priors.groups) {
    const single = { ...priors, groups: [group] };
    for (let guard = 0; guard < 500 && !checkRecipeSpacePrivacy(single, knowledge).passed; guard++) if (!coarsen(group)) break;
  }
  priors.groups = priors.groups.filter((group) => Object.keys(group.fields).length > 0);
  const check = checkRecipeSpacePrivacy(priors, knowledge);
  if (!check.passed) throw new Error(`Recipe-space priors failed the privacy check: ${check.findings.map((finding) => `${finding.group}: ${finding.detail}`).join("; ")}`);
  return priors;
}

/** Stable compact text: one group per line keeps the file small and diffs readable. */
export function serializeRecipeSpacePriors(priors: RecipeSpacePriors): string {
  const { groups, ...head } = priors;
  return `{${Object.entries(head).map(([key, value]) => `${JSON.stringify(key)}:${JSON.stringify(value)}`).join(",")},"groups":[\n${groups.map((group) => JSON.stringify(group)).join(",\n")}\n]}\n`;
}

function validatePriors(raw: unknown): RecipeSpacePriors {
  const priors = raw as RecipeSpacePriors;
  if (!priors || priors.schema_version !== RECIPE_SPACE_SCHEMA || !Array.isArray(priors.groups) || typeof priors.k !== "number" || priors.k < 5) throw new Error("Invalid recipe-space priors.");
  for (const group of priors.groups) {
    if (typeof group.group !== "string" || !Array.isArray(group.sims) || typeof group.fields !== "object" || typeof group.joint !== "object") throw new Error("Invalid recipe-space group.");
    for (const bins of [...Object.values(group.fields), ...Object.values(group.joint)]) {
      if (!Array.isArray(bins) || (bins as unknown[][]).some((bin) => !Array.isArray(bin) || Number(bin[bin.length - 1]) < priors.k)) throw new Error("Recipe-space priors contain a count below k.");
    }
  }
  return priors;
}

/** Overrides the priors path; "none" turns community-practice figures off. */
export const RECIPE_SPACE_ENV = "DIALIN_RECIPE_SPACE";
/** The published priors, or null when the file is absent or turned off. Local JSON only. */
export function loadRecipeSpacePriors(path?: string): RecipeSpacePriors | null {
  const configured = process.env[RECIPE_SPACE_ENV]?.trim();
  if (path === undefined && configured && /^(?:none|off)$/i.test(configured)) return null;
  path ??= configured || RECIPE_SPACE_PATH;
  if (!existsSync(path)) return null;
  if (statSync(path).size > 200_000) throw new Error("Recipe-space priors exceed 200 KB.");
  return validatePriors(JSON.parse(readFileSync(path, "utf8")));
}

const fmt = (value: number) => value > 0 ? `+${value}` : String(value);
const describeBin = (field: string, bin: CategoryBin | RangeBin) => bin.length === 2 ? bin[0].join("|")
  : bin[0] === bin[1] ? (field === "kelvin" ? `${bin[0]}K` : fmt(bin[0])) : field === "kelvin" ? `${bin[0]}-${bin[1]}K` : `${fmt(bin[0])}..${fmt(bin[1])}`;
const LABEL: Record<string, string> = { grain: "grain", color_chrome: "CC", color_chrome_fx_blue: "FX Blue", white_balance: "WB", kelvin: "Kelvin",
  wb_shift_r: "R", wb_shift_b: "B", dynamic_range: "DR", highlight: "H", shadow: "S", color: "Color", sharpness: "Sharp", noise_reduction: "NR", clarity: "Clarity", tone: "tone", wb_shift: "shift" };
const total = (bins: (CategoryBin | RangeBin)[]) => bins.reduce((sum, bin) => sum + (bin.length === 2 ? bin[1] : bin[2]), 0);

/** One line per group: the most common value or range of each setting with its share. Compact enough for a prompt. */
export function recipeSpaceSummary(priors: RecipeSpacePriors): string[] {
  return priors.groups.map((group) => {
    const parts = [...Object.entries(group.fields), ...Object.entries(group.joint)].map(([field, bins]) => {
      const list = bins as (CategoryBin | RangeBin)[];
      const top = [...list].sort((a, b) => (b.length === 2 ? b[1] : b[2]) - (a.length === 2 ? a[1] : a[2]))[0];
      return `${LABEL[field]} ${describeBin(field, top)} ${Math.round(100 * (top.length === 2 ? top[1] : top[2]) / total(list))}%`;
    });
    return `${group.group}: ${parts.join(" · ")}`;
  });
}

export type LookPractice = {
  slot: number | null; name: string; group: string | null;
  region: "common" | "uncommon" | "unusual" | "not_covered";
  unusual_settings: { setting: string; value: string | number; share: number }[];
  note: string;
};
type LookLike = Pick<RecipeFields, "name" | "film_sim" | "grain" | "color_chrome" | "color_chrome_fx_blue" | "white_balance" | "kelvin" | "wb_shift_r" | "wb_shift_b" | "dynamic_range" | "highlight" | "shadow" | "color" | "sharpness" | "noise_reduction" | "clarity"> & { slot: number | null };

/** Controls the slot writer does not send for a monochrome look (USB mono skip set): their community figures say
 *  nothing about what the look will do, so a monochrome look is never placed by them. */
const MONO_UNWRITTEN: readonly string[] = ["wb_shift_r", "wb_shift_b", "wb_shift", "color", "color_chrome", "color_chrome_fx_blue"];

/** Informational only: where a look's settings sit relative to community practice for its simulation. Never a quality judgment. */
export function assessLookPractice(look: LookLike, priors: RecipeSpacePriors): LookPractice {
  const group = priors.groups.find((item) => item.sims.includes(look.film_sim)) ?? null;
  const base = { slot: look.slot, name: look.name };
  const label = `${look.slot === null ? "" : `C${look.slot} `}"${look.name}"`;
  if (!group) return { ...base, group: null, region: "not_covered", unusual_settings: [],
    note: `${label}: no community-practice figures cover ${look.film_sim} (fewer than ${priors.k} recipes).` };
  const values = look as unknown as Record<string, string | number>;
  const unusual: (LookPractice["unusual_settings"][number] & { counted: number })[] = [];
  const skipped = isMono(look.film_sim) ? MONO_UNWRITTEN : [];
  for (const [field, bins] of Object.entries(group.fields) as [FieldName, (CategoryBin | RangeBin)[]][]) {
    if (field === "kelvin" && look.white_balance !== "Kelvin") continue;
    if (skipped.includes(field)) continue;
    const value = values[field];
    if (value === undefined) continue;
    const bin = bins.find((item) => item.length === 2 ? item[0].includes(String(value)) : Number(value) >= item[0] && Number(value) <= item[1]);
    const share = bin ? (bin.length === 2 ? bin[1] : bin[2]) / total(bins) : 0;
    if (share < priors.unusual_share) unusual.push({ setting: field, value, share: Math.round(share * 100) / 100, counted: total(bins) });
  }
  const derived: [JointName, string][] = [["tone", `${toneClass(look.highlight)}/${toneClass(look.shadow)}`], ["wb_shift", shiftClass(look.wb_shift_r, look.wb_shift_b)]];
  for (const [joint, label] of derived) {
    const bins = group.joint[joint];
    if (!bins || skipped.includes(joint)) continue;
    const bin = bins.find((item) => item[0].includes(label));
    const share = bin ? bin[1] / total(bins) : 0;
    if (share < priors.unusual_share) unusual.push({ setting: joint, value: label, share: Math.round(share * 100) / 100, counted: total(bins) });
  }
  const region = unusual.length === 0 ? "common" : unusual.length === 1 ? "uncommon" : "unusual";
  // Each figure counts only the recipes that published that setting, and values held by fewer than k recipes are not
  // published: a share of 0 means "not in the published figures", never "no recipe uses it".
  const detail = unusual.map((item) => `${LABEL[item.setting]} ${typeof item.value === "number" ? fmt(item.value) : item.value} (${item.share
    ? `${Math.round(item.share * 100)}% of the ${item.counted} ${group.group} recipes counted for this setting`
    : `not in the published ${group.group} figures, which count ${item.counted} recipes for this setting`})`).join(", ");
  const phrase = region === "common" ? "a common" : region === "uncommon" ? "a less common" : "an unusual";
  const note = `${label} sits in ${phrase} region of community practice for ${group.group}${detail ? `: ${detail}. Informational; departing from common practice can be the right choice.` : ". Informational."}`
    + (skipped.length ? " White-balance shift and color controls are not written for a monochrome look, so they are not compared." : "");
  return { ...base, group: group.group, region, unusual_settings: unusual.map(({ counted: _counted, ...item }) => item), note };
}
