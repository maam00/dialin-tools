// The app-facing HTTP layer for POST /api/plan and POST /api/adjust: auth, size limits, request validation, a
// per-device rate limit (in-memory stub), and one log line per request with tokens and estimated cost.
//
// Privacy: logs never contain what they said, the photo, the place or coordinates, or error messages (which can quote
// their words); only codes, counts, timings, models, tokens and dollars. The device id is hashed.
import { createHash, randomUUID } from "node:crypto";
import { type CameraCaps, CAMERAS, cameraFor, firmwareAtLeast } from "../cameras.js";
import type { RecipeKnowledge } from "../recipes/library.js";
import { adjustPlan, makePlan, modelConfig, planFromClient, type Quality } from "./engine.js";
import type { Ask } from "./model.js";
import { protectedSlotsFrom } from "./palette.js";
import { isCancellation, throwIfAborted } from "./abort.js";
import { explainRecipe } from "./reasoning.js";
import { ExactRequestPool, requestFingerprint, type RequestDisposition } from "./request-pool.js";
import { minutesOf, parseDate } from "./time.js";
import { type CallMeta, type Place, type Plan, PlanError } from "./types.js";

// ------------------------------------------------------------------ limits

export const LIMITS = {
  planBodyBytes: 2_600_000, // a 1568 px JPEG as base64 (~0.3–1.5 MB) plus the rest
  adjustBodyBytes: 400_000, // the plan the app got back, plus a sentence
  imageBase64Chars: 2_000_000, // ~1.5 MB of JPEG
  imageLongEdge: 1600, // the app resizes to 1568; a little slack for rounding
  saidChars: 1000,
  placeChars: 120,
  tasteRows: 50,
  pastLooks: 30,
};

// ------------------------------------------------------------------ rate limit (stub)

export type RateLimiter = { take: (key: string, now?: number) => { ok: true } | { ok: false; retryAfterS: number } };

/** Sliding window per key, in this server instance's memory only. A stub: on Vercel each instance counts on its own
 *  and forgets on a cold start. Swap for a shared store (Upstash / Vercel KV) with the same interface before launch. */
export function memoryLimiter(limit: number, windowMs: number, maxKeys = 10_000): RateLimiter {
  const hits = new Map<string, number[]>();
  return {
    take(key, now = Date.now()) {
      const recent = (hits.get(key) ?? []).filter((t) => now - t < windowMs);
      if (recent.length >= limit) {
        hits.set(key, recent);
        return { ok: false, retryAfterS: Math.max(1, Math.ceil((recent[0] + windowMs - now) / 1000)) };
      }
      recent.push(now);
      if (!hits.has(key) && hits.size >= maxKeys) hits.delete(hits.keys().next().value as string);
      hits.set(key, recent);
      return { ok: true };
    },
  };
}

/** "20/h", "5/m", "200/d" → a limiter. */
export function limiterFrom(spec: string | undefined, fallback: string): RateLimiter {
  const m = /^(\d+)\/(s|m|h|d)$/.exec((spec ?? fallback).trim()) ?? /^(\d+)\/(s|m|h|d)$/.exec(fallback);
  const [, n, unit] = m as RegExpExecArray;
  const ms = { s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 }[unit as "s" | "m" | "h" | "d"];
  return memoryLimiter(Number(n), ms);
}

const hash = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 12);

