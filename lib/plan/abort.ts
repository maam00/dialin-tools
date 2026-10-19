/** Cancellation stays distinct from failure/timeout so callers never start a fallback for departed work. */
export function throwIfAborted(signal?: AbortSignal): void {
  if (!signal?.aborted) return;
  throw signal.reason instanceof Error ? signal.reason : new DOMException("Request cancelled", "AbortError");
}

export function isCancellation(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

/** One disposable deadline, optionally tied to the owner of the request. */
export function requestDeadline(ms: number, parent?: AbortSignal): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const aborted = () => controller.abort(parent?.reason ?? new DOMException("Request cancelled", "AbortError"));
  if (parent?.aborted) aborted();
  else parent?.addEventListener("abort", aborted, { once: true });
  const timer = setTimeout(() => controller.abort(new DOMException("Request deadline exceeded", "TimeoutError")), Math.max(0, ms));
  timer.unref?.();
  return { signal: controller.signal, dispose: () => { clearTimeout(timer); parent?.removeEventListener("abort", aborted); } };
}

export async function abortableDelay(ms: number, signal?: AbortSignal): Promise<void> {
  throwIfAborted(signal);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { signal?.removeEventListener("abort", aborted); resolve(); }, ms);
    const aborted = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", aborted);
      try { throwIfAborted(signal); } catch (error) { reject(error); }
    };
    signal?.addEventListener("abort", aborted, { once: true });
  });
}
