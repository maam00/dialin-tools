import { readFileSync, statSync } from "node:fs";
import { X100VI, writable } from "../../lib/cameras.js";
import { recipeProblems } from "../../lib/plan/looks.js";
import { RECIPE_KEYS, type RecipeFields } from "../../lib/plan/types.js";

export const RECIPE_BOOK_SCHEMA = "dialin.recipes.v1" as const;
/** The reusable knowledge book is independent of the seven-slot rehearsal fixture. */
export const ORIGINAL_RECIPE_BOOK = new URL("../../data/recipes/original-book.json", import.meta.url);
const MAX_BYTES = 2_000_000;
const MAX_RECIPES = 500;
const object = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value);

export type RecipeDesign = {
  reference_id: string;
  reference_version: string;
  origin: "original_direction" | "creator_inspired_direction";
  camera: "X100VI";
  generation: "X-Trans V";
  intent_tags: string[];
  scene_tags: string[];
  avoid_tags: string[];
  rationale: string;
  tradeoff: string;
  adaptation: string;
  sources: { title: string; url: string; role: "manufacturer_fact" | "creator_tradeoff" }[];
  limitations: string[];
  photographic_validation: "not_rendered";
  exact_creator_copy: false;
  /** Shared planner/settings-file value-map check; USB has a separate map. Never camera acceptance evidence. */
  new_write_support: "mapped_value_subset" | "reference_only";
};

export type RecipeEntry = {
  id: string;
  title: string;
  author: string;
  origin: "original" | "user_owned" | "reference";
  source_url: string | null;
  description: string;
  tags: string[];
  photographic_validation: "not_verified";
  recipe: RecipeFields;
  /** Optional authored reasoning and source links, retained in planner context and JSON handoffs. */
  design?: RecipeDesign;
};
export type RecipeBook = { schema_version: typeof RECIPE_BOOK_SCHEMA; title: string; description: string; recipes: RecipeEntry[] };
export type RecipeBookValidation = { valid: boolean; issues: string[]; records: number; book?: RecipeBook };

function httpsURL(value: unknown): boolean {
  if (typeof value !== "string" || value.length > 2000) return false;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password; }
  catch { return false; }
}

function designProblems(raw: unknown, at: string): string[] {
  if (!object(raw)) return [`${at} must be a design object.`];
  const issues: string[] = [];
  const keys = ["reference_id", "reference_version", "origin", "camera", "generation", "intent_tags", "scene_tags", "avoid_tags",
    "rationale", "tradeoff", "adaptation", "sources", "limitations", "photographic_validation", "exact_creator_copy", "new_write_support"];
  if (Object.keys(raw).some((key) => !keys.includes(key))) issues.push(`${at} contains unsupported fields.`);
  for (const key of ["reference_id", "reference_version", "rationale", "tradeoff", "adaptation"] as const) {
    if (typeof raw[key] !== "string" || !raw[key].trim() || raw[key].length > 1000) issues.push(`${at}.${key} must be nonempty and at most 1000 characters.`);
  }
  if (!["original_direction", "creator_inspired_direction"].includes(String(raw.origin))) issues.push(`${at}.origin must identify an original or creator-inspired direction.`);
  if (raw.camera !== "X100VI" || raw.generation !== "X-Trans V") issues.push(`${at} currently supports X100VI / X-Trans V design notes only.`);
  for (const key of ["intent_tags", "scene_tags", "avoid_tags", "limitations"] as const) {
    if (!Array.isArray(raw[key]) || raw[key].length > 30 || raw[key].some((value) => typeof value !== "string" || !value.trim() || value.length > (key === "limitations" ? 1000 : 80))) {
      issues.push(`${at}.${key} must contain at most 30 bounded nonempty strings.`);
    }
  }
  if (!Array.isArray(raw.sources) || raw.sources.length < 1 || raw.sources.length > 16) issues.push(`${at}.sources must contain 1 to 16 attributed links.`);
  else for (const [index, source] of raw.sources.entries()) {
    const path = `${at}.sources[${index}]`;
    if (!object(source)) { issues.push(`${path} must be an object.`); continue; }
    if (Object.keys(source).some((key) => !["title", "url", "role"].includes(key))) issues.push(`${path} contains unsupported fields.`);
    if (typeof source.title !== "string" || !source.title.trim() || source.title.length > 1000) issues.push(`${path}.title must be nonempty and at most 1000 characters.`);
    if (!httpsURL(source.url)) issues.push(`${path}.url must be an HTTPS URL without credentials.`);
    if (!["manufacturer_fact", "creator_tradeoff"].includes(String(source.role))) issues.push(`${path}.role must be manufacturer_fact or creator_tradeoff.`);
  }
  if (raw.photographic_validation !== "not_rendered" || raw.exact_creator_copy !== false) issues.push(`${at} cannot claim rendered photographic evidence or an exact creator copy.`);
  if (!["mapped_value_subset", "reference_only"].includes(String(raw.new_write_support))) issues.push(`${at}.new_write_support must be mapped_value_subset or reference_only; it cannot certify camera acceptance.`);
  return issues;
}

