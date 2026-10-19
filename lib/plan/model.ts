// Every model call of the plan engine goes through an Ask: one structured call with a time budget and a fallback
// model, the same prompts and schemas over two transports (mirrors studio/ai.py):
//
//   api        The Anthropic TypeScript SDK, Messages API with structured outputs (output_config.format json_schema),
//              the system prompt cached, server-side refusal fallback on Sonnet/Opus. THE PRODUCTION PATH.
//              Unit-tested against a mocked client only: UNTESTED AGAINST THE LIVE API until a key exists.
//   claude -p  Explicit local opt-in only: headless Claude Code, with --json-schema.
//              Never used on Vercel or with NODE_ENV=production.
//
// Selection: DIALIN_MODEL_TRANSPORT=api|cli forces one; otherwise ANTHROPIC_API_KEY → api, else no transport.
// Timeouts: the primary model gets 72% of the budget, the fallback model the rest (or all of it after a fast failure).
import { spawn } from "node:child_process";
import { accessSync, constants, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import Anthropic from "@anthropic-ai/sdk";
import { claude } from "../claude.js";
import type { Usage } from "./types.js";
import { isCancellation, requestDeadline, throwIfAborted } from "./abort.js";

export type Effort = "low" | "medium" | "high" | "xhigh" | "max";

export const MODELS = {
  sonnet: "claude-sonnet-5-5",
  opus: "claude-opus-5-5",
  haiku: "claude-haiku-5-5",
} as const;

/** USD per million tokens (Claude API list prices, 2026-10). Cache writes are the 5-minute rate. Haiku 5.5's rate is
 *  for prompts up to 100K tokens; ours are far below. */
export const PRICES: Record<string, { input: number; output: number; cacheRead: number; cacheWrite: number }> = {
  [MODELS.opus]: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 },
  [MODELS.sonnet]: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5 },
  [MODELS.haiku]: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125 },
};

/** Estimated cost of one call, or null for an unknown model or missing usage. */
export function costUsd(model: string | null | undefined, usage: Usage | null | undefined): number | null {
  let p = model ? PRICES[model] : undefined;
  if (!p || !usage) return null;
  if (model === MODELS.haiku && usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens > 100_000) {
    p = { input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625 };
  }
  const usd = (usage.input_tokens * p.input + usage.output_tokens * p.output
    + usage.cache_read_input_tokens * p.cacheRead + usage.cache_creation_input_tokens * p.cacheWrite) / 1e6;
  return Math.round(usd * 1e6) / 1e6;
}

/** Models that get the server-side refusal fallback (Haiku 5.5 has none). */
const SERVER_FALLBACK = new Set<string>([MODELS.sonnet, MODELS.opus]);
export const SERVER_FALLBACK_BETA = "server-side-fallback-2026-07-01";

export type AskRequest = {
  task: string;
  system: string;
  text: string;
  /** Base64 JPEG, no data: prefix. Never logged. */
  imageBase64?: string | null;
  schema: Record<string, unknown>;
  model: string;
  fallback?: string | null;
  effort: Effort;
  fallbackEffort?: Effort;
  /** Total wall-clock budget for this ask, both models included. */
  timeoutMs: number;
  maxTokens?: number;
  signal?: AbortSignal;
  /** Benchmarks can disable hidden server fallback to keep the number of provider requests bounded. */
  serverFallback?: boolean;
};

export type UsageIteration = { type: string; model: string | null; usage: Usage; reportedCostUsd?: number | null;
  cacheCreation?: Record<string, number> | null };
/** The transport stopwatch is local. CLI aggregates are reported by the CLI, not independently measured
 * server phases. Neither single-result transport observes the first generated token. */
