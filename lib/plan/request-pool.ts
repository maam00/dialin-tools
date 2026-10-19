import { createHash } from "node:crypto";
import { throwIfAborted } from "./abort.js";
import { PlanError } from "./types.js";

type Entry<T> = { fingerprint: string; controller: AbortController; promise: Promise<T>; subscribers: number;
  completed: boolean; expiresAt: number };
export type RequestDisposition = "new" | "joined" | "reused";
const canonical = (value: unknown): unknown => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === "object" ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, v]) => [key, canonical(v)])) : value;
export const requestFingerprint = (value: unknown) => createHash("sha256").update(JSON.stringify(canonical(value))).digest("hex");

/** Per-instance exact-request reuse. Cancels upstream only after every active subscriber has left. */
export class ExactRequestPool<T> {
  private entries = new Map<string, Entry<T>>();
  constructor(private maxEntries = 128, private ttlMs = 300_000) {}

  async run(key: string, fingerprint: string, signal: AbortSignal,
    start: (signal: AbortSignal) => Promise<T>): Promise<{ value: T; disposition: RequestDisposition }> {
    throwIfAborted(signal);
    const now = Date.now();
    for (const [savedKey, entry] of this.entries) if (entry.completed && entry.expiresAt <= now) this.entries.delete(savedKey);
    let entry = this.entries.get(key);
    let disposition: RequestDisposition = entry?.completed ? "reused" : entry ? "joined" : "new";
    if (entry && entry.fingerprint !== fingerprint) throw new PlanError("That request ID was already used for different input. Start a new request.", "request_id_reused", 409);
    if (!entry) {
      if (this.entries.size >= this.maxEntries) {
        const evictable = [...this.entries].find(([, value]) => value.completed);
        if (evictable) this.entries.delete(evictable[0]);
        else throw new PlanError("The planner is busy. Try again shortly.", "planner_busy", 503);
      }
      const controller = new AbortController();
      const created: Entry<T> = { fingerprint, controller, subscribers: 0, completed: false, expiresAt: Infinity, promise: Promise.resolve(null as T) };
      created.promise = Promise.resolve().then(() => { throwIfAborted(controller.signal); return start(controller.signal); }).then((value) => {
        throwIfAborted(controller.signal);
        created.completed = true;
        created.expiresAt = Date.now() + this.ttlMs;
        return structuredClone(value);
      }).catch((error) => {
        if (this.entries.get(key) === created) this.entries.delete(key);
        throw error;
      });
      entry = created;
      this.entries.set(key, entry);
      disposition = "new";
    }
    const subscribed = entry;
    subscribed.subscribers += 1;
    const value = await new Promise<T>((resolve, reject) => {
      let finished = false;
      const finish = (failed: boolean, error: unknown, result?: T) => {
        if (finished) return;
        finished = true;
        signal.removeEventListener("abort", aborted);
        subscribed.subscribers -= 1;
        if (!subscribed.completed && subscribed.subscribers === 0) {
          subscribed.controller.abort();
          if (this.entries.get(key) === subscribed) this.entries.delete(key);
        }
        failed ? reject(error) : resolve(structuredClone(result as T));
      };
      const aborted = () => {
        try { throwIfAborted(signal); } catch (error) { finish(true, error); }
      };
      signal.addEventListener("abort", aborted, { once: true });
      subscribed.promise.then((result) => finish(false, null, result), (error) => finish(true, error));
      if (signal.aborted) aborted();
    });
    return { value, disposition };
  }
}
