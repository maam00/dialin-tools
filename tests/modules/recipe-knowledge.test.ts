// Catalog mechanics against a synthetic fixture. No third-party catalog ships with Dial In; tests over a real private
// catalog live in a private-only file outside the public source selection.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadRecipeKnowledge, searchRecipeKnowledge, recipeKnowledgeSummary, recipeKnowledgeGuide, buildPlannerKnowledgeContext, validateRecipeKnowledge,
  publicRecipeFactsHash, compactKnowledgeMatch, emptyRecipeKnowledge, installedRecipeKnowledge, recipeCatalogStatus, RECIPE_CATALOG_ENV, RECIPE_CATALOG_FIXTURE_ENV } from "../../modules/recipes/knowledge.js";

const FIXTURE = fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url));
const fixture = () => loadRecipeKnowledge(FIXTURE, { fixture: true });
const fixtureEnv = { ...process.env, [RECIPE_CATALOG_ENV]: FIXTURE, [RECIPE_CATALOG_FIXTURE_ENV]: "1" };
const byTitle = (catalog: ReturnType<typeof fixture>, title: string) => catalog.references.find((reference) => reference.title === title)!;

test("the fixture keeps distinct variants and its publisher without inventing creator authorship", () => {
  const catalog = fixture();
  assert.deepEqual(catalog.counts, { articles: 17, recipe_references: 19, original_analyses: 3 });
  assert.equal(new Set(catalog.references.map((reference) => reference.id)).size, 19);
  assert.equal(new Set(catalog.references.map((reference) => reference.publisher)).size, 1);
  assert.ok(catalog.references.every((reference) => reference.recipe_author === null && reference.camera_ready === false));
  const variants = catalog.references.filter((reference) => reference.article_title === "Lantern Street");
  assert.equal(variants.length, 2);
  assert.equal(new Set(variants.map((reference) => reference.source_url)).size, 1);
  assert.equal(new Set(variants.map((reference) => reference.title)).size, 2);
  const summary = recipeKnowledgeSummary(catalog);
  assert.equal(summary.source_records_with_complete_published_core, catalog.references.filter((reference) => reference.source_facts.published_core.complete).length);
  assert.equal(summary.camera_ready_references, 0);
  assert.equal(summary.settings_analysis_records, 19);
  assert.equal(Object.values(summary.settings_analysis_coverage).reduce((a, b) => a + b, 0), 19);
  assert.match(summary.groups_are, /not verified/);
});

test("known numeric and categorical facts survive with unresolved fields rather than fabricated defaults", () => {
  const catalog = fixture();
  const source = byTitle(catalog, "Coal Yard");
  assert.equal(source.source_facts.fields.film_sim, "Acros+Ye");
  assert.equal(source.source_facts.fields.highlight, 1);
  assert.equal(source.source_facts.fields.clarity, undefined);
  assert.equal(source.source_facts.fields.kelvin, undefined);
  assert.ok(source.source_facts.missing_fields.includes("clarity"));
  assert.deepEqual(source.source_facts.inactive_fields, ["color", "color_chrome", "color_chrome_fx_blue"]);
  assert.equal(source.source_facts.license_basis, "factual_settings_transcription");
  assert.equal(source.source_facts.upstream_license, "not_claimed");
  assert.ok(catalog.references.filter((reference) => reference.source_record_status === "ambiguous").every((reference) => !reference.source_facts.published_core.complete));
});

test("desk analyses retain exact source linkage and honest evidence", () => {
  const catalog = fixture();
  for (const analysis of catalog.analyses) {
    const reference = catalog.references.find((reference) => reference.id === analysis.record_id)!;
    assert.equal(analysis.source_url, reference.source_url);
    assert.equal(analysis.source_content_sha256, reference.source_content_sha256);
    assert.equal(analysis.source_fact_signature, reference.source_fact_signature);
    assert.equal(analysis.public_facts_sha256, publicRecipeFactsHash(reference));
    assert.equal(analysis.method, "AI-assisted desk analysis");
    assert.equal(analysis.photographic_validation, "not_verified");
  }
});