export type AttemptTiming = {
  transport: "cli_process" | "sdk_nonstreaming";
  transportMs: number | null;
  cliReportedDurationMs: number | null;
  cliReportedApiMs: number | null;
  cliReportedTurns: number | null;
  firstTokenMs: null;
  firstTokenUnavailableReason: "cli_single_result" | "sdk_nonstreaming";
};
export type AttemptObservations = {
  servedModel?: string | null;
  providerRequestID?: string | null;
  stopReason?: string | null;
  usage?: Usage | null;
  /** Provider top-level usage before aggregating server/client attempts. */
  providerUsage?: Usage | null;
  usageIterations?: UsageIteration[];
  usageComplete?: boolean;
  usageScope?: "api_request" | "cli_aggregate";
  reportedCostUsd?: number | null;
  outputTokenDetails?: Record<string, number> | null;
  cacheCreation?: Record<string, number> | null;
  timing?: AttemptTiming;
};
export type AskTry = AttemptObservations & { model: string; ms: number; ok: boolean; code: string | null; usd?: number | null };

export type AskAnswer = {
  ok: boolean;
  data: unknown;
  model: string;
  via: string;
  ms: number;
  /** A plain sentence (never the person's words). */
  error: string | null;
  /** Safe to log. */
  code: string | null;
  usage: Usage | null;
  usd: number | null;
  tries: AskTry[];
  requestedModel?: string;
  servedModel?: string | null;
  usageComplete?: boolean;
  reportedCostUsd?: number | null;
};

export type Ask = (req: AskRequest) => Promise<AskAnswer>;

export class ModelError extends Error {
  constructor(message: string, public code: string, public fatal = false, public observations: AttemptObservations = {}) {
    super(message);
    this.name = "ModelError";
  }
}

export type AttemptResult = AttemptObservations & { data: unknown; model: string; usage: Usage | null };
/** One try on one model within budgetMs; throws ModelError (or an SDK error) on failure. */
export type Attempt = (req: AskRequest, model: string, effort: Effort, budgetMs: number) => Promise<AttemptResult>;

export const PRIMARY_SHARE = 0.72;
const MIN_ATTEMPT_MS = 6_000;

const usageKeys = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] as const;
const zeroUsage = (): Usage => ({ input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 });
const sumUsage = (values: Usage[]): Usage => values.reduce((sum, u) => {
  for (const key of usageKeys) sum[key] += u[key];
  return sum;
}, zeroUsage());

export function attemptCost(observations: AttemptObservations): number | null {
  if (observations.usageIterations?.length) {
    const costs = observations.usageIterations.map((iteration) => costWithCacheTTL(iteration.model, iteration.usage, iteration.cacheCreation));
    return costs.some((value) => value === null) ? null : Math.round(costs.reduce<number>((sum, value) => sum + (value ?? 0), 0) * 1e6) / 1e6;
  }
  return costWithCacheTTL(observations.servedModel, observations.usage, observations.cacheCreation);
}

function costWithCacheTTL(model: string | null | undefined, usage: Usage | null | undefined, cache?: Record<string, number> | null): number | null {
  const standard = costUsd(model, usage);
  if (standard === null || !model || !usage) return null;
  const inputPrice = model === MODELS.haiku && usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens > 100_000
    ? 0.5 : PRICES[model]?.input;
  if (inputPrice === undefined) return null;
  return Math.round((standard + (cache?.ephemeral_1h_input_tokens ?? 0) * inputPrice * 0.75 / 1e6) * 1e6) / 1e6;
}

function measurements(tries: AskTry[]) {
  const known = tries.flatMap((t) => t.usage ? [t.usage] : []);
  const complete = tries.length > 0 && tries.every((t) => t.usage !== null && t.usage !== undefined && t.usageComplete !== false);
  return {
    usage: known.length ? sumUsage(known) : null,
    usageComplete: complete,
    usd: complete && tries.every((t) => t.usd !== null && t.usd !== undefined)
      ? Math.round(tries.reduce((sum, t) => sum + (t.usd ?? 0), 0) * 1e6) / 1e6 : null,
    reportedCostUsd: tries.length && tries.every((t) => typeof t.reportedCostUsd === "number")
      ? tries.reduce((sum, t) => sum + (t.reportedCostUsd ?? 0), 0) : null,
  };
}

