# Use a recipe book independently

List, search and validate a complete recipe book, or see the guidance the planner uses, without planning a shoot, connecting a camera, installing USB dependencies or calling a model. The default book holds Dial In's 10 original recipe directions with their rationale, tradeoffs, adaptation guidance and links to Fujifilm's own documentation. The planner also uses 20 original film-simulation profiles and 31 setting rules, 7 of them scenario rules for common light (fluorescent/LED green casts, blue hour, neon at night, backlight, bright sand and snow, overcast, tungsten mixed with daylight). This guidance was written after studying widely shared community recipes; no third-party recipes are included. None of it has been evaluated from real photographs. Seven is a camera palette default, not a collection limit.

From the repository root with Node dependencies installed:

```sh
npm run dialin -- recipes list
npm run dialin -- recipes search --query "portrait"
npm run dialin -- recipes knowledge --query "people in mixed light"
npm run dialin -- recipes knowledge --full
npm run dialin -- recipes validate --file my-recipes.json
npm run dialin -- recipes search --file my-recipes.json --query "Classic Chrome" --limit 10 --out matches.json
```

Book search is transparent text browsing over title, description, simulation and tags. All query words must match. `knowledge` shows what the planner would use for a brief: the parsed intent (color/monochrome scope, grain, Clarity, added warmth, excluded simulations, review notes), the original directions it selects (`original_directions`) and the scenario rules its light words point to (`scenario_rules`, a disclosed word map, not image analysis); `--limit 1..20` (default 8). `--full` adds the 20 simulation profiles, 31 setting rules, 10 directions and the exact planner context text. The parser is bounded English: check `parsed_intent` against the photographer's words. The [planner](../planner/README.md) includes this guidance automatically; `--book my-recipes.json` adds your own complete settings. The photographer does not have to pick recipes by hand.

## Community-practice figures

`data/recipe-space/priors.json` summarizes how widely shared community recipes set each control for each film simulation: per-setting counts or ranges, highlight/shadow class pairs and white-balance shift directions. Every count covers at least 5 recipes, rare simulations are merged into groups, and no recipe, name, link or identifier is included. A conservative check proves that, for every source recipe, at least 3 of its settings cannot be derived from the published figures. `recipes knowledge` shows one summary line per simulation (`planner_context.community_practice`; `--full` adds the whole file), the planner includes the same lines in its request, and finalization adds an informational note per look: a common, less common or unusual region of community practice. Each share is over the recipes counted for that setting, and values held by fewer than 5 recipes are not published, so "not in the published figures" never means no recipe uses a value. A monochrome look is not compared on WB shift or color controls, which the slot writer does not send for it. Common is not the same as good, and the note never fails a plan. `DIALIN_RECIPE_SPACE=none` turns the figures off, or names another file. The figures are rebuilt privately from a catalog with `node --import tsx scripts/build-recipe-space.ts --out data/recipe-space/priors.json --replace`, which refuses to write a file that fails the privacy check.

## An optional private catalog

Dial In ships no third-party recipe catalog. If you keep your own `dialin.recipe-knowledge.v1` catalog, point the tools at it with `DIALIN_RECIPE_CATALOG=/path/to/catalog.json` (or place it at `data/recipe-knowledge/catalog.json` in your checkout; `DIALIN_RECIPE_CATALOG=none` turns it off). Then `recipes sources [--query] [--limit 1..100]` searches its records, `recipes analyze [--query | --id]` prints source-bound setting interpretations, `knowledge` adds a bounded, constraint-checked shortlist of its records, and the planner cites them by ID. Each record keeps its source URL, status, published setting facts and missing fields; ambiguous or missing settings stay unknown, and records are never camera-ready or quality-ranked. Without a catalog, `sources`, `knowledge` and `analyze` print a one-line note naming the built-in guidance and how to point at a catalog, then exit 0. Whether you may use someone else's recipes is between you and their author.

To prepare recipes from a book for particular slots, use the [camera module](../camera/README.md) directly. `--ids` selects book IDs in the same order as `--slots`; no planner or model call is needed:

```sh
npm run dialin -- camera prepare --in examples/planner/recipes.original.json --ids original-2,original-4 --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/my-shoot/camera-preparation.json
```

Replace the example file, IDs, camera and firmware with your own declared inputs. This is offline preparation; review its validation and readiness before any separate hardware operation. If you already have bare settings, a recipe array or a camera `placements` file, start with `camera prepare` instead of wrapping them in a book. `recipes validate` checks the attributed book format below.

## Make your own book