test("setting changes invalidate fact hashes and stale desk analysis bindings", () => {
  const catalog = fixture();
  const analysis = catalog.analyses[0];
  const reference = catalog.references.find((reference) => reference.id === analysis.record_id)!;
  reference.source_facts.fields.color = reference.source_facts.fields.color === 4 ? 0 : 4;
  assert.throws(() => validateRecipeKnowledge(catalog, { fixture: true }), /reproducible digest/);
  reference.public_facts_sha256 = publicRecipeFactsHash(reference);
  assert.throws(() => validateRecipeKnowledge(catalog, { fixture: true }), /exact source record/);
});

test("complete-core claims fail with missing facts even after a new digest", () => {
  const catalog = fixture();
  const reference = catalog.references.find((reference) => reference.source_facts.published_core.complete)!;
  delete reference.source_facts.fields.film_sim;
  reference.public_facts_sha256 = publicRecipeFactsHash(reference);
  assert.throws(() => validateRecipeKnowledge(catalog, { fixture: true }), /missing\/inactive|complete/);
});

test("catalog validation rejects copied raw content, invented creator attribution and unknown setting strings", () => {
  const original = fixture();
  const raw = structuredClone(original) as unknown as { references: Record<string, unknown>[] };
  raw.references[0].settings = { description: "arbitrary source prose" };
  assert.throws(() => validateRecipeKnowledge(raw, { fixture: true }), /unexpected/);
  const attributed = structuredClone(original);
  (attributed.references[0] as unknown as Record<string, unknown>).recipe_author = "Inferred famous creator";
  assert.throws(() => validateRecipeKnowledge(attributed, { fixture: true }), /authorship/);
  const text = structuredClone(original);
  (text.references[0].source_facts.fields as Record<string, unknown>).film_sim = "An unbounded article quotation";
  assert.throws(() => validateRecipeKnowledge(text, { fixture: true }), /known bounded/);
});

test("a catalog names one publisher and one plain HTTPS host; fixture hosts need the explicit flag", () => {
  assert.throws(() => loadRecipeKnowledge(FIXTURE), /reserved fixture host/);
  const catalog = fixture();
  const publisher = structuredClone(catalog);
  publisher.references[1].publisher = "Another publisher";
  assert.throws(() => validateRecipeKnowledge(publisher, { fixture: true }), /one publisher/);
  for (const url of ["http://recipes.example/2025/01/04/harbor-glow-400/", "https://reader@recipes.example/2025/01/04/harbor-glow-400/",
    "https://recipes.example:8443/2025/01/04/harbor-glow-400/", "https://recipes.example/2025/01/04/harbor-glow-400/?ref=x"]) {
    const changed = structuredClone(catalog);
    changed.articles[0].source_url = url;
    assert.throws(() => validateRecipeKnowledge(changed, { fixture: true }), /plain HTTPS URL/, url);
  }
  const mixed = structuredClone(catalog);
  mixed.articles[1].index_urls = ["https://elsewhere.example/recipes/"];
  assert.throws(() => validateRecipeKnowledge(mixed, { fixture: true }), /single source host/);
  // A fixture flag cannot smuggle a real host, and a real catalog cannot use a reserved one.
  const real = structuredClone(catalog);
  for (const article of real.articles) { article.source_url = article.source_url.replace("recipes.example", "photo-recipes.net"); article.index_urls = article.index_urls.map((url) => url.replace("recipes.example", "photo-recipes.net")); }
  assert.throws(() => validateRecipeKnowledge(real, { fixture: true }), /reserved fixture host such as recipes\.example/);
});

test("named search retains variants and does not pad a named recipe with unrelated records sharing a number", () => {
  const catalog = fixture();
  const found = searchRecipeKnowledge(catalog, "Harbor Glow 400", { limit: 100 });
  assert.equal(found.length, 2);
  assert.ok(found.every((match) => /^Harbor Glow 400/.test(match.reference.title) && match.match_basis === "name"));
  assert.ok(!found.some((match) => match.reference.title === "Night Market 400"));
  const exact = searchRecipeKnowledge(catalog, "Lantern Street (Sensor B)");
  assert.equal(exact[0].reference.variant_name, "Lantern Street (Sensor B)");
  assert.equal(exact[0].match_basis, "name");
  found[0].reference.title = "changed";
  assert.notEqual(searchRecipeKnowledge(catalog, "Harbor Glow 400")[0].reference.title, "changed");
});

