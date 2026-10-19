import type { IncomingMessage, ServerResponse } from "node:http";

/** A consumed request can still lose its response socket while the model runs. */
export function nodeRequestOwner(request: IncomingMessage, response: ServerResponse): { signal: AbortSignal; dispose: () => void } {
  const controller = new AbortController();
  const aborted = () => controller.abort(new DOMException("Request cancelled", "AbortError"));
  const closed = () => { if (!response.writableEnded) aborted(); };
  request.once("aborted", aborted);
  response.once("close", closed);
  if (request.aborted || response.destroyed) aborted();
  return { signal: controller.signal, dispose: () => {
    request.removeListener("aborted", aborted);
    response.removeListener("close", closed);
  } };
}