/** The rate-limit key: the app's install id (x-device-id), else the caller's IP. Both hashed. */
export function deviceKey(request: Request): string {
  const id = request.headers.get("x-device-id") ?? "";
  if (/^[A-Za-z0-9._-]{8,64}$/.test(id)) return `d:${hash(id)}`;
  const ip = (request.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  return `ip:${hash(ip)}`;
}

// ------------------------------------------------------------------ responses and logs

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  Response.json(body, { status, headers: { "cache-control": "no-store", ...headers } });

const fail = (status: number, code: string, error: string, headers: Record<string, string> = {}) =>
  json({ error, code }, status, headers);

export type Log = (line: Record<string, unknown>) => void;
const defaultLog: Log = (line) => console.log(JSON.stringify(line));

function callsForLog(calls: CallMeta[] | undefined) {
  return (calls ?? []).map((c) => ({
    task: c.task, model: c.model, via: c.via, ok: c.ok, ms: c.ms, code: c.error,
    in: c.usage?.input_tokens ?? null, out: c.usage?.output_tokens ?? null,
    cache_read: c.usage?.cache_read_input_tokens ?? null, cache_write: c.usage?.cache_creation_input_tokens ?? null,
    usd: c.usd, requested_model: c.requested_model ?? null, served_model: c.served_model ?? null,
    usage_complete: c.usage_complete ?? null, reported_cost_usd: c.reported_cost_usd ?? null,
    tries: c.tries ?? [],
  }));
}

const totalUsd = (calls: CallMeta[] | undefined) =>
  !calls?.length || calls.some((c) => c.usd === null) ? null
    : Math.round(calls.reduce((s, c) => s + (c.usd ?? 0), 0) * 1e6) / 1e6;

// ------------------------------------------------------------------ request parsing

const bad = (msg: string, code = "bad_request") => new PlanError(msg, code, 400);

async function readJson(request: Request, maxBytes: number): Promise<Record<string, unknown>> {
  throwIfAborted(request.signal);
  const declared = Number(request.headers.get("content-length") ?? 0);
  if (declared > maxBytes) throw new PlanError("That request is too big.", "too_large", 413);
  const reader = request.body?.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let size = 0;
  const aborted = () => { void reader?.cancel().catch(() => {}); };
  request.signal.addEventListener("abort", aborted, { once: true });
  try {
    if (reader) while (true) {
      throwIfAborted(request.signal);
      const chunk = await reader.read();
      throwIfAborted(request.signal);
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new PlanError("That request is too big.", "too_large", 413);
      }
      text += decoder.decode(chunk.value, { stream: true });
    }
    text += decoder.decode();
  } finally { request.signal.removeEventListener("abort", aborted); reader?.releaseLock(); }
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw bad("The body must be JSON.");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw bad("The body must be a JSON object.");
  return body as Record<string, unknown>;
}

/** Width and height from a JPEG's SOF header, or null when it isn't a readable JPEG. */
export function jpegSize(buf: Uint8Array): { width: number; height: number } | null {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < buf.length) {
    if (buf[i] !== 0xff) return null;
    const marker = buf[i + 1];
    if (marker === 0xff) { i += 1; continue; } // fill byte
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) { i += 2; continue; }
    const len = (buf[i + 2] << 8) | buf[i + 3];
    if (len < 2) return null;
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) return { height: (buf[i + 5] << 8) | buf[i + 6], width: (buf[i + 7] << 8) | buf[i + 8] };
    i += 2 + len;
  }
  return null;
}

/** The scene photo: base64 JPEG (a data: prefix is tolerated), at most LIMITS.imageLongEdge on the long side. */
export function parseSceneImage(v: unknown): { base64: string; width: number; height: number } | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v !== "string") throw bad("scene_image must be a base64 JPEG string.", "bad_image");
  const base64 = v.replace(/^data:image\/[a-z]+;base64,/i, "").replace(/\s+/g, "");
  if (base64.length > LIMITS.imageBase64Chars) throw new PlanError("That photo is too big. Send it at 1568 px on the long side.", "image_too_large", 413);
  if (!/^[A-Za-z0-9+/]+=*$/.test(base64)) throw bad("scene_image isn't base64.", "bad_image");
  const size = jpegSize(Buffer.from(base64, "base64"));
  if (!size) throw bad("scene_image must be a JPEG.", "bad_image");
  if (Math.max(size.width, size.height) > LIMITS.imageLongEdge) {
    throw bad(`That photo is ${size.width}×${size.height}. Resize it to 1568 px on the long side.`, "image_too_large");
  }
  return { base64, ...size };
}

