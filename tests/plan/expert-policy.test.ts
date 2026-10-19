import assert from "node:assert/strict";
import { test } from "node:test";
import { assessPolicyLook, effectiveRecipeFields, effectiveRecipeSignature, inferPhotographicPolicy,
  sanitizeFactualRationale, validateFactualRationale } from "../../lib/plan/expert-policy.js";
import type { RecipeDesign, RecipeFields } from "../../lib/plan/types.js";

const recipe = (changes: Partial<RecipeFields> = {}): RecipeFields => ({ name: "Scene color", film_sim: "Reala Ace",
  grain: "Off", color_chrome: "Off", color_chrome_fx_blue: "Off", white_balance: "Auto", kelvin: 0,
  wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR200", highlight: -0.5, shadow: 0, color: 0, sharpness: -1,
  noise_reduction: -4, clarity: 0, why: "A starting interpretation.", ...changes });
const design = (changes: Partial<RecipeDesign> = {}): RecipeDesign => ({ purpose: "A scene interpretation", scene_fit: "Fits the stated subject.",
  choices: [{ setting: "film_sim", reason: "A restrained color interpretation.", knowledge_ids: ["sim-reala-ace"] }],
  tradeoff: "Less vivid color.", alternative: "A different color treatment.", uncertainty: "Check the actual light.", ...changes });
const codes = (value: ReturnType<typeof validateFactualRationale>) => value.map((i) => i.code);

test("cast avoidance handles lists and plurals without turning subject colors or negated prohibitions into intent", () => {
  for (const said of ["Avoid amber, orange or nostalgic warm casts.", "No warm or orange tints.", "Without any orange faces."]) {
    assert.equal(inferPhotographicPolicy({ said }).avoidWarmCast, true, said);
  }
  for (const said of ["Don't avoid warm casts; I like them.", "Avoid orange clothing in the scene.", "Warm amber light on the street."]) {
    assert.equal(inferPhotographicPolicy({ said }).avoidWarmCast, false, said);
  }
});

for (const said of ["All color, no monochrome.", "All seven looks must be colour.", "Every look should retain color.",
  "No B&W", "Don't include black-and-white", "Colour-only recipes", "Only color looks", "Without any monochrome"]) {
  test(`whole-palette color instruction is enforced: ${said}`, () => {
    const policy = inferPhotographicPolicy({ said });
    assert.equal(policy.paletteMode, "color");
    assert.equal(policy.primaryMode, "color");
    assert.equal(assessPolicyLook({ look: recipe({ film_sim: "Acros+Ye" }), policy, isPrimary: false })[0]?.severity, "conflict");
    assert.deepEqual(assessPolicyLook({ look: recipe(), policy, isPrimary: true }), []);
  });
}

test("a subject color priority constrains the primary without banning every optional B&W interpretation", () => {
  const policy = inferPhotographicPolicy({ said: "Keep the red swimsuit distinct and preserve believable skin color." });
  assert.equal(policy.primaryMode, "color");
  assert.equal(policy.paletteMode, "either");
  assert.equal(assessPolicyLook({ look: recipe({ film_sim: "Acros+R" }), policy, isPrimary: true })[0]?.scope, "primary");
  assert.deepEqual(assessPolicyLook({ look: recipe({ film_sim: "Acros+R" }), policy, isPrimary: false }), []);
});

test("explicit main-only prohibitions stay scoped to that main look", () => {
  const policy = inferPhotographicPolicy({ said: "No monochrome for my main look. A B&W alternate is fine." });
  assert.equal(policy.primaryMode, "color");
  assert.equal(policy.paletteMode, "either");
  assert.deepEqual(assessPolicyLook({ look: recipe({ film_sim: "Acros+Ye" }), policy, isPrimary: false }), []);
});

test("explicit monochrome primary differs from an optional monochrome alternate", () => {
  assert.equal(inferPhotographicPolicy({ said: "I want a black and white portrait." }).primaryMode, "monochrome");
  assert.equal(inferPhotographicPolicy({ said: "I want a black and white alternative." }).primaryMode, "either");
  assert.equal(inferPhotographicPolicy({ said: "All B&W looks." }).paletteMode, "monochrome");
});

