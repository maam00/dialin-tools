import { analyzeRecipeCatalog } from "./analysis.js";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { parseArgs } from "node:util";
import { inspectRecipeCatalog, loadRecipeBook, readRecipeJSON, searchRecipeBook, validateRecipeBook } from "./index.js";
import { loadRecipeSpacePriors } from "./space.js";
import { buildPlannerKnowledgeContext, compactKnowledgeMatch, installedRecipeKnowledge, RECIPE_CATALOG_ENV, recipeKnowledgeGuide, recipeKnowledgeSummary, searchRecipeKnowledge, type RecipeCatalogStatus } from "./knowledge.js";

const HELP = `Browse or validate recipes locally. No model or camera is used.

npm run dialin -- recipes list
npm run dialin -- recipes search --query "portrait"
npm run dialin -- recipes knowledge --query "people in mixed light"
npm run dialin -- recipes knowledge --full
npm run dialin -- recipes validate --file my-recipes.json
npm run dialin -- recipes search --catalog DIRECTORY --query "Classic Chrome"

Options: --file BOOK.json | --catalog DIRECTORY, --query TEXT, --id REFERENCE_ID, --limit N, --out FILE, --full
list/search: complete original recipe book, or your --file book.
knowledge: what the planner would use for a brief: parsed intent, the original directions it selects and, with a
  private catalog, bounded catalog references; --query is optional; --limit 1..20 (default 8, as in planning).
  It also shows the community-practice summary (aggregate counts per simulation, each over at least 5 recipes).
  It lists the original directions it selects and the scenario rules the brief's light words point to.
  --full adds the 20 simulation profiles, 31 setting rules, 10 directions, the full priors and the planner context text.
sources / analyze: search a private catalog (--limit 1..100) or print its source-bound setting interpretations
  (optional --query or exact --id). No catalog ships with Dial In; set ${RECIPE_CATALOG_ENV}=/path/to/catalog.json
  to use your own. Without one they print a one-line note and the built-in guidance that is available.
Seven is a default camera palette size, never a library limit. JSON goes to stdout unless --out is supplied.
--out creates parent folders and a new file, refusing to overwrite an existing one.
`;

const catalogSummary = (status: RecipeCatalogStatus) => ({ installed: status.installed, origin: status.origin, note: status.note, how_to_install: status.how_to_install });