Copy [the original direction book](../../data/recipes/original-book.json) to a private file and replace its entries with material you may use. Preserve attribution and source URLs. The seven-entry rehearsal fixture in `examples/planner/recipes.original.json` remains available for deterministic examples. The book has this shape:

```ts
type RecipeBook = {
  schema_version: "dialin.recipes.v1";
  title: string;
  description: string;
  recipes: Array<{
    id: string;
    title: string;
    author: string;
    origin: "original" | "user_owned" | "reference";
    source_url: string | null;
    description: string;
    tags: string[];
    photographic_validation: "not_verified";
    recipe: RecipeFields; // Complete existing Dial In recipe fields, as in the example.
    design?: RecipeDesign; // Optional rationale, tradeoffs, adaptations, source links and explicit limits.
  }>;
};
```

Use descriptions and tags to capture intended subjects, light, rendering goals and avoid conditions, while distinguishing your hypotheses from actual experience. Reference entries require an HTTPS URL; attribution alone does not establish permission. The format permits 1–500 recipes and files up to 2 MB. IDs must be unique. Validation uses the existing X100VI app value tables, requires complete settings, and rejects unsupported native fields. Inactive Kelvin must be 0; Kelvin white balance requires a supported nonzero temperature.

The optional `RecipeDesign` contract in [index.ts](index.ts) preserves the detailed reasoning and all source links in the original direction book. Keep it when adapting those entries. Its `new_write_support` is a check against the shared planner/settings-file value map; USB uses a separate transport map. Always use `camera prepare` for the chosen transport rather than interpreting this metadata as a blanket write authorization or prohibition.

`photographic_validation` is deliberately `not_verified`: this compact format has no evidence model capable of certifying matched camera renderings. Keep actual image, body/firmware, source-settings and evaluation evidence separately until the evidence schema supports it. Passing validation does not establish firmware support, a safe camera write or good photographic rendering.

## Callable TypeScript API

```ts
import {
  loadRecipeBook, readRecipeJSON, validateRecipeBook, searchRecipeBook,
} from "./modules/recipes/index.js";

const book = loadRecipeBook(); // Complete original directions, no private catalog required.
const matches = searchRecipeBook(book, "portrait", 10);
const validation = validateRecipeBook(readRecipeJSON("my-recipes.json"));
```

`loadRecipeBook(path?)` returns a validated copy or throws. `validateRecipeBook(unknown)` returns `{valid, issues, records, book?}` without sending content anywhere. `searchRecipeBook(book, query?, limit?)` returns copies, so browsing cannot mutate the caller's book. `runRecipes(args: string[]): Promise<number>` is the CLI entry point.

The guidance and catalog API lives in `modules/recipes/knowledge.ts`: `recipeKnowledgeGuide()`, `buildPlannerKnowledgeContext(text, { knowledge? })`, `recipeCatalogStatus()`, `installedRecipeKnowledge()` (an empty catalog when none is installed), `loadRecipeKnowledge(path?)`, `searchRecipeKnowledge(knowledge, query, options)` and `recipeKnowledgeSummary(knowledge)`. They read local files only and make no network or model call. `modules/recipes/analysis.ts` exposes `analyzeRecipe(reference)` and `analyzeRecipeCatalog(references)`. `modules/recipes/space.ts` exposes `buildRecipeSpacePriors(catalog)`, `checkRecipeSpacePrivacy(priors, catalog)`, `loadRecipeSpacePriors()`, `recipeSpaceSummary(priors)` and `assessLookPractice(look, priors)`. Tests use the invented catalog in `tests/fixtures/recipe-catalog.fixture.json`, loaded with the explicit fixture flag.

An optional read-only adapter reads a research dataset you supply locally:

```sh
npm run dialin -- recipes search --catalog /path/to/permission-reviewed-catalog --query "Classic Chrome"
npm run dialin -- recipes validate --catalog /path/to/permission-reviewed-catalog
```

The API is `inspectRecipeCatalog(directory, query?, limit?)`. It reads that dataset's snapshot/normalization format and reports its limitations. It does not copy recipes, obtain usage rights, train a model or inject the dataset into the standalone planner. Catalog validation means snapshot integrity, not that every record can be written to a camera.

Browse/validation results use `dialin.recipes.result.v1`; analysis results use `dialin.recipe-settings-analysis.v1`. JSON goes to stdout, or `--out` creates parent folders and a new file, refusing overwrite. Choose a new filename when repeating a saved search. Invalid books and command errors return exit code `1`; success returns `0`. `--help` works without a model or camera. No catalog, API key or native transport is required for the default commands.