test("subject colors and time do not themselves manufacture a color-only or B&W requirement", () => {
  const policy = inferPhotographicPolicy({ said: "Red brick beside blue water at noon; friends indoors later." });
  assert.equal(policy.primaryMode, "either");
  assert.equal(policy.paletteMode, "either");
  assert.equal(policy.avoidWarmCast, false);
});

test("current natural-color intent wins over persistent monochrome preference", () => {
  const policy = inferPhotographicPolicy({ said: "Natural color for the people today.", tasteNotes: "Only monochrome looks." });
  assert.equal(policy.primaryMode, "color");
  assert.equal(policy.paletteMode, "either");
  assert.ok(policy.constraints.every((c) => c.source === "said"));
});

test("current monochrome request wins over persistent all-color taste", () => {
  const policy = inferPhotographicPolicy({ said: "I want a black and white portrait.", tasteNotes: "All color." });
  assert.equal(policy.primaryMode, "monochrome");
  assert.equal(policy.paletteMode, "either");
});

test("quoted or negated bans are not silently converted into hard user constraints", () => {
  for (const said of ["I'm not saying no monochrome.", "Don't avoid monochrome.", "Not only color looks."]) {
    assert.equal(inferPhotographicPolicy({ said }).paletteMode, "either", said);
  }
});

test("contradictions and exceptions remain inspectable rather than becoming model permission", () => {
  const contradiction = inferPhotographicPolicy({ said: "All color. Only monochrome looks." });
  assert.equal(contradiction.requiresReview, true);
  assert.equal(assessPolicyLook({ look: recipe(), policy: contradiction, isPrimary: true })[0]?.code, "monochrome_intent");
  const exception = inferPhotographicPolicy({ said: "No monochrome except one optional B&W look." });
  assert.equal(exception.requiresReview, true);
  assert.equal(exception.paletteMode, "color");
});

test("protected conflicting banks are disclosed and stay protected", () => {
  const policy = inferPhotographicPolicy({ said: "All color." });
  const kept = { ...recipe({ film_sim: "Acros+Ye" }), status: "kept" };
  const before = structuredClone(kept);
  assert.equal(assessPolicyLook({ look: kept, policy, isPrimary: true })[0]?.severity, "preserved_conflict");
  assert.deepEqual(kept, before);
  assert.deepEqual(assessPolicyLook({ look: { ...kept, recipe_known: false }, policy, isPrimary: true }), []);
});

test("warmth versus cast is qualitative evidence, never a made-up numeric WB restriction", () => {
  const policy = inferPhotographicPolicy({ said: "Keep the warmth, but no orange vintage cast." });
  assert.equal(policy.avoidWarmCast, true);
  assert.equal(policy.preserveWarmth, true);
  assert.equal(policy.requiresReview, true);
  assert.deepEqual(assessPolicyLook({ look: recipe({ white_balance: "Kelvin", kelvin: 6300 }), policy, isPrimary: true }), []);
});

test("effective payload ignores names, inactive Kelvin and omitted mono controls without mutating inputs", () => {
  const color = recipe({ kelvin: 6300 });
  assert.equal(effectiveRecipeSignature(color), effectiveRecipeSignature(recipe({ name: "Different", why: "Other", kelvin: 0 })));
  const mono = recipe({ film_sim: "Acros+Ye", color: 3, color_chrome: "Strong", color_chrome_fx_blue: "Strong", wb_shift_r: 5, wb_shift_b: -4 });
  const before = structuredClone(mono);
  assert.equal(effectiveRecipeSignature(mono), effectiveRecipeSignature(recipe({ film_sim: "Acros+Ye" })));
  assert.deepEqual(mono, before);
  assert.equal(effectiveRecipeFields(mono).wb_shift_r, 0);
});