function parsePlace(v: unknown): Place | string | null {
  if (v === undefined || v === null || v === "") return null;
  if (typeof v === "string") {
    if (v.length > LIMITS.placeChars) throw bad("place is too long.");
    return v.trim() || null;
  }
  if (typeof v === "object" && !Array.isArray(v)) {
    const o = v as Record<string, unknown>;
    const lat = Number(o.lat);
    const lon = Number(o.lon);
    if (typeof o.lat !== "number" || typeof o.lon !== "number" || !(lat >= -90 && lat <= 90) || !(lon >= -180 && lon <= 180)) {
      throw bad("place needs lat and lon as numbers.");
    }
    const name = typeof o.name === "string" && o.name.trim() ? o.name.trim().slice(0, LIMITS.placeChars) : `${lat.toFixed(2)}, ${lon.toFixed(2)}`;
    return { name, lat, lon };
  }
  throw bad("place must be a name or {name, lat, lon}.");
}

function parseCamera(v: unknown): { cam: CameraCaps; firmware: string | null; slots: unknown; warnings: string[] } {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw bad("camera is required: {model, firmware, slots}.");
  const o = v as Record<string, unknown>;
  const cam = cameraFor(typeof o.model === "string" ? o.model : null);
  if (!cam) {
    throw new PlanError(`Dial In doesn't support that camera yet (supported: ${CAMERAS.map((c) => c.id).join(", ")}).`,
      "unsupported_camera", 400);
  }
  const warnings: string[] = [];
  let firmware: string | null = null;
  if (o.firmware !== undefined && o.firmware !== null) {
    if (typeof o.firmware !== "string" || !/^\d{1,2}(\.\d{1,3}){0,2}$/.test(o.firmware.trim())) throw bad("camera.firmware must look like \"1.10\".");
    firmware = o.firmware.trim();
    if (cam.firmware.minimum && !firmwareAtLeast(firmware, cam.firmware.minimum)) {
      warnings.push(`firmware ${firmware} is older than ${cam.firmware.minimum}; update the camera if a look won't load`);
    }
  }
  let slots: unknown = null;
  if (o.slots !== undefined && o.slots !== null) {
    if (!Array.isArray(o.slots) || o.slots.length > cam.slots) throw bad(`camera.slots must list up to ${cam.slots} slots.`);
    const seenSlots = new Set<number>();
    for (const [i, s] of o.slots.entries()) {
      const ok = typeof s === "string" ? s.length <= 40
        : s && typeof s === "object" && typeof (s as { name?: unknown }).name === "string" && ((s as { name: string }).name.length <= 40);
      if (!ok) throw bad("each camera slot is a name (or {slot, name, recipe?}).");
      const slot = typeof s === "object" && s !== null && "slot" in s ? (s as { slot: unknown }).slot : i + 1;
      if (!Number.isInteger(slot) || (slot as number) < 1 || (slot as number) > cam.slots || seenSlots.has(slot as number)) {
        throw bad(`camera.slots must identify each slot once, from C1 to C${cam.slots}.`, "bad_camera_slots");
      }
      seenSlots.add(slot as number);
    }
    slots = o.slots;
  }
  return { cam, firmware, slots, warnings };
}

function parseTaste(v: unknown): unknown {
  if (v === undefined || v === null) return null;
  if (typeof v !== "object") throw bad("taste must be an object.");
  const rows = Array.isArray(v) ? v : (v as { keep_rates?: unknown }).keep_rates;
  if (Array.isArray(rows) && rows.length > LIMITS.tasteRows) throw bad(`taste has more than ${LIMITS.tasteRows} rows.`);
  if (!Array.isArray(v) && Object.keys(v).length > LIMITS.tasteRows + 3) throw bad("taste is too big.");
  return v;
}

