import assert from "node:assert/strict";
import { test } from "node:test";
import { X100VI } from "../../lib/cameras.js";
import { inferPhotographicPolicy, validateFactualRationale } from "../../lib/plan/expert-policy.js";
import { EXPERT_REFERENCES, referenceContext, selectExpertReferences } from "../../lib/plan/expert-references.js";
import { recipeProblems } from "../../lib/plan/looks.js";
import type { PhotographicBrief } from "../../lib/plan/types.js";

const brief = (changes: Partial<PhotographicBrief> = {}): PhotographicBrief => ({ intent: "Natural everyday family color",
  subjects: ["people", "faces"], lighting: ["daylight"], color_priorities: ["believable skin"], rendering_goal: "faithful natural color",
  observations: ["Daylight and people are described"], uncertainties: ["Exposure not measured"], ...changes });

test("the bounded catalog has original, complete, legal native settings and explicit unrendered provenance", () => {
  assert.ok(EXPERT_REFERENCES.length >= 8 && EXPERT_REFERENCES.length <= 12);
  assert.equal(new Set(EXPERT_REFERENCES.map((r) => r.id)).size, EXPERT_REFERENCES.length);
  for (const r of EXPERT_REFERENCES) {
    assert.equal(r.author, "Dial In");
    assert.equal(r.photographic_validation, "not_rendered");
    assert.equal(r.exact_creator_copy, false);
    assert.deepEqual(recipeProblems(r.settings, X100VI), [], r.id);
    assert.ok(r.sources.every((s) => s.url.startsWith("https://www.fujifilm-x.com/") || s.url.startsWith("https://fujifilm-dsc.com/")));
    assert.ok(r.rationale && r.tradeoff && r.adaptation && r.limitations.length);
  }
});

test("natural and warm intentions in the same scene retrieve different relevant references", () => {
  const natural = selectExpertReferences({ brief: brief(), camera: X100VI });
  const warm = selectExpertReferences({ brief: brief({ intent: "Warm nostalgic family album memories", rendering_goal: "Amber warm memory", color_priorities: ["Warmth"] }), camera: X100VI });
  assert.ok(natural.some((m) => m.reference.id === "ref-faithful-everyday"));
  assert.equal(warm[0].reference.id, "ref-warm-memory");
  assert.notEqual(natural[0].reference.id, warm[0].reference.id);
});

test("whole-palette color prohibits monochrome references without manufacturing new candidates", () => {
  const matches = selectExpertReferences({ brief: brief({ intent: "Natural color and dramatic graphic monochrome alternatives" }),
    camera: X100VI, policy: inferPhotographicPolicy({ said: "All color, no B&W." }), limit: 6 });
  assert.ok(matches.length);
  assert.ok(matches.every((m) => !m.reference.settings.film_sim.startsWith("Acros")));
});

test("a primary-only color priority still allows honestly scoped reference alternatives", () => {
  const matches = selectExpertReferences({ brief: brief({ intent: "Faithful natural color with an optional gentle monochrome gesture look", rendering_goal: "Natural color and monochrome alternative" }),
    policy: inferPhotographicPolicy({ said: "Keep skin color believable." }), camera: X100VI, limit: 6 });
  assert.ok(matches.some((m) => m.reference.id === "ref-gentle-monochrome"));
});

test("avoiding a warm cast excludes the warm-memory direction without banning a Kelvin setting", () => {
  const matches = selectExpertReferences({ brief: brief({ intent: "Nostalgic family album but no orange cast" }),
    policy: inferPhotographicPolicy({ said: "No orange cast." }), camera: X100VI });
  assert.ok(matches.every((m) => m.reference.id !== "ref-warm-memory"));
});

test("native ASTIA context is explicit and excluded from the new-write shortlist by default", () => {
  const b = brief({ intent: "Natural skin and colorful portrait", subjects: ["green foliage", "blue sky", "faces"], lighting: ["outdoors"] });
  assert.ok(!selectExpertReferences({ brief: b, camera: X100VI, limit: 6 }).some((m) => m.reference.id === "ref-astia-context"));
  const context = selectExpertReferences({ brief: b, camera: X100VI, includeUnmapped: true, limit: 6 });
  const astia = context.find((m) => m.reference.id === "ref-astia-context")!;
  assert.equal(astia.new_write_supported, false);
  assert.match(referenceContext([astia]), /native context only; new write not mapped/);
});

test("no matching evidence or reviewed body yields no invented reference filler", () => {
  assert.deepEqual(selectExpertReferences({ brief: brief({ intent: "", subjects: [], lighting: [], color_priorities: [], rendering_goal: "", observations: [] }), camera: X100VI }), []);
  assert.deepEqual(selectExpertReferences({ brief: brief(), camera: { ...X100VI, id: "X100V" } }), []);
  assert.match(referenceContext([]), /No reviewed reference direction matched/);
});

test("returned references are isolated copies and transparent scores are not camera/rendering proof", () => {
  const matches = selectExpertReferences({ brief: brief(), camera: X100VI });
  const canonical = EXPERT_REFERENCES.find((r) => r.id === matches[0].reference.id)!;
  const before = structuredClone(canonical);
  matches[0].reference.settings.color = 4;
  assert.deepEqual(canonical, before);
  const text = referenceContext(selectExpertReferences({ brief: brief(), camera: X100VI }));
  assert.match(text, /unrendered hypotheses/);
  assert.match(text, /independently authored numeric settings/);
});

test("reference prose does not repeat the saved high-confidence factual errors", () => {
  for (const r of EXPERT_REFERENCES) {
    assert.deepEqual(validateFactualRationale({ recipe: r.settings, reason: `${r.rationale}. ${r.tradeoff}. ${r.adaptation}` }), [], r.id);
  }
});