test("active fields and active Kelvin remain distinct; unmapped native state never enters this payload proof", () => {
  assert.notEqual(effectiveRecipeSignature(recipe()), effectiveRecipeSignature(recipe({ shadow: 1 })));
  assert.notEqual(effectiveRecipeSignature(recipe({ white_balance: "Kelvin", kelvin: 5600 })), effectiveRecipeSignature(recipe({ white_balance: "Kelvin", kelvin: 6300 })));
  assert.notEqual(effectiveRecipeSignature(recipe({ grain: "Weak Small" })), effectiveRecipeSignature(recipe({ grain: "Weak Large" })));
});

test("the saved Acros red-direction mistake is caught while correct/qualified filter advice is retained", () => {
  assert.ok(codes(validateFactualRationale({ recipe: recipe({ film_sim: "Acros+Ye" }), design: design({ alternative: "Acros+R gives more drama but darkens red." }) })).includes("red_filter_direction"));
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "The red filter lightens blue." })).includes("red_filter_blue_direction"));
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "The red filter lightens red and darkens blue." }), []);
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "The red filter does not darken red." }), []);
});

test("DR floor claims are model-scoped and Auto DR cannot silently claim DR400", () => {
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "DR400 works at ISO250." })).includes("dr_iso_floor"));
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "DR200 needs ISO125." })).includes("dr_iso_floor"));
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "DR400 needs ISO500 or more." }), []);
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), cameraModel: "Other", reason: "DR400 needs ISO250." }), []);
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "Auto DR selects DR400." })).includes("auto_dr_400"));
});

test("ASTIA can be gentle for skin without becoming universally desaturated", () => {
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "Astia makes all colors muted." })).includes("astia_color_generalization"));
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "Astia is gentler than Velvia and can keep vivid greens." }), []);
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "Astia is not uniformly desaturated." }), []);
});

test("mixed-light certainty and the saved B&W complete-cast-removal claim are caught", () => {
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "A fallback that removes fluorescent cast completely." })).includes("mixed_light_guarantee"));
  assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason: "Auto WB guarantees neutral faces in mixed light." })).includes("mixed_light_guarantee"));
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "Auto WB cannot guarantee neutral faces in mixed light." }), []);
  assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason: "Start with Auto WB, then check the face under mixed light." }), []);
});

test("observed WB output promises are caught beyond mixed-light keywords", () => {
  const observed = ["Auto with no shift avoids any warm or vintage cast.", "Auto, no shift, keeps skin free of orange.",
    "Auto, unshifted, keeps the water clean and cast-free.", "Daylight with a slight cool shift removes any orange.",
    "Auto with a small warm shift keeps amber without orange faces.",
    "Mild shifts keep several skin tones from going orange.",
    "Reala Ace's firm highlights keep reflective scales distinct; slight cool shift keeps silver from turning yellow-green."];
  for (const reason of observed) assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason })).includes("wb_cast_certainty"), reason);
});

test("cast-reduction intent and not adding a fixed cast are not rejected as guarantees", () => {
  const reasonable = ["Auto WB aims to avoid orange skin.", "The shift reduces orange under this light.",
    "Auto with no shift does not add an artistic warm cast.", "Auto WB avoids a fixed cast on bright sand.",
    "Auto WB may leave skin free of orange; check the camera.", "Milder WB shifts help keep skin from going orange.",
    "Auto WB cannot guarantee cast-free skin."];
  for (const reason of reasonable) assert.deepEqual(validateFactualRationale({ recipe: recipe(), reason }), [], reason);
});

test("a rejected WB promise clears prose and review state without a numeric WB correction", () => {
  const input = { recipe: recipe({ wb_shift_r: 1, wb_shift_b: -1 }),
    design: design({ scene_fit: "Auto WB keeps faces free of orange." }) };
  const before = structuredClone(input);
  const result = sanitizeFactualRationale(input);
  assert.equal(result.design?.scene_fit, "");
  assert.equal(result.design?.requires_review, true);
  assert.deepEqual(input, before);
});