/** Validate a local book without a model, camera connection, or inferred photographic-quality claim. */
export function validateRecipeBook(raw: unknown): RecipeBookValidation {
  const issues: string[] = [];
  const cameraRecipes = Array.isArray(raw) ? raw : object(raw) && Array.isArray(raw.recipes) ? raw.recipes : [raw];
  if ((object(raw) && Array.isArray(raw.placements)) || cameraRecipes.some((entry) => object(entry) && "film_sim" in entry && !("recipe" in entry))) {
    return { valid: false, records: cameraRecipes.length, issues: [
      "This is camera-recipe JSON, not a dialin.recipes.v1 recipe book. Use camera prepare --in FILE --slots C2,C7 with your actual target slots to check bare recipes. For recipe browsing or planner references, wrap settings in the attributed book format shown in modules/recipes/README.md.",
    ] };
  }
  if (!object(raw)) return { valid: false, issues: ["The book must be a JSON object."], records: 0 };
  if (raw.schema_version !== RECIPE_BOOK_SCHEMA) issues.push(`schema_version must be ${RECIPE_BOOK_SCHEMA}.`);
  for (const field of ["title", "description"] as const) {
    if (typeof raw[field] !== "string" || !raw[field].trim() || raw[field].length > 1000) issues.push(`${field} must be a nonempty string of at most 1000 characters.`);
  }
  if (!Array.isArray(raw.recipes) || raw.recipes.length < 1 || raw.recipes.length > MAX_RECIPES) {
    return { valid: false, issues: [...issues, `recipes must contain 1 to ${MAX_RECIPES} entries.`], records: 0 };
  }
  const ids = new Set<string>();
  for (const [index, entry] of raw.recipes.entries()) {
    const at = `recipes[${index}]`;
    if (!object(entry)) { issues.push(`${at} must be an object.`); continue; }
    if (typeof entry.id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(entry.id) || ids.has(entry.id)) {
      issues.push(`${at}.id must be a unique simple identifier.`);
    } else ids.add(entry.id);
    for (const field of ["title", "author", "description"] as const) {
      if (typeof entry[field] !== "string" || !entry[field].trim() || entry[field].length > 1000) issues.push(`${at}.${field} must be nonempty and at most 1000 characters.`);
    }
    if (!["original", "user_owned", "reference"].includes(String(entry.origin))) issues.push(`${at}.origin must be original, user_owned, or reference.`);
    if (entry.source_url !== null && !httpsURL(entry.source_url)) issues.push(`${at}.source_url must be null or an HTTPS URL without credentials.`);
    if (entry.origin === "reference" && !entry.source_url) issues.push(`${at}.source_url is required for a reference.`);
    if (!Array.isArray(entry.tags) || entry.tags.length > 30 || entry.tags.some((tag) => typeof tag !== "string" || !tag.trim() || tag.length > 80)) {
      issues.push(`${at}.tags must contain at most 30 nonempty short strings.`);
    }
    if (entry.photographic_validation !== "not_verified") issues.push(`${at}.photographic_validation must be not_verified; this file format cannot certify photographic evidence.`);
    if (entry.design !== undefined) issues.push(...designProblems(entry.design, `${at}.design`));
    if (!object(entry.recipe)) { issues.push(`${at}.recipe must contain a complete settings object.`); continue; }
    const unknown = Object.keys(entry.recipe).filter((key) => !(RECIPE_KEYS as readonly string[]).includes(key));
    if (unknown.length) issues.push(`${at}.recipe contains unsupported fields; retain native extras separately until the schema supports them.`);
    for (const field of ["name", "why"] as const) {
      if (typeof entry.recipe[field] !== "string" || !entry.recipe[field].trim() || entry.recipe[field].length > 1000) issues.push(`${at}.recipe.${field} must be nonempty and at most 1000 characters.`);
    }
    issues.push(...recipeProblems(entry.recipe, X100VI).map((problem) => `${at}.recipe: ${problem}`));
    if (entry.recipe.white_balance === "Kelvin" && entry.recipe.kelvin === 0) issues.push(`${at}.recipe: Kelvin WB needs a nonzero color temperature.`);
    if (entry.recipe.white_balance !== "Kelvin" && entry.recipe.kelvin !== 0) issues.push(`${at}.recipe: inactive kelvin must be 0 in this app format.`);
    if (object(entry.design)) {
      const values = writable(X100VI);
      const mapped = values.filmSims.includes(String(entry.recipe.film_sim)) && values.whiteBalances.includes(String(entry.recipe.white_balance))
        && values.color.includes(entry.recipe.color as number) && values.noiseReduction.includes(entry.recipe.noise_reduction as number);
      if (entry.design.new_write_support !== (mapped ? "mapped_value_subset" : "reference_only")) {
        issues.push(`${at}.design.new_write_support must match the current value map; this is not camera-acceptance evidence.`);
      }
    }
  }
  return { valid: issues.length === 0, issues, records: raw.recipes.length,
    ...(issues.length ? {} : { book: structuredClone(raw) as RecipeBook }) };
}

