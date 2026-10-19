// Retrieval mechanics over the synthetic fixture catalog (invented recipes on recipes.example). These are objective
// constraint and coverage checks of the retrieval rules, not claims about any real recipe collection.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { buildPlannerKnowledgeContext, loadRecipeKnowledge } from "../../modules/recipes/knowledge.js";

const knowledge = loadRecipeKnowledge(fileURLToPath(new URL("../fixtures/recipe-catalog.fixture.json", import.meta.url)), { fixture: true });

type Result = ReturnType<typeof buildPlannerKnowledgeContext>;
const fields = (r: Result) => r.matches.map((m) => m.reference.source_facts.fields);
const mono = (sim?: string) => /^(Acros|Monochrome|Sepia)/.test(sim ?? "");
const colorOnly = (r: Result) => r.matches.length > 0 && fields(r).every((f) => f.film_sim && !mono(f.film_sim));
const monoOnly = (r: Result) => r.matches.length > 0 && fields(r).every((f) => mono(f.film_sim));
const noStrong = (r: Result) => r.matches.length > 0 && r.matches.every((m) => {
  const f = m.reference.source_facts; return (f.fields.grain && !f.fields.grain.startsWith("Strong")) || ["Off", "Weak"].includes(f.native.grain_strength ?? "");
});
const noGrain = (r: Result) => r.matches.length > 0 && r.matches.every((m) => m.reference.source_facts.fields.grain === "Off" || m.reference.source_facts.native.grain_strength === "Off");
const noDelay = (r: Result) => r.matches.length > 0 && fields(r).every((f) => f.clarity === 0);
const adaptiveOption = (r: Result) => fields(r).slice(0, 4).some((f) => f.white_balance?.startsWith("Auto"));
const saferWarmth = (r: Result) => r.matches.length > 0 && fields(r).every((f) => mono(f.film_sim) || f.film_sim !== "Nostalgic Neg" && (f.wb_shift_r ?? 99) <= 0 && (f.wb_shift_b ?? -99) >= 0);
const diverse = (r: Result) => r.matches.length >= 6 && new Set(r.matches.map((m) => m.reference.article_id)).size === r.matches.length && new Set(fields(r).map((f) => f.film_sim)).size >= 3;

