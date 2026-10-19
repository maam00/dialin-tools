import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadLocalRecipeKnowledge } from "../../lib/recipes/local.js";

test("local research refuses mixed snapshot receipts and incomplete app-server loading", () => {
  const directory = mkdtempSync(join(tmpdir(), "dialin-recipe-fixture-"));
  try {
    const index = JSON.stringify({ version: "synthetic", observed_at: "2026-10-14", entries: [], gaps: [] });
    const writeSettings = (hash: string, complete: boolean) => writeFileSync(join(directory, "public-settings.json"), JSON.stringify({
      version: "synthetic", observed_at: "2026-10-14", index_sha256: hash, records: [], fetch_summary: { complete_coverage: complete },
    }));
    writeFileSync(join(directory, "public-index.json"), index);
    writeSettings("a".repeat(64), true);
    assert.throws(() => loadLocalRecipeKnowledge(directory, "private_research"), /different source snapshots/);
    const hash = createHash("sha256").update(index).digest("hex");
    writeSettings(hash, false);
    assert.equal(loadLocalRecipeKnowledge(directory, "private_research").library.entries.length, 0);
    assert.throws(() => loadLocalRecipeKnowledge(directory, "private_research", { requireComplete: true }), /incomplete/);
    writeSettings(hash, true);
    const k = loadLocalRecipeKnowledge(directory, "private_research", { requireComplete: true });
    assert.deepEqual(k.judgments, []);
    assert.deepEqual(k.permissions, []);
    assert.equal(k.mode, "private_research");
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
