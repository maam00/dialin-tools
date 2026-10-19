// Conservative intent inference and bounded factual checks. No model, camera, network or settings mutation.
import { RECIPE_KEYS, type Exposure, type RecipeDesign, type RecipeFields } from "./types.js";

export const PHOTOGRAPHIC_POLICY_VERSION = "x100vi-intent-2026-10-15.4";
export type RenderingMode = "color" | "monochrome" | "either";
export type ConstraintScope = "primary" | "palette";
export type PhotographicConstraint = {
  kind: "color_only" | "monochrome_only" | "avoid_warm_cast" | "preserve_warmth" | "avoid_simulation";
  scope: ConstraintScope;
  source: "said" | "taste";
  evidence: string;
  /** Only for avoid_simulation: canonical film simulation names the photographer excluded. */
  simulations?: string[];
};
export type PhotographicPolicy = {
  version: string;
  primaryMode: RenderingMode;
  paletteMode: RenderingMode;
  avoidWarmCast: boolean;
  preserveWarmth: boolean;
  /** Film simulations the photographer explicitly excluded ("no Classic Chrome", "anything but Velvia"). */
  avoidSimulations: string[];
  constraints: PhotographicConstraint[];
  requiresReview: boolean;
  uncertainties: string[];
};

const monoNames = new Set(["Acros", "Acros+Ye", "Acros+R", "Acros+G", "Monochrome", "Monochrome+Ye", "Monochrome+R", "Monochrome+G", "Sepia"]);
export const isMonochromeRecipe = (recipe: Pick<RecipeFields, "film_sim">): boolean => monoNames.has(recipe.film_sim);
const mono = "(?:monochrome|b\\s*&\\s*w|black[ -]+and[ -]+white|black[ -]+white|b/w)";
const color = "colou?r";
const normalized = (value: string) => value.replace(/[’‘]/g, "'").replace(/[–—]/g, "-").replace(/\s+/g, " ").trim();