test("capture recovery, exact save delay and subject-freezing claims are not aesthetic judgment", () => {
  const claims: [string, string][] = [["Softer highlights recover clipped capture detail.", "tone_recovers_capture"],
    ["Clarity always adds a one-second pause.", "clarity_fixed_delay"], ["IBIS freezes moving subjects.", "stabilization_subject_motion"]];
  for (const [reason, code] of claims) assert.ok(codes(validateFactualRationale({ recipe: recipe(), reason })).includes(code), reason);
});

test("sanitization removes only affected prose, marks review, and leaves settings/source inputs unchanged", () => {
  const input = { recipe: recipe(), reason: "The red filter darkens red.", design: design({ alternative: "Acros+R gives more drama but darkens red." }) };
  const before = structuredClone(input);
  const out = sanitizeFactualRationale(input);
  assert.equal(out.reason, "");
  assert.equal(out.design?.alternative, "");
  assert.equal(out.design?.requires_review, true);
  assert.equal(out.design?.tradeoff, input.design.tradeoff);
  assert.equal(out.why, input.recipe.why);
  assert.deepEqual(input, before);
});

test("an incorrect setting-choice reason is removed without an invented replacement", () => {
  const d = design({ choices: [{ setting: "dynamic_range", reason: "DR400 needs ISO125.", knowledge_ids: ["dr-iso"] }] });
  const out = sanitizeFactualRationale({ recipe: recipe(), design: d });
  assert.equal(out.design?.choices[0].reason, "");
  assert.deepEqual(out.design?.choices[0].knowledge_ids, ["dr-iso"]);
  assert.equal(out.design?.requires_review, true);
});

test("singular exclusions and trailing only enforce a complete monochrome palette", () => {
  for (const said of ["Exactly seven monochrome looks only.", "No color look at all.", "Black and white recipes only."]) {
    const policy = inferPhotographicPolicy({ said });
    assert.equal(policy.paletteMode, "monochrome", said);
    assert.equal(assessPolicyLook({ look: recipe(), policy, isPrimary: false })[0]?.code, "monochrome_intent");
  }
});

test("explicit cast avoidance flags deliberate amber design without pretending to measure illumination", () => {
  const policy = inferPhotographicPolicy({ said: "Natural faces. Avoid amber, orange or nostalgic warm casts." });
  for (const look of [recipe({ film_sim: "Nostalgic Neg" }), recipe({ wb_shift_r: 4, wb_shift_b: -5 })]) {
    assert.equal(assessPolicyLook({ look, policy, isPrimary: false })[0]?.code, "warm_cast_intent");
    assert.equal(assessPolicyLook({ look: { ...look, status: "kept" }, policy, isPrimary: false })[0]?.severity, "preserved_conflict");
  }
  for (const look of [recipe(), recipe({ wb_shift_r: 1, wb_shift_b: -1 }), recipe({ film_sim: "Acros", wb_shift_r: 4, wb_shift_b: -5 })]) {
    assert.deepEqual(assessPolicyLook({ look, policy, isPrimary: true }), []);
  }
});

test("named simulation exclusions become palette constraints; positive, ambiguous and negated mentions do not", () => {
  const cases: [string, string[]][] = [
    ["Street at golden hour, anything but Classic Chrome please.", ["Classic Chrome"]],
    ["No Classic Chrome and nothing with Nostalgic Neg, the couple hates that look.", ["Classic Chrome", "Nostalgic Neg"]],
    ["No Classic Chrome or Nostalgic Negative.", ["Classic Chrome", "Nostalgic Neg"]],
    ["I hate Velvia; keep it natural.", ["Velvia"]],
    ["Use Reala Ace instead of Classic Chrome.", ["Classic Chrome"]],
    ["Eterna Bleach Bypass is banned.", ["Eterna Bleach Bypass"]],
    ["No Eterna, but bleach bypass is fine.", ["Eterna"]],
    ["Classic Chrome for the street, Velvia for flowers.", []],
    ["Natural color except Velvia for the landscapes.", []],
    ["Don't avoid Classic Chrome; I love it.", []],
  ];
  for (const [said, expected] of cases) assert.deepEqual(inferPhotographicPolicy({ said }).avoidSimulations, expected, said);
  assert.deepEqual(inferPhotographicPolicy({ said: "No Acros today." }).avoidSimulations.sort(), ["Acros", "Acros+G", "Acros+R", "Acros+Ye"]);
});

