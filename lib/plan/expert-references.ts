// Original reference directions, not a copied creator recipe catalog or a record of camera-rendered quality.
import { type CameraCaps, writable } from "../cameras.js";
import { isMonochromeRecipe, type PhotographicPolicy } from "./expert-policy.js";
import type { PhotographicBrief, RecipeFields } from "./types.js";

export const EXPERT_REFERENCE_VERSION = "x100vi-directions-2026-10-14.1";
export type ReferenceSource = {
  title: string;
  url: string;
  role: "manufacturer_fact" | "creator_tradeoff";
};
export type ExpertReference = {
  id: string;
  title: string;
  camera: "X100VI";
  generation: "X-Trans V";
  origin: "original_direction" | "creator_inspired_direction";
  author: "Dial In";
  settings: RecipeFields;
  intent_tags: readonly string[];
  scene_tags: readonly string[];
  avoid_tags: readonly string[];
  rationale: string;
  tradeoff: string;
  adaptation: string;
  sources: readonly ReferenceSource[];
  limitations: readonly string[];
  photographic_validation: "not_rendered";
  exact_creator_copy: false;
};

const sources = {
  quality: { title: "X100VI image quality controls", url: "https://fujifilm-dsc.com/en/manual/x100vi/menu_shooting/image_quality_setting/index.html", role: "manufacturer_fact" },
  guide: { title: "Fujifilm simulation use and filter behavior", url: "https://www.fujifilm-x.com/en-gb/learning-centre/empower-your-photography-with-fujifilm-film-simulations/", role: "manufacturer_fact" },
  reala: { title: "Fujifilm REALA ACE characteristics", url: "https://www.fujifilm-x.com/en-us/products/film-simulation/reala-ace/", role: "manufacturer_fact" },
  chrome: { title: "Fujifilm CLASSIC CHROME characteristics", url: "https://www.fujifilm-x.com/en-us/products/film-simulation/classic-chrome/", role: "manufacturer_fact" },
  proNeg: { title: "Fujifilm PRO Neg. Std and Hi characteristics", url: "https://www.fujifilm-x.com/en-us/products/film-simulation/pro-neg-std/", role: "manufacturer_fact" },
  nostalgic: { title: "Fujifilm NOSTALGIC Neg. characteristics", url: "https://www.fujifilm-x.com/en-us/products/film-simulation/nostalgic-neg/", role: "manufacturer_fact" },
  velvia: { title: "Fujifilm Velvia characteristics", url: "https://www.fujifilm-x.com/en-us/products/film-simulation/velvia/", role: "manufacturer_fact" },
  acros: { title: "Fujifilm ACROS texture", url: "https://www.fujifilm-x.com/en-us/products/film-simulation/acros/", role: "manufacturer_fact" },
  edgoose: { title: "Josh Edgoose with Fujifilm: intention and recipe design", url: "https://www.fujifilm-x.com/en-gb/learning-centre/make-your-own-film-simulation-recipe/", role: "creator_tradeoff" },
  boucry: { title: "Nathalie Boucry: family-memory intention and light-dependent tradeoffs", url: "https://www.fujifilm-x.com/nl-nl/stories/classic-neg-fs-recipe-x-nathalie-boucry/", role: "creator_tradeoff" },
} satisfies Record<string, ReferenceSource>;

/** Independently authored numeric starting points. NR -4/Clarity0 reflect current write/speed policy, not best taste. */
function settings(name: string, values: Partial<RecipeFields>): RecipeFields {
  return { name, film_sim: "Reala Ace", grain: "Off", color_chrome: "Off", color_chrome_fx_blue: "Off",
    white_balance: "Auto", kelvin: 0, wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR200", highlight: -0.5, shadow: 0,
    color: 0, sharpness: -1, noise_reduction: -4, clarity: 0, why: "An unrendered starting direction for review.", ...values };
}
type Direction = Omit<ExpertReference, "camera" | "generation" | "author" | "photographic_validation" | "exact_creator_copy">;
const direction = (value: Direction): ExpertReference => ({ camera: "X100VI", generation: "X-Trans V", author: "Dial In",
  photographic_validation: "not_rendered", exact_creator_copy: false, ...value });

