// Source declarations are model claims; comparisons below are computed from the final normalized settings.
import { createHash } from "node:crypto";
import { RECIPE_KEYS, type Plan, type RecipeFields } from "../../lib/plan/types.js";
import type { RecipeBook } from "../recipes/index.js";
import type { RecipeKnowledge } from "../recipes/knowledge.js";

export type SourceUse = {
  relationship: "original" | "inspired" | "adapted" | "exact";
  /** catalog/book: an exact stable ID. outside: a recipe named from elsewhere, recorded as stated and unverified. */
  references: { kind: "catalog" | "book" | "outside"; id: string }[];
  reason: string;
};
type Field = Exclude<keyof RecipeFields, "name" | "why">;
const fields = RECIPE_KEYS.filter((key): key is Field => key !== "name" && key !== "why");
const object = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value);
const digest = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const mono = (sim: unknown) => typeof sim === "string" && /^(?:Acros|Monochrome)(?:\+|$)|^Sepia$/.test(sim);
const clean = (value: string) => value.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const phrase = (text: string, name: string) => name && ` ${text} `.includes(` ${name} `);
// Published ISO/exposure values are shooting guidance set on the body's dials and menus. The slot writer never sets them,
// so they are disclosed per comparison but do not decide whether represented rendering settings match.
const GUIDANCE_NATIVE = new Set(["iso", "iso_auto_max", "iso_min", "iso_max", "exposure_compensation", "exposure_compensation_min", "exposure_compensation_max"]);
type ComparableSource = { kind: "catalog" | "book"; id: string; title: string; settings: Partial<RecipeFields>; inactive: Set<Field>; complete: boolean };
function comparableSource(kind: "catalog" | "book", id: string, title: string, settings: Partial<RecipeFields>, inactiveFields: readonly string[], complete: boolean): ComparableSource {
  const inactive = new Set<Field>(inactiveFields as Field[]);
  if (mono(settings.film_sim)) for (const field of ["color", "color_chrome", "color_chrome_fx_blue"] as const) inactive.add(field);
  if (settings.white_balance !== undefined && settings.white_balance !== "Kelvin") inactive.add("kelvin");
  return { kind, id, title, settings, inactive, complete };
}
const sameRepresented = (source: ComparableSource, look: Record<string, unknown>) =>
  source.complete && fields.every((key) => source.inactive.has(key) || (source.settings[key] !== undefined && source.settings[key] === look[key]));