export type ParsedPlanRequest = {
  said: string;
  image: { base64: string; width: number; height: number } | null;
  place: Place | string | null;
  date: string | null;
  now: string | null;
  cam: CameraCaps;
  firmware: string | null;
  slots: unknown;
  taste: unknown;
  pastLooks: unknown;
  count: number | null;
  protectedSlots?: number[];
  quality: Quality;
  shootingMode: "automatic" | "guided";
  reasoningMode: "compact" | "detailed";
  warnings: string[];
};

export function parsePlanRequest(b: Record<string, unknown>, allowOpus: boolean): ParsedPlanRequest {
  if (b.said !== undefined && b.said !== null && typeof b.said !== "string") throw bad("said must be a string.");
  const said = String(b.said ?? "").trim();
  if (said.length > LIMITS.saidChars) throw bad(`said is longer than ${LIMITS.saidChars} characters.`);
  const image = parseSceneImage(b.scene_image);
  if (!said && !image) throw bad("Say what you're shooting, or send a photo of the scene.", "no_input");
  const place = parsePlace(b.place);
  let date: string | null = null;
  if (b.date !== undefined && b.date !== null && b.date !== "") {
    const p = typeof b.date === "string" ? parseDate(b.date) : null;
    if (!p) throw bad("date must be YYYY-MM-DD.");
    const days = (Date.UTC(p.y, p.m - 1, p.d) - Date.now()) / 86_400_000;
    if (days < -366 || days > 366) throw bad("date must be within a year of today.");
    date = b.date as string;
  }
  let now: string | null = null;
  if (b.now !== undefined && b.now !== null && b.now !== "") {
    if (typeof b.now !== "string" || minutesOf(b.now) === null) throw bad("now must be HH:MM.");
    now = b.now.trim();
  }
  const { cam, firmware, slots, warnings } = parseCamera(b.camera);
  const protectedSlots = b.protected_slots === undefined ? undefined : protectedSlotsFrom(b.protected_slots, cam);
  if (b.past_looks !== undefined && b.past_looks !== null && (!Array.isArray(b.past_looks) || b.past_looks.length > LIMITS.pastLooks)) {
    throw bad(`past_looks must be a list of up to ${LIMITS.pastLooks} looks.`);
  }
  let count: number | null = null;
  if (b.count !== undefined && b.count !== null) {
    if (!Number.isInteger(b.count) || (b.count as number) < 1 || (b.count as number) > cam.slots) throw bad(`count must be 1 to ${cam.slots}.`);
    count = b.count as number;
  }
  let quality: Quality = "sonnet";
  if (b.shooting_mode !== undefined && b.shooting_mode !== "automatic" && b.shooting_mode !== "guided") {
    throw bad("shooting_mode must be automatic or guided.");
  }
  const shootingMode = b.shooting_mode === "automatic" ? "automatic" : "guided";
  if (b.reasoning_mode !== undefined && b.reasoning_mode !== "compact" && b.reasoning_mode !== "detailed") {
    throw bad("reasoning_mode must be compact or detailed.");
  }
  const reasoningMode = b.reasoning_mode === "compact" ? "compact" : "detailed";
  if (b.model !== undefined && b.model !== null) {
    if (b.model !== "sonnet" && b.model !== "opus") throw bad("model must be \"sonnet\" or \"opus\".");
    if (b.model === "opus" && !allowOpus) warnings.push("the deeper model isn't switched on for this server, so the standard one planned this");
    else quality = b.model;
  }
  return { said, image, place, date, now, cam, firmware, slots, taste: parseTaste(b.taste), pastLooks: b.past_looks ?? null,
    count, protectedSlots, quality, shootingMode, reasoningMode, warnings };
}

/** What the plan was based on, so the app can say it ("Based on your photo"). The photo is context, not metering. */
function basis(p: ParsedPlanRequest, plan: Plan) {
  const forecast = plan.conditions.source;
  const parts = [p.image ? "your photo" : "", p.said ? "what you said" : "",
    forecast === "open-meteo" ? "the forecast" : forecast === "computed" ? "the sun times" : ""].filter(Boolean);
  const line = parts.length > 1 ? `Based on ${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}.` : `Based on ${parts[0] ?? "what you said"}.`;
  return { photo: Boolean(p.image), words: Boolean(p.said), forecast, line };
}

