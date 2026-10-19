import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { buildRecipeLibrary, type PublicRecipeIndex, type PublicRecipeSettings, type RecipeJudgment, type RecipeKnowledge } from "./library.js";
import type { RecipeUsageGrant, RecipeUseMode } from "./permissions.js";

/** Explicit local tooling only. Never import the public corpus into the browser bundle or parse a client-supplied path. */
export function loadLocalRecipeKnowledge(directory: string, mode: RecipeUseMode, options: { requireComplete?: boolean } = {}): RecipeKnowledge {
  const read = <T>(name: string): T => JSON.parse(readFileSync(resolve(directory, name), "utf8")) as T;
  const optional = <T>(name: string): T[] => {
    if (!existsSync(resolve(directory, name))) return [];
    const value = read<T[] | { judgments: T[] }>(name);
    const rows = Array.isArray(value) ? value : value.judgments;
    if (!Array.isArray(rows)) throw new Error(`Invalid ${name}; expected an array.`);
    return rows;
  };
  const indexText = readFileSync(resolve(directory, "public-index.json"), "utf8");
  const index = JSON.parse(indexText) as PublicRecipeIndex;
  const settings = read<PublicRecipeSettings>("public-settings.json");
  if (settings.index_sha256 !== createHash("sha256").update(indexText).digest("hex")) throw new Error("Recipe settings and index are from different source snapshots.");
  if (options.requireComplete && (settings.fetch_summary as { complete_coverage?: boolean })?.complete_coverage !== true) {
    throw new Error("Recipe extraction is incomplete; keep it in research tooling until every inventory entry has a receipt.");
  }
  return { library: buildRecipeLibrary(settings, index),
    permissions: optional<RecipeUsageGrant>("usage-permissions.json"), judgments: optional<RecipeJudgment>("reviewed-judgments.json"), mode };
}