/** Failures return receipts; owner cancellation throws and never starts a fallback. */
export function makeAsk(attempt: Attempt, via: string): Ask {
  return async (req) => {
    throwIfAborted(req.signal);
    const t0 = Date.now();
    const order = [req.model, ...(req.fallback && req.fallback !== req.model ? [req.fallback] : [])];
    const tries: AskTry[] = [];
    let last: ModelError | null = null;
    for (let n = 0; n < order.length; n++) {
      throwIfAborted(req.signal);
      const left = req.timeoutMs - (Date.now() - t0);
      const budget = n ? left : order.length > 1 ? left * PRIMARY_SHARE : left;
      if (budget < MIN_ATTEMPT_MS) break;
      const ta = Date.now();
      try {
        const r = await attempt(req, order[n], n ? (req.fallbackEffort ?? req.effort) : req.effort, Math.round(budget));
        throwIfAborted(req.signal);
        const { data: _data, model: _model, ...observations } = r;
        tries.push({ ...observations, model: order[n], ms: Date.now() - ta, ok: true, code: null, usd: attemptCost(observations) });
        const model = r.model || order[n];
        return { ok: true, data: r.data, model, requestedModel: req.model, servedModel: r.servedModel ?? null,
          via, ms: Date.now() - t0, error: null, code: null, ...measurements(tries), tries };
      } catch (e) {
        throwIfAborted(req.signal);
        if (isCancellation(e)) throw e;
        last = toModelError(e);
        tries.push({ ...last.observations, model: order[n], ms: Date.now() - ta, ok: false, code: last.code,
          usd: attemptCost(last.observations), usageComplete: last.observations.usageComplete ?? false });
        if (last.fatal) break;
      }
    }
    throwIfAborted(req.signal);
    return { ok: false, data: null, model: order[0], requestedModel: req.model, servedModel: null,
      via, ms: Date.now() - t0, error: last?.message ?? "Claude ran out of time",
      code: last?.code ?? "timeout", ...measurements(tries), tries };
  };
}

/** SDK and transport failures → a plain sentence and a loggable code. Most specific first. */
export function toModelError(e: unknown): ModelError {
  if (e instanceof ModelError) return e;
  if (e instanceof Error && e.name === "TimeoutError") return new ModelError("Claude took too long", "timeout");
  if (e instanceof Anthropic.APIConnectionTimeoutError) return new ModelError("Claude took too long", "timeout");
  if (e instanceof Anthropic.APIUserAbortError) return new ModelError("Claude took too long", "timeout");
  if (e instanceof Anthropic.AuthenticationError) return new ModelError("the server's Claude API key was refused", "auth", true);
  if (e instanceof Anthropic.PermissionDeniedError) return new ModelError("the server's Claude API key isn't allowed to do this", "permission", true);
  if (e instanceof Anthropic.RateLimitError) return new ModelError("Claude is rate-limited right now", "rate_limited");
  if (e instanceof Anthropic.BadRequestError) return new ModelError("Claude rejected the request", "bad_request");
  if (e instanceof Anthropic.InternalServerError) return new ModelError("Claude is overloaded or had a server error", "server_error");
  if (e instanceof Anthropic.APIConnectionError) return new ModelError("couldn't reach Claude", "connection");
  if (e instanceof Anthropic.APIError) {
    if (e.status === 402) return new ModelError("the server's Claude account needs billing attention", "billing", true);
    return new ModelError(`Claude API error ${e.status ?? ""}`.trim(), "api_error");
  }
  return new ModelError(e instanceof Error ? e.message.slice(0, 200) : String(e).slice(0, 200), "unknown");
}

// ------------------------------------------------------------------ transport 1: the Claude API (production)

