// Where and when: a place name → coordinates (Nominatim), and the day's sun and sky (Open-Meteo, no key).
// Ported from studio/plan.py (geocode, sun_times, day_conditions). When the forecast is out of range or offline, the
// sun times are computed here from the sunrise equation. Caches live in memory (one server instance).
//
// Privacy: nothing here logs a place or coordinates.
import { daysSince2000, h12, hhmm, longDate, minutesOf, pyRound, utcToday } from "./time.js";
import { type Block, type Conditions, type HourSky, type Place, PlanError } from "./types.js";
import { abortableDelay, requestDeadline, throwIfAborted } from "./abort.js";

export const NOMINATIM = "https://nominatim.openstreetmap.org/search";
export const OPEN_METEO = "https://api.open-meteo.com/v1/forecast";
const USER_AGENT = "DialInApp/0.1 (photo-planning app backend; low volume)";

export type GetJson = (url: string, headers?: Record<string, string>, timeoutMs?: number, signal?: AbortSignal) => Promise<unknown>;

async function fetchJson(url: string, headers: Record<string, string> = {}, timeoutMs = 10_000, signal?: AbortSignal): Promise<unknown> {
  throwIfAborted(signal);
  const deadline = requestDeadline(timeoutMs, signal);
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": USER_AGENT, Accept: "application/json", ...headers }, signal: deadline.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const result = await res.json();
    throwIfAborted(deadline.signal);
    return result;
  } finally { deadline.dispose(); }
}

let getJson: GetJson = fetchJson;
/** Tests replace the network. Returns the previous function. */
export function setGetJson(fn: GetJson | null): GetJson {
  const prev = getJson;
  getJson = fn ?? fetchJson;
  return prev;
}

const geoCache = new Map<string, Place & { display: string }>();
const forecastCache = new Map<string, { at: number; data: Forecast }>();
let lastNominatim = 0;

/** Tests: forget cached places and forecasts. */
export function clearCaches(): void {
  geoCache.clear();
  forecastCache.clear();
  lastNominatim = 0;
}

/** Free text ("Montauk, NY") → coordinates. Nominatim, politely: one request a second at most, an identifying
 *  User-Agent, every answer cached. The name stays what they typed. The app should send lat/lon instead. */
export async function geocode(place: string, signal?: AbortSignal): Promise<Place> {
  throwIfAborted(signal);
  const key = place.trim().toLowerCase().replace(/\s+/g, " ");
  if (!key) throw new PlanError("No place given.", "no_place", 400);
  const hit = geoCache.get(key);
  if (hit) return { name: place.trim(), lat: hit.lat, lon: hit.lon };
  const wait = 1000 - (Date.now() - lastNominatim);
  if (wait > 0) await abortableDelay(wait, signal);
  const url = `${NOMINATIM}?${new URLSearchParams({ q: place, format: "jsonv2", limit: "1", "accept-language": "en" })}`;
  let hits: unknown;
  try {
    hits = await getJson(url, undefined, undefined, signal);
    throwIfAborted(signal);
  } catch {
    throwIfAborted(signal);
    throw new PlanError(`Couldn't look up "${place.trim()}" just now.`, "geocode_failed", 502);
  } finally {
    lastNominatim = Date.now();
  }
  const h = Array.isArray(hits) ? (hits[0] as { lat?: string; lon?: string; display_name?: string } | undefined) : undefined;
  if (!h?.lat || !h.lon) throw new PlanError(`Couldn't find "${place.trim()}" on the map.`, "place_not_found", 400);
  const found = { name: place.trim(), lat: round4(Number(h.lat)), lon: round4(Number(h.lon)), display: h.display_name ?? "" };
  geoCache.set(key, found);
  return { name: found.name, lat: found.lat, lon: found.lon };
}

const round4 = (x: number) => Math.round(x * 10_000) / 10_000;

// ------------------------------------------------------------------ sun

/** Sunrise and sunset ("HH:MM", local) from the sunrise equation; within a couple of minutes of NOAA.
 *  null where the sun doesn't rise or set that day. */