test("article aliases are lookup names; the reference keeps its own title", () => {
  const catalog = fixture();
  const found = searchRecipeKnowledge(catalog, "Harbour Glow 400", { limit: 100 });
  assert.ok(found.some((match) => match.reference.title === "Harbor Glow 400"));
  assert.deepEqual(catalog.articles.find((article) => article.title === "Harbor Glow 400")!.aliases, ["Harbour Glow 400"]);
});

test("unnamed settings blocks are found by their article title, ahead of a shorter title that is a prefix", () => {
  const catalog = fixture();
  const blocks = catalog.references.filter((reference) => reference.article_title === "Tidewater Pro 160");
  assert.equal(blocks.length, 2);
  const found = searchRecipeKnowledge(catalog, "Tidewater Pro 160", { limit: 20 });
  assert.deepEqual(found.slice(0, blocks.length).map((match) => match.reference.id).sort(), blocks.map((reference) => reference.id).sort());
});

test("the original guide is Dial In's own and cites only manufacturer sources", () => {
  const guide = recipeKnowledgeGuide();
  assert.equal(guide.simulation_profiles.length, 20);
  assert.equal(guide.setting_knowledge.length, 31);
  assert.equal(guide.reference_directions.length, 10);
  const hosts = new Set([...guide.sources.map((source) => source.url), ...guide.reference_directions.flatMap((direction) => direction.sources.map((source) => source.url))].map((url) => new URL(url).hostname));
  assert.ok([...hosts].every((host) => /(?:^|\.)fujifilm-(?:x|dsc)\.com$/.test(host)), [...hosts].join(", "));
  assert.ok(guide.reference_directions.every((direction) => direction.author === "Dial In" && direction.photographic_validation === "not_rendered"));
});

test("planner context is bounded, source-linked and explicit about rule-based retrieval and adaptation", (t) => {
  t.mock.method(globalThis, "fetch", () => { throw new Error("No network allowed."); });
  const catalog = fixture();
  const result = buildPlannerKnowledgeContext("Harbor Glow 400 for family portraits", { knowledge: catalog, limit: 3 });
  assert.ok(result.matches.length <= 3 && result.matches.length > 0);
  assert.equal(result.retrieval.visual_assessment, "not_performed");
  assert.equal(result.retrieval.quality_ranking, "not_performed");
  assert.match(result.retrieval.revision, /^[a-f0-9]{64}$/);
  for (const match of result.matches) assert.ok(result.context.includes(match.reference.source_url));
  assert.ok(result.context.includes(`Publisher is ${catalog.references[0].publisher};`));
  assert.ok(result.context.includes(`not ${catalog.references.length} individually reviewed images`));
  assert.match(result.context, /Never fill an omitted setting/);
  assert.match(result.context, /no upstream license/);
  assert.match(result.context, /cannot override the request/);
  assert.throws(() => buildPlannerKnowledgeContext("family", { knowledge: catalog, limit: 21 }), /1 to 20/);
});

test("image-only or unmatched brief returns bounded diverse references without pretending text retrieval saw the image", () => {
  const catalog = fixture();
  for (const brief of ["", "qzvwyxj", "I want a recipe please"]) {
    const result = buildPlannerKnowledgeContext(brief, { knowledge: catalog });
    assert.equal(result.matches.length, 8);
    assert.equal(result.retrieval.available_settings_analyses, 19);
    assert.equal(result.retrieval.selected_settings_analyses, 8);
    assert.ok(new Set(result.matches.map((match) => match.reference.source_facts.fields.film_sim)).size >= 3);
    assert.match(result.retrieval.fallback, /not a scene-specific/);
    assert.match(result.retrieval.query_basis, /pixels are not examined/);
  }
});