type BetaParams = Anthropic.Beta.Messages.MessageCreateParamsNonStreaming;
type BetaMessage = Anthropic.Beta.Messages.BetaMessage;
/** The slice of the SDK client we use (so tests can pass a mock). */
export type SdkLike = {
  beta: { messages: { create: (params: BetaParams, options?: { timeout?: number; maxRetries?: number; signal?: AbortSignal }) => PromiseLike<BetaMessage> } };
};

/** The request body for one SDK try. Exported for tests. */
export function sdkParams(req: AskRequest, model: string, effort: Effort): BetaParams {
  const content: Anthropic.Beta.Messages.BetaContentBlockParam[] = [];
  if (req.imageBase64) {
    content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: req.imageBase64 } });
  }
  content.push({ type: "text", text: req.text });
  const serverFallback = req.serverFallback !== false && SERVER_FALLBACK.has(model) && process.env.DIALIN_SERVER_FALLBACK !== "off";
  return {
    model,
    max_tokens: req.maxTokens ?? 16_000,
    // Stable prefix, cached: the system prompt is the same for every request on this camera.
    system: [{ type: "text", text: req.system, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content }],
    // Adaptive thinking is the default on all three models; effort is the depth control.
    output_config: { effort, format: { type: "json_schema", schema: req.schema } },
    ...(serverFallback ? { betas: [SERVER_FALLBACK_BETA], fallbacks: "default" as const } : {}),
  };
}

export function sdkAttempt(client: SdkLike): Attempt {
  return async (req, model, effort, budgetMs) => {
    throwIfAborted(req.signal);
    const deadline = requestDeadline(budgetMs, req.signal);
    const started = performance.now();
    let res: BetaMessage;
    try {
      res = await client.beta.messages.create(sdkParams(req, model, effort), { timeout: budgetMs, maxRetries: 0, signal: deadline.signal });
      throwIfAborted(deadline.signal);
    } catch (error) {
      throwIfAborted(req.signal);
      let failure = error;
      try { throwIfAborted(deadline.signal); } catch (deadlineError) { failure = deadlineError; }
      if (isCancellation(failure)) throw failure;
      const mapped = toModelError(failure);
      throw new ModelError(mapped.message, mapped.code, mapped.fatal, {
        ...mapped.observations, timing: sdkTiming(elapsedMs(started)),
      });
    } finally { deadline.dispose(); }
    const observations = { ...sdkObservations(res), timing: sdkTiming(elapsedMs(started)) };
    if (res.stop_reason === "refusal") throw new ModelError("Claude declined this one", "refused", false, observations);
    if (res.stop_reason === "max_tokens") throw new ModelError("Claude's answer ran out of room", "max_tokens", false, observations);
    const block = res.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") throw new ModelError("Claude sent no answer", "no_text", false, observations);
    let data: unknown;
    try {
      data = JSON.parse(block.text);
    } catch {
      throw new ModelError("Claude's answer wasn't readable", "bad_json", false, observations);
    }
    return {
      data,
      model: res.model || model,
      ...observations,
      usage: observations.usage ?? null,
    };
  };
}