export const EXPERT_REFERENCES: readonly ExpertReference[] = [
  direction({ id: "ref-faithful-everyday", title: "Faithful everyday color", origin: "original_direction",
    settings: settings("Everyday color", { why: "A restrained color baseline for varied subjects." }),
    intent_tags: ["faithful", "natural", "believable", "everyday", "family"], scene_tags: ["people", "daylight", "mixed subjects"], avoid_tags: ["monochrome only"],
    rationale: "Start with REALA ACE's varied-subject color and avoid a strong global cast.",
    tradeoff: "Its firmer highlights can still be harsh on a bright face; DR200 is not clipping insurance.",
    adaptation: "Decide DR and tones from highlight priority; preserve a requested cast instead of automatic neutrality.",
    sources: [sources.reala, sources.quality], limitations: ["Uncalibrated JPEG color is not exact product-color proof.", "Auto WB adapts; it cannot guarantee skin across different light sources."] }),
  direction({ id: "ref-gentle-people", title: "Gentle people", origin: "original_direction",
    settings: settings("Gentle faces", { film_sim: "Pro Neg Std", highlight: -1, shadow: -0.5, why: "Gentler gradation for people when strong contrast is unwanted." }),
    intent_tags: ["people", "portrait", "skin", "gentle", "natural"], scene_tags: ["faces", "window", "controlled light"], avoid_tags: ["hard silhouette"],
    rationale: "Use Pro Neg Std's soft portrait gradation, then judge whether additional softening is necessary.",
    tradeoff: "Can lose useful separation in flat light; it does not smooth away skin texture.",
    adaptation: "Consider stronger tone separation for flat light, rather than declaring this the universal skin recipe.",
    sources: [sources.proNeg, sources.guide], limitations: ["Pro Neg Hi is a distinct base, not an exact equivalent produced by slider changes.", "Actual skin and lighting still need review."] }),
  direction({ id: "ref-quiet-documentary", title: "Quiet documentary", origin: "original_direction",
    settings: settings("Quiet story", { film_sim: "Classic Chrome", highlight: -0.5, shadow: 0.5, color: -1, why: "Restrained color lets gesture and surroundings lead." }),
    intent_tags: ["documentary", "restrained", "quiet", "muted", "story"], scene_tags: ["street", "market", "interior", "weathered"], avoid_tags: ["exact red hue", "vivid color"],
    rationale: "Classic Chrome's restraint supports a quiet record without treating every photograph as nostalgia.",
    tradeoff: "Muted reds and stronger shadows may cost important clothing color or face detail.",
    adaptation: "Protect a face with exposure and gentler tones; choose a different base when the red hue is the subject.",
    sources: [sources.chrome], limitations: ["Not an exact historical film-stock reproduction.", "A documentary style is interpretation, not colorimetric neutrality."] }),
  direction({ id: "ref-warm-memory", title: "Warm memory", origin: "creator_inspired_direction",
    settings: settings("Warm memory", { film_sim: "Nostalgic Neg", grain: "Weak Small", wb_shift_r: 1, wb_shift_b: -1,
      highlight: -1, shadow: -0.5, color: 1, why: "A deliberate warm album interpretation, with restrained texture." }),
    intent_tags: ["warm", "nostalgic", "amber", "memory", "album"], scene_tags: ["family", "travel", "daylight"], avoid_tags: ["no orange cast", "neutral skin"],
    rationale: "A family-memory intention can justify warmth and texture; the numeric recipe here is independently authored.",
    tradeoff: "Amber highlights plus warm WB shifts can push skin orange; warm ambient lamps increase that risk.",
    adaptation: "Reduce the added cast before replacing the base if faces are too orange. Keep warmth only when requested.",
    sources: [sources.nostalgic, sources.boucry, sources.edgoose], limitations: ["Inspired by creative intention/tradeoffs, not Boucry's or Edgoose's published numeric recipe.", "No diffusion-filter softness or halation is implied."] }),
  direction({ id: "ref-vivid-nature", title: "Deliberate vivid nature", origin: "original_direction",
    settings: settings("Vivid nature", { film_sim: "Velvia", white_balance: "Daylight", highlight: -1, shadow: -0.5,
      color_chrome: "Weak", color_chrome_fx_blue: "Weak", why: "Color drama for foliage, flowers and scenic frames." }),
    intent_tags: ["vivid", "colorful", "saturated", "dramatic"], scene_tags: ["foliage", "flowers", "landscape", "scenery"], avoid_tags: ["natural faces", "muted documentary"],
    rationale: "Velvia already supplies strong color; keep extra color density modest until the scene warrants more.",
    tradeoff: "Already saturated subjects and skin may become dense; FX Blue can over-darken an important blue surface.",
    adaptation: "Choose blue depth separately from red/green detail; fixed Daylight may need changing under new illumination.",
    sources: [sources.velvia, sources.guide, sources.quality], limitations: ["Not automatically appropriate because it is sunny.", "Does not guarantee saturated-channel or highlight recovery."] }),
  direction({ id: "ref-saturated-detail", title: "Saturated color detail", origin: "original_direction",
    settings: settings("Color detail", { color_chrome: "Strong", highlight: -1, color: 0,
      why: "Explore gradation in saturated objects without extra overall color." }),
    intent_tags: ["red", "hue", "detail", "fabric", "product"], scene_tags: ["red fabric", "bright flowers", "signage", "window"], avoid_tags: ["exact calibrated color"],
    rationale: "Separate saturated-color gradation from the overall Color slider and preserve the important hue.",
    tradeoff: "Stronger Chrome can change density beyond the desired object; compare with it Off.",
    adaptation: "Use the mildest strength that serves visible detail; do not claim it removes glare or fixes sensor clipping.",
    sources: [sources.reala, sources.quality], limitations: ["A processing effect cannot replace lighting or optical reflection control.", "Precise product color needs a controlled color workflow beyond this proposal."] }),
  direction({ id: "ref-mixed-interior", title: "Faces in mixed interiors", origin: "original_direction",
    settings: settings("Mixed interior", { film_sim: "Pro Neg Std", dynamic_range: "DR100", highlight: -0.5, shadow: -0.5,
      why: "An adaptable starting point for faces and retained room atmosphere." }),
    intent_tags: ["believable face", "cozy", "atmosphere", "no green faces"], scene_tags: ["mixed", "LED", "fluorescent", "tungsten", "window", "interior"], avoid_tags: ["uniform neutral correction"],
    rationale: "Begin with adaptable Auto WB; diagnose the dominant subject light before adding a green/magenta correction.",
    tradeoff: "One WB cannot neutralize differently lit regions; keeping ambience may leave some cast.",
    adaptation: "DR100 here is provisional for modest contrast, not an indoor rule. Bright windows/signs may justify higher DR.",
    sources: [sources.proNeg, sources.quality], limitations: ["No precise Kelvin is inferred from a phone JPEG.", "Auto WB and zero shift do not guarantee neutrality under LED spectra."] }),
  direction({ id: "ref-gentle-monochrome", title: "Gentle monochrome separation", origin: "original_direction",
    settings: settings("Gentle B&W", { film_sim: "Acros+Ye", grain: "Weak Small", highlight: -0.5, shadow: 0,
      why: "A quieter monochrome interpretation of gesture and form." }),
    intent_tags: ["monochrome", "black and white", "gesture", "form", "gentle"], scene_tags: ["people", "street", "clouds"], avoid_tags: ["retain color", "all color"],
    rationale: "Yellow filtering provides milder blue separation than red, on ACROS's own tonal/texture base.",
    tradeoff: "Loses meaningful hue information; native monochrome tint is not represented by this Recipe.",
    adaptation: "Use only where color is optional, and check the camera's tint when neutral B&W matters.",
    sources: [sources.acros, sources.guide], limitations: ["The signature is not a neutral-tint guarantee.", "Added grain is distinct from ACROS's embedded ISO-dependent texture."] }),
  direction({ id: "ref-dramatic-monochrome", title: "Dramatic monochrome separation", origin: "original_direction",
    settings: settings("Graphic B&W", { film_sim: "Acros+R", highlight: 0, shadow: 1, grain: "Weak Small",
      why: "Stronger color-to-tone separation for a deliberate graphic interpretation." }),
    intent_tags: ["monochrome", "black and white", "graphic", "dramatic", "silhouette"], scene_tags: ["blue sky", "red brick", "geometry", "hard light"], avoid_tags: ["retain color", "soft faces"],
    rationale: "Red filtering darkens blues relative to reds, useful only when those relationships serve the photograph.",
    tradeoff: "Harder shadows can lose face detail; a red object becomes lighter relative to a blue one.",
    adaptation: "Retain intentional silhouette rather than automatically lifting every face; choose gentler filtering for another goal.",
    sources: [sources.acros, sources.guide], limitations: ["Not mandatory for midday, indoors or any particular weather.", "Native monochrome tint remains unknown."] }),
  direction({ id: "ref-astia-context", title: "Gentle skin with surrounding color", origin: "original_direction",
    settings: settings("Skin and color", { film_sim: "Astia", highlight: -0.5, shadow: 0,
      why: "An unmapped native alternative for skin and lively surroundings." }),
    intent_tags: ["skin", "portrait", "natural", "colorful"], scene_tags: ["outdoors", "blue sky", "green foliage"], avoid_tags: ["fully desaturated"],
    rationale: "ASTIA can treat skin gently while retaining vivid surrounding blues/greens; it is not uniformly muted.",
    tradeoff: "Native X100VI support does not establish a permitted new settings-file write in the current map.",
    adaptation: "An already-kept ASTIA bank can remain exact; a new mapped substitute must be called a compromise.",
    sources: [sources.guide], limitations: ["Reference-only for new writes until mapping/acceptance evidence exists.", "Pro Neg Std does not become an identical ASTIA rendering by copying these sliders."] }),
];