// ------------------------------------------------------------------ handlers

export type Deps = { ask?: Ask; limiter?: RateLimiter; log?: Log; env?: NodeJS.ProcessEnv; recipeKnowledge?: RecipeKnowledge;
  /** Trusted server/qualification override; never taken from client JSON. */
  outputMode?: "concise" | "legacy" };

function checkToken(request: Request, env: NodeJS.ProcessEnv): boolean {
  const token = env.APP_TOKEN;
  return !token || request.headers.get("x-app-token") === token;
}

/** POST /api/plan. */
export function planHandler(deps: Deps = {}) {
  const env = deps.env ?? process.env;
  const limiter = deps.limiter ?? limiterFrom(env.DIALIN_PLAN_RATE, "20/h");
  const log = deps.log ?? defaultLog;
  const requests = new ExactRequestPool<Plan>();
  return async function POST(request: Request): Promise<Response> {
    const rid = randomUUID().slice(0, 8);
    const t0 = Date.now();
    const base = { evt: "plan", rid };
    if (!checkToken(request, env)) {
      log({ ...base, status: 401, code: "bad_token" });
      return fail(401, "bad_token", "This app isn't allowed to use the server.");
    }
    if (request.signal.aborted) return fail(499, "cancelled", "That request was cancelled.");
    const device = deviceKey(request);
    const rl = limiter.take(device);
    if (!rl.ok) {
      log({ ...base, device, status: 429, code: "rate_limited" });
      return fail(429, "rate_limited", "That's a lot of plans. Try again in a little while.", { "retry-after": String(rl.retryAfterS) });
    }
    let parsed: ParsedPlanRequest | null = null;
    try {
      const body = await readJson(request, LIMITS.planBodyBytes);
      parsed = parsePlanRequest(body, modelConfig(env).allowOpus);
      const requestID = request.headers.get("x-request-id");
      if (requestID && !/^[A-Za-z0-9._-]{8,128}$/.test(requestID)) throw bad("x-request-id must be 8 to 128 simple characters.");
      const input = parsed;
      const generate = (signal: AbortSignal) => makePlan({
        said: input.said, imageBase64: input.image?.base64 ?? null, place: input.place, date: input.date, now: input.now,
        cameraSlots: input.slots, cam: input.cam, taste: input.taste, pastLooks: input.pastLooks, count: input.count,
        protectedSlots: input.protectedSlots,
        quality: input.quality, shootingMode: input.shootingMode, reasoningMode: input.reasoningMode, signal, ask: deps.ask,
        recipeKnowledge: deps.recipeKnowledge, outputMode: deps.outputMode,
      });
      let disposition: RequestDisposition = "new";
      let plan: Plan;
      if (requestID) {
        const shared = await requests.run(`${device}:${requestID}`, requestFingerprint(body), request.signal, generate);
        plan = shared.value;
        disposition = shared.disposition;
      } else plan = await generate(request.signal);
      throwIfAborted(request.signal);
      plan.warnings = [...parsed.warnings, ...plan.warnings];
      plan.camera_info = { model: parsed.cam.id, firmware: parsed.firmware };
      plan.basis = basis(parsed, plan);
      log({
        ...base, device, status: 200, ms: Date.now() - t0, camera: parsed.cam.id, quality: parsed.quality,
        image: parsed.image ? `${parsed.image.width}x${parsed.image.height}` : null, said_chars: parsed.said.length,
        place: parsed.place ? (typeof parsed.place === "string" ? "name" : "coords") : null, forecast: plan.conditions.source,
        looks: plan.day_looks.length, new: plan.write.slots.length, write: plan.write.mode, warnings: plan.warnings.length,
        request_key: requestID ? hash(`${device}:${requestID}`) : null, request_reuse: disposition,
        retry: (plan.calls ?? []).length > 1, calls: callsForLog(plan.calls), usd: totalUsd(plan.calls),
      });
      return json(plan);
    } catch (e) {
      if (request.signal.aborted || isCancellation(e)) {
        log({ ...base, device, status: 499, ms: Date.now() - t0, code: "cancelled" });
        return fail(499, "cancelled", "That request was cancelled.");
      }
      if (e instanceof Error && e.name === "TimeoutError") {
        log({ ...base, device, status: 504, ms: Date.now() - t0, code: "timeout" });
        return fail(504, "timeout", "That plan took too long. Try again.");
      }
      const pe = e instanceof PlanError ? e : null;
      const status = pe?.status ?? 500;
      log({ ...base, device, status, ms: Date.now() - t0, code: pe?.code ?? "internal",
        calls: callsForLog(pe?.calls), usd: totalUsd(pe?.calls),
        ...(pe ? {} : { err: e instanceof Error ? e.name : typeof e }) });
      return fail(status, pe?.code ?? "internal", pe?.message ?? "Something went wrong on our side. Try again.");
    }
  };
}