const finiteCount = (value: unknown) => typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
const finiteMeasurement = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
const elapsedMs = (started: number): number => Math.round(performance.now() - started);
function sdkTiming(transportMs: number): AttemptTiming {
  return { transport: "sdk_nonstreaming", transportMs, cliReportedDurationMs: null, cliReportedApiMs: null,
    cliReportedTurns: null, firstTokenMs: null, firstTokenUnavailableReason: "sdk_nonstreaming" };
}
function cliTiming(result: Record<string, unknown> = {}, transportMs: number | null = null): AttemptTiming {
  return { transport: "cli_process", transportMs, cliReportedDurationMs: finiteMeasurement(result.duration_ms),
    cliReportedApiMs: finiteMeasurement(result.duration_api_ms),
    cliReportedTurns: Number.isSafeInteger(result.num_turns) ? finiteMeasurement(result.num_turns) : null,
    firstTokenMs: null, firstTokenUnavailableReason: "cli_single_result" };
}
const safeID = (value: unknown): string | null => typeof value === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(value) ? value : null;
const safeModelID = (value: unknown): string | null => typeof value === "string" && /^claude-[A-Za-z0-9-]{1,120}$/.test(value) ? value : null;
function readUsage(value: unknown): Usage | null {
  if (!value || typeof value !== "object") return null;
  const u = value as Record<string, unknown>;
  if (typeof u.input_tokens !== "number" || !Number.isFinite(u.input_tokens) || u.input_tokens < 0
      || typeof u.output_tokens !== "number" || !Number.isFinite(u.output_tokens) || u.output_tokens < 0) return null;
  return Object.fromEntries(usageKeys.map((key) => [key, finiteCount(u[key])])) as Usage;
}

function numericFields(value: unknown, keys: string[]): Record<string, number> | null {
  if (!value || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  return Object.fromEntries(keys.filter((key) => typeof record[key] === "number").map((key) => [key, finiteCount(record[key])]));
}

/** Whitelist observability fields, never retain response text or headers with credentials. */
function sdkObservations(res: BetaMessage): AttemptObservations {
  const usage = readUsage(res.usage);
  const iterations: UsageIteration[] = [];
  let allIterationsKnown = true;
  for (const entry of res.usage?.iterations ?? []) {
    const value = readUsage(entry);
    if (!value) { allIterationsKnown = false; continue; }
    iterations.push({ type: safeID(entry.type) ?? "unknown", model: "model" in entry ? safeModelID(entry.model) : null, usage: value,
      cacheCreation: "cache_creation" in entry ? numericFields(entry.cache_creation, ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]) : null });
  }
  // Iterations include separately billed compaction tokens absent from top-level usage.
  // Retain top-level totals when no breakdown exists; never add both totals and their breakdown.
  return {
    servedModel: safeModelID(res.model),
    providerRequestID: safeID((res as BetaMessage & { _request_id?: string })._request_id),
    stopReason: safeID(res.stop_reason),
    usage: iterations.length ? sumUsage(iterations.map((entry) => entry.usage)) : usage,
    providerUsage: usage,
    usageIterations: iterations,
    usageComplete: Boolean(usage) && allIterationsKnown,
    usageScope: "api_request",
    outputTokenDetails: numericFields(res.usage?.output_tokens_details, ["text_tokens", "thinking_tokens", "tool_use_tokens"]),
    cacheCreation: numericFields(res.usage?.cache_creation, ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]),
  };
}

// ------------------------------------------------------------------ transport 2: headless Claude Code (local dev)