/** Objective shortlist checks, not gold-standard aesthetic ratings or measured photographic outcomes. */
const RECIPE_SCENARIOS: { id: string; brief: string; limit?: number; expectation: string; check: (r: Result) => boolean }[] = [
  { id: "beach-family-no-mono", brief: "Family portraits at the beach, all color, no monochrome or black and white.", expectation: "known color settings only", check: colorOnly },
  { id: "wedding-without-bw", brief: "Wedding across gardens and reception, without B&W, natural skin.", expectation: "known color settings only", check: colorOnly },
  { id: "food-color-required", brief: "Faithful color food photographs for a restaurant menu.", expectation: "color-critical input excludes monochrome", check: colorOnly },
  { id: "product-faithful", brief: "Product catalog with accurate colors and white packaging.", expectation: "color-critical input excludes monochrome", check: colorOnly },
  { id: "mono-architecture", brief: "Only black and white for dramatic architecture, no color.", expectation: "known monochrome settings only", check: monoOnly },
  { id: "mono-street", brief: "Monochrome only for a rainy street documentary.", expectation: "known monochrome settings only", check: monoOnly },
  { id: "bw-portrait", brief: "B&W only portraits in window light.", expectation: "known monochrome settings only", check: monoOnly },
  { id: "clean-product", brief: "Clean product photographs, faithful color, no grain, no orange cast.", expectation: "compatible facts or explicit no-compatible-source outcome", check: (r) => r.matches.length ? colorOnly(r) && noGrain(r) && saferWarmth(r) : r.retrieval.selection_status === "no_compatible_source_settings" },
  { id: "family-no-heavy-grain", brief: "Natural family memories, no heavy grain.", expectation: "no strong or unknown grain", check: noStrong },
  { id: "portrait-avoid-strong", brief: "Portraits with gentle texture; avoid strong grain.", expectation: "no strong or unknown grain", check: noStrong },
  { id: "grain-free", brief: "Grain-free clear color travel photographs.", expectation: "grain explicitly off", check: noGrain },
  { id: "orange-tungsten", brief: "Family under tungsten and window light, no orange skin.", expectation: "exclude added-warmth settings; this does not prove color accuracy", check: saferWarmth },
  { id: "warmth-avoid", brief: "Portraits in mixed light, avoid warm casts.", expectation: "exclude added-warmth settings", check: saferWarmth },
  { id: "children-action", brief: "Children running indoors, fast action, no save delay.", expectation: "Clarity explicitly zero", check: noDelay },
  { id: "sports-no-clarity", brief: "Indoor sports, no nonzero clarity and no monochrome.", expectation: "Clarity explicitly zero and color", check: (r) => noDelay(r) && colorOnly(r) },
  { id: "mixed-day", brief: "Travel in changing light from daylight to tungsten interiors and night streets.", expectation: "adaptive white-balance option among first four", check: adaptiveOption },
  { id: "led-reception", brief: "Portraits at a wedding reception under mixed LED and window light.", expectation: "adaptive white-balance option among first four", check: adaptiveOption },
  { id: "full-day-named", brief: "Use Harbor Glow 400 as inspiration for a full day: morning sun, rainy streets, window portraits, tungsten interiors and neon night.", expectation: "named inspiration plus varied source families", check: (r) => diverse(r) && r.matches.some((m) => /Harbor Glow 400/.test(m.reference.title) && m.match_basis === "name") },
  { id: "full-day-rain", brief: "A full day of sun, rainy streets, indoor portraits and neon night. I want color choices for each.", expectation: "distinct articles and at least three simulation bases", check: diverse },
  { id: "snow-highlights", brief: "Snowy mountains and bright white clouds, keep important highlight detail.", expectation: "at least one softer highlight and higher DR starting point", check: (r) => fields(r).some((f) => (f.highlight ?? 99) <= 0 && /DR200|DR400/.test(f.dynamic_range ?? "")) },
  { id: "vivid-gardens", brief: "Vivid saturated gardens, flowers and foliage, color is the subject.", expectation: "a vivid color starting point", check: (r) => fields(r).some((f) => f.film_sim === "Velvia" || (f.color ?? -99) >= 2) },
  { id: "muted-documentary", brief: "Muted restrained documentary in overcast streets.", expectation: "a restrained color starting point", check: (r) => fields(r).some((f) => !mono(f.film_sim) && (f.color ?? 99) <= 0) },
  { id: "explicit-warmth", brief: "Outdoor family portraits in open shade. I explicitly want warm nostalgic color and an amber memory feeling, even if it is less neutral. One color look.", expectation: "requested warmth takes priority over a neutral-portrait default", check: (r) => colorOnly(r) && r.matches.slice(0, 3).every((m) => ["possible", "elevated"].includes(m.settings_analysis!.traits.warm_cast_risk)) },
  { id: "intentional-silhouette", brief: "A person backlit by a bright window. Deliberately lose facial detail for a bold silhouette and clean graphic shape. One monochrome look; this is intentional, not a failed natural portrait.", expectation: "graphic monochrome choices and no invented vivid-color preference", check: (r) => monoOnly(r) && !r.retrieval.parsed_intent.priorities.includes("vivid_color") && r.matches.slice(0, 3).some((m) => m.settings_analysis!.traits.contrast === "hard") },
  { id: "day-with-mono-options", brief: "A full day from dawn family portraits, beach at noon, shaded greenery, market, cafe window, sunset, to tungsten dinner. Seven useful looks with Harbor Glow 400 as inspiration. Include a neutral fallback and two distinct monochrome options.", expectation: "two distinct monochrome references plus named and neutral color choices", check: (r) => r.matches.filter((m) => mono(m.reference.source_facts.fields.film_sim)).length >= 2 && r.matches.some((m) => /Harbor Glow 400/.test(m.reference.title)) && fields(r).some((f) => !mono(f.film_sim) && f.wb_shift_r === 0 && f.wb_shift_b === 0) },
  { id: "one-dependable-color", brief: "Natural faces in a cafe. One dependable color look.", expectation: "adjectives do not erase an explicit single-color request", check: colorOnly },
  { id: "mixed-rendering", brief: "Neon night. Two looks: one accurate color and one monochrome.", expectation: "both requested rendering families are represented", check: (r) => fields(r).some((f) => mono(f.film_sim)) && fields(r).some((f) => f.film_sim && !mono(f.film_sim)) },
  { id: "no-color-cast", brief: "Portraits with no color cast.", expectation: "color-cast concerns do not request monochrome-only", check: (r) => r.retrieval.parsed_intent.rendering !== "monochrome" && fields(r).some((f) => f.film_sim && !mono(f.film_sim)) },
  { id: "generic-nostalgic-color", brief: "I want warm nostalgic color and an amber memory feeling.", expectation: "generic adjectives are not treated as a named source", check: (r) => diverse(r) && !r.matches.some((m) => m.match_basis === "name") },
  { id: "empty-bounded", brief: "", limit: 3, expectation: "fallback respects three-record limit", check: (r) => r.matches.length === 3 },
  { id: "unseen-bounded", brief: "qzvwyxj", limit: 2, expectation: "fallback respects two-record limit", check: (r) => r.matches.length === 2 },
];

