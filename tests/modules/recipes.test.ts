import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { loadRecipeBook, searchRecipeBook, validateRecipeBook } from "../../modules/recipes/index.js";
import { EXPERT_REFERENCES, EXPERT_REFERENCE_VERSION } from "../../lib/plan/expert-references.js";

test("standalone original book searches names, simulation and scene tags without a provider", (t) => {
  t.mock.method(globalThis, "fetch", () => { throw new Error("Recipes must remain local."); });
  const book = loadRecipeBook();
  assert.equal(book.recipes.length, EXPERT_REFERENCES.length);
  assert.ok(book.recipes.length > 7, "A camera's slot count must not cap the reusable library.");
  assert.ok(book.recipes.every((recipe) => recipe.origin === "original" && recipe.photographic_validation === "not_verified"));
  assert.equal(searchRecipeBook(book, "portrait")[0].title, "Gentle people");
  assert.equal(searchRecipeBook(book, "Classic Chrome")[0].title, "Quiet documentary");
  assert.equal(searchRecipeBook(book, "LED")[0].title, "Faces in mixed interiors");
  assert.deepEqual(searchRecipeBook(book, "no matching recipe"), []);
  const found = searchRecipeBook(book, "portrait");
  found[0].recipe.color = 99;
  assert.equal(searchRecipeBook(book, "portrait")[0].recipe.color, 0);
});

test("default book retains every authored direction's settings, reasoning and attributed source links", () => {
  const book = loadRecipeBook();
  for (const reference of EXPERT_REFERENCES) {
    const entry = book.recipes.find((candidate) => candidate.id === reference.id);
    assert.ok(entry?.design, reference.id);
    assert.deepEqual(entry.recipe, reference.settings);
    assert.equal(entry.design.reference_version, EXPERT_REFERENCE_VERSION);
    for (const field of ["origin", "rationale", "tradeoff", "adaptation", "sources", "limitations", "intent_tags", "scene_tags", "avoid_tags", "camera", "generation", "exact_creator_copy", "photographic_validation"] as const) {
      assert.deepEqual(entry.design[field], reference[field], `${reference.id}: ${field}`);
    }
  }
  assert.equal(book.recipes.find((entry) => entry.id === "ref-astia-context")?.design?.new_write_support, "reference_only");
  assert.equal(book.recipes.find((entry) => entry.id === "ref-warm-memory")?.design?.origin, "creator_inspired_direction");
  assert.equal(loadRecipeBook(new URL("../../examples/planner/recipes.original.json", import.meta.url)).recipes.length, 7,
    "The historical deterministic seven-look rehearsal remains separate.");
});

test("design metadata rejects unsafe source links, invented provenance roles and photographic acceptance claims", () => {
  const changes = [
    (design: Record<string, unknown>) => { (design.sources as Record<string, unknown>[])[0].url = "https://username:secret@example.com/source"; },
    (design: Record<string, unknown>) => { (design.sources as Record<string, unknown>[])[0].url = "file:///private/photograph.jpg"; },
    (design: Record<string, unknown>) => { (design.sources as Record<string, unknown>[])[0].role = "creator_endorsement"; },
    (design: Record<string, unknown>) => { design.photographic_validation = "camera_verified"; },
    (design: Record<string, unknown>) => { design.exact_creator_copy = true; },
    (design: Record<string, unknown>) => { design.new_write_support = "camera_verified"; },
  ];
  for (const change of changes) {
    const book = loadRecipeBook();
    change(book.recipes[0].design as unknown as Record<string, unknown>);
    const checked = validateRecipeBook(book);
    assert.equal(checked.valid, false);
    assert.equal(checked.book, undefined);
    assert.ok(checked.issues.some((issue) => issue.includes(".design")));
  }
  const book = loadRecipeBook();
  const astia = book.recipes.find((entry) => entry.id === "ref-astia-context")!;
  astia.design!.new_write_support = "mapped_value_subset";
  assert.match(validateRecipeBook(book).issues.join(" "), /must match the current value map/);
});

test("user-owned recipes retain attribution and fail on duplicate IDs, omitted or invalid settings", () => {
  const book = loadRecipeBook();
  book.recipes = [book.recipes[0]];
  book.recipes[0].origin = "user_owned";
  book.recipes[0].author = "Example photographer";
  const valid = validateRecipeBook(book);
  assert.equal(valid.valid, true);
  assert.equal(valid.book?.recipes[0].author, "Example photographer");
  const invalid = structuredClone(book);
  invalid.recipes.push(structuredClone(invalid.recipes[0]));
  invalid.recipes[0].recipe.color = 99;
  delete (invalid.recipes[0].recipe as Partial<typeof invalid.recipes[0]["recipe"]>).white_balance;
  const result = validateRecipeBook(invalid);
  assert.equal(result.valid, false);
  assert.match(result.issues.join(" "), /unique|color|white_balance/);
  assert.equal(result.book, undefined);
});

test("native extras, unknown evidence claims and fake reference identity are not silently accepted", () => {
  const book = loadRecipeBook();
  const data = structuredClone(book) as unknown as { recipes: Record<string, unknown>[] };
  data.recipes[0].origin = "reference";
  data.recipes[0].photographic_validation = "camera_verified";
  (data.recipes[0].recipe as Record<string, unknown>).smooth_skin = "Strong";
  const result = validateRecipeBook(data);
  assert.equal(result.valid, false);
  assert.match(result.issues.join(" "), /source_url is required/);
  assert.match(result.issues.join(" "), /cannot certify/);
  assert.match(result.issues.join(" "), /unsupported fields/);
});

test("camera recipe inputs explain the independent preparation route instead of reporting missing book fields", () => {
  const recipe = loadRecipeBook().recipes[0].recipe;
  for (const raw of [recipe, [recipe], { recipes: [recipe] }, { placements: [{ slot: 2, recipe }] }]) {
    const result = validateRecipeBook(raw);
    assert.equal(result.valid, false);
    assert.equal(result.issues.length, 1);
    assert.match(result.issues[0], /camera prepare/);
    assert.match(result.issues[0], /recipe book/);
    assert.equal(result.book, undefined);
  }
});

test("CLI reads a standalone user book, writes parseable JSON and returns failure on invalid settings", () => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-recipes-module-"));
  const script = "import {runRecipes} from './modules/recipes/cli.ts'; process.exitCode=await runRecipes(process.argv.slice(1));";
  try {
    const path = join(dir, "book.json");
    const out = join(dir, "new-results", "found.json");
    const book = loadRecipeBook();
    writeFileSync(path, JSON.stringify(book));
    const run = (args: string[]) => spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", script, ...args], {
      cwd: new URL("../../", import.meta.url), encoding: "utf8", env: { ...process.env, ANTHROPIC_API_KEY: "" },
    });
    const searched = run(["search", "--file", path, "--query", "monochrome", "--out", out]);
    assert.equal(searched.status, 0, searched.stderr);
    const match = JSON.parse(readFileSync(out, "utf8")).matches[0];
    assert.equal(match.title, "Gentle monochrome separation");
    assert.ok(match.design.sources.some((source: { url: string }) => source.url.startsWith("https://www.fujifilm-x.com/")));
    book.recipes[0].recipe.color = 999;
    writeFileSync(path, JSON.stringify(book));
    const checked = run(["validate", "--file", path]);
    assert.equal(checked.status, 1);
    assert.equal(JSON.parse(checked.stdout).valid, false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