export async function runRecipes(args: string[]): Promise<number> {
  try {
    const { positionals, values } = parseArgs({ args, allowPositionals: true, strict: true, options: {
      help: { type: "boolean", short: "h" }, file: { type: "string" }, catalog: { type: "string" },
      query: { type: "string" }, id: { type: "string" }, limit: { type: "string" }, out: { type: "string" }, full: { type: "boolean" },
    } });
    if (values.help) { console.log(HELP); return 0; }
    if (values.out && existsSync(values.out)) throw new Error("Output already exists; choose a new --out path.");
    if (values.out) mkdirSync(dirname(values.out), { recursive: true });
    const operation = positionals[0] ?? "list";
    if (!["list", "search", "validate", "sources", "knowledge", "analyze"].includes(operation) || positionals.length > 1) throw new Error("Use recipes list, search, validate, sources, knowledge, or analyze. See --help.");
    const usesKnowledge = operation === "sources" || operation === "knowledge" || operation === "analyze";
    if (usesKnowledge && (values.file || values.catalog)) throw new Error(`sources/knowledge/analyze use the private catalog named by ${RECIPE_CATALOG_ENV}. Use search --file or --catalog for another book.`);
    if (values.id !== undefined && (operation !== "analyze" || values.query !== undefined || !values.id.trim())) throw new Error("Use a nonempty --id only with recipes analyze, without --query.");
    if (values.file && values.catalog) throw new Error("Choose --file or --catalog, not both.");
    if (operation !== "search" && !usesKnowledge && values.query !== undefined) throw new Error("--query is used by recipes search, sources, or knowledge.");
    if (operation === "search" && !values.query?.trim()) throw new Error("recipes search requires --query TEXT.");
    if (operation === "validate" && values.limit !== undefined) throw new Error("--limit does not apply to validation.");
    if (values.full && operation !== "sources" && operation !== "knowledge") throw new Error("--full applies to recipes sources and recipes knowledge.");
    // knowledge defaults to the planner's own bounded shortlist size.
    const limit = values.limit === undefined ? operation === "knowledge" ? 8 : 20 : Number(values.limit);
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw new Error("--limit must be an integer from 1 to 100.");
    if (operation === "knowledge" && limit > 20) throw new Error("recipes knowledge --limit must be 1 to 20 for bounded planner context. Use sources to browse up to 100 records.");
    let output: unknown;
    let code = 0;
    if (usesKnowledge) {
      const { knowledge, status } = installedRecipeKnowledge();
      if (!status.installed) {
        // Degrade, never crash: name what is missing, what built-in guidance remains and how to point at a catalog.
        const guide = recipeKnowledgeGuide();
        console.error(`recipes ${operation}: ${status.note} Built-in guidance: ${guide.simulation_profiles.length} film-simulation profiles, ${guide.setting_knowledge.length} setting rules and ${guide.reference_directions.length} original directions (recipes knowledge --full, recipes list). ${status.how_to_install}`);
        const base = { schema_version: "dialin.recipes.result.v1", operation, source: "built_in_guidance", catalog: catalogSummary(status),
          built_in_guidance: { simulation_profiles: guide.simulation_profiles.length, setting_rules: guide.setting_knowledge.length, original_directions: guide.reference_directions.length,
            original_book: "npm run recipes -- list", full_guide: "npm run recipes -- knowledge --full" } };
        if (operation === "analyze") output = { ...base, ...analyzeRecipeCatalog([]) };
        else if (operation === "sources") output = { ...base, matches: [], ...(values.full ? { guide } : {}) };
        else {
          const context = buildPlannerKnowledgeContext(values.query ?? "", { knowledge, limit });
          output = { ...base, planner_context: values.full ? context : { retrieval: context.retrieval, matches: [],
            original_directions: context.original_directions, scenario_rules: context.scenario_rules, community_practice: context.community_practice },
            ...(values.full ? { guide, community_practice_priors: loadRecipeSpacePriors() } : {}) };
        }
      } else if (operation === "analyze") {
        const references = values.id !== undefined
          ? knowledge.references.filter((entry) => entry.id === values.id)
          : values.query !== undefined ? searchRecipeKnowledge(knowledge, values.query, { limit: values.limit === undefined ? 1000 : limit }).map((match) => match.reference)
          : knowledge.references.slice(0, values.limit === undefined ? undefined : limit);
        if (values.id !== undefined && !references.length) throw new Error("No catalog reference has that exact ID. Use recipes sources to find its stable ID.");
        output = { operation, source: "private_recipe_catalog", catalog_revision: recipeKnowledgeSummary(knowledge).revision,
          ...analyzeRecipeCatalog(references) };
      } else if (values.full) output = { schema_version: "dialin.recipes.result.v1", operation, source: "private_recipe_catalog", detail: "full",
        summary: recipeKnowledgeSummary(knowledge),
        ...(operation === "sources" ? { matches: searchRecipeKnowledge(knowledge, values.query ?? "", { limit }) }
          : { guide: recipeKnowledgeGuide(), planner_context: buildPlannerKnowledgeContext(values.query ?? "", { knowledge, limit }), community_practice_priors: loadRecipeSpacePriors() }) };
      else {
        // Compact by default: the same records and verdicts without repeating per-statement evidence and the guide.
        const summary = recipeKnowledgeSummary(knowledge);
        const { limitations: _limitations, ...compactSummary } = summary;
        const base = { schema_version: "dialin.recipes.result.v1", operation, source: "private_recipe_catalog", detail: "compact",
          full_output: `Add --full for per-statement evidence${operation === "knowledge" ? ", the photographic guide and the exact planner context text" : " and source links per statement"}.`,
          summary: { ...compactSummary, limitations: `${summary.limitations.length} catalog limitations; see --full.` } };
        if (operation === "sources") output = { ...base, matches: searchRecipeKnowledge(knowledge, values.query ?? "", { limit }).map(compactKnowledgeMatch) };
        else {
          const context = buildPlannerKnowledgeContext(values.query ?? "", { knowledge, limit });
          output = { ...base, planner_context: { retrieval: context.retrieval, matches: context.matches.map(compactKnowledgeMatch),
            original_directions: context.original_directions, scenario_rules: context.scenario_rules, community_practice: context.community_practice } };
        }
      }
    } else if (values.catalog) {
      const catalog = await inspectRecipeCatalog(values.catalog, values.query, limit);
      output = { schema_version: "dialin.recipes.result.v1", source: "local_research_catalog", operation,
        ...(operation === "validate" ? { valid_snapshot: true, summary: catalog.summary,
          limitation: "Snapshot integrity checked. Consult normalization counts; this is not exact-write or photographic validation." } : catalog) };
    } else if (operation === "validate") {
      const result = validateRecipeBook(readRecipeJSON(values.file));
      const { book: _, ...validation } = result;
      output = { schema_version: "dialin.recipes.result.v1", operation, ...validation,
        limitation: "Valid means the current app setting vocabulary is accepted; native baseline, transport and photographic suitability remain unverified." };
      code = result.valid ? 0 : 1;
    } else {
      const book = loadRecipeBook(values.file);
      output = { schema_version: "dialin.recipes.result.v1", operation, source: values.file ? "user_supplied_book" : "original_directions",
        title: book.title, total_records: book.recipes.length, matches: searchRecipeBook(book, values.query, limit),
        limitation: "Text browsing only. These entries do not certify photographic quality or a safe camera write." };
    }
    const text = JSON.stringify(output, null, 2) + "\n";
    if (values.out) writeFileSync(values.out, text, { flag: "wx" });
    else process.stdout.write(text);
    return code;
  } catch (error) {
    console.error(JSON.stringify({ error: error instanceof SyntaxError ? "Invalid recipe JSON." : error instanceof Error ? error.message : "Recipe operation failed." }));
    return 1;
  }
}
