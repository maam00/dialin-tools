/** Offline camera preparation. No device, filesystem, network, model, or USB dependency. */
import { createHash } from "node:crypto";
import { cameraFor, writable, type CameraCaps } from "../../lib/cameras.js";
import { recipeProblems } from "../../lib/plan/looks.js";
import { RECIPE_KEYS, type RecipeFields } from "../../lib/plan/types.js";
import { recipeToPresetValues, slotName, type Recipe } from "../../lib/fuji/recipe.js";
import { MONOCHROME_SIMS } from "../../lib/fuji/vendor/enums.js";
import { translateUIToPresetProps, type PresetUIValues } from "../../lib/fuji/vendor/preset-translate.js";
import { RECIPE_BOOK_SCHEMA, validateRecipeBook } from "../recipes/index.js";
import { code, normalizedFirmware, PROFILES, profileStatus, verifiedWriters, X100VI_110, type CameraProfile } from "./profiles.js";

export { normalizedFirmware };

export const CAMERA_PREPARATION_SCHEMA = "dialin.camera-preparation.v1";
export type CameraTransport = "usb" | "bluetooth";
export type CameraPlacement = { slot: number; recipe: Recipe };
export type CameraIssue = { code: string; path: string; message: string };
export type PreparationOptions = {
  model?: string; firmware?: string; transport?: CameraTransport;
  slots?: readonly (number | string)[]; protectedSlots?: readonly (number | string)[];
  recipeIds?: readonly string[];
};
export type TransportReadiness = {
  state: "blocked" | "requires_device_checks" | "photo_import_only";
  reasons: string[];
};
export type CameraPreparation = {
  schema_version: typeof CAMERA_PREPARATION_SCHEMA;
  input_sha256: string;
  camera: { model: string; firmware: string | null; identity_source: "user_declared_not_observed" };
  selected_transport: CameraTransport;
  source_kind: "recipes" | "recipe_book" | "placements" | "planner";
  placements: CameraPlacement[];
  protected_slots: number[];
  validation: { valid: boolean; errors: CameraIssue[]; warnings: string[] };
  encoding: { settings_file_mapping_confirmed: boolean; unconfirmed: CameraIssue[];
    /** What the USB writer would send per slot. `values` holds only written fields; `not_written` names the rest. */
    usb_preset_preview: UsbPreview[] };
  readiness: { usb: TransportReadiness; bluetooth: TransportReadiness; wifi: TransportReadiness };
  execution: { mode: "offline_preparation"; camera_operations: 0; provider_calls: 0; network_calls: 0;
    backup: "NOT_RUN"; upload: "NOT_RUN"; readback: "NOT_RUN" };
  transfer_authorized: false;
};

