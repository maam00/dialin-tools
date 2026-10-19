/** Transparent text/setting matching for a reference shortlist, never an image-quality model. */
import type { RecipeReference, RecipeDeskAnalysis } from "./knowledge.js";
import type { RecipeSettingsAnalysis } from "./analysis.js";
import { inferPhotographicPolicy, stripAvoidedSimulations, WARM_BUT_NOT } from "../../lib/plan/expert-policy.js";

export type ShootPriority = "portrait" | "color_fidelity" | "mixed_light" | "highlight_detail" | "low_light" | "action" | "vivid_color" | "restrained_color" | "soft_tones" | "gritty_texture" | "warm_color" | "monochrome_option" | "graphic_shape";
export type ShootIntent = {
  rendering: "color" | "monochrome" | null;
  avoid_added_warmth: boolean;
  grain: "off" | "not_strong" | null;
  clarity_zero: boolean;
  monochrome_options: number;
  priorities: ShootPriority[];
  scene_segments: string[];
  conflicts: string[];
  /** Simulations named in an explicit exclusion; unknown simulations cannot satisfy it. */
  excluded_simulations: string[];
  /** Full-spectrum infrared recipes need a converted camera and are excluded unless infrared is requested. */
  infrared_requested: boolean;
  /** Soft contradictions for the host agent to resolve; they do not exclude references. */
  review_notes: string[];
};
const normal = (text: string) => text.toLowerCase().replace(/[’']/g, "").replace(/\bb\s*[&/]\s*w\b/g, "black and white").replace(/[^a-z0-9]+/g, " ").trim();
const negation = "(?:no|without|avoid|exclude|never|not|dont want|do not want)";
const mono = "(?:monochrome|black (?:and )?white|b w)";
const negative = (text: string, feature: string) => new RegExp(`\\b${negation} (?:any |a |the |added |extra |more |too |overly )?(?:${feature})\\b`).test(text);

export function inferShootIntent(text: string): ShootIntent {
  // The engine's bounded policy owns simulation exclusions and subject-first cast phrasing; reuse it rather than drift.
  const policy = inferPhotographicPolicy({ said: text });
  const value = normal(stripAvoidedSimulations(text));
  const noMono = negative(value, mono);
  const noColor = new RegExp(`\\b${negation} colou?r\\b(?! (?:cast|casts|shift|shifts|bias|tint|noise|fringing|chrome|chrome effect))`).test(value);
  const count = "(?:one|two|three|four|five|six|seven|single|[1-7])";
  const countColor = new RegExp(`\\b${count} (?:[a-z]+ )?colou?r\\b`).test(value);
  const countMono = new RegExp(`\\b${count} (?:[a-z]+ )?${mono}\\b`).test(value);
  const oneColor = /\b(?:one|single|1) (?:[a-z]+ )?colou?r (?:look|recipe)\b/.test(value) && !countMono && !/\b(?:include|optional|option|alternative)\b/.test(value);
  const oneMono = new RegExp(`\\b(?:one|single|1) (?:[a-z]+ )?${mono} (?:look|recipe)\\b`).test(value) && !countColor && !/\b(?:include|optional|option|alternative)\b/.test(value);
  const colorOnly = oneColor || noMono || /\b(?:all|only|strictly|exclusively) colou?r\b|\bcolou?r only\b/.test(value);
  const monoOnly = oneMono || noColor || new RegExp(`\\b(?:all|only|strictly|exclusively) ${mono}\\b|\\b${mono} only\\b`).test(value);
  const noGrain = negative(value, "grain") || /\bgrain (?:free|off)\b|\b(?:zero|0) grain\b|\bgrain set to off\b/.test(value);
  const noStrongGrain = negative(value, "(?:strong|heavy|large|coarse) grain");
  // "Warm but not orange" asks for warmth with a limit, not for less warmth: keep the warm intent and note the limit.
  const warmWithLimit = WARM_BUT_NOT.test(text) && !policy.avoidWarmCast;
  const avoidWarmth = (!warmWithLimit && negative(value, "(?:orange|warm|amber|yellow)(?: skin(?: tones?)?| faces?| casts?| tones?| highlights?)?")) || policy.avoidWarmCast;
  const clarityZero = negative(value, "(?:nonzero |non zero )?clarity") || negative(value, "(?:save|saving|capture|processing) delay") || /\b(?:zero|0) clarity\b|\bclarity (?:0|zero|off)\b/.test(value);
  // Remove recognized negative clauses before taste/scene expansion. The parsed intent is exposed for review.
  const positive = value.replace(new RegExp(`\\b${negation} (?:any |a |the |added |extra |more |too |overly )?(?:${mono}|colou?r|(?:strong |heavy |large |coarse )?grain|silhouettes?|(?:orange|warm|amber|yellow)(?: skin(?: tones?)?| faces?| casts?| tones?| highlights?)?)\\b`, "g"), " ");
  const priorities: ShootPriority[] = [];
  const add = (priority: ShootPriority, condition: boolean) => { if (condition) priorities.push(priority); };
  const graphic = /\b(?:silhouette|graphic shape|graphic form)\b/.test(positive);
  add("graphic_shape", graphic);
  add("portrait", !graphic && /\b(?:portraits?|family|families|children|kids|faces?|skin|wedding|bride|people|baby)\b/.test(positive));
  // A named hue or skin that must stay accurate is a color-fidelity request, not a vivid one.
  const hueAccuracy = /\b(?:red|reds|blue|blues|green|greens|yellow|orange|pink|purple|brand|product|skin(?: tones?)?|colou?rs?)\b(?: [a-z]+){0,4} (?:must|should|needs? to|has to|have to)? ?(?:stay|be|look|remain|appear|render) (?:accurate|true|faithful|correct|exact)\b/.test(positive);
  add("color_fidelity", hueAccuracy || /\b(?:faithful|accurate|true|natural|neutral|critical) colou?rs?\b|\bcolou?r (?:fidelity|critical|accuracy)\b|\bproducts? (?:catalog|catalogue|photographs?|photography|photos?|shots?|images?)\b|\bpackshots?\b/.test(positive));
  add("mixed_light", /\b(?:mixed|changing|varied) (?:light|lighting|illumination)\b|\bled\b|\breception\b/.test(positive) || (/\b(?:sun|daylight|window|outdoor)\b/.test(positive) && /\b(?:tungsten|interior|interiors|indoors?|night|neon)\b/.test(positive)));
  add("highlight_detail", /\b(?:snow|snowy|clouds|backlit|backlight|white dress|highlight|highlights|harsh|midday|noon|high contrast)\b/.test(positive));
  add("low_light", /\b(?:night|neon|dim|low light|evening|dark|tungsten|concert)\b/.test(positive));
  add("action", /\b(?:action|sports|running|moving|fast|burst|children|kids|candid|dance|dancing)\b/.test(positive));
  add("vivid_color", /\b(?:vivid|saturated|vibrant)\b|\bbold colou?r\b|\b(?:rich|lush|dense|deep) (?:colou?rs?|greens?|reds?|blues?|hues?)\b/.test(positive));
  add("restrained_color", /\b(?:muted|restrained|subdued|desaturated|quiet|documentary)\b/.test(positive));
  add("warm_color", (!avoidWarmth && /\b(?:warm|amber|nostalgic)\b/.test(positive)) || warmWithLimit);
  const numberWords: Record<string, number> = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7 };
  const monoCount = positive.match(new RegExp(`\\b(one|two|three|four|five|six|seven|[1-7]) (?:distinct |different |optional )?${mono}\\b`));
  // A plain positive mention ("black and white street photos") is a preference, not an only-constraint. Without any
  // color wording it ranks monochrome sources first; beside color wording it reserves one monochrome option.
  const monoMentioned = new RegExp(`\\b${mono}\\b`).test(positive);
  const colorWording = /\b(?:colou?rs?|colou?rful|vivid|saturated|vibrant|warm|pastel|hues?|reds?|blues?|greens?)\b/.test(positive);
  const monochromeOptions = noMono || monoOnly ? 0 : monoCount ? numberWords[monoCount[1]] ?? Number(monoCount[1])
    : new RegExp(`\\b${mono} (?:option|alternative)|\\b(?:include|some|an optional) ${mono}\\b`).test(positive) ? 1
    : monoMentioned ? colorWording ? 1 : 7 : 0;
  add("monochrome_option", monochromeOptions > 0);
  add("soft_tones", /\b(?:gentle|soft|delicate|pastel|low contrast)\b/.test(positive));
  add("gritty_texture", /\b(?:gritty|rough|coarse|heavy grain|strong grain)\b/.test(positive));
  const scene_segments = [
    ["daylight", /\b(?:sun|sunny|morning|daylight|daytime|beach|outdoor|mountain|mountains|snow|snowy)\b/],
    ["overcast_or_rain", /\b(?:rain|rainy|overcast|cloudy)\b/],
    ["interior", /\b(?:interior|interiors|indoor|indoors|window|cafe|restaurant|tungsten|reception)\b/],
    ["night", /\b(?:night|neon|evening|concert|dark)\b/],
  ].filter(([, expression]) => (expression as RegExp).test(positive)).map(([name]) => name as string);
  const conflicts = colorOnly && monoOnly ? ["Both color-only and monochrome-only constraints were detected; resolve the photographer's intent before generating."] : [];
  // Selective color: a specific named hue kept vivid/in color beside a monochrome mention ("keep the red dress vivid").
  const review_notes: string[] = monoMentioned && /\b(?:keep|retain|preserve|leave)\b(?: [a-z]+){0,2} (?:red|blue|green|yellow|orange|pink|purple)\b(?: [a-z]+){0,2} (?:vivid|colou?red|colou?rful|saturated|bright|in colou?r)\b/.test(positive)
    ? ["Monochrome and a preserved subject color were both requested. An in-camera recipe cannot keep one hue in a monochrome frame; offer separate color and monochrome looks or ask which matters more."] : [];
  // Source groups are navigation, not compatibility. Another named body is surfaced rather than silently planned for.
  const bodyPattern = /\b(?:x[- ]?(?:t|e|s|h|m|a|pro|half)\d{1,3}(?:\s?(?:ii|iii|iv|r|s|hs))?|x[- ]?100(?:\s?(?:f|s|t|v|vi))?|x[- ]?(?:30|70)|xf10|gfx\s?\d{2,3}[a-z]*(?:\s?ii)?)\b/gi;
  const bodies = [...new Set([...text.matchAll(bodyPattern)].map((match) => match[0].toUpperCase().replace(/^X[\s-]?/, "X-").replace(/^X-100/, "X100")))]
    .filter((body) => !/^X100\s?VI$/i.test(body));
  if (warmWithLimit) review_notes.push("Warm, with a limit: keep the warmth the photographer asked for, and keep faces from turning orange (moderate warm shifts, check skin under the actual light).");
  if (bodies.length) review_notes.push(`The brief names ${bodies.join(", ")}. Source groups are navigation, not compatibility; available simulations and controls differ by body, and this planner's capability contract is the requested camera.`);
  return { rendering: colorOnly ? "color" : monoOnly ? "monochrome" : priorities.includes("color_fidelity") && !monochromeOptions ? "color" : null,
    avoid_added_warmth: avoidWarmth, grain: noGrain ? "off" : noStrongGrain ? "not_strong" : null,
    clarity_zero: clarityZero, monochrome_options: monochromeOptions, priorities, scene_segments, conflicts,
    excluded_simulations: policy.avoidSimulations, infrared_requested: /\b(?:infrared|ir|full spectrum|aerochrome)\b/.test(value), review_notes };
}

/** Unknown values cannot satisfy an explicit setting constraint. Missing unrelated controls remain visible. */
export function recipeConstraintFailures(reference: RecipeReference, analysis: RecipeSettingsAnalysis, intent: ShootIntent): string[] {
  const failures: string[] = [];
  const traits = analysis.traits;
  const f = reference.source_facts.fields;
  const grain = reference.source_facts.native.grain_strength ?? f.grain?.split(" ")[0];
  if (intent.conflicts.length) failures.push("conflicting_rendering_requirements");
  if (intent.rendering === "color" && traits.rendering !== "color") failures.push("requires_known_color");
  if (intent.rendering === "monochrome" && traits.rendering !== "monochrome") failures.push("requires_known_monochrome");
  if (intent.grain === "off" && grain !== "Off") failures.push("requires_known_grain_off");
  if (intent.grain === "not_strong" && !["Off", "Weak"].includes(grain ?? "")) failures.push("excludes_strong_or_unknown_grain");
  if (intent.clarity_zero && f.clarity !== 0) failures.push("requires_known_zero_clarity");
  // This excludes added artistic warmth; even an unshifted Auto WB does not promise orange-free skin. The analysis
  // trait also catches warm Kelvin settings and Ambience priority, which keep or add a warm cast without shifts.
  if (intent.avoid_added_warmth && traits.rendering !== "monochrome" && (traits.rendering !== "color" || f.film_sim === "Nostalgic Neg" || f.wb_shift_r === undefined || f.wb_shift_b === undefined || f.wb_shift_r > 0 || f.wb_shift_b < 0
    || traits.warm_cast_risk === "elevated" || traits.warm_cast_risk === "possible")) failures.push("excludes_added_or_unknown_warmth");
  if ((intent.excluded_simulations ?? []).length && (!f.film_sim || intent.excluded_simulations.includes(f.film_sim))) failures.push("excludes_requested_or_unknown_simulation");
  if (!intent.infrared_requested && reference.source_groups.includes("Full Spectrum IR")) failures.push("requires_infrared_converted_camera");
  return failures;
}

export function matchRecipeToShoot(reference: RecipeReference, analysis: RecipeSettingsAnalysis, desk: RecipeDeskAnalysis | null, intent: ShootIntent) {
  const traits = analysis.traits;
  const f = reference.source_facts.fields;
  let score = 0;
  const reasons: string[] = [];
  const covered: ShootPriority[] = [];
  const add = (priority: ShootPriority, condition: boolean, points: number, reason: string) => {
    if (intent.priorities.includes(priority) && condition) { score += points; covered.push(priority); reasons.push(reason); }
  };
  add("portrait", ["Pro Neg Std", "Pro Neg Hi", "Astia", "Reala Ace", "Provia"].includes(f.film_sim ?? "") && !intent.priorities.includes("warm_color") && traits.warm_cast_risk === "not_indicated" && traits.color_intensity !== "vivid" && traits.contrast !== "hard", 4, "Portrait-oriented or balanced color base without identified added-warmth indicators; inspect actual skin.");
  add("color_fidelity", ["Provia", "Reala Ace", "Pro Neg Std", "Astia"].includes(f.film_sim ?? "") && (f.color ?? 99) <= 1 && (f.color ?? -99) >= -1 && traits.warm_cast_risk === "not_indicated", 8, "Relatively restrained settings offer a color-fidelity comparison; accuracy is unmeasured.");
  add("mixed_light", traits.rendering === "color" && traits.wb_mode === "adaptive", 6, "Auto-family white balance can respond to changed illumination; mixed-light casts remain possible.");
  add("highlight_detail", ["DR200", "DR400"].includes(f.dynamic_range ?? "") && (f.highlight ?? 99) <= 0, 5, "Higher DR and non-hardened highlight rendering provide a starting point; ISO floors and exposure still matter.");
  add("low_light", traits.rendering === "color" && (traits.wb_mode === "adaptive" || f.white_balance === "Incandescent"), 3, "White-balance mode is a candidate for changing or tungsten light; no measured color-temperature match.");
  add("graphic_shape", traits.rendering === "monochrome" && traits.contrast === "hard", 9, "Harder monochrome tones support a deliberate graphic comparison; silhouette shape and exposure depend on capture.");
  add("action", f.clarity === 0, 5, "Zero Clarity avoids that setting's extra processing delay; shutter speed still controls motion blur.");
  add("vivid_color", traits.rendering === "color" && traits.color_intensity === "vivid", 5, "Known settings support an intentionally vivid color comparison.");
  add("restrained_color", traits.rendering === "color" && traits.color_intensity === "restrained", 5, "Known settings support a restrained color comparison.");
  add("warm_color", traits.rendering === "color" && ["elevated", "possible"].includes(traits.warm_cast_risk), 8, "Published settings include warmth indicators for comparison; the actual cast and skin response remain unmeasured.");
  add("monochrome_option", traits.rendering === "monochrome", 3, "Provides the requested monochrome alternative; choose a filter by subject hues and intent.");
  add("soft_tones", traits.contrast === "soft" || traits.highlight_rendering === "softened", 4, "Softened tone settings offer gentler rendering; do not recover clipped capture data.");
  add("gritty_texture", traits.texture === "strong", 4, "Strong grain supplies requested visible texture, distinct from capture noise.");
  if (intent.infrared_requested && reference.source_groups.includes("Full Spectrum IR")) { score += 10; reasons.push("Published for a full-spectrum infrared-converted camera; an unmodified camera cannot reproduce this rendering."); }
  if (desk) {
    // Negative author guidance is a penalty, never positive evidence because a word happened to match.
    const avoid = desk.avoid_tags.join(" ").toLowerCase();
    if (intent.priorities.includes("color_fidelity") && /color|colour|product|skin/.test(avoid)) { score -= 5; reasons.push("Desk analysis cautions against faithful-color use."); }
    if (intent.priorities.includes("action") && /action|burst|speed/.test(avoid)) { score -= 3; reasons.push("Desk analysis notes a speed tradeoff."); }
  }
  if (reference.source_facts.published_core.complete) score += 2;
  if (desk) score += 0.5;
  if (/^\[unnamed/i.test(reference.title)) score -= 3;
  if (reference.source_record_status === "ambiguous") score -= 12;
  if (analysis.status === "insufficient_facts") score -= 10;
  if (traits.rendering === "unknown") score -= 5;
  return { score, reasons, covered: [...new Set(covered)] };
}