for (const scenario of RECIPE_SCENARIOS) test(`shoot shortlist: ${scenario.id} — ${scenario.expectation}`, () => {
  const result = buildPlannerKnowledgeContext(scenario.brief, { knowledge, limit: scenario.limit });
  assert.ok(scenario.check(result), `${scenario.id}: ${JSON.stringify(result.matches.map((m) => ({ title: m.reference.title, fields: m.reference.source_facts.fields })))}`);
  assert.equal(result.retrieval.visual_assessment, "not_performed");
  assert.equal(result.retrieval.quality_ranking, "not_performed");
});

const sims = (r: Result) => fields(r).map((f) => f.film_sim);
const warmRisk = (r: Result) => r.matches.map((m) => m.settings_analysis!.traits.warm_cast_risk);
const groups = (r: Result) => r.matches.flatMap((m) => m.reference.source_groups);

/** Independent audit, 2026-10-15: new wording, not tuned to the scenarios above. Constraint and coverage checks only. */
const AUDIT_SCENARIOS: typeof RECIPE_SCENARIOS = [
  { id: "anything-but-classic-chrome", brief: "Street photos downtown at golden hour, anything but Classic Chrome please.", expectation: "an excluded simulation never appears; unknown simulations cannot satisfy the exclusion", check: (r) => r.matches.length > 0 && sims(r).every((sim) => sim && sim !== "Classic Chrome") && r.retrieval.parsed_intent.excluded_simulations.includes("Classic Chrome") },
  { id: "two-simulations-banned", brief: "Beach wedding: ceremony in harsh sun, family formals in open shade, reception under string lights. No Classic Chrome and nothing with Nostalgic Neg, the couple hates that look. Natural skin.", expectation: "both bans hold and a banned name does not become a warm-color request", check: (r) => r.matches.length > 0 && sims(r).every((sim) => sim !== "Classic Chrome" && sim !== "Nostalgic Neg") && !r.retrieval.parsed_intent.priorities.includes("warm_color") },
  { id: "hate-velvia", brief: "Autumn foliage hike. I hate Velvia, keep it natural.", expectation: "a disliked simulation is excluded", check: (r) => r.matches.length > 0 && !sims(r).includes("Velvia") },
  { id: "skin-not-yellow", brief: "Office headshots, skin shouldn't look yellow or orange.", expectation: "subject-first cast wording excludes added or warm-risk settings", check: (r) => r.retrieval.parsed_intent.avoid_added_warmth && r.matches.length > 0 && warmRisk(r).every((risk) => risk === "not_indicated" || risk === "not_applicable") },
  { id: "warm-kelvin-excluded", brief: "Wedding reception portraits, avoid warm casts.", expectation: "warm Kelvin and Ambience settings count as warmth even without shifts", check: (r) => r.matches.length > 0 && warmRisk(r).every((risk) => risk === "not_indicated" || risk === "not_applicable") },
  { id: "readable-backlight", brief: "Bride backlit by the sunset; I need her face readable, not a silhouette.", expectation: "a negated silhouette is not a graphic-shape request", check: (r) => !r.retrieval.parsed_intent.priorities.includes("graphic_shape") && r.retrieval.parsed_intent.priorities.includes("portrait") },
  { id: "bare-black-and-white", brief: "Black and white street photos at night.", expectation: "a plain monochrome mention ranks monochrome sources first without a hard ban on color", check: (r) => r.matches.slice(0, 3).every((m) => mono(m.reference.source_facts.fields.film_sim)) && r.matches.some((m) => !mono(m.reference.source_facts.fields.film_sim)) && r.retrieval.parsed_intent.rendering === null },
  { id: "mostly-color-one-bw", brief: "A day at the zoo, mostly color but a B&W look for the elephants would be nice.", expectation: "one monochrome option beside color references", check: (r) => r.retrieval.parsed_intent.monochrome_options === 1 && fields(r).filter((f) => mono(f.film_sim)).length >= 1 && fields(r).filter((f) => f.film_sim && !mono(f.film_sim)).length >= 3 },
  { id: "selective-color-contradiction", brief: "Monochrome but keep the red dress vivid.", expectation: "the contradiction is surfaced and both renderings stay available", check: (r) => r.retrieval.parsed_intent.review_notes.length === 1 && fields(r).some((f) => mono(f.film_sim)) && fields(r).some((f) => f.film_sim && !mono(f.film_sim)) },
  { id: "red-must-stay-accurate", brief: "Red lipstick product shots on white seamless; the red must stay accurate.", expectation: "a named hue that must stay accurate is color-critical", check: (r) => r.retrieval.parsed_intent.priorities.includes("color_fidelity") && colorOnly(r) },
  { id: "zero-grain", brief: "Clean architectural interiors, zero grain.", expectation: "grain-off vocabulary", check: noGrain },
  { id: "rich-greens", brief: "Lush green ferns and moss in a rainforest, rich greens.", expectation: "rich color wording is a vivid request, not an unmatched fallback", check: (r) => r.retrieval.parsed_intent.priorities.includes("vivid_color") && r.retrieval.fallback === "none" },
  { id: "no-infrared-leak", brief: "Dancer against a sunset sky, pure black silhouette.", expectation: "full-spectrum infrared recipes need a converted camera and stay out of ordinary briefs", check: (r) => r.matches.length > 0 && !groups(r).includes("Full Spectrum IR") },
  { id: "infrared-requested", brief: "Full spectrum infrared landscape look.", expectation: "an infrared request reaches the infrared-converted source first", check: (r) => r.matches[0].reference.source_groups.includes("Full Spectrum IR") },
  { id: "other-body-named", brief: "Recipes for my X-T30 II on a city walk.", expectation: "another camera body is surfaced rather than silently planned for", check: (r) => r.retrieval.parsed_intent.review_notes.some((note) => /X-T30 II/.test(note)) },
  { id: "strict-no-fit", brief: "Black and white only, grain off, zero clarity.", expectation: "an honest empty result instead of violating constraints", check: (r) => r.retrieval.selection_status === "no_compatible_source_settings" },
  { id: "exact-named-variant", brief: "I want exactly Kodak Quayside 320 as published, unchanged, for a sunny day.", expectation: "the named source is retrieved by name", check: (r) => r.matches[0].reference.title === "Kodak Quayside 320" && r.matches[0].match_basis === "name" },
];

for (const scenario of AUDIT_SCENARIOS) test(`audit shortlist: ${scenario.id} — ${scenario.expectation}`, () => {
  const result = buildPlannerKnowledgeContext(scenario.brief, { knowledge, limit: scenario.limit });
  assert.ok(scenario.check(result), `${scenario.id}: ${JSON.stringify({ intent: result.retrieval.parsed_intent, matches: result.matches.map((m) => ({ title: m.reference.title, groups: m.reference.source_groups, fields: m.reference.source_facts.fields })) })}`);
});

test("bounded English: non-English and unparsed phrasing leave intent unrestricted rather than guessed", () => {
  // Documented boundary, not desired behavior: the host agent must read the photographer's words itself.
  const result = buildPlannerKnowledgeContext("Schwarzweiß Porträts im Fensterlicht, keine Farbe", { knowledge });
  assert.equal(result.retrieval.parsed_intent.rendering, null);
  assert.match(result.context, /Check parsed_intent against the actual request/);
});