export function sunTimes(lat: number, lon: number, date: string, utcOffsetS: number): [string, string] | null {
  const n = daysSince2000(date);
  const jstar = n - lon / 360;
  const m = (357.5291 + 0.98560028 * jstar) % 360;
  const mr = (m * Math.PI) / 180;
  const c = 1.9148 * Math.sin(mr) + 0.02 * Math.sin(2 * mr) + 0.0003 * Math.sin(3 * mr);
  const lam = (((m + c + 180 + 102.9372) % 360) * Math.PI) / 180;
  const jtransit = 2451545.0 + jstar + 0.0053 * Math.sin(mr) - 0.0069 * Math.sin(2 * lam);
  const decl = Math.asin(Math.sin(lam) * Math.sin((23.4397 * Math.PI) / 180));
  const phi = (lat * Math.PI) / 180;
  const cosw = (Math.sin((-0.833 * Math.PI) / 180) - Math.sin(phi) * Math.sin(decl)) / (Math.cos(phi) * Math.cos(decl));
  if (!(cosw > -1 && cosw < 1)) return null;
  const w = (Math.acos(cosw) * 180) / Math.PI;
  const local = (j: number) => {
    const t = new Date(((j - 2440587.5) * 86400 + utcOffsetS + 30) * 1000); // +30 s rounds to the minute
    return `${String(t.getUTCHours()).padStart(2, "0")}:${String(t.getUTCMinutes()).padStart(2, "0")}`;
  };
  return [local(jtransit - w / 360), local(jtransit + w / 360)];
}

// ------------------------------------------------------------------ sky

export const WMO: Record<number, string> = {
  0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "fog", 51: "drizzle", 53: "drizzle",
  55: "drizzle", 56: "freezing drizzle", 57: "freezing drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
  66: "freezing rain", 67: "freezing rain", 71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow", 80: "showers",
  81: "showers", 82: "heavy showers", 85: "snow showers", 86: "snow showers", 95: "thunderstorms", 96: "thunderstorms",
  99: "thunderstorms",
};

export function skyWord(cloud: number, rain = 0, code: number | null = null): string {
  if (code !== null && code >= 45 && code in WMO) return WMO[code];
  if (rain >= 50) return "rain likely";
  if (cloud < 20) return "clear";
  if (cloud < 50) return "some cloud";
  if (cloud < 80) return "mostly cloudy";
  return "grey";
}

type Forecast = {
  timezone?: string;
  utc_offset_seconds?: number;
  daily?: {
    time?: string[];
    sunrise?: string[];
    sunset?: string[];
    uv_index_max?: (number | null)[];
    temperature_2m_max?: (number | null)[];
    temperature_2m_min?: (number | null)[];
  };
  hourly?: Record<string, (number | null)[] | string[] | undefined>;
};

/** Sun times and the sky for one place and date (null date = today where the place is). The shape of
 *  lib/dayplan.ts DayConditions plus timezone, temps, chip (the forecast chip), hours and source. */
export async function dayConditions(place: Place, date: string | null, signal?: AbortSignal): Promise<Conditions> {
  throwIfAborted(signal);
  const q: Record<string, string> = {
    latitude: place.lat.toFixed(4),
    longitude: place.lon.toFixed(4),
    timezone: "auto",
    daily: "sunrise,sunset,uv_index_max,temperature_2m_max,temperature_2m_min",
    hourly: "temperature_2m,cloud_cover,precipitation_probability,weather_code,wind_speed_10m",
    temperature_unit: "fahrenheit",
    wind_speed_unit: "mph",
    ...(date ? { start_date: date, end_date: date } : { forecast_days: "1" }),
  };
  const cacheKey = `${q.latitude},${q.longitude},${date ?? "today"}`;
  const hit = forecastCache.get(cacheKey);
  let d: Forecast | null = null;
  if (hit && Date.now() - hit.at < (date ? 3 : 1) * 3600_000) {
    d = hit.data;
  } else {
    try {
      d = (await getJson(`${OPEN_METEO}?${new URLSearchParams(q)}`, undefined, undefined, signal)) as Forecast;
      throwIfAborted(signal);
      if (forecastCache.size > 500) forecastCache.clear();
      forecastCache.set(cacheKey, { at: Date.now(), data: d });
    } catch {
      throwIfAborted(signal);
      d = null; // out of range or offline: the sun still rises
    }
  }
  if (d?.daily?.sunrise?.length && d.daily.time?.length) return fromForecast(place, d.daily.time[0], d);
  return withoutForecast(place, date ?? utcToday(), signal);
}