/** Bounded intent receipts, not a general natural-language fidelity judge. Unnamed targets stay unresolved. */
function exactSourceRequests(intention: string, book: RecipeBook, knowledge: RecipeKnowledge) {
  const sources = [
    // An unnamed settings block is requested by its article title; every block of that article becomes a candidate.
    ...knowledge.references.map((reference) => ({ kind: "catalog" as const, id: reference.id, title: /^\[unnamed/i.test(reference.title) ? reference.article_title : reference.title })),
    ...book.recipes.map((recipe) => ({ kind: "book" as const, id: recipe.id, title: recipe.title })),
  ];
  const containsID = (text: string, id: string) => text.split(/[^a-zA-Z0-9_-]+/).includes(id);
  const sourceName = (text: string, source: typeof sources[number]) => {
    if (containsID(text, source.id)) return source.id;
    const name = clean(source.title);
    if (!name || name.startsWith("unnamed public settings block")) return null;
    const normalized = clean(text);
    const short = name.replace(/^(?:kodak|fujicolor|fujifilm|ilford) /, "");
    return phrase(normalized, name) ? name : short.split(" ").length >= 2 && phrase(normalized, short) ? short : null;
  };
  const sentences = intention.replace(/[’‘]/g, "'").split(/[.!?;\n]/);
  const scopes = sentences.filter((sentence) => {
    for (const match of sentence.matchAll(/\bexact(?:ly)?\b/gi)) {
      const position = match.index!;
      const prefix = sentence.slice(0, position);
      const localPrefix = prefix.slice(Math.max(prefix.lastIndexOf(",") + 1, prefix.length - 100));
      // Negation can contain a verb: "do not copy exactly", "no need for exact settings".
      if (/\b(?:not|never|no|don't|do not|without|avoid|isn't|aren't)\b[^,;.!?]{0,75}$/i.test(localPrefix)) continue;
      const after = sentence.slice(position + match[0].length);
      // Counts/timing are not a request for a source recipe's exact settings.
      if (/^\s+(?:[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\b/i.test(after)) continue;
      const scope = sentence.slice(Math.max(0, position - 150), position + match[0].length + 150);
      if (!/\b(?:recipe|recipes|settings|source|copy|copies|reproduce|replicate|unchanged|match|same|preset|presets)\b/i.test(scope) && !sources.some((source) => sourceName(scope, source))) continue;
      if (!/\b(?:use|want|need|give|copy|reproduce|replicate|match|keep|load|preserve|exact)\b/i.test(scope)) continue;
      return true;
    }
    return false;
  });
  const requested: { name: string; candidates: { kind: "catalog" | "book"; id: string }[] }[] = [];
  for (const scope of scopes) {
    const matches = sources.flatMap((source) => {
      // A common brand prefix may be omitted, as in "Quayside 320" for "Kodak Quayside 320".
      const matched = sourceName(scope, source);
      return matched ? [{ name: matched, ...source }] : [];
    });
    // Prefer an explicitly named variant over an overlapping shorter family title.
    const precise = matches.filter((match) => !matches.some((other) => other.name !== match.name && phrase(other.name, match.name)));
    if (!precise.length) requested.push({ name: "unresolved source in exact-settings request", candidates: [] });
    for (const match of precise) {
      let group = requested.find((request) => request.name === match.name);
      if (!group) { group = { name: match.name, candidates: [] }; requested.push(group); }
      if (!group.candidates.some((candidate) => candidate.kind === match.kind && candidate.id === match.id)) group.candidates.push({ kind: match.kind, id: match.id });
    }
  }
  return { requested: scopes.length > 0, sources: requested };
}

function explicitlyPermitsAdaptation(intention: string): boolean {
  return intention.replace(/[’‘]/g, "'").split(/[.!?;\n]/).some((sentence) => {
    const permission = /\b(?:you may|feel free to)\s+adapt\b|\badaptations?\s+(?:is|are)\s+(?:allowed|acceptable|okay|ok)\b|\b(?:prepare|provide|offer|propose|give(?: me)?)\s+(?:(?:a|an|one|safe|proposed|useful)\s+){0,5}(?:interpretation|adaptation|alternative)\b/gi;
    for (const match of sentence.matchAll(permission)) {
      const prefix = sentence.slice(0, match.index!);
      const localPrefix = prefix.slice(Math.max(prefix.lastIndexOf(",") + 1, prefix.length - 80));
      if (/\b(?:not|never|no|don't|do not|without|avoid)\b[^,;.!?]{0,75}$/i.test(localPrefix)) continue;
      if (/^(?:you may|feel free to|adaptations?)/i.test(match[0])) return true;
      // A request for a fallback is permission only when it explicitly addresses unsatisfied source fidelity.
      if (/\bexact\b[^.!?;]{0,100}\b(?:cannot|can't|not possible|unavailable|unsatisfied)\b/i.test(sentence)) return true;
    }
    return false;
  });
}

export const sourceUseSchema = {
  type: "object", additionalProperties: false, required: ["relationship", "references", "reason"],
  properties: {
    relationship: { type: "string", enum: ["original", "inspired", "adapted", "exact"], description: "Your declared use of sources; local validation computes the actual final setting differences." },
    references: { type: "array", maxItems: 3, items: { type: "object", additionalProperties: false, required: ["kind", "id"],
      properties: { kind: { type: "string", enum: ["catalog", "book", "outside"] }, id: { type: "string", description: "catalog/book: the exact reference ID from the installed private catalog or supplied book; never a guessed ID. outside: the name of a recipe from elsewhere that is in neither, as stated; it is recorded as an unverified inspiration and allowed only with relationship inspired." } } } },
    reason: { type: "string", description: "Why the source serves this role and which choices you adapted, or the original design intent. Maximum 800 characters." },
  },
};

function parseUse(value: unknown): SourceUse | null {
  if (!object(value) || Object.keys(value).some((key) => !["relationship", "references", "reason"].includes(key))
    || !["original", "inspired", "adapted", "exact"].includes(String(value.relationship))
    || typeof value.reason !== "string" || !value.reason.trim() || value.reason.length > 800
    || !Array.isArray(value.references) || value.references.length > 3) return null;
  const seen = new Set<string>();
  for (const item of value.references) {
    if (!object(item) || Object.keys(item).some((key) => !["kind", "id"].includes(key)) || !["catalog", "book", "outside"].includes(String(item.kind))
      || typeof item.id !== "string" || !item.id.trim() || item.id.length > 200 || seen.has(`${item.kind}:${item.id}`)) return null;
    seen.add(`${item.kind}:${item.id}`);
  }
  if (value.relationship === "original" ? value.references.length !== 0 : value.references.length === 0) return null;
  if (value.relationship === "exact" && value.references.length !== 1) return null;
  return structuredClone(value) as SourceUse;
}

type GrainComparison = { field: "grain_strength" | "grain_size"; source: string | number | boolean; proposed: string | null; represented_by: "grain" };
export type SourceComparison = {
  kind: "catalog" | "book" | "outside"; id: string; title: string; source_url: string | null; publisher: string | null; author: string | null;
  source_revision: string | null; source_status: string; published_core_complete: boolean;
  matched_fields: Field[]; changed_fields: { field: Field; source: unknown; proposed: unknown }[]; supplied_missing_fields: { field: Field; proposed: unknown }[];
  matched_native_fields: GrainComparison[]; changed_native_fields: GrainComparison[]; inactive_native_fields: string[];
  inactive_source_fields: Field[]; unrepresented_native_fields: string[]; unwritten_guidance_fields: { field: string; source: string | number | boolean }[];
  comparison: "matches_represented_settings" | "adapted_or_partial" | "not_compared_outside_reference";
  /** Present only for a stated outside inspiration, which nothing here can verify. */
  verification?: "unverified_stated_inspiration";
  native_and_photographic_equivalence_verified: false;
};
export function buildSourceTrace(plan: Plan, suppliedLooks: readonly unknown[], book: RecipeBook, knowledge: RecipeKnowledge, intention = "") {
  const issues: string[] = [];
  // Complete sources only: an "original" declaration that repeats one of these is an unattributed copy.
  const completeSources = [
    ...knowledge.references.filter((reference) => reference.source_record_status === "public_settings" && reference.source_facts.published_core.complete)
      .map((reference) => comparableSource("catalog", reference.id, reference.title, reference.source_facts.fields, reference.source_facts.inactive_fields, true)),
    ...book.recipes.map((entry) => comparableSource("book", entry.id, entry.title, entry.recipe, [], true)),
  ];
  const rows = plan.day_looks.map((look) => {
    const finalSettings = Object.fromEntries(fields.map((key) => [key, look[key]]));
    const base = { slot: look.slot, name: look.name, settings_sha256: digest(finalSettings) };
    if (look.status === "kept") return { ...base, status: "kept_camera_recipe" as const, declaration: null, comparisons: [] };
    // The engine reports the accepted draft after any repair/name normalization. Never match by array position.
    const candidates = suppliedLooks.filter((row) => object(row) && row.name === look.name);
    const use = candidates.length === 1 && object(candidates[0]) ? parseUse(candidates[0].source_use) : null;
    if (!use) {
      issues.push(`${look.name}: supply one valid source_use declaration with exact source IDs, or original with no references.`);
      return { ...base, status: "needs_revision" as const, declaration: null, comparisons: [] };
    }
    if (use.relationship === "original") {
      const copied = completeSources.find((source) => sameRepresented(source, look as unknown as Record<string, unknown>));
      if (copied) issues.push(`${look.name}: declared original, but its represented settings repeat ${copied.kind} source ${copied.id} ("${copied.title}"). Declare that source as exact or adapted instead.`);
    }
    const comparisons = use.references.flatMap((ref): SourceComparison[] => {
      if (ref.kind === "outside") {
        // A stated outside inspiration has no settings here: nothing is compared, hashed or verified.
        if (use.relationship !== "inspired") issues.push(`${look.name}: outside recipe "${ref.id}" has no settings available for comparison, so declare it inspired; adapted and exact need a catalog or book source.`);
        // "Outside" means in neither the catalog nor the book: a name or stable ID of either is cited by its kind, so its settings are compared.
        const known = knowledge.references.find((entry) => entry.id === ref.id || [entry.title, entry.article_title, entry.variant_name ?? ""].some((name) => !/^\[unnamed/i.test(name) && clean(name) === clean(ref.id)));
        const inBook = known ? null : book.recipes.find((entry) => entry.id === ref.id || (!!clean(entry.title) && clean(entry.title) === clean(ref.id)));
        if (known) issues.push(`${look.name}: "${ref.id}" is catalog source ${known.id}; cite it with kind catalog so its settings are compared.`);
        if (inBook) issues.push(`${look.name}: "${ref.id}" is book source ${inBook.id}; cite it with kind book so its settings are compared.`);
        return [{ kind: ref.kind, id: ref.id, title: ref.id, source_url: null, publisher: null, author: null, source_revision: null,
          source_status: "stated_outside_inspiration" as const, published_core_complete: false,
          matched_fields: [], changed_fields: [], supplied_missing_fields: [], matched_native_fields: [], changed_native_fields: [], inactive_native_fields: [],
          inactive_source_fields: [], unrepresented_native_fields: [], unwritten_guidance_fields: [],
          comparison: "not_compared_outside_reference" as const, verification: "unverified_stated_inspiration" as const,
          native_and_photographic_equivalence_verified: false as const }];
      }
      const record = ref.kind === "catalog" ? knowledge.references.find((entry) => entry.id === ref.id) : null;
      const entry = ref.kind === "book" ? book.recipes.find((entry) => entry.id === ref.id) : null;
      if (!record && !entry) {
        const hint = ref.kind === "catalog" && !knowledge.references.length ? " No private recipe catalog is installed; cite a book ID, or name a recipe from elsewhere with kind outside and relationship inspired." : "";
        issues.push(`${look.name}: unknown ${ref.kind} source ID ${ref.id}.${hint}`); return [];
      }
      const source: Partial<RecipeFields> = record?.source_facts.fields ?? entry!.recipe;
      const inactive = comparableSource(ref.kind, ref.id, "", source, record?.source_facts.inactive_fields ?? [], true).inactive;
      const comparable = fields.filter((key) => !inactive.has(key));
      const changed = comparable.filter((key) => source[key] !== undefined && source[key] !== look[key])
        .map((field) => ({ field, source: source[field]!, proposed: look[field] }));
      const matched = comparable.filter((key) => source[key] !== undefined && source[key] === look[key]);
      const filled = comparable.filter((key) => source[key] === undefined).map((field) => ({ field, proposed: look[field] }));
      const native = record?.source_facts.native ?? {};
      // Compare known grain components even when the source's combined grain field is incomplete.
      const finalGrain = /^Off$|^(Weak|Strong) (Small|Large)$/.test(look.grain) ? look.grain.split(" ") : [];
      const nativeGrain = ["grain_strength", "grain_size"] as const;
      const inactiveNative = native.grain_strength === "Off" ? ["grain_size"] : [];
      const grainComparisons = nativeGrain.filter((field) => native[field] !== undefined && !inactiveNative.includes(field))
        .map((field) => ({ field, source: native[field]!, proposed: (field === "grain_strength" ? finalGrain[0] : finalGrain[1]) ?? null, represented_by: "grain" as const }));
      const changedNative = grainComparisons.filter((comparison) => comparison.source !== comparison.proposed);
      const matchedNative = grainComparisons.filter((comparison) => comparison.source === comparison.proposed);
      const guidance = Object.entries(native).filter(([key]) => GUIDANCE_NATIVE.has(key)).map(([field, value]) => ({ field, source: value as string | number | boolean }));
      const unrepresentedNative = Object.keys(native).filter((key) => !GUIDANCE_NATIVE.has(key) && !inactiveNative.includes(key) && !grainComparisons.some((comparison) => comparison.field === key && comparison.proposed !== null));
      const complete = record ? record.source_record_status === "public_settings" && record.source_facts.published_core.complete : true;
      const exactComparable = complete && changed.length === 0 && changedNative.length === 0 && filled.length === 0 && unrepresentedNative.length === 0;
      if (use.relationship === "exact" && !exactComparable) {
        const blockers = [
          ...(!complete ? [record && record.source_record_status !== "public_settings" ? `source status ${record.source_record_status}` : "incomplete published core"] : []),
          ...[...changed, ...changedNative].map((item) => `${item.field} ${item.source} -> ${item.proposed}`),
          ...filled.map((item) => `${item.field} not published`), ...unrepresentedNative.map((field) => `${field} not representable`),
        ];
        issues.push(`${look.name}: exact source claim is unsupported by ${blockers.slice(0, 6).join("; ")}${blockers.length > 6 ? "; ..." : ""}. Declare an adaptation and explain the differences.`);
      }
      return [{ kind: ref.kind, id: ref.id, title: record?.title ?? entry!.title,
        source_url: record?.source_url ?? entry!.source_url,
        publisher: record?.publisher ?? null, author: record ? record.recipe_author : entry!.author,
        source_revision: record?.public_facts_sha256 ?? digest(entry),
        source_status: record?.source_record_status ?? "complete_book_entry",
        published_core_complete: complete,
        matched_fields: matched, changed_fields: changed, supplied_missing_fields: filled,
        matched_native_fields: matchedNative, changed_native_fields: changedNative, inactive_native_fields: inactiveNative,
        inactive_source_fields: [...inactive], unrepresented_native_fields: unrepresentedNative, unwritten_guidance_fields: guidance,
        comparison: exactComparable ? "matches_represented_settings" as const : "adapted_or_partial" as const,
        native_and_photographic_equivalence_verified: false,
      }];
    });
    return { ...base, status: issues.some((issue) => issue.startsWith(`${look.name}:`)) ? "needs_revision" as const : "compared" as const,
      declaration: use, comparisons };
  });
  const request = exactSourceRequests(intention, book, knowledge);
  const exactRows = rows.filter((row) => row.declaration?.relationship === "exact" && row.status === "compared");
  const requestedSources = request.sources.map((source) => ({ ...source,
    matching_looks: exactRows.filter((row) => row.comparisons.some((comparison) => source.candidates.some((candidate) => candidate.kind === comparison.kind && candidate.id === comparison.id))).map((row) => row.name) }));
  const fulfilled = requestedSources.length > 0 && requestedSources.every((source) => source.matching_looks.length > 0);
  const requestedFidelity = { exact_requested: request.requested, adaptation_permitted: explicitlyPermitsAdaptation(intention), exact_source_looks: exactRows.map((row) => row.name), requested_sources: requestedSources,
    status: !request.requested ? "not_requested" : fulfilled ? "represented_settings_compared" : "unresolved",
    note: request.requested && !fulfilled ? "The requested exact source copy remains unresolved. The output may be a useful proposed adaptation, but does not satisfy exact source fidelity. An unrelated exact copy cannot fulfill a named source request." : "Source comparison covers represented settings only, not rendering or native camera equivalence. Published ISO/exposure guidance is listed per comparison for the photographer to set; it is not written." };
  return { schema_version: "dialin.planner.sources.v1", requested_fidelity: requestedFidelity, status: issues.length ? "needs_revision" as const : "compared" as const,
    evidence: "model_declared_use_with_computed_setting_differences" as const,
    limitations: ["A declaration records the agent's stated source use, not proof of its internal reasoning.",
      "Matching represented values does not establish identical rendering, full native settings or camera acceptance.",
      "Exact means every represented rendering setting matches and no other published native control is lost. Published ISO and exposure-compensation guidance is disclosed in unwritten_guidance_fields for the photographer to set on the camera; Dial In does not write it.",
      "An outside reference is a recipe named from elsewhere without settings available here. It is recorded as stated, with no source hash or comparison, and is not verified."], rows, issues };
}