/** The claude binary: DIALIN_CLAUDE, PATH, then the usual installs. */
export function claudeBin(env: NodeJS.ProcessEnv = process.env): string | null {
  const home = env.HOME ?? "";
  const candidates = env.DIALIN_CLAUDE ? [env.DIALIN_CLAUDE] : [
    ...(env.PATH ?? "").split(delimiter).filter(Boolean).map((d) => join(d, "claude")),
    join(home, ".local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
  ];
  for (const c of candidates) {
    try {
      accessSync(c, constants.X_OK);
      return c;
    } catch { /* next */ }
  }
  return null;
}

/** studio/ai.py cli_argv, plus --effort so dev runs think as much as production. The prompt goes in on stdin. */
export function cliArgv(system: string, schema: Record<string, unknown>, model: string, effort: Effort, hasImage = false): string[] {
  return ["-p", "--model", model, "--effort", effort, "--output-format", "json",
    "--json-schema", JSON.stringify(schema), "--no-session-persistence",
    // Text requests already carry their complete context. Only an attached scene needs the image Read tool.
    "--tools", hasImage ? "Read" : "", ...(hasImage ? ["--allowedTools", "Read"] : []),
    "--permission-prompts", "none", "--strict-mcp-config",
    "--system-prompt", system];
}

/** claude -p's JSON result → the structured answer and its usage. Exported for tests. */
export function parseCliResult(stdout: string): { data: unknown; usage: Usage | null; costUsd: number | null;
  servedModel: string | null; usageIterations: UsageIteration[]; timing: AttemptTiming } {
  const i = stdout.indexOf("{");
  const j = stdout.lastIndexOf("}");
  if (i < 0 || j < i) throw new ModelError("claude -p sent no answer", "cli_failed");
  let res: Record<string, unknown>;
  try {
    res = JSON.parse(stdout.slice(i, j + 1));
  } catch {
    throw new ModelError("claude -p's answer wasn't readable", "bad_json");
  }
  const usage = readUsage(res.usage);
  const usageIterations: UsageIteration[] = [];
  if (res.modelUsage && typeof res.modelUsage === "object" && !Array.isArray(res.modelUsage)) {
    for (const [model, entry] of Object.entries(res.modelUsage)) {
      if (!safeModelID(model) || !entry || typeof entry !== "object") continue;
      const u = entry as Record<string, unknown>;
      const value = readUsage({ input_tokens: u.inputTokens, output_tokens: u.outputTokens,
        cache_read_input_tokens: u.cacheReadInputTokens, cache_creation_input_tokens: u.cacheCreationInputTokens });
      if (value) usageIterations.push({ type: "cli_model_aggregate", model, usage: value,
        reportedCostUsd: typeof u.costUSD === "number" ? finiteCount(u.costUSD) : null });
    }
  }
  const timing = cliTiming(res);
  const observations: AttemptObservations = { usage, providerUsage: usage, servedModel: safeModelID(res.model), usageIterations,
    usageScope: "cli_aggregate", usageComplete: Boolean(usage),
    timing,
    reportedCostUsd: typeof res.total_cost_usd === "number" && Number.isFinite(res.total_cost_usd) && res.total_cost_usd >= 0 ? res.total_cost_usd : null };
  if (res.is_error) {
    const msg = String(res.result ?? res.subtype ?? "claude -p reported an error").slice(0, 200);
    throw new ModelError(msg, /limit|rate/i.test(msg) ? "rate_limited" : "cli_failed", false, observations);
  }
  let data = res.structured_output;
  if (data === undefined || data === null) {
    try {
      data = JSON.parse(String(res.result ?? ""));
    } catch {
      throw new ModelError("claude -p returned no structured answer", "bad_json", false, observations);
    }
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new ModelError("claude -p returned something other than an object", "bad_json", false, observations);
  }
  return { data, usage, servedModel: observations.servedModel ?? null, usageIterations,
    costUsd: observations.reportedCostUsd ?? null, timing };
}

export function cliAttempt(bin: string | null = claudeBin()): Attempt {
  return async (req, model, effort, budgetMs) => {
    throwIfAborted(req.signal);
    if (!bin) throw new ModelError("claude isn't installed on this Mac", "cli_missing", true);
    let dir: string | null = null;
    let prompt = req.text;
    if (req.imageBase64) {
      // The CLI reads images from disk with its Read tool: a private temp folder, deleted right after.
      dir = mkdtempSync(join(tmpdir(), "dialin-scene-"));
      const file = join(dir, "scene.jpg");
      writeFileSync(file, Buffer.from(req.imageBase64, "base64"), { mode: 0o600 });
      prompt = `Look at ${file} with the Read tool before you answer.\n\n${prompt}`;
    }
    const env: NodeJS.ProcessEnv = { ...process.env, DISABLE_AUTOUPDATER: "1" };
    delete env.ANTHROPIC_API_KEY; // dev mode is Claude Code's own login, never a key
    const started = performance.now();
    let transportMs: number | null = null;
    try {
      const { stdout, stderr, code, timedOut } = await run(bin, cliArgv(req.system, req.schema, model, effort, Boolean(req.imageBase64)), prompt,
        dir ?? tmpdir(), env, budgetMs, req.signal);
      transportMs = elapsedMs(started);
      throwIfAborted(req.signal);
      if (timedOut) throw new ModelError("Claude took too long", "timeout");
      if (code !== 0 && stdout.indexOf("{") < 0) {
        const line = (stderr.trim().split("\n").pop() ?? `claude -p failed (exit ${code})`).slice(0, 200);
        throw new ModelError(line, /limit|rate/i.test(line) ? "rate_limited" : "cli_failed");
      }
      const r = parseCliResult(stdout);
      return { data: r.data, model: r.servedModel ?? model, servedModel: r.servedModel, usage: r.usage,
        usageIterations: r.usageIterations, usageComplete: Boolean(r.usage), usageScope: "cli_aggregate", reportedCostUsd: r.costUsd,
        timing: { ...r.timing, transportMs } };
    } catch (error) {
      throwIfAborted(req.signal);
      if (isCancellation(error)) throw error;
      const mapped = toModelError(error);
      throw new ModelError(mapped.message, mapped.code, mapped.fatal, {
        ...mapped.observations,
        timing: { ...cliTiming(), ...mapped.observations.timing, transportMs: transportMs ?? elapsedMs(started) },
      });
    } finally {
      if (dir) rmSync(dir, { recursive: true, force: true });
    }
  };
}

function run(bin: string, argv: string[], input: string, cwd: string, env: NodeJS.ProcessEnv, timeoutMs: number, signal?: AbortSignal):
  Promise<{ stdout: string; stderr: string; code: number | null; timedOut: boolean }> {
  return new Promise((resolve, reject) => {
    throwIfAborted(signal);
    const child = spawn(bin, argv, { cwd, env, detached: true, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const kill = () => {
      try {
        if (child.pid) process.kill(-child.pid, "SIGKILL"); // its whole process group
      } catch { /* already gone */ }
    };
    const timer = setTimeout(() => {
      timedOut = true;
      kill();
    }, timeoutMs);
    signal?.addEventListener("abort", kill, { once: true });
    const cleanup = () => { clearTimeout(timer); signal?.removeEventListener("abort", kill); };
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("error", (e) => {
      cleanup();
      reject(new ModelError(`claude couldn't start (${(e as NodeJS.ErrnoException).code ?? e.message})`, "cli_missing", true));
    });
    child.on("close", (code) => {
      cleanup();
      resolve({ stdout, stderr, code, timedOut });
    });
    child.stdin.on("error", () => { /* it died before reading the prompt; close reports it */ });
    child.stdin.end(input);
  });
}

// ------------------------------------------------------------------ which transport

export type Transport = "api" | "cli" | "none";

export function transportMode(env: NodeJS.ProcessEnv = process.env): Transport {
  const deployed = Boolean(env.VERCEL) || env.NODE_ENV === "production";
  const forced = env.DIALIN_MODEL_TRANSPORT;
  if (forced === "api") return "api";
  if (forced === "cli") return deployed ? "none" : "cli";
  if (env.ANTHROPIC_API_KEY) return "api";
  return "none";
}

/** The SDK with a key, explicitly opted-in local CLI, or a clear failure. Never start a logged-in CLI implicitly. */
export function defaultAsk(env: NodeJS.ProcessEnv = process.env): Ask {
  const mode = transportMode(env);
  if (mode === "api") return makeAsk(sdkAttempt(claude()), "api");
  if (mode === "cli") return makeAsk(cliAttempt(), "claude -p");
  return async (req) => ({
    ok: false, data: null, model: req.model, via: "none", ms: 0, error: "No model transport configured. Use desktop plan --mode agent, provide ANTHROPIC_API_KEY, or explicitly opt into DIALIN_MODEL_TRANSPORT=cli for local development.",
    code: "no_model", usage: null, usd: null, tries: [],
  });
}