export type ReferenceMatch = { reference: ExpertReference; score: number; matched_tags: string[]; new_write_supported: boolean };
const text = (value: string) => value.toLowerCase().replace(/[^a-z0-9&]+/g, " ").trim();
const contains = (haystack: string, tag: string) => (` ${haystack} `).includes(` ${text(tag)} `);

/** Transparent lexical shortlist, not an image classifier or quality rank. The model still reasons over this shortlist. */
export function selectExpertReferences(input: {
  brief: PhotographicBrief;
  policy?: PhotographicPolicy;
  camera: CameraCaps;
  limit?: number;
  includeUnmapped?: boolean;
}): ReferenceMatch[] {
  if (input.camera.id !== "X100VI") return [];
  const intent = text([input.brief.intent, input.brief.rendering_goal, ...input.brief.color_priorities].join(" "));
  const scene = text([...input.brief.subjects, ...input.brief.lighting, ...input.brief.observations].join(" "));
  const ok = writable(input.camera);
  const matches: ReferenceMatch[] = [];
  for (const reference of EXPERT_REFERENCES) {
    const isMono = isMonochromeRecipe(reference.settings);
    if (input.policy?.paletteMode === "color" && isMono || input.policy?.paletteMode === "monochrome" && !isMono) continue;
    if (input.policy?.avoidWarmCast && reference.id === "ref-warm-memory") continue;
    if (input.policy?.avoidSimulations?.includes(reference.settings.film_sim)) continue;
    const new_write_supported = ok.filmSims.includes(reference.settings.film_sim) && ok.whiteBalances.includes(reference.settings.white_balance)
      && ok.color.includes(reference.settings.color) && ok.noiseReduction.includes(reference.settings.noise_reduction);
    if (!new_write_supported && !input.includeUnmapped) continue;
    const intentMatches = reference.intent_tags.filter((tag) => contains(intent, tag));
    const sceneMatches = reference.scene_tags.filter((tag) => contains(scene, tag));
    const avoid = reference.avoid_tags.filter((tag) => contains(intent, tag));
    const score = intentMatches.length * 3 + sceneMatches.length - avoid.length * 4;
    // No generic filler when supplied evidence does not match this reference.
    if (score <= 0) continue;
    matches.push({ reference: structuredClone(reference), score, matched_tags: [...new Set([...intentMatches, ...sceneMatches])], new_write_supported });
  }
  return matches.sort((a, b) => b.score - a.score || a.reference.id.localeCompare(b.reference.id))
    .slice(0, Math.min(6, Math.max(1, Math.trunc(input.limit ?? 4))));
}

export function referenceContext(matches: readonly ReferenceMatch[]): string {
  if (!matches.length) return "No reviewed reference direction matched. Reason from the supplied brief and verified camera constraints; do not invent a creator recipe.";
  return [`ORIGINAL REFERENCE DIRECTIONS ${EXPERT_REFERENCE_VERSION}; unrendered hypotheses, not golden recipes or exact creator copies.`,
    ...matches.map(({ reference: r, matched_tags, new_write_supported }) =>
      `[${r.id}] ${r.title}; matched: ${matched_tags.join(", ")}; ${new_write_supported ? "current new-write value subset" : "native context only; new write not mapped"}.\n`
      + `Starting settings: ${JSON.stringify(r.settings)}\nIntent: ${r.rationale}\nTradeoff: ${r.tradeoff}\nAdapt: ${r.adaptation}\n`
      + `Limits: ${r.limitations.join(" ")}\nProvenance: ${r.origin}, independently authored numeric settings; `
      + r.sources.map((s) => `${s.role}: ${s.title} (${s.url})`).join("; ")),
    "Select/adapt only when this subject and intention warrant it. Explain every changed effective setting; retain reference IDs only as provenance, never camera or taste proof.",
  ].join("\n\n");
}
