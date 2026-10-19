import assert from "node:assert/strict";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const FIXTURE = fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url));
const run = (args: string[], catalog: "fixture" | "none" = "fixture") => spawnSync(process.execPath, ["scripts/dialin.mjs", "recipes", ...args], {
  cwd: new URL("../../", import.meta.url), encoding: "utf8", maxBuffer: 20_000_000,
  env: { ...process.env, DIALIN_RECIPE_CATALOG: catalog === "fixture" ? FIXTURE : "none", DIALIN_RECIPE_CATALOG_FIXTURE: catalog === "fixture" ? "1" : "" } });

test("analysis CLI exposes every catalog record's source-bound assessment without a model or camera", () => {
  const directory = mkdtempSync(join(tmpdir(), "dialin-analysis-"));
  const path = join(directory, "new", "analysis.json");
  try {
    const result = run(["analyze", "--out", path]);
    assert.equal(result.status, 0, result.stderr);
    const output = JSON.parse(readFileSync(path, "utf8"));
    assert.equal(output.source, "private_recipe_catalog");
    assert.equal(output.coverage.references, 19);
    assert.equal(output.coverage.fact_bearing, 18);
    assert.equal(output.coverage.with_interactions, 18);
    assert.equal(output.coverage.with_adaptations, 18);
    assert.equal(output.coverage.insufficient_facts, 1);
    assert.equal(output.coverage.photographed, 0);
    const selected = run(["analyze", "--id", output.analyses[0].binding.record_id]);
    assert.equal(selected.status, 0, selected.stderr);
    assert.equal(JSON.parse(selected.stdout).analyses.length, 1);
    assert.equal(run(["analyze", "--out", path]).status, 1);
    assert.equal(run(["analyze", "--id", "unknown"]).status, 1);
    assert.equal(run(["list", "--id", "unknown"]).status, 1);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("analysis title lookup preserves source variants and never silently returns the entire library", () => {
  const result = run(["analyze", "--query", "Harbor Glow 400"]);
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.equal(output.analyses.length, 2);
  assert.equal(new Set(output.analyses.map((item: { binding: { record_id: string } }) => item.binding.record_id)).size, output.analyses.length);
  assert.equal(JSON.parse(run(["analyze", "--query", "unknownphrasezzzz"]).stdout).analyses.length, 0);
});

test("without a private catalog, analyze prints one note, the built-in guidance and an empty result", () => {
  for (const args of [["analyze"], ["analyze", "--id", "any-id"], ["analyze", "--query", "anything"]]) {
    const result = run(args, "none");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr.trim().split("\n").length, 1);
    assert.match(result.stderr, /disabled[\s\S]*20 film-simulation profiles, 31 setting rules and 10 original directions[\s\S]*DIALIN_RECIPE_CATALOG=\/path\/to\/catalog\.json/);
    const output = JSON.parse(result.stdout);
    assert.equal(output.catalog.installed, false);
    assert.equal(output.source, "built_in_guidance");
    assert.deepEqual(output.analyses, []);
    assert.equal(output.coverage.references, 0);
    assert.equal(output.built_in_guidance.setting_rules, 31);
  }
});