export type UsbPreview = { slot: number; values: Partial<PresetUIValues>; not_written: { fields: string[]; reason: string } };
// PresetUIValues field → custom-slot property it is written to. Exposure is a live control, never slot data.
const PRESET_PROPERTY: Record<keyof PresetUIValues, number | null> = {
  filmSimulation: 0xd192, dynamicRange: 0xd190, grainEffect: 0xd195, smoothSkin: 0xd198, colorChrome: 0xd196,
  colorChromeFxBlue: 0xd197, whiteBalance: 0xd199, wbShiftR: 0xd19a, wbShiftB: 0xd19b, wbColorTemp: 0xd19c,
  highlightTone: 0xd19d, shadowTone: 0xd19e, color: 0xd19f, sharpness: 0xd1a0, noiseReduction: 0xd1a1, clarity: 0xd1a2,
  exposure: null, dRangePriority: 0xd191, monoWC: 0xd193, monoMG: 0xd194,
};
/** The preview a person can trust: only fields the profile's writer sends for this recipe, never a value it skips. */
export function usbPreview(slot: number, recipe: Recipe, profile: CameraProfile = X100VI_110): UsbPreview {
  const all = recipeToPresetValues(recipe);
  const mono = MONOCHROME_SIMS.has(all.filmSimulation);
  const skip = new Set(mono ? profile.mono_skip.map(code) : []);
  const sent = new Set([...translateUIToPresetProps(all, []).map((p) => p.id), 0xd191].filter((id) => profile.write_order.map(code).includes(id) && !skip.has(id)));
  const values: Partial<PresetUIValues> = {}, missing: string[] = [];
  for (const [field, id] of Object.entries(PRESET_PROPERTY) as [keyof PresetUIValues, number | null][]) {
    if (id !== null && sent.has(id)) (values as Record<string, number>)[field] = all[field];
    else missing.push(field);
  }
  return { slot, values, not_written: { fields: missing, reason: mono
    ? "Monochrome look: the writer skips Color Chrome, FX Blue, WB shift and Color, so the slot keeps its stored values for them. Mono toning, exposure and an inactive Kelvin are never written."
    : "Mono toning, exposure and an inactive Kelvin are never written to a custom slot." } };
}
/** Recipe values whose USB encodings are CITED, not yet written and read back on this body. */
function citedValues(placements: CameraPlacement[], profile: CameraProfile | null): string[] {
  const verified = profile?.usb_verified;
  if (!verified) return [];
  return placements.flatMap(({ slot, recipe: r }) => [
    ...(!verified.film_sims.includes(r.film_sim) ? [`film simulation ${r.film_sim}`] : []),
    ...(!verified.white_balances.includes(r.white_balance) ? [`white balance ${r.white_balance}`] : []),
    ...(!verified.noise_reduction.includes(r.noise_reduction) ? [`NR ${r.noise_reduction > 0 ? "+" : ""}${r.noise_reduction}`] : []),
  ].map((value) => `C${slot}: ${value} uses a cited USB encoding that has not been written and read back on ${profile!.model} ${profile!.firmware.join("/")}; the apply's strict readback is its only check.`));
}
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const issue = (code: string, path: string, message: string): CameraIssue => ({ code, path, message });
const digest = (v: unknown) => createHash("sha256").update(JSON.stringify(v) ?? "null").digest("hex");
export function cameraSlot(value: unknown): number | null {
  if (typeof value === "number") return Number.isInteger(value) && value >= 1 && value <= 7 ? value : null;
  return typeof value === "string" && /^C?[1-7]$/i.test(value) ? Number(value.replace(/^C/i, "")) : null;
}
function slotList(values: readonly unknown[], path: string, errors: CameraIssue[]): number[] {
  const slots: number[] = [];
  values.forEach((v, i) => {
    const n = cameraSlot(v);
    if (n === null) errors.push(issue("invalid_slot", `${path}[${i}]`, "Use an integer 1–7 or C1–C7."));
    else if (slots.includes(n)) errors.push(issue("duplicate_slot", `${path}[${i}]`, `C${n} occurs more than once.`));
    else slots.push(n);
  });
  return slots;
}
function protectionInput(value: unknown, path: string, errors: CameraIssue[]): unknown[] {
  if (value === undefined) return [];
  if (Array.isArray(value)) return value;
  errors.push(issue("invalid_protection", path, "Protected slots must be an array when supplied; null, text and objects are not accepted."));
  return [];
}
function validateRecipe(raw: unknown, path: string, cam: CameraCaps, errors: CameraIssue[]): Recipe | null {
  if (!object(raw)) { errors.push(issue("invalid_recipe", path, "A recipe must be an object.")); return null; }
  const start = errors.length;
  for (const k of Object.keys(raw)) if (!(RECIPE_KEYS as readonly string[]).includes(k)) {
    errors.push(issue("unrepresented_field", `${path}.${k}`, "This field is not represented by the current recipe writer; it was not discarded."));
  }
  // Existing validation supplies the real enum/range contract; do not call tidyLook or confirmLook,
  // since importing someone's own recipe must not substitute settings or generate missing values.
  for (const problem of recipeProblems(raw, cam)) errors.push(issue("invalid_recipe_value", path, problem));
  for (const k of ["kelvin", "wb_shift_r", "wb_shift_b", "color", "sharpness", "noise_reduction", "clarity"]) {
    if (!Number.isInteger(raw[k])) errors.push(issue("integer_required", `${path}.${k}`, "Supply a JSON integer, not text or a fraction."));
  }
  if (typeof raw.name === "string" && (slotName(raw.name) !== raw.name || raw.name.length > cam.nameMax)) {
    errors.push(issue("slot_name", `${path}.name`, `Choose an explicit printable ASCII name of at most ${cam.nameMax} characters; it will not be silently shortened.`));
  }
  if (raw.why !== undefined && typeof raw.why !== "string") errors.push(issue("invalid_type", `${path}.why`, "why must be text when supplied."));
  if (raw.white_balance === "Kelvin" && !(typeof raw.kelvin === "number" && raw.kelvin >= 2500)) {
    errors.push(issue("kelvin_required", `${path}.kelvin`, "Kelvin white balance requires an explicit supported temperature; no default is invented."));
  }
  if (raw.white_balance !== "Kelvin" && raw.kelvin !== 0) {
    errors.push(issue("inactive_kelvin", `${path}.kelvin`, "Use explicit 0 when Kelvin white balance is inactive; no supplied value is discarded."));
  }
  if (errors.length !== start) return null;
  return { ...raw, why: raw.why ?? "" } as Recipe;
}
function mappingIssues(placements: CameraPlacement[], cam: CameraCaps): CameraIssue[] {
  const allowed = writable(cam), problems: CameraIssue[] = [];
  for (const { slot, recipe: r } of placements) {
    for (const [field, values] of [["film_sim", allowed.filmSims], ["white_balance", allowed.whiteBalances],
      ["noise_reduction", allowed.noiseReduction], ...(!cam.monoSims.has(r.film_sim) ? [["color", allowed.color]] : [])] as [keyof Recipe, readonly unknown[]][]) {
      if (!values.includes(r[field])) problems.push(issue("unconfirmed_settings_file_code", `C${slot}.${field}`,
        "The native recipe value exists, but its Bluetooth settings-file code is not confirmed. No substitute was chosen."));
    }
  }
  return problems;
}

