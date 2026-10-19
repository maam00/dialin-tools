// Taste: keep rates per look from past shoots (hearts ÷ frames shot with the look), and what Claude has learned.
// Ported from studio/plan.py (normalize_taste, taste_summary, _where, _rate_text).
import { monthDay } from "./time.js";
import type { TasteRow, TasteSummary } from "./types.js";

/** "C4 Old fisherman" → "Old fisherman". */
export const plainLookName = (s: string) => (s ?? "").trim().replace(/^C\d\s+/, "");

/** The request's taste → rows, learned lines and free-text notes. Accepts
 *   { keep_rates: [{look, hearted, shot, date?, place?}], learned: [string], notes: string }   (the app's form)
 *   [{look, hearted, shot, …}, {learned: "…"}]                                               (studio/plan.py's list)
 *   {"Harbor light": {hearted: 3, shot: 12}} / {"Harbor light": [3, 12]} / {"Harbor light": "3/12"}. */
export function normalizeTaste(taste: unknown): { rows: TasteRow[]; learned: string[]; notes: string } {
  const out = { rows: [] as TasteRow[], learned: [] as string[], notes: "" };
  if (!taste || typeof taste !== "object") return out;
  let items: [string | null, unknown][];
  if (Array.isArray(taste)) {
    items = taste.map((t) => [null, t]);
  } else {
    const t = taste as Record<string, unknown>;
    if ("keep_rates" in t || "learned" in t || "notes" in t) {
      if (typeof t.notes === "string") out.notes = t.notes.trim().slice(0, 300);
      if (Array.isArray(t.learned)) out.learned = t.learned.filter((x) => typeof x === "string").map((x) => x.slice(0, 240));
      items = Array.isArray(t.keep_rates) ? t.keep_rates.map((r) => [null, r]) : [];
    } else {
      items = Object.entries(t);
    }
  }
  for (const [name, v] of items) {
    let look: unknown;
    let h: unknown;
    let n: unknown;
    let date: unknown = "";
    let place: unknown = "";
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const r = v as Record<string, unknown>;
      if (typeof r.learned === "string") {
        out.learned.push(r.learned.slice(0, 240));
        continue;
      }
      look = r.look ?? r.name ?? name;
      h = r.hearted ?? r.kept ?? r.hearts;
      n = r.shot ?? r.frames ?? r.total;
      date = r.date ?? "";
      place = r.place ?? "";
    } else if (Array.isArray(v) && v.length >= 2) {
      [look, h, n] = [name, v[0], v[1]];
    } else if (typeof v === "string" && v.includes("/")) {
      const [a, b] = v.split("/", 2);
      [look, h, n] = [name, a, b];
    } else {
      continue;
    }
    const hi = Number.parseInt(String(h), 10);
    const ni = Number.parseInt(String(n), 10);
    if (!Number.isFinite(hi) || !Number.isFinite(ni)) continue;
    const plain = plainLookName(String(look ?? ""));
    if (plain && ni > 0 && hi >= 0 && hi <= ni) {
      out.rows.push({ look: plain, hearted: hi, shot: ni, date: String(date || ""), place: String(place || "") });
    }
  }
  out.learned = out.learned.slice(0, 6);
  return out;
}

/** {"place": "Example Bay", "date": "2026-05-16"} → "Example Bay May 16". */
function where(r: TasteRow): string {
  const place = (r.place || "").split(",")[0].trim();
  return [place, monthDay(r.date || "")].filter(Boolean).join(" ");
}

/** name (lower) → summed keep rates. favorite = a look they reuse: 5+ hearts and either a keep rate well above their
 *  average or a third of their hearts. */
export function tasteSummary(rows: TasteRow[]): Map<string, TasteSummary> {
  const by = new Map<string, TasteSummary>();
  for (const r of rows) {
    const k = r.look.toLowerCase();
    let s = by.get(k);
    if (!s) {
      s = { look: r.look, hearted: 0, shot: 0, dates: [], where: [], rate: 0, score: 0, favorite: false, quote: "" };
      by.set(k, s);
    }
    s.hearted += r.hearted;
    s.shot += r.shot;
    if (r.date && !s.dates.includes(r.date)) s.dates.push(r.date);
    const w = where(r);
    if (w && !s.where.includes(w)) s.where.push(w);
  }
  const all = [...by.values()];
  const totalH = all.reduce((a, s) => a + s.hearted, 0);
  const totalN = all.reduce((a, s) => a + s.shot, 0);
  const avg = totalN ? (totalH + 1) / (totalN + 5) : 0.2;
  for (const s of all) {
    s.rate = Math.round((s.hearted / s.shot) * 1000) / 1000;
    s.score = Math.round(((s.hearted + 1) / (s.shot + 5)) * 1000) / 1000;
    s.favorite = s.hearted >= 5 && (s.score >= 1.5 * avg || (totalH > 0 && s.hearted / totalH >= 0.3));
    s.quote = `You hearted ${s.hearted} of ${s.shot} in ${s.look}`;
  }
  return by;
}

/** "you hearted 3 of 12 (25%), Example Bay May 16". */
export function rateText(t: TasteSummary): string {
  const w = t.where.join(", ");
  return `you hearted ${t.hearted} of ${t.shot} (${Math.round(100 * t.rate)}%)${w ? `, ${w}` : ""}`;
}
