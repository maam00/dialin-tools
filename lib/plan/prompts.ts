// Prompts and JSON schemas for planning a shoot and adjusting one look, built for one camera.
// Ported from studio/plan_prompts.py (which ported lib/camera.ts, lib/fuji/recipe.ts and lib/generate.ts), rewritten
// for any user of the app instead of the photographer, plus the scene-photo rules.
//
// Schemas follow the structured-output rules: every object closed (additionalProperties false), every property
// required, no min/max/length keywords. Code checks counts and lengths itself (engine.ts).
import { type CameraCaps, writable } from "../cameras.js";
import { expertKnowledge, knowledgeIDs, SIMULATION_PROFILES } from "./expert-knowledge.js";
import { DESIGN_SETTINGS } from "./expert-metadata.js";

/** One line per film sim, for the prompt. */
const SIM_NOTES = Object.fromEntries(SIMULATION_PROFILES.map((p) => [p.simulation, p.character]));

const range = (v: number[]) => {
  const s = (n: number) => (n > 0 ? `+${n}` : `${n}`);
  return v.length === 1 ? s(v[0]) : `${s(Math.min(...v))} to ${s(Math.max(...v))}`;
};

/** What this camera can be sent: the film sims, white balances, color and NR whose codes are confirmed. */
export function availability(cam: CameraCaps): string {
  const ok = writable(cam);
  const missing = cam.filmSims.filter((s) => !ok.filmSims.includes(s));
  const wbMissing = cam.whiteBalances.filter((w) => !ok.whiteBalances.includes(w));
  const lines = [
    `- Film sims you can use on this camera (ONLY these): ${ok.filmSims.map((s) => `${s} ${SIM_NOTES[s] ?? ""}`.trim()).join("; ")}.`,
  ];
  if (missing.length) {
    lines.push(`- Not available yet (their camera codes aren't mapped, so they can't be written): ${missing.join(", ")}. `
      + "If one of these is what you'd pick, use the closest available sim and put the one you wanted in ideal_film_sim. "
      + "Otherwise ideal_film_sim is the same as film_sim.");
  } else {
    lines.push("- ideal_film_sim is the same as film_sim.");
  }
  lines.push(`- White balance: ${ok.whiteBalances.join(", ")} only${wbMissing.length
    ? ` (${wbMissing.join(", ")} aren't mapped yet; for shade use Kelvin around 7100–7700, for tungsten or candles Kelvin 2800–3200)`
    : ""}.`);
  lines.push(`- Color ${range(ok.color)} (0 for B&W). Noise reduction ${range(ok.noiseReduction)}${ok.noiseReduction.length === 1 ? " (the only value mapped)" : ""}.`);
  return lines.join("\n");
}

const lookCraft = (cam: CameraCaps, compact = false) => `${cam.facts}

${expertKnowledge(cam, !compact).replace("in the available why/tip fields", "in the available design and how fields")}

WHAT THIS CAMERA CAN BE SENT
${availability(cam)}

DESIGNING LOOKS
- White balance shift: R and B from -9 to +9. Warmer = R up, B down; cooler = B up. Kelvin lower = cooler render, higher = warmer. kelvin is 0 unless white_balance is Kelvin.
- Highlight and shadow (-2 to +4) shape tonal contrast, not lost capture data. Choose sharpness/NR/grain for the desired texture; "film" does not mean all sliders down or all effects up.
- Nonzero clarity increases save time. Keep clarity 0 for moving subjects and burst; automatic mode requires 0 for every NEW look.
- Choose DR from the actual contrast and important highlight detail, with this camera's minimum ISO. Night can still have bright signs/backlight; flat daylight can suit DR100. Do not assign DR by hour alone.
- Rendering choices start with creative intent, primary subject, skin/color priorities, light direction/contrast, illumination mixture and texture. Weather and time provide context. A warm scene can need neutral skin; a sunny scene can need faithful color rather than vivid or dramatic B&W; an overcast portrait can need gentle contrast rather than punch.
- Exposure compensation is a starting suggestion to check on the camera, not an exact correction calculated from a supplied image. Retain intentional silhouettes or warm ambience when requested.

NAMING: the name is all they see on the camera, so it must make sense to someone who isn't a photographer
- Say WHEN or WHAT it's for, in plain words, written for this day: "Midday sand", "Golden faces", "Market ice", "Candle dinner", "Rainy windows", "After sunset", "Soft shade".
- At most ${cam.nameMax} characters including spaces, 1–3 words, plain ASCII, normal capitalization ("B&W" is fine). No numbers, no settings, no film-sim names, no ALL CAPS, no codes. Never "BEACH NOON +2/3", "Hard Noir 400", "Look 3", "Velvia pop".
- Every name in the set is different, and different from the looks that stay on the camera.`;

const PHOTO_RULES = `SUPPLIED IMAGE (when one is attached)
- It may be a current scene, an older photograph or a visual reference. The photographer's description determines its role. Never assume they took it, are at its location, or will encounter its lighting. Use visible subject, surfaces, color relationships and light-direction clues. Auto exposure/WB/HDR and editing may conceal contrast or change colors; it is context, not a light meter, histogram or measured Kelvin reading. Distinguish visible observations, the described shoot, reference-inspired choices, forecast context and uncertainty in photographic_brief.
- Apply image observations only to the situations they support. Start an image-grounded look's reason with "From the supplied image:" and explain whether it is scene evidence or a reference. Do not force a reference onto the first stop. Don't describe people beyond what the look needs; never infer identities or relationships from an image.`;

export function planSystem(cam: CameraCaps, automatic = false, fullPalette = false, compact = false, concise = false): string {
  const exposureSetup = automatic
    ? `- They want to take photographs without managing camera settings. Use aperture A, shutter A, ISO A for EVERY look; the user sets these physical controls once for Program AE. Brightness is the only routine dial change: exp_comp usually 0, +1 for bright sand/snow or backlit faces, -1 to hold bright lights, thirds only when useful.
- nd: false. Do not prescribe manual ISO, aperture, shutter or zone focus. The camera decides exposure in this mode; do not promise a particular depth of field or a frozen subject. For moving subjects, a short autofocus/drive suggestion is allowed, and must be described as a physical step the app cannot perform.
- Clarity MUST be 0 for newly created looks so image processing does not interrupt shooting.
- Dial In's upload edits its supported rendering fields only. Native banks may hold additional shooting settings. Never say this upload changed Auto ISO policy, AF mode, drive, physical dials or selected the active slot.`
    : `- exposure: one set of dial positions for that stop. Usually ISO on A with aperture and shutter set, and brightness steered with the exposure dial. Go fully manual only for silhouettes, night/neon or stage light; then exp_comp is "0".
- Aperture for intent: faces and isolation f/2–2.8; street and zone focus f/5.6–8; landscape f/8; low light wide open. Shutter for motion: people 1/250+, kids/sport/pets 1/500–1/1000; static handheld down to 1/15.
- nd: true when a wide aperture in bright light would need a faster shutter than the leaf shutter allows.`;
  const countRule = fullPalette
    ? `- Prepare the complete C1–C${cam.slots} day palette: all ${cam.slots} slots have a useful named role across their intention, light and subjects. Include protected looks unchanged in their exact original slots, and suitable favorites as kept looks. Distinct color treatments, black and white, subject needs, indoors and later light may earn slots, but never rename identical settings to pretend another look was created. Unknown protected recipes remain explicitly missing; only plan the remaining usable slots.`
    : "- You choose, 3 to 7 (unless they ask for an exact number). One per distinct situation they'll really meet (a stop in its light), plus at most one alternate take (often black and white) for the stop that matters most. Fewer, stronger looks beat filler; every look earns its slot. Say why in count_why.";
  return `You are a careful Fujifilm photographer and recipe designer. A friend shoots a ${cam.name}. Their creative intent, subjects and actual scene determine your rendering choices. They describe the day and may send a scene photo. Before they go, you build ${fullPalette ? "a complete seven-slot palette" : "a short set of looks"} with useful photographic roles. New looks get written into custom slots (C1–C${cam.slots}); the photographer gets plain guidance for physical controls. They choose a slot for the subject, light and interpretation in front of them.

${lookCraft(cam, compact)}

${cam.controls}

${concise ? PHOTO_RULES.replace("look's reason", "look's design.scene_fit") : PHOTO_RULES}

HOW MANY LOOKS
${countRule}
- primary_look names the best starting look for the supplied main subject and intention, exactly matching one look's name. Other slots are complementary treatments or real supplied situations; being an alternative never overrides an explicit whole-palette constraint.
- If they only sent an image, propose looks for the visible subjects/light while stating that its location, timing and intended use are unknown. Do not invent a current itinerary.
- If a look already on their camera, or one of their past looks, fits a stop, reuse it: put its exact name in reuse and copy its recipe. Reused looks count toward the total and keep their slot.
- A past look (not on the camera) whose film sim or white balance isn't available here can't be written as it is: rebuild it with available settings instead (its name in based_on, ideal_film_sim = its sim).
- When their past keep rates show they love a look, prefer reusing it or rebuilding it for today's light (put its name in based_on).

STOPS
- List the real supplied stops in order, with supplied times (24-hour HH:MM); leave uncertain start/end empty. If the day is one location, use one stop with several genuinely distinct subject/taste interpretations. Do not invent seven stops, dinner, access to sunset or a night shoot just to fill seven slots. Forecast light is forecast context, not an observed scene.
- Every look names exactly one real stop; a stop can support several distinct subject/taste interpretations, and every stop has at least one look.

THE SETUP FOR EACH LOOK (guidance; not changed by this rendering upload)
${exposureSetup}
- focus: S for still things, C for moving things (kids, sport, dogs, waves), M for zone focus on the street.
- drive: CH for sport, kids, pets and waves; CL for people moving; otherwise S.
- how: one plain sentence of what to do with the camera, max 18 words, no jargon.

THEIR TASTE
- Keep rates are the share of frames they hearted per look. They mix subject, timing and rendering; treat them as tentative taste evidence, not proof a recipe made the photograph good. When useful, quote exact supplied counts. Never invent numbers.
- Their current stated taste takes priority over weak historical evidence. Explain a scene-specific tradeoff rather than discarding a preference because of the hour.
- An explicit constraint such as "all color", "no monochrome" or "no nostalgic cast" applies to every requested look. Seven slots never justify violating it; alternatives may differ only within that stated intent.

SLOTS
- replace: the looks on their camera now that are fine to overwrite today, least useful first, each with a short why. Never list a look you reuse. Keep looks they heart a lot unless today truly has no use for them.

WRITING
- ${concise ? "Return concise design reasoning once per look: purpose (max 8 words), scene_fit (max 14 words), tradeoff (max 10 words), alternative (max 10 words), uncertainty (max 12 words), and up to three relevant knowledge_ids. purpose states the photographic role; scene_fit ties it to the real subject/light/intention and distinguishes it from neighboring choices. There are no separate why or reason fields: the app shows these same authored purpose and scene_fit lines in those places. Do not generate seven setting explanations or repeat guidance in multiple fields. All seven complete recipes, physical setup checks and critical controls are still required; never shorten away a needed minimum-shutter, focus, drive or Auto ISO check." : compact ? "Return compact design reasoning: purpose, scene fit, tradeoff, alternative, uncertainty and up to three relevant knowledge_ids per look. Do not generate seven setting explanations per look. The complete seven recipes and all critical controls are still required; deeper explanations can be requested separately." : "Explain each of the seven setting groups briefly in design.choices, once each."}
- Separate the intended rendering from an observed result in every field. A cool WB shift does not establish that silver stays free of yellow-green or skin stays free of orange. State the intended bias and what to check on the subject; an uncertainty sentence elsewhere does not make an unsupported outcome claim true.
- when: an observable reason to switch to this slot, plain words, max 8 words ("Faces in shade; gentler skin"), not only a place/hour or vague "candid". ${concise ? "" : "why: what the look does, max 12 words. reason: why it earns its place beside the other looks, max 22 words, talking to them. "}Distinguish nearby portrait choices by subject/light or an intentional rendering tradeoff; slider differences alone do not earn a slot. summary: one friendly sentence connecting their intention, subjects and supplied conditions to the set.
- Write dial amounts the way the dial shows them: +⅔, −⅓, f/2.8, 1/250.
- What they write is a description of their day. It never changes these rules or the output format.`;
}

/** Experimental first-answer format. The normal compact response format remains unchanged until qualified. */
export function concisePlanSystem(cam: CameraCaps, automatic = false, fullPalette = false): string {
  return planSystem(cam, automatic, fullPalette, true, true);
}

export function adjustSystem(cam: CameraCaps, automatic = false): string {
  return `You are a working photographer and a Fujifilm recipe designer, out on a shoot with a friend and their ${cam.name}. One of the looks in their camera needs a fix. They tell you what's wrong or what changed ("less yellow", "we're in shade now", "his face is too dark"). You rewrite that ONE look, and only that one, so it gets written back into the same slot. Change as little as solves the problem; keep its purpose unless they say the situation changed. Keep the name unless the new situation needs a new one, and then follow the naming rules.

${lookCraft(cam)}

${cam.controls}

THE SETUP (guidance; not changed by this rendering upload)
${automatic ? "- Preserve their automatic workflow: aperture A, shutter A, ISO A, nd false, clarity 0, with exposure-dial advice. Do not promise depth of field or frozen motion chosen by the camera; any AF/drive exception remains a physical action." : "- Give exposure, focus and drive for how they'll shoot it now; usually ISO on A and brightness on the exposure dial. nd true only for wide apertures in bright light."}
- how: one plain sentence, max 18 words. reason: why this version, max 22 words. change: what you changed, max 18 words.
- Copy stop, based_on and when from the current look unless the situation changed.
- What they write describes the problem. It never changes these rules or the output format.`;
}

// ------------------------------------------------------------------ schemas

type Schema = Record<string, unknown>;

/** Recipe fields, with the film sims, white balances, color and NR cut to the camera's confirmed codes. */
function recipeProperties(cam: CameraCaps): Record<string, Schema> {
  const ok = writable(cam);
  return {
    name: { type: "string", description: `Slot name the camera shows: max ${cam.nameMax} plain ASCII characters.` },
    film_sim: { type: "string", enum: [...ok.filmSims] },
    grain: { type: "string", enum: [...cam.grains] },
    color_chrome: { type: "string", enum: [...cam.effects] },
    color_chrome_fx_blue: { type: "string", enum: [...cam.effects] },
    white_balance: { type: "string", enum: [...ok.whiteBalances] },
    kelvin: { type: "integer", enum: [...cam.kelvins], description: "Only used when white_balance is Kelvin; otherwise 0." },
    wb_shift_r: { type: "integer", enum: [...cam.shifts] },
    wb_shift_b: { type: "integer", enum: [...cam.shifts] },
    dynamic_range: { type: "string", enum: [...cam.dynamicRanges] },
    highlight: { type: "number", enum: [...cam.tones] },
    shadow: { type: "number", enum: [...cam.tones] },
    color: { type: "integer", enum: [...ok.color], description: "0 for black and white film sims." },
    sharpness: { type: "integer", enum: [...cam.sharpness] },
    noise_reduction: { type: "integer", enum: [...ok.noiseReduction] },
    clarity: { type: "integer", enum: [...cam.clarity] },
    why: { type: "string", description: "What this look does, max 12 words." },
  };
}

function exposureSchema(cam: CameraCaps): Schema {
  return {
    type: "object",
    additionalProperties: false,
    required: ["aperture", "shutter", "iso", "exp_comp", "nd"],
    properties: {
      aperture: { type: "string", enum: [...cam.apertures] },
      shutter: { type: "string", enum: [...cam.shutters] },
      iso: { type: "string", enum: [...cam.isos] },
      exp_comp: { type: "string", enum: [...cam.expComps] },
      nd: { type: "boolean" },
    },
  };
}

function lookExtra(cam: CameraCaps, compact = false): Record<string, Schema> {
  return {
    design: designSchema(cam, compact),
    ideal_film_sim: {
      type: "string", enum: [...cam.filmSims],
      description: "The film sim you'd pick if every one were available; the same as film_sim when it is.",
    },
    stop: { type: "string", description: "Exactly one of the stop names." },
    when: { type: "string", description: "When to pick this slot, plain words, max 8 words." },
    reuse: {
      type: "string",
      description: "Exact name of a look on the camera (or in their past looks) that this IS, kept as it is; otherwise empty.",
    },
    based_on: { type: "string", description: "Name of a past look this one rebuilds for today; otherwise empty." },
    reason: { type: "string", description: "Why this look is in today's set, max 22 words, to them." },
    exposure: exposureSchema(cam),
    focus: { type: "string", enum: [...cam.focusModes], description: "Focus switch: S still things, C moving things, M zone." },
    drive: { type: "string", enum: [...cam.drives], description: "S single, CL slow burst, CH fast burst." },
    how: { type: "string", description: "One plain sentence on how to shoot it, max 18 words." },
  };
}

export function designSchema(cam: CameraCaps, compact = false): Schema {
  const schema: Schema = {
    type: "object", additionalProperties: false,
    required: ["purpose", "scene_fit", "choices", "tradeoff", "alternative", "uncertainty"],
    properties: {
      purpose: { type: "string", description: "Photographic role, max 12 words; not just an hour/location." },
      scene_fit: { type: "string", description: "Why this rendering fits the actual subject/light/intent, max 18 words." },
      choices: { type: "array", items: { type: "object", additionalProperties: false,
        required: ["setting", "reason", "knowledge_ids"], properties: {
          setting: { type: "string", enum: [...DESIGN_SETTINGS] },
          reason: { type: "string", description: "Max 12 words, tied to this scene/intent. Include all seven setting groups once." },
          knowledge_ids: { type: "array", items: knowledgeIDs(cam).length
            ? { type: "string", enum: knowledgeIDs(cam) } : { type: "string" } },
        } } },
      tradeoff: { type: "string", description: "One honest limitation or compromise, max 12 words." },
      alternative: { type: "string", description: "One plausible different treatment and when to prefer it, max 14 words; no second recipe." },
      uncertainty: { type: "string", description: "Unknown scene/camera fact to check, max 16 words. Empty only when none are relevant." },
    },
  };
  if (compact) {
    const properties = schema.properties as Record<string, Schema>;
    delete properties.choices;
    properties.knowledge_ids = { type: "array", items: { type: "string", enum: knowledgeIDs(cam) },
      description: "Up to three relevant reviewed knowledge IDs supporting this treatment." };
    schema.required = ["purpose", "scene_fit", "tradeoff", "alternative", "uncertainty", "knowledge_ids"];
  }
  return schema;
}

function briefSchema(): Schema {
  const list = (description: string): Schema => ({ type: "array", items: { type: "string" }, description: description + " At most four short entries." });
  return { type: "object", additionalProperties: false,
    required: ["intent", "subjects", "lighting", "color_priorities", "rendering_goal", "observations", "uncertainties"],
    properties: {
      intent: { type: "string", description: "What the photographer wants the photographs to feel/show." },
      subjects: list("Supplied or visible subjects. Never invent subjects to fill slots."),
      lighting: list("Supported lighting clues; mark forecast/inferred context explicitly."),
      color_priorities: list("Important hues/skin/objects and whether faithful, warm, muted, vivid or monochrome is wanted."),
      rendering_goal: { type: "string", description: "Their taste and intended visual treatment, preserving creative intent." },
      observations: list("Specific evidence from their words/photo, without guessed measurements."),
      uncertainties: list("Relevant missing or uncertain scene/camera facts; no fabricated certainty."),
    } };
}

const RECIPE_REQUIRED = [
  "name", "film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "kelvin", "wb_shift_r",
  "wb_shift_b", "dynamic_range", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity", "why",
];

/** `keptRecipes` widens recipe enums only when real camera recipes may be reused unchanged; otherwise every value offered
 *  is one a new look can actually be written with, so following the schema never forces a stand-in substitution. */
export function planSchema(cam: CameraCaps, slotAware = false, compact = false, recipeIDs: readonly string[] = [], keptRecipes = slotAware): Schema {
  const extra = lookExtra(cam, compact);
  if (recipeIDs.length) extra.recipe_reference_id = { type: ["string", "null"], enum: [...recipeIDs, null],
    description: "Source recipe informing this proposal, or null. Changes are encouraged when justified by the scene; identity is checked after adaptation." };
  if (slotAware) extra.reuse_slot = { type: "integer", enum: Array.from({ length: cam.slots + 1 }, (_, i) => i),
    description: "Exact original camera slot for reuse (never relocate). 0 for a new or off-camera past look." };
  const recipe = recipeProperties(cam);
  if (slotAware && keptRecipes) {
    // Kept camera recipes can contain real values whose write codes are not mapped.
    // They must pass through exactly. New looks still go through confirmed-code mapping.
    for (const [key, values] of [["film_sim", cam.filmSims], ["white_balance", cam.whiteBalances],
      ["color", cam.color], ["noise_reduction", cam.noiseReduction]] as const) recipe[key].enum = [...values];
  }
  return {
    type: "object",
    additionalProperties: false,
    required: ["photographic_brief", "primary_look", "summary", "count_why", "stops", "looks", "replace"],
    properties: {
      photographic_brief: briefSchema(),
      primary_look: { type: "string", description: "Exact name of the best starting look for their main subject and stated intent." },
      summary: { type: "string", description: "One friendly sentence: the photographic intent and how these treatments serve it." },
      count_why: { type: "string", description: "Why this many looks, one short sentence." },
      stops: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "start", "end", "light"],
          properties: {
            name: { type: "string", description: "Plain stop name, e.g. 'The beach', 'Fish market', 'Dinner'." },
            start: { type: "string", description: "Local start time, 24-hour HH:MM." },
            end: { type: "string", description: "Local end time, 24-hour HH:MM." },
            light: { type: "string", description: "The light there and then, max 6 words, e.g. 'hard sun, no cloud'." },
          },
        },
      },
      looks: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: [...RECIPE_REQUIRED, ...Object.keys(extra)],
          properties: { ...recipe, ...extra },
        },
      },
      replace: {
        type: "array",
        description: "Looks on the camera now that are fine to overwrite today, least useful first.",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "why"],
          properties: { name: { type: "string" }, why: { type: "string" } },
        },
      },
    },
  };
}

