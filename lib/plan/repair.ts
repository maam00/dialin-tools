// A bounded repair of new palette entries. Accepted siblings and the plan envelope never come back from the model.
import type { CameraCaps } from "../cameras.js";
import { effectiveRecipeSignature } from "./expert-policy.js";
import { lookProblems } from "./looks.js";
import type { PalettePolicy } from "./palette.js";
import type { Library } from "./slots.js";
import type { CameraSlot, ModelLook, ModelPlan } from "./types.js";

const low = (value: unknown) => String(value ?? "").trim().toLowerCase();
const object = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value);

export type TargetedRepair = {
  count: number;
  /** Only discarded new duplicates get replacements with their original, unambiguous names. */
  replacementNames: string[];
  originalOrder: string[];
};

/** Deliberately narrow: one or two missing new entries, with no other plan, identity or intent errors. */
export function targetedRepairFor(data: ModelPlan, originalLooks: readonly ModelLook[], problems: readonly string[],
  expected: number | null, policy: PalettePolicy, cam: CameraCaps): TargetedRepair | null {
  if (!policy.full || expected === null || !Array.isArray(data.looks) || !Array.isArray(data.stops)
    || !data.looks.length || originalLooks.some((look) => !object(look)) || originalLooks.length > expected) return null;
  const count = expected - data.looks.length;
  if (count < 1 || count > 2 || !problems.length || !data.stops.length
    || typeof data.summary !== "string" || typeof data.count_why !== "string" || !Array.isArray(data.replace)) return null;
  const names = originalLooks.map((look) => low(look.name));
  if (names.some((name) => !name) || new Set(names).size !== names.length) return null;
  if (data.primary_look && !data.looks.some((look) => look.name === data.primary_look)) return null;
  if (data.looks.some((look) => !look.reuse && lookProblems(look, cam).length)) return null;
  const stopNames = data.stops.map((stop) => low(stop?.name));
  if (stopNames.some((name) => !name) || new Set(stopNames).size !== stopNames.length) return null;
  const removed = originalLooks.filter((look) => !data.looks.includes(look));
  const allowed = new Set([`${data.looks.length} looks; make ${expected}`]);
  for (const look of removed) {
    // A protected/kept omission, malformed value or ambiguous source cannot be patched as a new look.
    if (look.reuse || look.reuse_slot || lookProblems(look, cam).length) return null;
    const repeated = data.looks.find((other) => effectiveRecipeSignature(other) === effectiveRecipeSignature(look));
    if (!repeated) return null;
    allowed.add(`${look.name}: repeats the settings of ${repeated.name}; give each new look a distinct rendering purpose`);
  }
  for (const stop of data.stops) if (!data.looks.some((look) => low(look.stop) === low(stop.name))) {
    allowed.add(`stop '${stop.name}' has no look`);
  }
  if (!problems.every((problem) => allowed.has(problem))) return null;
  return { count, replacementNames: removed.map((look) => look.name), originalOrder: originalLooks.map((look) => look.name) };
}

/** Reuse the current mode's recipe schema; the reply cannot rewrite summary, stops, primary or accepted entries. */
export function targetedRepairSchema(planSchema: Record<string, unknown>): Record<string, unknown> {
  const properties = planSchema.properties as Record<string, unknown>;
  return { type: "object", additionalProperties: false, required: ["looks"], properties: { looks: properties.looks } };
}

export function targetedRepairText(content: string, data: ModelPlan, target: TargetedRepair, problems: readonly string[]): string {
  return `${content}\n\nYOUR LAST ANSWER BROKE THESE RULES:\n${problems.map((problem) => `- ${problem}`).join("\n")}\n\n`
    + `REPAIR ONLY ${target.count} NEW LOOK${target.count === 1 ? "" : "S"}. Return only {\"looks\": [...]} containing those ${target.count} entries. `
    + "The accepted looks below are immutable context: do not repeat, rewrite or return them. Do not return summary, stops, primary_look or replace. "
    + "Every repair must be a new look: reuse is empty and reuse_slot is 0. Preserve the request's subjects, taste, physical setup checks and source-ID rules. "
    + "Use the existing stop names and cover any stop missing a look. Make each rendering distinct from every accepted look. "
    + (target.replacementNames.length ? `Replace the discarded duplicates using these exact names: ${JSON.stringify(target.replacementNames)}. ` : "")
    + `Add ${target.count - target.replacementNames.length} other new look(s) with unique names.\n\nAccepted plan (do not rewrite):\n${JSON.stringify(data)}`;
}

/** Atomic assembly. Even a provider that ignores the schema cannot change an accepted sibling or camera identity. */
export function mergeTargetedRepair(data: ModelPlan, raw: unknown, target: TargetedRepair, camera: CameraSlot[] | null,
  library: Library, candidateIDs: readonly string[]): ModelPlan | null {
  if (!object(raw) || Object.keys(raw).some((key) => key !== "looks") || !Array.isArray(raw.looks) || raw.looks.length !== target.count) return null;
  const repairs = raw.looks;
  const acceptedNames = new Set(data.looks.map((look) => low(look.name)));
  const identities = new Set([...(camera ?? []).map((slot) => low(slot.name)), ...library.keys()].filter(Boolean));
  const sourceIDs = new Set(candidateIDs);
  const seen = new Set<string>();
  for (const look of repairs) {
    if (!object(look) || typeof look.name !== "string" || !low(look.name) || acceptedNames.has(low(look.name))
      || identities.has(low(look.name)) || seen.has(low(look.name)) || look.reuse || look.reuse_slot
      || (look.recipe_reference_id != null && (typeof look.recipe_reference_id !== "string" || !sourceIDs.has(look.recipe_reference_id)))) return null;
    if (["stop", "when", "reason", "why", "how", "focus", "drive", "based_on"].some((key) => typeof look[key] !== "string")
      || !object(look.exposure) || (look.reuse !== undefined && typeof look.reuse !== "string")) return null;
    seen.add(low(look.name));
  }
  if (!target.replacementNames.every((name) => repairs.some((look) => look.name === name))) return null;
  const byName = new Map([...data.looks, ...repairs as ModelLook[]].map((look) => [look.name, look]));
  const ordered = target.originalOrder.flatMap((name) => byName.has(name) ? [byName.get(name)!] : []);
  const originalNames = new Set(target.originalOrder);
  ordered.push(...repairs.filter((look) => !originalNames.has(look.name)) as ModelLook[]);
  return { ...data, looks: ordered };
}