/** POST /api/adjust. */
export function adjustHandler(deps: Deps = {}) {
  const env = deps.env ?? process.env;
  const limiter = deps.limiter ?? limiterFrom(env.DIALIN_ADJUST_RATE, "120/h");
  const log = deps.log ?? defaultLog;
  return async function POST(request: Request): Promise<Response> {
    const rid = randomUUID().slice(0, 8);
    const t0 = Date.now();
    const base = { evt: "adjust", rid };
    if (!checkToken(request, env)) {
      log({ ...base, status: 401, code: "bad_token" });
      return fail(401, "bad_token", "This app isn't allowed to use the server.");
    }
    if (request.signal.aborted) return fail(499, "cancelled", "That request was cancelled.");
    const device = deviceKey(request);
    const rl = limiter.take(device);
    if (!rl.ok) {
      log({ ...base, device, status: 429, code: "rate_limited" });
      return fail(429, "rate_limited", "That's a lot of changes. Try again in a little while.", { "retry-after": String(rl.retryAfterS) });
    }
    try {
      const b = await readJson(request, LIMITS.adjustBodyBytes);
      const rawPlan = b.plan as Record<string, unknown> | undefined;
      const model = (b.camera as { model?: unknown } | undefined)?.model
        ?? (rawPlan?.camera_info as { model?: unknown } | undefined)?.model;
      const cam = cameraFor(typeof model === "string" ? model : null);
      if (!cam) throw new PlanError("Say which camera (camera.model), e.g. \"X100VI\".", "unsupported_camera", 400);
      if (typeof b.said !== "string" || !b.said.trim()) throw bad("Say what to change.", "no_input");
      if (b.said.length > LIMITS.saidChars) throw bad(`said is longer than ${LIMITS.saidChars} characters.`);
      if (!Number.isInteger(b.slot)) throw bad(`slot must be a number from 1 to ${cam.slots}.`, "bad_slot");
      let now: string | null = null;
      if (b.now !== undefined && b.now !== null && b.now !== "") {
        if (typeof b.now !== "string" || minutesOf(b.now) === null) throw bad("now must be HH:MM.");
        now = b.now;
      }
      const plan = planFromClient(rawPlan, cam);
      const out = await adjustPlan({ plan, slot: b.slot as number, said: b.said, now, cam, signal: request.signal, ask: deps.ask });
      throwIfAborted(request.signal);
      const calls = out.look.adjusted?.calls;
      log({ ...base, device, status: 200, ms: Date.now() - t0, camera: cam.id, slot: out.look.slot,
        renamed: out.look.name !== out.look.replaces, calls: callsForLog(calls), usd: totalUsd(calls) });
      return json({ look: out.look, write_slot: out.look.slot, plan: out.plan });
    } catch (e) {
      if (request.signal.aborted || isCancellation(e)) {
        log({ ...base, device, status: 499, ms: Date.now() - t0, code: "cancelled" });
        return fail(499, "cancelled", "That request was cancelled.");
      }
      if (e instanceof Error && e.name === "TimeoutError") {
        log({ ...base, device, status: 504, ms: Date.now() - t0, code: "timeout" });
        return fail(504, "timeout", "That change took too long. Try again.");
      }
      const pe = e instanceof PlanError ? e : null;
      const status = pe?.status ?? 500;
      log({ ...base, device, status, ms: Date.now() - t0, code: pe?.code ?? "internal",
        calls: callsForLog(pe?.calls), usd: totalUsd(pe?.calls),
        ...(pe ? {} : { err: e instanceof Error ? e.name : typeof e }) });
      return fail(status, pe?.code ?? "internal", pe?.message ?? "Something went wrong on our side. Try again.");
    }
  };
}