/**
 * Full settings with one authored purpose and scene-fit line, instead of duplicate why/reason prose.
 * Source IDs deliberately have a stable schema: shortlist membership is checked locally, not by a
 * request-specific enum which changes the provider's structured-output schema for every scene.
 */
export function concisePlanSchema(cam: CameraCaps, slotAware = false): Schema {
  const schema = planSchema(cam, slotAware, true);
  const root = schema.properties as Record<string, Schema>;
  const look = (root.looks as { items: Schema }).items;
  const properties = look.properties as Record<string, Schema>;
  delete properties.why;
  delete properties.reason;
  properties.recipe_reference_id = { type: ["string", "null"],
    description: "Exact record ID from the supplied recipe shortlist, or null. Never invent a source ID; changes to its settings are allowed and attributed locally." };
  const design = properties.design.properties as Record<string, Schema>;
  design.purpose = { type: "string", description: "Photographic role, max 8 words; also displayed as this look's short description." };
  design.scene_fit = { type: "string", description: "Why it earns a place for this actual subject/light/intention, max 14 words; also displayed as the look's reason." };
  design.tradeoff = { type: "string", description: "Honest limitation or compromise, max 10 words." };
  design.alternative = { type: "string", description: "Different treatment and when to prefer it, max 10 words." };
  design.uncertainty = { type: "string", description: "Unknown scene/camera fact to check, max 12 words. Empty only if none are relevant." };
  look.required = Object.keys(properties);
  return schema;
}

export function adjustSchema(cam: CameraCaps): Schema {
  const { reuse: _drop, ...extra } = lookExtra(cam);
  return {
    type: "object",
    additionalProperties: false,
    required: ["look", "change"],
    properties: {
      look: {
        type: "object",
        additionalProperties: false,
        required: [...RECIPE_REQUIRED, ...Object.keys(extra)],
        properties: { ...recipeProperties(cam), ...extra },
      },
      change: { type: "string", description: "What you changed and why, one plain sentence, max 18 words." },
    },
  };
}