/** Explicit Recipe JSON or the planner's write intent becomes placements, never a settings backup/upload. */
export function prepareCamera(input: unknown, options: PreparationOptions = {}): CameraPreparation {
  const errors: CameraIssue[] = [], warnings: string[] = [];
  const cam = cameraFor(options.model ?? "X100VI");
  if (!cam) errors.push(issue("unsupported_model", "camera.model", `Only the X100VI profile is implemented. No camera was contacted. To help add this body, run \`camera report\` (docs/ADD-YOUR-CAMERA.md).`));
  // USB is the only verified write path, so it is the default; Bluetooth must be asked for and reports its block.
  const transport = options.transport ?? "usb";
  if (transport !== "usb" && transport !== "bluetooth") errors.push(issue("invalid_transport", "transport", "Use usb or bluetooth; Wi-Fi is photo import, not recipe loading."));
  const firmware = normalizedFirmware(options.firmware);
  if (options.firmware && !firmware) errors.push(issue("invalid_firmware", "camera.firmware", "Use the exact firmware version, such as 1.10. Suffixes and extra components are not accepted."));
  let kind: CameraPreparation["source_kind"] = "recipes";
  let raws: unknown[] = [], mapped: unknown[] = [], inheritedProtected: unknown[] = [];
  const isBook = object(input) && input.schema_version === RECIPE_BOOK_SCHEMA;
  if (options.recipeIds !== undefined && !isBook) errors.push(issue("book_required", "ids", "Recipe IDs select entries from a dialin.recipes.v1 book. Omit --ids for bare recipes, placements or a plan."));
  const planner = object(input) && input.schema_version === "dialin.planner.v1" && object(input.plan) ? input.plan : null;
  if (isBook) {
    kind = "recipe_book";
    const validated = validateRecipeBook(input);
    for (const message of validated.issues) errors.push(issue("invalid_book", "book", message));
    if (validated.book) {
      const ids = options.recipeIds ?? validated.book.recipes.map((entry) => entry.id);
      if (ids.length === 0 || new Set(ids).size !== ids.length) errors.push(issue("invalid_recipe_ids", "ids", "Select one to seven distinct recipe IDs in destination order."));
      for (const id of ids) {
        const entry = validated.book.recipes.find((entry) => entry.id === id);
        if (!entry) errors.push(issue("unknown_recipe_id", "ids", `Recipe ID ${JSON.stringify(id)} is absent from the book.`));
        else raws.push(entry.recipe);
      }
    }
    inheritedProtected = protectionInput(input.protected_slots, "protected_slots", errors);
    mapped = [...(options.slots ?? [])];
    if (!options.slots) errors.push(issue("explicit_slots_required", "slots", "Supply --slots with one destination per selected recipe, in the same order as --ids or the book."));
  } else if (planner) {
    kind = "planner";
    if (options.slots) errors.push(issue("planner_mapping", "slots", "Planner write intent already maps slots; do not remap by array position."));
    const declared = object(planner.write) && Array.isArray(planner.write.slots) ? planner.write.slots : null;
    const looks = Array.isArray(planner.day_looks) ? planner.day_looks : [];
    if (!declared) errors.push(issue("missing_write_intent", "plan.write.slots", "Planner artifact needs explicit write slots."));
    const selected = slotList(declared ?? [], "plan.write.slots", errors);
    inheritedProtected = protectionInput(planner.protected_slots, "plan.protected_slots", errors);
    for (const slot of selected) {
      const candidates = looks.filter((l) => object(l) && l.slot === slot);
      if (candidates.length !== 1 || !object(candidates[0]) || candidates[0].status !== "new" || candidates[0].recipe_known !== true) {
        errors.push(issue("unsafe_plan_target", `plan.day_looks.C${slot}`, "A write target must identify one known new recipe; kept or unknown looks are never rewritten.")); continue;
      }
      raws.push(Object.fromEntries(RECIPE_KEYS.filter((k) => k in candidates[0]).map((k) => [k, candidates[0][k]])));
      mapped.push(slot);
    }
  } else if (object(input) && Array.isArray(input.placements)) {
    kind = "placements";
    if (options.slots) errors.push(issue("duplicate_mapping", "slots", "Use placements or --slots, not both."));
    for (const p of input.placements) {
      if (!object(p) || Object.keys(p).some((k) => k !== "slot" && k !== "recipe")) {
        errors.push(issue("invalid_placement", "placements", "Each placement contains exactly slot and recipe.")); continue;
      }
      mapped.push(p.slot); raws.push(p.recipe);
    }
    inheritedProtected = protectionInput(input.protected_slots, "protected_slots", errors);
  } else {
    raws = Array.isArray(input) ? input : object(input) && Array.isArray(input.recipes) ? input.recipes : [input];
    if (object(input) && Array.isArray(input.recipes)) inheritedProtected = protectionInput(input.protected_slots, "protected_slots", errors);
    mapped = [...(options.slots ?? [])];
    if (!options.slots) errors.push(issue("explicit_slots_required", "slots", "Explicit destination slots are required; there is no positional C1 default."));
  }
  if (raws.length < 1 || raws.length > 7) errors.push(issue("recipe_count", "recipes", "Supply one to seven recipes to prepare."));
  if (mapped.length !== raws.length) errors.push(issue("mapping_count", "slots", "Provide exactly one explicit destination for each recipe."));
  const slots = slotList(mapped, "slots", errors);
  const requestedProtected = slotList([...inheritedProtected, ...protectionInput(options.protectedSlots, "options.protectedSlots", errors)].filter((v, i, a) => a.indexOf(v) === i), "protected_slots", errors);
  for (const slot of slots) if (requestedProtected.includes(slot)) errors.push(issue("protected_slot", `C${slot}`, "This destination is protected. Nothing was prepared for transfer."));
  const parsed: CameraPlacement[] = [];
  raws.forEach((raw, i) => {
    const recipe = cam ? validateRecipe(raw, `recipes[${i}]`, cam, errors) : null;
    const slot = cameraSlot(mapped[i]);
    if (recipe && slot !== null) parsed.push({ slot, recipe });
  });
  const valid = errors.length === 0;
  const placements = valid ? parsed : [];
  const unconfirmed = cam ? mappingIssues(placements, cam) : [];
  // Bluetooth settings-file layout (lib/cameras.ts) and USB writer profile (profiles.ts) are separate evidence.
  const knownFirmware = !!firmware && !!cam?.confirmed.firmware.includes(firmware);
  const usbVerified = !!cam && profileStatus(cam.id, firmware).status === "verified";
  warnings.push("Preparation preserves supplied recipe settings. It is not a backup, wire payload, camera readback, or authorization to write.");
  warnings.push("The existing writers force D Range Priority and Smooth Skin Off. Unrepresented native controls cannot be claimed preserved from a recipe JSON.");
  if (parsed.some(({ recipe }) => cam?.monoSims.has(recipe.film_sim))) warnings.push("Monochrome writes leave inactive color/Color Chrome/WB-shift memories and native monochrome tint unresolved; exact complete-bank equivalence is not claimed.");
  if (!usbVerified) warnings.push(`The offline declaration does not match a verified USB writer profile (${verifiedWriters()}). Live USB application is blocked until the exact supported firmware is declared and observed.`);
  const previewProfile = (cam ? profileStatus(cam.id, firmware).profile ?? PROFILES.find((p) => p.model === cam.id && p.write_status === "verified") : null) ?? X100VI_110;
  if (transport === "usb") warnings.push(...citedValues(parsed, previewProfile));
  const usbReasons = ["No physical identity, complete current-slot backup, durable backup save, accepted writes, or independent readbacks have run."];
  if (!valid) usbReasons.push("Input validation failed.");
  if (!usbVerified) usbReasons.push(`The desktop write wrapper requires a declared and observed verified profile: ${verifiedWriters()}.`);
  return {
    schema_version: CAMERA_PREPARATION_SCHEMA, input_sha256: digest(input),
    camera: { model: cam?.id ?? options.model ?? "unknown", firmware, identity_source: "user_declared_not_observed" },
    selected_transport: transport, source_kind: kind, placements,
    protected_slots: Array.from({ length: 7 }, (_, i) => i + 1).filter((s) => !slots.includes(s) || requestedProtected.includes(s)),
    validation: { valid, errors, warnings },
    encoding: { settings_file_mapping_confirmed: valid && knownFirmware && unconfirmed.length === 0, unconfirmed,
      usb_preset_preview: placements.map(({ slot, recipe }) => usbPreview(slot, recipe, previewProfile)) },
    readiness: {
      usb: { state: valid && usbVerified ? "requires_device_checks" : "blocked", reasons: usbReasons },
      bluetooth: { state: "blocked", reasons: ["BLESlotWriter.wirelessWritesValidated is false; production modified-settings upload is disabled.",
        ...(!knownFirmware ? ["The settings-file decoder/mapping is scoped to X100VI firmware 1.10."] : []),
        ...(unconfirmed.length ? ["Some recipe fields have unconfirmed settings-file codes."] : []),
        "Whole-camera Python BLE restore is not a selected-slot recipe-loading substitute.",
        "No fresh same-camera backup, narrow patch/guard, upload, restart, independent readback or recovery proof has run."] },
      wifi: { state: "photo_import_only", reasons: ["Wi-Fi is implemented for photo return. It does not apply this recipe artifact; physical import/Photos evidence is separate."] },
    },
    execution: { mode: "offline_preparation", camera_operations: 0, provider_calls: 0, network_calls: 0, backup: "NOT_RUN", upload: "NOT_RUN", readback: "NOT_RUN" },
    transfer_authorized: false,
  };
}