test("an excluded simulation conflicts on the final written look and stays preserved on a kept bank", () => {
  const policy = inferPhotographicPolicy({ said: "No Classic Chrome." });
  assert.equal(assessPolicyLook({ look: recipe({ film_sim: "Classic Chrome" }), policy, isPrimary: false })[0]?.code, "simulation_intent");
  assert.equal(assessPolicyLook({ look: { ...recipe({ film_sim: "Classic Chrome" }), status: "kept" }, policy, isPrimary: false })[0]?.severity, "preserved_conflict");
  assert.deepEqual(assessPolicyLook({ look: recipe({ film_sim: "Reala Ace" }), policy, isPrimary: true }), []);
});

test("subject-first cast wording avoids warm casts without turning subject colors into a constraint", () => {
  for (const said of ["The bride's skin must never look orange or yellow.", "Skin shouldn't turn orange.", "No yellow skin please.", "Keep faces neutral, not amber."]) {
    assert.equal(inferPhotographicPolicy({ said }).avoidWarmCast, true, said);
  }
  for (const said of ["Kids in yellow raincoats; faces should not be hidden.", "A yellow taxi beside orange flowers."]) {
    assert.equal(inferPhotographicPolicy({ said }).avoidWarmCast, false, said);
  }
});

test("an all-monochrome palette with a requested color exception is flagged for review", () => {
  const policy = inferPhotographicPolicy({ said: "All black and white, but give me one color look for the sunset." });
  assert.equal(policy.paletteMode, "monochrome");
  assert.equal(policy.requiresReview, true);
});

test("design reasons that state a different final value are flagged; contrasted source values are not", () => {
  const choice = (setting: "film_sim" | "white_balance" | "dynamic_range" | "tone_curve" | "color" | "texture", reason: string) =>
    design({ choices: [{ setting, reason, knowledge_ids: ["taste-intent"] }] });
  const final = recipe({ film_sim: "Classic Chrome", color: 3, wb_shift_r: 2, wb_shift_b: -6, dynamic_range: "DR400", highlight: -1, shadow: 0.5, clarity: 0, grain: "Off" });
  const mismatch = (setting: Parameters<typeof choice>[0], reason: string) => codes(validateFactualRationale({ recipe: final, design: choice(setting, reason) })).includes("stated_setting_mismatch");
  assert.ok(mismatch("film_sim", "Pro Neg Std renders skin gently."));
  assert.ok(mismatch("color", "Color 0 keeps skin natural."));
  assert.ok(mismatch("white_balance", "Auto with R+1, B-2 adds a mild glow."));
  assert.ok(mismatch("dynamic_range", "DR200 keeps ISO low."));
  assert.ok(mismatch("tone_curve", "Highlight -2 softens the dress."));
  assert.ok(mismatch("texture", "Clarity +3 and weak grain as published."));
  for (const [setting, reason] of [["film_sim", "Classic Chrome replaces Eterna, changing the source character."], ["color", "Color+3 is stronger than source Color+2."],
    ["white_balance", "Reduce source R+3/B-5 warmth; R+2, B-6 keeps it golden."], ["dynamic_range", "Shade alone does not justify DR200; DR400 holds the sky."],
    ["tone_curve", "Lift from source Shadow+2 to keep separation."], ["texture", "Reduce strong grain; zero clarity avoids delay."], ["color", "A restrained color interpretation."]] as const) {
    assert.ok(!mismatch(setting, reason), reason);
  }
  const sanitized = sanitizeFactualRationale({ recipe: final, design: choice("color", "Color 0 keeps skin natural.") });
  assert.equal(sanitized.design?.choices[0].reason, "");
  assert.equal(sanitized.design?.requires_review, true);
});