// Closed vocabulary of camera simulation names. "Monochrome" is a rendering word and stays with color/mono rules.
const SIMULATION_NAMES: readonly (readonly [string, string])[] = [
  ["Classic Chrome", "classic[ -]+chrome"], ["Reala Ace", "reala[ -]+ace"], ["Pro Neg Hi", "pro[ -]*neg\\.?[ -]+hi(?:gh)?"],
  ["Pro Neg Std", "pro[ -]*neg\\.?[ -]+(?:std|standard)"], ["Classic Neg", "classic[ -]+neg(?:ative)?\\.?"],
  ["Nostalgic Neg", "nostalgic[ -]+neg(?:ative)?\\.?"], ["Eterna Bleach Bypass", "(?:eterna[ -]+)?bleach[ -]+bypass"],
  ["Eterna", "eterna(?![ -]+bleach)"], ["Provia", "provia"], ["Velvia", "velvia"], ["Astia", "astia"], ["Sepia", "sepia"],
  ["Acros+Ye", "acros ?\\+ ?ye(?:llow)?"], ["Acros+R", "acros ?\\+ ?r(?:ed)?"], ["Acros+G", "acros ?\\+ ?g(?:reen)?"],
  ["Acros", "acros(?! ?\\+)"],
];
const simulationName = SIMULATION_NAMES.map(([, pattern]) => pattern).join("|");
const simulationList = `(?:${simulationName})(?:\\s*(?:,|/|\\bor\\b|\\band\\b|\\bnor\\b)\\s*(?:the\\s+|any\\s+)?(?:${simulationName}))*`;
// "except"/"other than" alone are ambiguous ("natural color except Velvia for landscapes" includes Velvia) and stay unparsed.
const avoidPrefix = "\\b(?:no|not|never|without|avoid(?:ing)?|exclud(?:e|ing)|skip|ban|nothing (?:with|in|using|on)|any(?:thing)? (?:but|except|other than)|everything (?:but|except)|instead of|rather than|(?:do not|don't|dont|never) (?:use|want|give me|include|shoot)|hate|dislike|sick of|tired of|done with|no more)";
const avoidSimulationPattern = new RegExp(`${avoidPrefix}\\s+(?:(?:the|any|a|more|of|in|with|using)\\s+){0,2}(${simulationList})\\b|\\b(${simulationList})\\s+(?:is|are)\\s+(?:banned|off[ -]limits|out|not allowed)\\b`, "gi");
/** Canonical simulation names in a phrase. Specific names are consumed first, so "Eterna Bleach Bypass" is not also "Eterna". */
export function simulationsNamedIn(value: string): string[] {
  const names: string[] = [];
  let rest = ` ${normalized(value).toLowerCase()} `;
  for (const [name, pattern] of SIMULATION_NAMES) {
    const expression = new RegExp(`(?<![a-z])(?:${pattern})(?![a-z])`, "gi");
    if (expression.test(rest)) {
      names.push(name);
      rest = rest.replace(expression, " ");
    }
  }
  // A bare "Acros" exclusion covers the whole ACROS family; filtered variants stay individually named.
  return names.includes("Acros") ? [...new Set([...names, "Acros+Ye", "Acros+R", "Acros+G"])] : names;
}
/** Bounded English exclusion of named simulations. Positive mentions and negated bans ("don't avoid Velvia") are not exclusions. */
export function avoidedSimulations(value: string): { simulations: string[]; evidence: string[] } {
  const simulations = new Set<string>();
  const evidence: string[] = [];
  for (const clause of normalized(value).split(/[.;!?\n]/).filter(Boolean)) {
    for (const match of clause.matchAll(avoidSimulationPattern)) {
      const before = clause.slice(Math.max(0, match.index! - 30), match.index!);
      if (/\b(?:don't|do not|not|never|not saying|don't mean)\s*$/i.test(before) && /^(?:avoid|exclud|skip|ban|no\b)/i.test(match[0])) continue;
      const named = simulationsNamedIn(match[1] ?? match[2] ?? "");
      if (!named.length) continue;
      named.forEach((name) => simulations.add(name));
      evidence.push(clause.trim().slice(0, 240));
    }
  }
  return { simulations: [...simulations], evidence: [...new Set(evidence)] };
}
/** The same text with recognized simulation exclusions removed, so a banned name never counts as a positive match. */
export function stripAvoidedSimulations(value: string): string {
  return normalized(value).split(/([.;!?\n])/).map((clause) => clause.replace(avoidSimulationPattern, (match, _list, _suffix, offset: number) =>
    /\b(?:don't|do not|not|never)\s*$/i.test(clause.slice(Math.max(0, offset - 30), offset)) && /^(?:avoid|exclud|skip|ban|no\b)/i.test(match) ? match : " ")).join("");
}

type Rule = { kind: PhotographicConstraint["kind"]; scope: ConstraintScope; pattern: RegExp };
/** "warm but not orange", "warmth, but not too yellow", "warm without going amber". */
export const WARM_BUT_NOT = /\bwarm(?:th|er)?\b[^.;!?]{0,25}?\b(?:but|yet|though)\s+not\s+(?:too\s+|overly\s+|so\s+)?(?:orange|amber|yellow)\b|\bwarm(?:th|er)?\b[^.;!?]{0,25}?\bwithout\s+(?:going|turning|getting|looking)\s+(?:orange|amber|yellow)\b/i;
const rules: readonly Rule[] = [
  { kind: "color_only", scope: "palette", pattern: new RegExp(`\\b(?:all(?:\\s+seven)?(?:\\s+(?:looks|slots|recipes|options))?(?:\\s+(?:in|must be|should be|need to be))?\\s+${color}|${color}[ -]+only|only\\s+${color}(?:\\s+(?:looks|slots|recipes|options))?)\\b`, "i") },
  { kind: "color_only", scope: "palette", pattern: new RegExp(`\\b(?:no|without|avoid|exclude)\\s+(?:any\\s+)?${mono}\\b|\\b(?:don't|do not|never)\\s+(?:want|include|use|offer|give me)\\s+(?:any\\s+)?${mono}\\b`, "i") },
  { kind: "color_only", scope: "palette", pattern: /\b(?:all|every|each)(?:\s+seven)?\s+(?:looks?|slots?|recipes?|options?)\s+(?:(?:must|should|need to)\s+)?(?:be|stay|remain|use|keep|retain|preserve)(?:\s+in)?\s+colou?r\b/i },
  { kind: "monochrome_only", scope: "palette", pattern: new RegExp(`\\b(?:all(?:\\s+seven)?(?:\\s+(?:looks|slots|recipes|options))?(?:\\s+(?:in|must be|should be|need to be))?\\s+${mono}|${mono}[ -]+only|only\\s+${mono}(?:\\s+(?:looks|slots|recipes|options))?)\\b`, "i") },
  { kind: "monochrome_only", scope: "palette", pattern: new RegExp(`\\b(?:no|without|exclude)\\s+(?:any\\s+)?${color}\\s+(?:looks?|recipes?|options?)\\b`, "i") },
  { kind: "monochrome_only", scope: "palette", pattern: new RegExp(`\\b${mono}\\s+(?:looks?|recipes?|options?)\\s+only\\b`, "i") },
  { kind: "color_only", scope: "palette", pattern: /\bcolou?r\s+(?:looks?|recipes?|options?)\s+only\b/i },
  { kind: "color_only", scope: "primary", pattern: new RegExp(`\\b(?:main|primary|default)\\s+(?:look|recipe|option)(?:\\s+\\w+){0,3}\\s+${color}\\b|\\b${color}\\s+(?:main|primary|default)\\b`, "i") },
  { kind: "monochrome_only", scope: "primary", pattern: new RegExp(`\\b(?:main|primary|default)\\s+(?:look|recipe|option)(?:\\s+\\w+){0,3}\\s+${mono}\\b|\\b${mono}\\s+(?:main|primary|default)\\b`, "i") },
  { kind: "monochrome_only", scope: "primary", pattern: new RegExp(`\\b(?:want|make|shoot|create|prefer)\\s+(?:(?:a|the|this|my)\\s+)?${mono}\\b`, "i") },
  { kind: "color_only", scope: "primary", pattern: /\b(?:keep|retain|preserve|protect|show)(?:\s+[\w'-]+){0,6}\s+(?:colou?r|hues?)\b|\b(?:colou?r|hue)\s+(?:accuracy|fidelity|matters?|is important|must remain)\b|\b(?:natural|believable|faithful|warm|nostalgic|muted|vivid)(?:\s+editorial)?\s+colou?r\b|\bkeep(?:\s+[\w'-]+){0,6}\s+(?:red|blue|green|yellow|orange)(?:\s+[\w'-]+){0,3}\s+distinct\b/i },
  { kind: "avoid_warm_cast", scope: "palette", pattern: /\b(?:no|avoid|without|don't want|do not want)\s+(?:(?:an?|any)\s+)?(?:(?:orange|amber|yellow|warm|nostalgic|vintage)(?:\s*(?:,|\/|\band\b|\bor\b)\s*|\s+)){1,6}(?:casts?|tints?|faces?|skin(?:\s*tones?)?)\b/i },
  // Subject-first phrasing: "skin must never look orange", "faces shouldn't turn yellow", "keep faces neutral, not amber".
  { kind: "avoid_warm_cast", scope: "palette", pattern: /\b(?:skin(?:\s*tones?)?|faces?|complexions?)\b[^.;!?]{0,30}?\b(?:never|not|shouldn't|should not|mustn't|must not|can't|cannot|won't|will not)\s+(?:(?:be|look|turn|go|appear|become|get|too|at all)\s+){0,3}(?:orange|yellow|amber|warmer|warm)\b/i },
  { kind: "preserve_warmth", scope: "primary", pattern: /\b(?:keep|retain|preserve|want|prefer|like|enjoy)(?:\s+[\w'-]+){0,4}\s+(?:warmth|amber|nostalgic warmth|warm nostalgic|warm nostalgic colou?r|warm colou?r)\b/i },
  // "warm but not orange": the warmth is wanted; the "not" limits how far it goes. It is not a request to remove warmth.
  { kind: "preserve_warmth", scope: "primary", pattern: WARM_BUT_NOT },
];

function extract(value: string, source: PhotographicConstraint["source"]): { constraints: PhotographicConstraint[]; ambiguities: string[] } {
  const constraints: PhotographicConstraint[] = [];
  const ambiguities: string[] = [];
  // Clause limits prevent an unrelated mention of a main look from downgrading a whole-palette instruction.
  for (const clause of normalized(value).split(/[.;!?\n]/).filter(Boolean)) {
    for (const rule of rules) {
      const match = rule.pattern.exec(clause);
      if (!match) continue;
      const before = clause.slice(Math.max(0, match.index - 45), match.index);
      if (/\b(?:not saying|don't mean|do not mean|used to say|previously asked for|someone said|ignore the words|not necessarily)\b/i.test(before)
          || /\b(?:don't|do not)\s*$/i.test(before) && /^(?:avoid|exclude)/i.test(match[0])
          || /\bnot\s*$/i.test(before) && /^only/i.test(match[0])) continue;
      if (rule.scope === "primary" && /^\s+(?:alternate|alternative|backup)\b/i.test(clause.slice(match.index + match[0].length))) continue;
      let scope = rule.scope;
      if ((rule.kind === "color_only" || rule.kind === "monochrome_only")
          && /\b(?:for|in)\s+(?:the |my )?(?:main|primary|default)(?:\s+look)?\b/i.test(clause)) scope = "primary";
      if (/\b(?:except|unless|but allow|although allow|but (?:give|include|add|make|keep|also|one|a single))\b/i.test(clause) && rule.scope === "palette") {
        ambiguities.push("An explicit palette restriction has an exception; review its scope instead of assuming permission.");
      }
      constraints.push({ kind: rule.kind, scope, source, evidence: clause.trim().slice(0, 240) });
    }
  }
  const avoided = avoidedSimulations(value);
  if (avoided.simulations.length) constraints.push({ kind: "avoid_simulation", scope: "palette", source, evidence: avoided.evidence.join(" / ").slice(0, 240), simulations: avoided.simulations });
  return { constraints, ambiguities };
}

/** Only direct English instructions earn hard constraints. Generic genre/time/color mentions do not. */
export function inferPhotographicPolicy(input: { said: string; tasteNotes?: string | null }): PhotographicPolicy {
  const current = extract(input.said, "said");
  const taste = extract(input.tasteNotes ?? "", "taste");
  const category = (c: PhotographicConstraint) => c.kind === "color_only" || c.kind === "monochrome_only" ? "mode" : c.kind === "avoid_simulation" ? "simulation" : "cast";
  const currentCategories = new Set(current.constraints.map(category));
  // Current intent wins over persistent taste within the same dimension. A preference cannot veto today's request.
  const selected = [...current.constraints, ...taste.constraints.filter((c) => !currentCategories.has(category(c)))];
  const constraints = selected.filter((c, i) => selected.findIndex((s) => s.kind === c.kind && s.scope === c.scope && s.source === c.source) === i);
  const uncertainties = [...current.ambiguities, ...taste.ambiguities];
  const modeFor = (scope: ConstraintScope): RenderingMode => {
    const relevant = constraints.filter((c) => (c.scope === scope || scope === "primary" && c.scope === "palette") && category(c) === "mode");
    const modes = new Set(relevant.map((c) => c.kind === "color_only" ? "color" : "monochrome"));
    if (modes.size > 1) {
      uncertainties.push(`Conflicting ${scope} color/monochrome instructions need review; neither instruction is silently discarded.`);
      return "either";
    }
    return [...modes][0] as RenderingMode | undefined ?? "either";
  };
  const paletteMode = modeFor("palette");
  const primaryMode = modeFor("primary");
  const avoidWarmCast = constraints.some((c) => c.kind === "avoid_warm_cast");
  const preserveWarmth = constraints.some((c) => c.kind === "preserve_warmth");
  if (avoidWarmCast && preserveWarmth) uncertainties.push("Requested warmth and avoided cast coexist; prioritize the subject and explain the compromise.");
  const avoidSimulations = [...new Set(constraints.flatMap((c) => c.kind === "avoid_simulation" ? c.simulations ?? [] : []))];
  return { version: PHOTOGRAPHIC_POLICY_VERSION, primaryMode, paletteMode, avoidWarmCast, preserveWarmth, avoidSimulations,
    constraints, requiresReview: uncertainties.length > 0, uncertainties: [...new Set(uncertainties)] };
}

export type PolicyIssue = {
  code: "color_intent" | "monochrome_intent" | "warm_cast_intent" | "simulation_intent";
  message: string;
  scope: ConstraintScope;
  severity: "conflict" | "preserved_conflict";
};

/** A kept conflicting recipe stays kept; this reports the mismatch rather than authorizing a replacement. */
export function assessPolicyLook(input: {
  look: Pick<RecipeFields, "film_sim"> & Partial<Pick<RecipeFields, "wb_shift_r" | "wb_shift_b">> & { status?: string; recipe_known?: boolean };
  policy: PhotographicPolicy;
  isPrimary: boolean;
}): PolicyIssue[] {
  if (input.look.recipe_known === false) return [];
  const expected = isMonochromeRecipe(input.look) ? "monochrome_only" : "color_only";
  const opposite = expected === "monochrome_only" ? "color_only" : "monochrome_only";
  const matches = input.policy.constraints.filter((c) => c.kind === opposite && (c.scope === "palette" || input.isPrimary));
  const issues: PolicyIssue[] = [];
  const scope: ConstraintScope = matches.some((c) => c.scope === "palette") ? "palette" : "primary";
  if (matches.length) issues.push({ code: opposite === "color_only" ? "color_intent" : "monochrome_intent", scope,
    severity: input.look.status === "kept" ? "preserved_conflict" : "conflict",
    message: opposite === "color_only" ? `This ${scope} requires color; a monochrome rendering loses that information.`
      : `This ${scope} requires monochrome; a color rendering contradicts that instruction.` });
  // A conservative design-conflict check, not a measured orange-cast detector. Kelvin alone,
  // small corrective shifts and inactive monochrome color controls do not justify rejection.
  const stronglyWarmShifted = (input.look.wb_shift_r ?? 0) >= 3 && (input.look.wb_shift_b ?? 0) <= -3;
  if (input.policy.avoidWarmCast && !isMonochromeRecipe(input.look)
      && (input.look.film_sim === "Nostalgic Neg" || stronglyWarmShifted)) issues.push({
    code: "warm_cast_intent", scope: "palette", severity: input.look.status === "kept" ? "preserved_conflict" : "conflict",
    message: "The requested avoidance of warm casts conflicts with this amber simulation or strongly warm-shifted design. Revise it or explicitly resolve the tradeoff; this check does not measure the scene's actual cast.",
  });
  // Applies to the final written simulation, so an automatic stand-in for an unmapped simulation is checked too.
  if ((input.policy.avoidSimulations ?? []).includes(input.look.film_sim)) issues.push({
    code: "simulation_intent", scope: "palette", severity: input.look.status === "kept" ? "preserved_conflict" : "conflict",
    message: `The photographer asked to avoid ${input.look.film_sim}; this look uses it. Choose another simulation (an automatic stand-in for an unmapped simulation can also produce it).`,
  });
  return issues;
}

export const EFFECTIVE_RECIPE_SIGNATURE_SCOPE = "supported_recipe_fields_not_complete_native_state";
/** Canonical supported payload fields. Equal fingerprints do not establish equal native tint or saved bank state. */
export function effectiveRecipeFields(recipe: RecipeFields): Omit<RecipeFields, "name" | "why"> {
  const fields = Object.fromEntries(RECIPE_KEYS.filter((key) => key !== "name" && key !== "why").map((key) => [key, recipe[key]])) as Omit<RecipeFields, "name" | "why">;
  if (fields.white_balance !== "Kelvin") fields.kelvin = 0;
  if (isMonochromeRecipe(recipe)) {
    fields.color = 0;
    fields.color_chrome = "Off";
    fields.color_chrome_fx_blue = "Off";
    fields.wb_shift_r = 0;
    fields.wb_shift_b = 0;
  }
  return fields;
}

export function effectiveRecipeSignature(recipe: RecipeFields): string {
  return JSON.stringify(Object.entries(effectiveRecipeFields(recipe)));
}

export type FactualRationaleIssue = { code: string; path: string; claim: string; message: string; knowledge_ids: string[] };
export type FactualRationaleInput = {
  recipe: RecipeFields;
  design?: RecipeDesign;
  reason?: string;
  exposure?: Exposure;
  cameraModel?: string;
};
function textFields(input: FactualRationaleInput): [string, string][] {
  const fields: [string, string][] = [["why", input.recipe.why], ["reason", input.reason ?? ""]];
  if (input.design) {
    for (const key of ["purpose", "scene_fit", "tradeoff", "alternative", "uncertainty"] as const) fields.push([`design.${key}`, input.design[key]]);
    input.design.choices.forEach((choice, i) => fields.push([`design.choices.${i}.reason`, choice.reason]));
  }
  return fields;
}
const denied = (claim: string) => /\b(?:cannot|can't|does not|doesn't|do not|don't|will not|won't|is not|isn't|are not|aren't|never|not guaranteed|no guarantee|not necessarily)\b/i.test(claim);

function unsupportedWbCertainty(claim: string): boolean {
  // Check unqualified outcome promises, not an intention to reduce a cast or avoid adding one.
  if (/\b(?:aims?|intends?|intended|tries?|trying|helps?|may|might|reduces?|lessens?|limits?)\b/i.test(claim)) return false;
  if (!/\b(?:auto(?:\s+WB)?|WB|white balance|daylight|kelvin|shifts?)\b/i.test(claim)) return false;
  return /\b(?:avoids?|prevents?|removes?|eliminates?)\s+(?:any|all|every)\s+(?:[\w-]+\s+){0,4}(?:cast|tint|orange|green|yellow)\b/i.test(claim)
    || /\b(?:keeps?|makes?|leaves?)\b.{0,55}\b(?:cast[ -]free|free of (?:any |all )?(?:orange|green|yellow|a cast|casts))\b/i.test(claim)
    || /\b(?:keeps?|makes?|leaves?)\b.{0,55}\bwithout\s+(?:orange|green|yellow)\s+(?:skin|faces?)\b/i.test(claim)
    || /\bkeeps?\b.{0,55}\bfrom (?:going|turning|becoming)\s+(?:orange|green|yellow)\b/i.test(claim);
}

const num = (value: string) => Number(value.replace("−", "-").replace(/^\+/, ""));
// A value named as the source's, the old value or a rejected option describes something else ("from source Shadow+2",
// "does not justify DR400", "reduce strong grain"); only assertive mentions are compared.
const contrastBefore = /\b(?:source(?:'s)?|from|than|instead of|rather than|not|unlike|replac\w*|reduc\w*|lower\w*|rais\w*|lift\w*|without|justif\w*|published|original|creator(?:'s)?|was|previous\w*|vs\.?|versus|or|over)\b[^,;:]{0,14}$/i;
const assertive = (text: string, index: number) => !contrastBefore.test(text.slice(Math.max(0, index - 32), index));
const stated = (text: string, pattern: RegExp, value: (match: RegExpMatchArray) => string | number) =>
  [...text.matchAll(pattern)].filter((match) => assertive(text, match.index!)).map(value);
/** Explicit values a design reason states for its own setting group, compared with the final look. Any matching mention
 *  passes, and contrasted mentions are ignored. Silent reasons are never inferred; this is a bounded consistency check. */
function statedSettingMismatches(setting: string, reason: string, recipe: RecipeFields): string[] {
  const text = normalized(reason);
  const out: string[] = [];
  const check = (label: string, values: (string | number)[], actual: string | number) => {
    if (values.length && !values.some((value) => value === actual)) out.push(`${label} ${[...new Set(values)].join("/")} (final ${actual})`);
  };
  if (setting === "film_sim") check("simulation", simulationsNamedIn(text), recipe.film_sim);
  if (setting === "color" && !isMonochromeRecipe(recipe)) check("Color", stated(text, /\bcolou?r(?!\s*chrome)\s*(?:[:=]\s*)?([+\-−]?\d)(?![\d.])/gi, (m) => num(m[1])), recipe.color);
  if (setting === "tone_curve") {
    check("Highlight", stated(text, /\bhighlights?\s*(?:[:=]\s*)?([+\-−]?\d(?:\.5)?)(?![\d.])/gi, (m) => num(m[1])), recipe.highlight);
    check("Shadow", stated(text, /\bshadows?\s*(?:[:=]\s*)?([+\-−]?\d(?:\.5)?)(?![\d.])/gi, (m) => num(m[1])), recipe.shadow);
  }
  if (setting === "dynamic_range") check("dynamic range", stated(text, /\bDR\s?(100|200|400)\b/gi, (m) => `DR${m[1]}`), recipe.dynamic_range);
  if (setting === "white_balance") {
    const modes = stated(text, /\b(auto|daylight|kelvin|shade|incandescent|fluorescent)\s+(?:wb|white balance)\b/gi, (m) => m[1].toLowerCase()) as string[];
    if (modes.length && !modes.some((mode) => recipe.white_balance.toLowerCase().startsWith(mode))) out.push(`WB ${[...new Set(modes)].join("/")} (final ${recipe.white_balance})`);
    if (recipe.white_balance === "Kelvin") check("Kelvin", stated(text, /\bkelvin\s*(\d{4,5})\b|\b(\d{4,5})\s?K\b/gi, (m) => Number(m[1] ?? m[2])), recipe.kelvin);
    check("WB shift R", stated(text, /\bR\s?([+\-−]\d)\b/g, (m) => num(m[1])), recipe.wb_shift_r);
    check("WB shift B", stated(text, /\bB\s?([+\-−]\d)\b/g, (m) => num(m[1])), recipe.wb_shift_b);
  }
  if (setting === "texture") {
    check("Clarity", [...stated(text, /\bclarity\s*(?:[:=]\s*)?([+\-−]?\d)(?![\d.])/gi, (m) => num(m[1])), ...stated(text, /\b(?:zero|no)\s+clarity\b/gi, () => 0)], recipe.clarity);
    check("Sharpness", stated(text, /\bsharpness\s*(?:[:=]\s*)?([+\-−]?\d)(?![\d.])/gi, (m) => num(m[1])), recipe.sharpness);
    check("grain", stated(text, /\b(no|weak|strong)(?:\s+(?:small|large))?\s+grain\b|\bgrain\s+(off)\b/gi, (m) => {
      const word = (m[1] ?? m[2]).toLowerCase();
      return word === "weak" ? "Weak" : word === "strong" ? "Strong" : "Off";
    }), recipe.grain.split(" ")[0]);
  }
  return out;
}

/** Finds specific unsupported fact claims. It is deliberately not a semantic taste scorer or exhaustive proof. */
export function validateFactualRationale(input: FactualRationaleInput): FactualRationaleIssue[] {
  const issues: FactualRationaleIssue[] = [];
  const add = (code: string, path: string, claim: string, message: string, knowledge_ids: string[]) => {
    if (!issues.some((i) => i.code === code && i.path === path)) issues.push({ code, path, claim, message, knowledge_ids });
  };
  input.design?.choices.forEach((choice, i) => {
    const mismatches = statedSettingMismatches(choice.setting, choice.reason ?? "", input.recipe);
    if (mismatches.length) add("stated_setting_mismatch", `design.choices.${i}.reason`, choice.reason,
      `This reason states ${mismatches.join("; ")}. The explanation no longer describes the final settings (an automatic change or an inconsistent answer).`, ["recipe-provenance"]);
  });
  for (const [path, value] of textFields(input)) {
    // Sentence/clause checks reduce false positives when the next sentence explicitly denies a claim.
    for (const raw of normalized(value).split(/[.;!?]/)) {
      const claim = raw.trim();
      if (!claim || denied(claim)) continue;
      if (unsupportedWbCertainty(claim)) add("wb_cast_certainty", path, claim,
        "A WB mode or shift can alter or reduce a cast, but cannot promise cast-free or orange-free output under unverified illumination.", ["wb-source", "wb-mixed"]);
      if (/(?:acros\s*\+?\s*r\b|red\s+(?:colou?r[ -]?)?filter)\s+(?:(?:gives|adds|creates)\s+[^,]{0,35}\s+but\s+)?(?:also\s+|generally\s+|will\s+|can\s+)?darken\w*\s+(?:the\s+)?reds?\b/i.test(claim)) {
        add("red_filter_direction", path, claim, "Red filtering lightens red relative to blue; do not explain it as darkening red.", ["monochrome-filters"]);
      }
      if (/(?:acros\s*\+?\s*r\b|red\s+(?:colou?r[ -]?)?filter)\s+(?:also\s+|generally\s+|will\s+|can\s+)?lighten\w*\s+(?:the\s+)?blues?\b/i.test(claim)) {
        add("red_filter_blue_direction", path, claim, "Red filtering darkens blue relative to red; do not explain it as lightening blue.", ["monochrome-filters"]);
      }
      if ((input.cameraModel ?? "X100VI") === "X100VI") {
        const dr = /\bDR\s*(200|400)\b[^,]{0,22}\b(?:needs?|requires?|works? at|starts? at|available at|minimum(?: ISO)?(?: is| of)?)\s+(?:ISO\s*)?(\d{2,5})\b/i.exec(claim);
        if (dr && Number(dr[2]) < (dr[1] === "400" ? 500 : 250)) add("dr_iso_floor", path, claim, `X100VI DR${dr[1]} needs ISO${dr[1] === "400" ? 500 : 250}+; this stated floor is too low.`, ["dr-iso"]);
        if (/\b(?:auto\s*(?:DR|dynamic range)|(?:DR|dynamic range)\s*auto)\b[^,]{0,25}\b(?:selects?|chooses?|uses?|includes?|supports?)\s+DR\s*400\b/i.test(claim)) add("auto_dr_400", path, claim, "X100VI Auto DR chooses DR100/200, not DR400.", ["dr-iso"]);
      }
      if (/\bastia\b/i.test(claim) && /\b(?:all (?:its )?colou?rs?|uniformly|universally)\b/i.test(claim) && /\b(?:muted|desaturat\w*|subdued)\b/i.test(claim)) add("astia_color_generalization", path, claim, "ASTIA's gentler skin treatment can retain vivid blues/greens; uniform desaturation misstates the base.", ["sim-astia"]);
      const mixed = /\b(?:mixed(?:[ -]light| illumination| sources)?|fluorescent|LED|neon|tungsten)\b/i.test(claim);
      const absolute = /\b(?:guarantee\w*|completely|perfectly|fully|always|all|every)\b/i.test(claim);
      const correction = /\b(?:neutraliz\w*|correct\w*|remov\w*|eliminat\w*|neutral|accurate|believable)\b/i.test(claim);
      if (mixed && absolute && correction && /\b(?:cast|skin|faces?|white balance|WB|light)\b/i.test(claim)) add("mixed_light_guarantee", path, claim, "A global WB or unverified monochrome tint cannot guarantee neutral skin or removal of every mixed-light cast.", ["wb-mixed", "workflow-seven"]);
      if (/\b(?:highlights?|shadows?|tone curve|tones?)\b/i.test(claim) && /\b(?:recover\w*|restor\w*)\b/i.test(claim) && /\b(?:clipped|lost capture|sensor-clipped)\b/i.test(claim)) add("tone_recovers_capture", path, claim, "JPEG tone shaping cannot restore genuinely uncaptured or sensor-clipped detail.", ["tone-curve"]);
      if (/\bclarity\b/i.test(claim) && /\b(?:exactly|always|fixed)\b/i.test(claim) && /\b(?:one|1)[ -]second\b/i.test(claim)) add("clarity_fixed_delay", path, claim, "Nonzero Clarity slows saving; Fujifilm specifies no fixed one-second delay.", ["clarity-speed"]);
      if (/\b(?:IBIS|stabili[sz]ation)\b[^,]{0,25}\b(?:freezes?|stops?|eliminates?)\b[^,]{0,15}\b(?:subject motion|moving subjects?|subject movement)\b/i.test(claim)) add("stabilization_subject_motion", path, claim, "Stabilization assists camera shake, not motion of the subject.", ["exposure-render"]);
    }
  }
  return issues;
}

/** Clear affected prose fields and retain review flags; neither numeric settings nor valid prose is rewritten. */
export function sanitizeFactualRationale(input: FactualRationaleInput): {
  design?: RecipeDesign; reason?: string; why: string; issues: FactualRationaleIssue[];
} {
  const issues = validateFactualRationale(input);
  const out = { design: input.design ? structuredClone(input.design) : undefined, reason: input.reason, why: input.recipe.why, issues };
  for (const issue of issues) {
    if (issue.path === "why") out.why = "";
    else if (issue.path === "reason") out.reason = "";
    else if (out.design) {
      out.design.requires_review = true;
      const match = /^design\.choices\.(\d+)\.reason$/.exec(issue.path);
      if (match) out.design.choices[Number(match[1])].reason = "";
      else (out.design as unknown as Record<string, unknown>)[issue.path.slice("design.".length)] = "";
    }
  }
  if (issues.length && out.design) out.design.requires_review = true;
  return out;
}
