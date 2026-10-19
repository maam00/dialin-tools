// Clock and date words, ported from studio/plan.py (_min, _hhmm, _h12, _clock, _span, strftime).

/** Python's round(): halves go to the even neighbour (round(82.5) == 82). */
export function pyRound(x: number): number {
  const f = Math.floor(x);
  const d = x - f;
  if (Math.abs(d - 0.5) < 1e-9) return f % 2 === 0 ? f : f + 1;
  return Math.round(x);
}

/** "18:16" → minutes after midnight, or null. */
export function minutesOf(hhmm: string | null | undefined): number | null {
  const m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(hhmm ?? "");
  if (!m || Number(m[1]) > 24 || Number(m[2]) > 59) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

const pad2 = (n: number) => String(n).padStart(2, "0");

/** Minutes → "HH:MM" (wraps around midnight like Python's %). */
export function hhmm(minutes: number): string {
  const m = ((minutes % 1440) + 1440) % 1440;
  return `${pad2(Math.floor(m / 60))}:${pad2(m % 60)}`;
}

/** "18:16" → "6:16". */
export function h12(t: string): string {
  const m = minutesOf(t);
  if (m === null) return t;
  const h = Math.floor(m / 60) % 12 || 12;
  return `${h}:${pad2(m % 60)}`;
}

/** "17:00" → "5pm", "17:30" → "5:30pm". */
export function clock(t: string, suffix = true): string {
  const total = minutesOf(t);
  if (total === null) return t;
  const m0 = total % 1440;
  const h = Math.floor(m0 / 60);
  const m = m0 % 60;
  const s = `${h % 12 || 12}${m ? `:${pad2(m)}` : ""}`;
  return s + (suffix ? (h < 12 ? "am" : "pm") : "");
}

/** "11:00", "14:00" → "11am–2pm"; "15:00", "16:00" → "3–4pm". */
export function span(a: string, b: string): string {
  const ta = minutesOf(a);
  const tb = minutesOf(b);
  if (ta === null || tb === null) return "";
  if ((ta < 720) === (tb < 720)) return `${clock(a, false)}–${clock(b)}`;
  return `${clock(a)}–${clock(b)}`;
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
  "November", "December"];

/** A valid calendar date "YYYY-MM-DD" → its parts, or null. */
export function parseDate(s: string | null | undefined): { y: number; m: number; d: number } | null {
  const r = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s ?? "");
  if (!r) return null;
  const y = Number(r[1]);
  const m = Number(r[2]);
  const d = Number(r[3]);
  const t = new Date(Date.UTC(y, m - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return null;
  return { y, m, d };
}

/** "2026-10-11" → "Sunday, October 11, 2026" (plan.py: f"{day.strftime('%A, %B')} {day.day}, {day.year}"). */
export function longDate(s: string): string {
  const p = parseDate(s);
  if (!p) return s;
  const wd = new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay();
  return `${WEEKDAYS[wd]}, ${MONTHS[p.m - 1]} ${p.d}, ${p.y}`;
}

/** "2026-10-11" → "Sun Oct 11", or null. */
export function shortDate(s: string): string | null {
  const p = parseDate(s);
  if (!p) return null;
  const wd = new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay();
  return `${WEEKDAYS[wd].slice(0, 3)} ${MONTHS[p.m - 1].slice(0, 3)} ${p.d}`;
}

/** "2026-10-09" → "Oct 9", or "". */
export function monthDay(s: string): string {
  const p = parseDate(s);
  return p ? `${MONTHS[p.m - 1].slice(0, 3)} ${p.d}` : "";
}

/** Days since 2000-01-01 (the sunrise equation's n, before the half-day). */
export function daysSince2000(s: string): number {
  const p = parseDate(s);
  if (!p) throw new Error(`bad date ${s}`);
  return Math.round((Date.UTC(p.y, p.m - 1, p.d) - Date.UTC(2000, 0, 1)) / 86_400_000);
}

/** Today in UTC as "YYYY-MM-DD" (only when the place, and so its time zone, is unknown). */
export function utcToday(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}
