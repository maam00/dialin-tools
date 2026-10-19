// Full-day palette policy is enforced by code, independently of the model's cooperation.
import type { CameraCaps } from "../cameras.js";
import { recipeOf, sameRecipe } from "./looks.js";
import { effectiveRecipeSignature } from "./expert-policy.js";
import { type CameraSlot, type ModelLook, type ModelPlan, type Plan, PlanError } from "./types.js";

const low = (s: unknown) => String(s ?? "").trim().toLowerCase();

export function protectedSlotsFrom(value: unknown, cam: CameraCaps): number[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > cam.slots
      || value.some((slot) => !Number.isInteger(slot) || slot < 1 || slot > cam.slots)
      || new Set(value).size !== value.length) {
    throw new PlanError(`protected_slots must be unique slot numbers from 1 to ${cam.slots}.`, "bad_protected_slots", 400);
  }
  return [...value].sort((a, b) => a - b);
}

export type PalettePolicy = {
  enabled: boolean;
  full: boolean;
  slots: number;
  requested: number | null;
  protectedSlots: number[];
  blockedSlots: number[];
};

export function palettePolicy(count: number | null, protectedSlots: number[], camera: CameraSlot[] | null,
  cam: CameraCaps, explicitProtection: boolean): PalettePolicy {
  return {
    enabled: explicitProtection || count === cam.slots,
    full: count === cam.slots,
    slots: cam.slots,
    requested: count,
    protectedSlots,
    blockedSlots: protectedSlots.filter((slot) => {
      const actual = camera?.find((s) => s.slot === slot);
      return !actual?.name || !actual.recipe;
    }),
  };
}

/** Resolve the exact slot, never a library recipe merely sharing the camera's name. */
export function cameraReuse(look: ModelLook, camera: CameraSlot[] | null): CameraSlot | undefined {
  if (look.reuse_slot) return camera?.find((s) => s.slot === look.reuse_slot && low(s.name) === low(look.reuse));
  const matches = (camera ?? []).filter((s) => s.name && low(s.name) === low(look.reuse || look.name));
  return matches.length === 1 ? matches[0] : undefined;
}

/** Keep usable suggestions, and surface violations for the bounded retry. No generated filler is added. */
export function enforcePaletteAnswer(data: ModelPlan, camera: CameraSlot[] | null, policy: PalettePolicy): string[] {
  if (!policy.enabled) return [];
  const problems: string[] = [];
  const seenSlots = new Set<number>();
  const kept: ModelLook[] = [];
  for (const look of Array.isArray(data.looks) ? data.looks : []) {
    if (!look || typeof look !== "object") { problems.push("a palette entry isn't a look"); continue; }
    if (typeof look.when !== "string" || !look.when.trim() || typeof look.reason !== "string" || !look.reason.trim()) {
      problems.push(`${look.name || "a look"}: explain when to use it and why it belongs in the day`);
      continue;
    }
    if (look.reuse_slot !== undefined && (!Number.isInteger(look.reuse_slot) || look.reuse_slot < 0 || look.reuse_slot > policy.slots)) {
      problems.push(`${look.name}: reuse_slot must identify the exact camera slot, or be 0`);
      continue;
    }
    let onCamera = cameraReuse(look, camera);
    if (look.reuse_slot && !onCamera) {
      problems.push(`${look.name}: reuse and reuse_slot must identify the same known camera look`);
      continue;
    }
    const namedCamera = (camera ?? []).filter((s) => s.name && low(s.name) === low(look.reuse || look.name));
    if (look.reuse && namedCamera.length && !onCamera) {
      problems.push(`${look.name}: that camera name is ambiguous; give its exact reuse_slot`);
      continue;
    }
    if (!look.reuse && !look.reuse_slot) {
      // Renaming an unchanged camera recipe does not create another new look.
      const copies = (camera ?? []).filter((s) => s.recipe && sameRecipe(s.recipe, look));
      if (!onCamera?.recipe || !sameRecipe(onCamera.recipe, look)) onCamera = copies.length === 1 ? copies[0] : undefined;
      if (copies.length > 1 && !onCamera) {
        problems.push(`${look.name}: unchanged camera settings need an exact reuse_slot, not a new name`);
        continue;
      }
      if (!onCamera && namedCamera.some((s) => policy.protectedSlots.includes(s.slot))) {
        problems.push(`${look.name}: that protected look must be reused unchanged in its original slot`);
        continue;
      }
    }
    if (onCamera && (look.reuse || look.reuse_slot || (onCamera.recipe && sameRecipe(onCamera.recipe, look)))) {
      if (!onCamera.recipe) {
        problems.push(`C${onCamera.slot}: its actual camera recipe is unknown; don't invent a kept look`);
        continue;
      }
      if (seenSlots.has(onCamera.slot)) {
        problems.push(`C${onCamera.slot}: one camera look cannot fill two palette entries`);
        continue;
      }
      seenSlots.add(onCamera.slot);
      Object.assign(look, onCamera.recipe, { name: onCamera.name, reuse: onCamera.name, reuse_slot: onCamera.slot });
    }
    const repeated = kept.find((other) => effectiveRecipeSignature(other) === effectiveRecipeSignature(look) && !(other.reuse_slot && look.reuse_slot));
    if (repeated) {
      problems.push(`${look.name}: repeats the settings of ${repeated.name}; give each new look a distinct rendering purpose`);
      if (look.reuse_slot) kept.splice(kept.indexOf(repeated), 1); // retain a real fixed camera look ahead of a new copy
      else continue;
    }
    kept.push(look);
  }
  const capacity = policy.slots - policy.protectedSlots.length
    - [...seenSlots].filter((slot) => !policy.protectedSlots.includes(slot)).length;
  let newCount = 0;
  data.looks = kept.filter((look) => {
    if (look.reuse_slot || newCount++ < capacity) return true;
    problems.push(`${look.name}: doesn't fit beside the protected and kept slots; keep those fixed and plan the remaining space`);
    return false;
  });
  // A name-based replacement list cannot safely distinguish duplicate protected names.
  const protectedNames = new Set((camera ?? []).filter((s) => policy.protectedSlots.includes(s.slot)).map((s) => low(s.name)));
  data.replace = (Array.isArray(data.replace) ? data.replace : []).filter((r) => !protectedNames.has(low(r?.name)));
  if (policy.full) {
    for (const slot of policy.protectedSlots.filter((s) => !policy.blockedSlots.includes(s))) {
      if (!seenSlots.has(slot)) problems.push(`C${slot}: include its protected look unchanged, with a useful when and reason`);
    }
  }
  return problems;
}