/** The place's UTC offset on `date` when there's no forecast for it: Open-Meteo names the zone (asked for today),
 *  Intl gives that zone's offset on the day (summer time included); else today's offset; else longitude / 15. */
async function offsetGuess(place: Place, date: string, signal?: AbortSignal): Promise<[number, string]> {
  throwIfAborted(signal);
  let d: Forecast;
  try {
    d = (await getJson(`${OPEN_METEO}?${new URLSearchParams({
      latitude: place.lat.toFixed(4), longitude: place.lon.toFixed(4), timezone: "auto", daily: "sunrise",
      forecast_days: "1",
    })}`, undefined, undefined, signal)) as Forecast;
    throwIfAborted(signal);
  } catch {
    throwIfAborted(signal);
    return [Math.round(place.lon / 15) * 3600, "approximate"];
  }
  const tz = d.timezone ?? "";
  const off = tz ? zoneOffsetSeconds(tz, date) : null;
  if (off !== null) return [off, tz];
  return [d.utc_offset_seconds ?? Math.round(place.lon / 15) * 3600, tz];
}

/** UTC offset of an IANA zone at local noon on `date`, in seconds, or null if the zone is unknown. */
export function zoneOffsetSeconds(tz: string, date: string): number | null {
  try {
    const [y, m, dd] = date.split("-").map(Number);
    const at = Date.UTC(y, m - 1, dd, 12);
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit",
      minute: "2-digit", second: "2-digit",
    }).formatToParts(new Date(at));
    const get = (t: string) => Number(parts.find((p) => p.type === t)?.value);
    const asLocal = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
    return Math.round((asLocal - at) / 1000);
  } catch {
    return null;
  }
}

async function withoutForecast(place: Place, date: string, signal?: AbortSignal): Promise<Conditions> {
  const [off, tz] = await offsetGuess(place, date, signal);
  throwIfAborted(signal);
  const [sunrise, sunset] = sunTimes(place.lat, place.lon, date, off) ?? ["06:30", "18:30"];
  const s = minutesOf(sunset) as number;
  const golden = `${hhmm(s - 60)}–${sunset}`;
  const blue = `${sunset}–${hhmm(s + 30)}`;
  const text = [
    `Place: ${place.name} (${place.lat.toFixed(2)}, ${place.lon.toFixed(2)})`,
    `Date: ${longDate(date)}`,
    `Sunrise ${h12(sunrise)}, sunset ${h12(sunset)} (computed). Evening golden hour ${h12(golden.slice(0, 5))}–`
      + `${h12(sunset)}, blue hour ${h12(sunset)}–${h12(blue.slice(-5))}.`,
    "No forecast for this date: plan for the season's typical light and say so.",
  ].join("\n");
  return {
    place: { name: place.name, lat: place.lat, lon: place.lon }, date, sunrise, sunset, goldenEvening: golden,
    blueHour: blue, uvMax: null, blocks: [], text, timezone: tz, temps: null, hours: [],
    chip: `No forecast yet · sunset ${h12(sunset)}`, source: "computed",
  };
}