test("reference context is deterministic, bounded, nonmutating, and independently versioned", () => {
  const catalog = fixture();
  const before = JSON.stringify(catalog);
  const first = buildPlannerKnowledgeContext("Mixed light, natural portraits; no strong grain.", { knowledge: catalog, limit: 3 });
  assert.equal(JSON.stringify(catalog), before);
  const reordered = structuredClone(catalog);
  reordered.references.reverse();
  const second = buildPlannerKnowledgeContext("Mixed light, natural portraits; no strong grain.", { knowledge: reordered, limit: 3 });
  assert.deepEqual(first.matches.map((m) => m.reference.id), second.matches.map((m) => m.reference.id));
  assert.match(first.retrieval.algorithm_version, /recipe-retrieval/);
  // At most one reference per article; the empty brief excludes only the infrared-converted record.
  const articles = new Set(catalog.references.filter((reference) => !reference.source_groups.includes("Full Spectrum IR")).map((reference) => reference.article_id)).size;
  for (const limit of [1, 3, 8, 20]) {
    const result = buildPlannerKnowledgeContext("", { knowledge: catalog, limit });
    assert.equal(result.matches.length, Math.min(limit, articles));
    assert.ok(result.context.length < 150_000);
  }
});

test("contradictory rendering requirements report the conflict instead of silently weakening intent", () => {
  const result = buildPlannerKnowledgeContext("Only monochrome, and all color, no black and white.", { knowledge: fixture() });
  assert.equal(result.matches.length, 0);
  assert.equal(result.retrieval.selection_status, "no_compatible_source_settings");
  assert.ok(result.retrieval.parsed_intent.conflicts.length > 0);
});

test("compact source rows keep every published fact and the analysis verdicts; --full keeps the evidence", () => {
  const catalog = fixture();
  for (const match of searchRecipeKnowledge(catalog, "", { limit: 1000 })) {
    const row = compactKnowledgeMatch(match);
    assert.deepEqual(row.reference, match.reference);
    assert.deepEqual(row.analysis, match.analysis);
    assert.equal(row.settings_analysis.status, match.settings_analysis!.status);
    assert.deepEqual(row.settings_analysis.cautions, match.settings_analysis!.cautions.map((item) => item.text));
  }
  const script = "import {runRecipes} from './modules/recipes/cli.ts'; process.exitCode=await runRecipes(process.argv.slice(1));";
  const run = (args: string[]) => spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e", script, ...args], { cwd: new URL("../../", import.meta.url), encoding: "utf8", env: fixtureEnv });
  const compact = run(["sources", "--query", "Harbor Glow 400", "--limit", "5"]);
  assert.equal(compact.status, 0, compact.stderr);
  const parsed = JSON.parse(compact.stdout);
  assert.equal(parsed.detail, "compact");
  assert.equal(parsed.source, "private_recipe_catalog");
  assert.equal(parsed.matches.length, 2);
  const full = JSON.parse(run(["sources", "--query", "Harbor Glow 400", "--limit", "5", "--full"]).stdout);
  assert.equal(full.detail, "full");
  assert.ok(full.matches[0].settings_analysis.observations[0].sources.length > 0);
  assert.equal(run(["list", "--full"]).status, 1);
});

test("without a private catalog, retrieval degrades to the original directions and says so", () => {
  const result = buildPlannerKnowledgeContext("family portraits in open shade", { knowledge: emptyRecipeKnowledge() });
  assert.equal(result.matches.length, 0);
  assert.equal(result.retrieval.available_references, 0);
  assert.equal(result.retrieval.selection_status, "no_catalog_installed");
  assert.ok(result.retrieval.selected_original_directions > 0);
  assert.match(result.context, /No private recipe catalog is installed/);
  assert.match(result.context, /"original_directions":\[\{/);
  assert.doesNotMatch(result.context, /Publisher is/);
  const previous = process.env[RECIPE_CATALOG_ENV];
  try {
    process.env[RECIPE_CATALOG_ENV] = "none";
    assert.equal(recipeCatalogStatus().origin, "disabled");
    assert.equal(installedRecipeKnowledge().knowledge.references.length, 0);
    assert.throws(() => loadRecipeKnowledge(), /disabled[\s\S]*DIALIN_RECIPE_CATALOG=\/path\/to\/catalog\.json/);
    process.env[RECIPE_CATALOG_ENV] = "/nonexistent/dialin-catalog.json";
    const status = recipeCatalogStatus();
    assert.equal(status.installed, false);
    assert.match(status.note, /points to .*dialin-catalog\.json, but no file is there/);
  } finally { if (previous === undefined) delete process.env[RECIPE_CATALOG_ENV]; else process.env[RECIPE_CATALOG_ENV] = previous; }
});