/** Reject identical new rendering after code substitutions/automatic-mode normalization, too. */
export function removePaletteCopies(plan: Plan, camera: CameraSlot[] | null): string[] {
  const accepted = plan.day_looks.filter((l) => l.status === "kept");
  const warnings: string[] = [];
  for (const look of plan.day_looks.filter((l) => l.status === "new")) {
    const copy = accepted.find((other) => effectiveRecipeSignature(recipeOf(other)) === effectiveRecipeSignature(recipeOf(look)));
    const cameraCopy = (camera ?? []).find((s) => s.recipe && effectiveRecipeSignature(s.recipe) === effectiveRecipeSignature(look));
    if (copy || cameraCopy) {
      const source = copy ? `"${copy.name}"` : `your existing C${cameraCopy!.slot} "${cameraCopy!.name}"`;
      warnings.push(`C${look.slot} is missing: "${look.name}" repeats the settings of ${source}; no filler look was added.`);
    } else accepted.push(look);
  }
  plan.day_looks = plan.day_looks.filter((l) => accepted.includes(l));
  return warnings;
}

export function paletteMetadata(plan: Plan, policy: PalettePolicy, cam: CameraCaps): void {
  if (!policy.enabled) return;
  plan.protected_slots = [...policy.protectedSlots];
  plan.blocked_slots = [...policy.blockedSlots];
  if (policy.requested !== null) plan.requested_count = policy.requested;
  if (!policy.full) {
    // A partial plan ("two new looks, keep C1-C5"): protected slots stay exactly as they are and are not part of
    // this plan, so an unread one is neither missing nor a reason to call the plan incomplete.
    plan.missing_slots = [];
    return;
  }
  const present = new Set(plan.day_looks.filter((l) => l.recipe_known && l.slot !== null).map((l) => l.slot));
  plan.missing_slots = policy.full ? Array.from({ length: cam.slots }, (_, i) => i + 1).filter((s) => !present.has(s))
    : [...policy.blockedSlots];
  plan.palette_complete = policy.full && present.size === cam.slots && policy.blockedSlots.length === 0;
  for (const slot of policy.blockedSlots) {
    plan.warnings.push(`C${slot} is protected, but its actual recipe wasn't read. It stays untouched and is missing from this palette.`);
  }
  if (policy.full && !plan.palette_complete) {
    plan.warnings.push(`Your seven-look palette is incomplete; missing ${plan.missing_slots.map((s) => `C${s}`).join(", ")}.`);
  }
}