/** POST /api/recipe-reasoning: explain a received recipe; never regenerate its settings. */
export function recipeReasoningHandler(deps: Deps = {}) {
  const env = deps.env ?? process.env;
  const limiter = deps.limiter ?? limiterFrom(env.DIALIN_ADJUST_RATE, "120/h");
  const log = deps.log ?? defaultLog;
  return async function POST(request: Request): Promise<Response> {
    const t0 = Date.now();
    const base = { evt: "recipe_reasoning", rid: randomUUID().slice(0, 8) };
    if (!checkToken(request, env)) {
      log({ ...base, status: 401, code: "bad_token" });
      return fail(401, "bad_token", "This app isn't allowed to use the server.");
    }
    if (request.signal.aborted) return fail(499, "cancelled", "That request was cancelled.");
    const device = deviceKey(request);
    const rate = limiter.take(device);
    if (!rate.ok) {
      log({ ...base, device, status: 429, code: "rate_limited" });
      return fail(429, "rate_limited", "Try again in a little while.", { "retry-after": String(rate.retryAfterS) });
    }
    try {
      const body = await readJson(request, LIMITS.adjustBodyBytes);
      const raw = body.plan as Record<string, unknown> | undefined;
      const model = (body.camera as { model?: unknown } | undefined)?.model
        ?? (raw?.camera_info as { model?: unknown } | undefined)?.model;
      const cam = cameraFor(typeof model === "string" ? model : null);
      if (!cam) throw new PlanError("Say which camera (camera.model), e.g. \"X100VI\".", "unsupported_camera", 400);
      if (!Number.isInteger(body.slot) || (body.slot as number) < 1 || (body.slot as number) > cam.slots) {
        throw bad(`slot must be a number from 1 to ${cam.slots}.`, "bad_slot");
      }
      const plan = planFromClient(raw, cam);
      const result = await explainRecipe({ plan, slot: body.slot as number, cam, ask: deps.ask, signal: request.signal });
      throwIfAborted(request.signal);
      log({ ...base, device, status: 200, ms: Date.now() - t0, camera: cam.id, slot: body.slot,
        calls: callsForLog(result.calls), usd: totalUsd(result.calls) });
      return json(result);
    } catch (error) {
      if (request.signal.aborted || isCancellation(error)) {
        log({ ...base, device, status: 499, ms: Date.now() - t0, code: "cancelled" });
        return fail(499, "cancelled", "That request was cancelled.");
      }
      const pe = error instanceof PlanError ? error : null;
      const status = pe?.status ?? (error instanceof Error && error.name === "TimeoutError" ? 504 : 500);
      const code = pe?.code ?? (status === 504 ? "timeout" : "internal");
      log({ ...base, device, status, ms: Date.now() - t0, code, calls: callsForLog(pe?.calls), usd: totalUsd(pe?.calls) });
      return fail(status, code, pe?.message ?? (status === 504 ? "That explanation took too long. Try again." : "Something went wrong on our side. Try again."));
    }
  };
}