/** Read only a bounded local JSON file. No URL fetching or author-local paths. */
export function readRecipeJSON(path: string | URL = ORIGINAL_RECIPE_BOOK): unknown {
  const stat = statSync(path);
  if (!stat.isFile() || stat.size > MAX_BYTES) throw new Error(`Recipe JSON must be a regular file of at most ${MAX_BYTES} bytes.`);
  return JSON.parse(readFileSync(path, "utf8")) as unknown;
}

export function loadRecipeBook(path: string | URL = ORIGINAL_RECIPE_BOOK): RecipeBook {
  const result = validateRecipeBook(readRecipeJSON(path));
  if (!result.book) throw new Error(`Invalid recipe book: ${result.issues.slice(0, 5).join(" ")}`);
  return result.book;
}

/** Transparent local browsing, not a scene recommender or photographic ranking model. */
export function searchRecipeBook(book: RecipeBook, query = "", limit = 20): RecipeEntry[] {
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_RECIPES) throw new Error(`limit must be 1 to ${MAX_RECIPES}.`);
  const tokens = (text: string) => text.toLocaleLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
  const words = tokens(query);
  return book.recipes.filter((entry) => {
    const text = [entry.id, entry.title, entry.description, entry.recipe.film_sim, ...entry.tags,
      ...(entry.design?.sources.map((source) => source.title) ?? []),
    ].join(" ");
    const indexed = new Set(tokens(text));
    // Negative/avoidance guidance remains visible on the record but is not a positive search tag.
    return words.every((word) => indexed.has(word));
  }).slice(0, limit).map((entry) => structuredClone(entry));
}

/** Optional adapter for the existing source-specific research catalog; never copies or sends it anywhere. */
export async function inspectRecipeCatalog(directory: string, query = "", limit = 20) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error("Catalog limit must be 1 to 100.");
  const { loadLocalRecipeKnowledge } = await import("../../lib/recipes/local.js");
  const { searchRecipes, recipeLibrarySummary } = await import("../../lib/recipes/library.js");
  const knowledge = loadLocalRecipeKnowledge(directory, "permission_reviewed");
  return { summary: recipeLibrarySummary(knowledge.library),
    matches: searchRecipes(knowledge.library, { query, limit }),
    limitation: "Text lookup and source normalization only; no model use, training, camera compatibility or photographic quality is certified." };
}