/** Recompute current validation/readiness instead of trusting an imported artifact's claims. */
export function inspectPreparation(input: unknown): CameraPreparation {
  if (!object(input) || input.schema_version !== CAMERA_PREPARATION_SCHEMA || !object(input.camera)
    || !Array.isArray(input.placements) || !Array.isArray(input.protected_slots)) throw new Error("Not a camera preparation artifact.");
  if (typeof input.camera.model !== "string" || (input.camera.firmware !== null && typeof input.camera.firmware !== "string")) throw new Error("Invalid declared camera identity.");
  if (input.selected_transport !== "usb" && input.selected_transport !== "bluetooth") throw new Error("Invalid preparation transport.");
  return prepareCamera({ placements: input.placements, protected_slots: input.protected_slots }, {
    model: input.camera.model, firmware: input.camera.firmware ?? undefined, transport: input.selected_transport,
  });
}

export function cameraCapabilities() {
  return { model: "X100VI", software_profile_firmware: ["1.10"], computer_workflow: true,
    offline: ["import existing Recipe JSON", "explicit destination slots", "validation", "encoding preview"],
    usb: "Explicit desktop info/backup/apply, with identity, durable backup and strict readback checks; no implicit writes.",
    bluetooth: "Settings-file mapping and native protected writer exist; production modified-settings upload remains blocked.",
    wifi: "Photo import implementation exists separately; not recipe transfer.",
    boundaries: "No generic camera support, simulated acceptance, or whole-settings restore shortcut is implied.",
    profiles: PROFILES.map((p) => ({ id: p.id, model: p.model, firmware: p.firmware, write_status: p.write_status })),
    other_bodies: "Writes unsupported. `camera report` makes a read-only report for a 'Camera report' issue (docs/ADD-YOUR-CAMERA.md)." };
}