function fromForecast(place: Place, date: string, d: Forecast): Conditions {
  const daily = d.daily ?? {};
  const hourly = d.hourly ?? {};
  const sunrise = (daily.sunrise as string[])[0].slice(11, 16);
  const sunset = (daily.sunset as string[])[0].slice(11, 16);
  const sr = minutesOf(sunrise) as number;
  const ss = minutesOf(sunset) as number;
  const golden = `${hhmm(ss - 60)}–${sunset}`;
  const blue = `${sunset}–${hhmm(ss + 30)}`;
  const uv = daily.uv_index_max?.[0] ?? null;
  const tmax = daily.temperature_2m_max?.[0] ?? null;
  const tmin = daily.temperature_2m_min?.[0] ?? null;

  const times = (hourly.time as string[] | undefined) ?? [];
  const at = (k: string, i: number) => {
    const v = (hourly[k] as (number | null)[] | undefined)?.[i];
    return typeof v === "number" ? v : 0;
  };
  const hours: HourSky[] = times.map((t, i) => ({
    h: Number(t.slice(11, 13)), cloud: pyRound(at("cloud_cover", i)), rain: pyRound(at("precipitation_probability", i)),
    temp: pyRound(at("temperature_2m", i)), code: Math.trunc(at("weather_code", i)), wind: pyRound(at("wind_speed_10m", i)),
  }));

  const sunriseH = Math.floor(sr / 60);
  const sunsetH = Math.floor(ss / 60);
  const ranges: [string, number, number][] = [
    ["morning", sunriseH, 11], ["midday", 11, 15], ["afternoon", 15, sunsetH - 1],
    ["golden hour", sunsetH - 1, sunsetH + 1], ["night", sunsetH + 1, 23],
  ];
  const blocks: Block[] = [];
  for (const [label, a, b] of ranges) {
    if (b <= a) continue;
    const hs = hours.filter((h) => a <= h.h && h.h < b);
    const cloud = hs.length ? pyRound(hs.reduce((s, h) => s + h.cloud, 0) / hs.length) : 0;
    const rain = Math.max(0, ...hs.map((h) => h.rain));
    const worst = hs.length ? Math.max(...hs.map((h) => h.code)) : null;
    blocks.push({ label, hours: `${a}:00–${b}:00`, cloud, rain, sky: skyWord(cloud, rain, worst && worst >= 45 ? worst : null) });
  }

  const dayHours = hours.filter((h) => sunriseH <= h.h && h.h <= sunsetH);
  const dayCloud = dayHours.length ? dayHours.reduce((s, h) => s + h.cloud, 0) / dayHours.length : 0;
  const dayRain = Math.max(0, ...dayHours.map((h) => h.rain));
  const skies = new Set(blocks.filter((b) => b.label !== "night").map((b) => b.sky));
  let sky = skies.size === 1 ? `${skyWord(dayCloud)} all day` : skyWord(dayCloud);
  if (sky.startsWith("grey")) sky = sky.includes("all day") ? "Grey all day" : "Mostly grey";
  const temps = tmin !== null && tmax !== null ? `${pyRound(tmin)}–${pyRound(tmax)}°F` : null;
  const chip = [sky.slice(0, 1).toUpperCase() + sky.slice(1), dayRain < 20 ? "no rain" : `${dayRain}% rain`, temps,
    `sunset ${h12(sunset)}`].filter(Boolean).join(" · ");

  const hourLine = (h: HourSky) => {
    const bits = [`${String(h.h).padStart(2, "0")}h ${WMO[h.code] ?? skyWord(h.cloud)} ${h.cloud}% cloud ${h.temp}°F`];
    if (h.rain >= 20) bits.push(`rain ${h.rain}%`);
    if (h.wind >= 15) bits.push(`wind ${h.wind} mph`);
    return bits.join(" ");
  };
  const text = [
    `Place: ${place.name} (${place.lat.toFixed(2)}, ${place.lon.toFixed(2)})`,
    `Date: ${longDate(date)}`,
    `Sunrise ${h12(sunrise)}, sunset ${h12(sunset)}. Evening golden hour ${h12(golden.slice(0, 5))}–${h12(sunset)}, `
      + `blue hour ${h12(sunset)}–${h12(blue.slice(-5))}.${uv !== null ? ` Max UV ${uv}.` : ""}`,
    temps ? `Temperature ${temps}.` : "",
    `Sky by time of day: ${blocks.map((b) => `${b.label} ${b.hours} ${b.sky}, ${b.cloud}% cloud${b.rain >= 20 ? `, ${b.rain}% rain` : ""}`).join("; ")}.`,
    `Hour by hour: ${hours.filter((h) => h.h >= 6 && h.h <= 23).map(hourLine).join("; ")}.`,
  ].filter((x) => x !== "").join("\n");
  return {
    place: { name: place.name, lat: place.lat, lon: place.lon }, date, sunrise, sunset, goldenEvening: golden,
    blueHour: blue, uvMax: uv, blocks, text, timezone: d.timezone ?? "", temps, hours, chip, source: "open-meteo",
  };
}

/** No place: no forecast or sun times, just the date. */
export function noPlaceConditions(date: string): Conditions {
  return {
    place: null, date, sunrise: null, sunset: null, goldenEvening: null, blueHour: null, uvMax: null, blocks: [],
    hours: [], timezone: "", temps: null, source: "none", chip: "",
    text: `Date: ${longDate(date)}\nNo place given, so no forecast or sun times: plan for what they said and the `
      + "supplied scene clues. Future illumination remains uncertain.",
  };
}
