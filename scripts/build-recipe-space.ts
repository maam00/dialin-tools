// Build the public community-practice priors from a private recipe catalog. Runs locally; no network or model.
// The output holds only aggregate counts (each >= k records) and is refused unless the privacy check passes.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { installedRecipeKnowledge, loadRecipeKnowledge } from "../modules/recipes/knowledge.js";
import { buildRecipeSpacePriors, checkRecipeSpacePrivacy, serializeRecipeSpacePriors } from "../modules/recipes/space.js";

const HELP = `Usage: node --import tsx scripts/build-recipe-space.ts --out data/recipe-space/priors.json [--catalog CATALOG.json] [--replace]

Reads the private catalog (--catalog, else DIALIN_RECIPE_CATALOG, else data/recipe-knowledge/catalog.json), aggregates
how its recipes set each control per film simulation, and writes only counts that each cover at least 5 recipes.
It refuses to write if any record could be reconstructed. An existing --out is replaced only with --replace.`;

export function main(args: string[]): number {
  const { values } = parseArgs({ args, options: { out: { type: "string" }, catalog: { type: "string" }, replace: { type: "boolean" }, help: { type: "boolean", short: "h" } } });
  if (values.help) { console.log(HELP); return 0; }
  if (!values.out) { console.error(HELP); return 2; }
  const installed = values.catalog ? null : installedRecipeKnowledge();
  if (installed && !installed.status.installed) { console.error(`${installed.status.note} ${installed.status.how_to_install}`); return 1; }
  const knowledge = installed ? installed.knowledge : loadRecipeKnowledge(resolve(values.catalog!));
  const out = resolve(values.out);
  if (existsSync(out) && !values.replace) { console.error("Output already exists; pass --replace to update it."); return 1; }
  const priors = buildRecipeSpacePriors(knowledge);
  const check = checkRecipeSpacePrivacy(priors, knowledge);
  if (!check.passed) { console.error(JSON.stringify({ error: "Privacy check failed; nothing written.", findings: check.findings })); return 1; }
  const text = serializeRecipeSpacePriors(priors);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, text);
  // Local summary only: it describes the private source and is never written into the public file.
  console.log(JSON.stringify({ out, bytes: Buffer.byteLength(text), groups: priors.groups.length, k: priors.k,
    privacy: { passed: true, checked_records: check.checked_records, fewest_underivable_settings: check.worst_unresolved } }, null, 2));
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));
