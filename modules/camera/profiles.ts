/** Camera profiles: a body's custom-slot USB map as data, and whether Dial In may write to it. No device access.
 *  Writing needs a profile in PROFILES with write_status "verified" for the exact model AND firmware, and that status
 *  needs a supervised hardware record in tests/fixtures/camera/ (docs/ADD-YOUR-CAMERA.md). A camera report or a draft
 *  profile never authorizes a write: drafts are always read_only and only code review can change PROFILES. */
import { X100VI, type CameraCaps } from "../../lib/cameras.js";
import { EFFECTS, FILM_SIMS, GRAINS, WHITE_BALANCES } from "../../lib/fuji/recipe.js";
import { FilmSim, WBMode } from "../../lib/fuji/vendor/enums.js";
import { NR_ENCODE } from "../../lib/fuji/vendor/preset-translate.js";

export const CAMERA_PROFILE_SCHEMA = "dialin.camera-profile.v1";
export const HARDWARE_EVIDENCE_SCHEMA = "dialin.camera-hardware-evidence.v1";
export type WriteStatus = "verified" | "read_only" | "unknown";
export type HardwareCheck = "passed" | "failed" | "not_run";
/** The bar for writes on a body: each must pass on that exact body and firmware, supervised, after a backup. */
export const HARDWARE_CHECKS = ["write", "readback", "exact_restore", "restart_persistence"] as const;
/** One custom-slot property. `values`/`range` = raw wire values the map accepts; `observed` (drafts) = values seen. */
export type SlotProperty = { code: string; field: string; written: boolean; signed?: boolean;
  values?: readonly number[]; range?: readonly [number, number, number]; observed?: readonly number[] };
export type CameraProfile = {
  schema_version: typeof CAMERA_PROFILE_SCHEMA; id: string; model: string; firmware: readonly string[];
  write_status: Exclude<WriteStatus, "unknown">; slots: number; name_max: number | null;
  cursor: string; name: string; properties: readonly SlotProperty[];
  /** Properties the writer sets, in the order the body accepts. Only verified profiles carry one. */
  write_order: readonly string[]; mono_skip: readonly string[];
  /** Encoding deltas: a written value the body reads back differently (e.g. Grain Off). Nothing else may differ. */
  readback_equivalents: readonly { code: string; wrote: string; reads: readonly string[] }[];
  film_sims: readonly string[]; grains: readonly string[]; color_chrome: readonly string[]; white_balances: readonly string[];
  required_operations: readonly string[];
  evidence: { fixture: string | null; checks: Record<(typeof HARDWARE_CHECKS)[number], HardwareCheck>; source: string };
  /** Verified profiles only: recipe values written over USB on this body and read back clean. Other native values use
   *  CITED encodings; the apply's strict readback is then their only check. The desktop planner offers only these. */
  usb_verified?: { film_sims: readonly string[]; white_balances: readonly string[]; noise_reduction: readonly number[]; evidence: string };
};

export const hex4 = (n: number) => `0x${n.toString(16).padStart(4, "0")}`;
export const code = (s: string) => Number.parseInt(s.slice(2), 16);
const CODE = /^0x[0-9a-f]{4}$/;
const span = (lo: number, hi: number, step: number) => Array.from({ length: Math.floor((hi - lo) / step) + 1 }, (_, i) => lo + i * step);
const prop = (c: string, field: string, written: boolean, accepts: Partial<SlotProperty> = {}): SlotProperty => ({ code: c, field, written, ...accepts });
const signed = (lo: number, hi: number, step: number) => ({ signed: true, range: [lo, hi, step] as const });

// docs/FUJI_PROTOCOL.md §4.1, checked on the X100VI 1.10. D1A5 is the LIVE image size, never slot data.
export const X100VI_110: CameraProfile = {
  schema_version: CAMERA_PROFILE_SCHEMA, id: "X100VI-1.10", model: "X100VI", firmware: ["1.10"], write_status: "verified",
  slots: X100VI.slots, name_max: X100VI.nameMax, cursor: "0xd18c", name: "0xd18d",
  properties: [
    prop("0xd18e", "image_size", false), prop("0xd18f", "image_quality", false),
    prop("0xd190", "dynamic_range", true, { values: [100, 200, 400, 0xffff] }),
    prop("0xd191", "d_range_priority", true, { values: [0, 1, 2, 0x8000] }),
    prop("0xd192", "film_sim", true, { values: Object.values(FilmSim) }),
    prop("0xd193", "mono_warm_cool", false, signed(-180, 180, 10)), prop("0xd194", "mono_magenta_green", false, signed(-180, 180, 10)),
    prop("0xd195", "grain", true, { values: span(1, 7, 1) }),
    prop("0xd196", "color_chrome", true, { values: [1, 2, 3] }), prop("0xd197", "color_chrome_fx_blue", true, { values: [1, 2, 3] }),
    prop("0xd198", "smooth_skin", true, { values: [1, 2, 3] }),
    prop("0xd199", "white_balance", true, { values: Object.values(WBMode) }),
    prop("0xd19a", "wb_shift_r", true, signed(-9, 9, 1)), prop("0xd19b", "wb_shift_b", true, signed(-9, 9, 1)),
    prop("0xd19c", "kelvin", true, { values: [0], range: [2500, 10000, 10] }),
    prop("0xd19d", "highlight", true, signed(-20, 40, 5)), prop("0xd19e", "shadow", true, signed(-20, 40, 5)),
    prop("0xd19f", "color", true, signed(-40, 40, 10)), prop("0xd1a0", "sharpness", true, signed(-40, 40, 10)),
    prop("0xd1a1", "noise_reduction", true, { values: Object.values(NR_ENCODE) }),
    prop("0xd1a2", "clarity", true, signed(-50, 50, 10)),
    prop("0xd1a3", "lens_modulation_optimizer", false), prop("0xd1a4", "color_space", false),
  ],
  // The order lib/fuji/camera.ts and modules/camera/usb.ts have written on this body (docs/FUJI_PROTOCOL.md §4.2).
  write_order: ["0xd192", "0xd191", "0xd190", "0xd195", "0xd196", "0xd197", "0xd198", "0xd199", "0xd19c", "0xd19a", "0xd19b",
    "0xd19d", "0xd19e", "0xd19f", "0xd1a0", "0xd1a1", "0xd1a2"],
  mono_skip: ["0xd196", "0xd197", "0xd19a", "0xd19b", "0xd19f"],
  readback_equivalents: [{ code: "0xd195", wrote: "0100", reads: ["0600", "0700"] }],
  film_sims: X100VI.filmSims, grains: Object.keys(GRAINS), color_chrome: Object.keys(EFFECTS), white_balances: X100VI.whiteBalances,
  required_operations: ["0x1001", "0x1002", "0x1003", "0x1015", "0x1016"],
  evidence: { fixture: "tests/fixtures/camera/X100VI-1.10.hardware.json",
    checks: { write: "passed", readback: "passed", exact_restore: "passed", restart_persistence: "passed" },
    source: "Supervised USB sessions on the owner's X100VI 1.10 with macOS 27; see the fixture." },
  // docs/FUJIFILM-PROTOCOL.md 2.3. Film simulations: Reala Ace, Pro Neg Std, Velvia, Classic Chrome, Nostalgic Neg,
  // Acros+R and Acros+Ye were written to C1-C7 and read back clean on 2026-10-09; the other 13 were each written to C7
  // and read back clean on 2026-10-13 (with Reala Ace and Acros+R as controls). White balance and NR: only these values
  // have been written; the rest of each table is CITED.
  usb_verified: { film_sims: X100VI.filmSims, white_balances: ["Auto", "Daylight", "Kelvin"], noise_reduction: [-4],
    evidence: "VERIFIED-HW on one X100VI 1.10: all 20 film simulations, Auto/Daylight/Kelvin white balance and NR -4 written over USB and read back clean (2026-10-09, 2026-10-13)." },
};

/** Every profile Dial In ships. Add a body as read_only from a reviewed draft; only the hardware bar makes it verified. */
export const PROFILES: readonly CameraProfile[] = [X100VI_110];

/** Wire codes → names, for drafts built from a report. */
export const WIRE_NAMES: Record<string, Record<number, string>> = {
  "0xd192": Object.fromEntries(Object.entries(FILM_SIMS).map(([name, c]) => [c, name])),
  "0xd195": { 1: "Off", 2: "Weak Small", 3: "Strong Small", 4: "Weak Large", 5: "Strong Large", 6: "Off", 7: "Off" },
  "0xd196": { 1: "Off", 2: "Weak", 3: "Strong" },
  "0xd199": Object.fromEntries(Object.entries(WHITE_BALANCES).map(([name, c]) => [c, name])),
};

export function normalizedFirmware(raw: string | null | undefined): string | null {
  const m = raw?.trim().match(/^(?:ver\s*)?(\d+)\.(\d+)$/i);
  return m ? `${Number(m[1])}.${m[2]}` : null;
}
const modelKey = (s: string) => s.toLowerCase().replace(/fujifilm|fuji/g, "").replace(/[\s_-]+/g, "");
export const accepts = (p: SlotProperty, v: number) => !!p.values?.includes(v)
  || (!!p.range && v >= p.range[0] && v <= p.range[1] && (v - p.range[0]) % p.range[2] === 0);

/** verified = a shipped verified profile for this exact model and firmware; read_only = a known body, but not this
 *  firmware or not verified; unknown = no profile. `body` is any shipped profile for the model (slot count etc.);
 *  `verified_firmware` lists the firmware Dial In may write on this model. */
export function profileStatus(model: string | null | undefined, firmware: string | null | undefined):
  { status: WriteStatus; profile: CameraProfile | null; body: CameraProfile | null; verified_firmware: string[] } {
  const k = modelKey(model ?? ""), fw = normalizedFirmware(firmware);
  const same = k ? PROFILES.filter((p) => modelKey(p.model) === k) : [];
  const exact = same.find((p) => fw !== null && p.firmware.includes(fw)) ?? null;
  return { status: exact ? exact.write_status : same.length ? "read_only" : "unknown", profile: exact, body: exact ?? same[0] ?? null,
    verified_firmware: same.filter((p) => p.write_status === "verified").flatMap((p) => p.firmware) };
}
/** The values a desktop plan may propose for this body: the planner's existing contract (lib/cameras.ts, built from
 *  Bluetooth settings-file codes), with the film simulations widened to those the verified USB profile has written and
 *  read back clean. The desktop toolkit writes only over USB. A simulation added here has no promoted settings-file
 *  code, so its entry carries the USB property value (D192) and says so; the Bluetooth path still refuses it. White
 *  balance, Color and NR stay as the planner already had them. Bodies without a verified USB profile are unchanged. */
export function usbPlanningCaps(cam: CameraCaps): CameraCaps {
  const profile = PROFILES.find((p) => p.write_status === "verified" && modelKey(p.model) === modelKey(cam.id) && p.usb_verified);
  if (!profile?.usb_verified) return cam;
  const extra = cam.filmSims.filter((sim) => profile.usb_verified!.film_sims.includes(sim) && !(sim in cam.confirmed.filmSims));
  if (!extra.length) return cam;
  const source = `usb-${profile.id}`;
  return { ...cam, confirmed: { ...cam.confirmed,
    sources: { ...cam.confirmed.sources, [source]: profile.usb_verified.evidence },
    filmSims: { ...cam.confirmed.filmSims, ...Object.fromEntries(extra.map((sim) => [sim, {
      code: (FILM_SIMS as Record<string, number>)[sim],
      seen: `${source}: USB slot property D192 = ${(FILM_SIMS as Record<string, number>)[sim]} written and read back clean; no settings-file code promoted, so Bluetooth writes still refuse it` }])) } } };
}

/** "X100VI 1.10", for messages. */
export const verifiedWriters = () => PROFILES.filter((p) => p.write_status === "verified").map((p) => `${p.model} ${p.firmware.join("/")}`).join(", ");
/** The profile that may write to this body, or null. Requires a valid verified profile in PROFILES. */
export function writerProfile(model: string | null | undefined, firmware: string | null | undefined): CameraProfile | null {
  const { status, profile } = profileStatus(model, firmware);
  return status === "verified" && profile && !validateProfile(profile).length ? profile : null;
}

const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
/** Structural checks, plus the rule that "verified" needs a hardware record where every check passed. */
export function validateProfile(input: unknown): string[] {
  if (!object(input)) return ["A profile must be an object."];
  const p = input as Partial<CameraProfile>, issues: string[] = [];
  if (p.schema_version !== CAMERA_PROFILE_SCHEMA) issues.push(`schema_version must be ${CAMERA_PROFILE_SCHEMA}.`);
  if (typeof p.id !== "string" || !/^[\w.+-]{1,64}$/.test(p.id)) issues.push("id must be a short identifier such as X-T5-4.31.");
  if (typeof p.model !== "string" || !/^[\x20-\x7e]{1,40}$/.test(p.model)) issues.push("model must be the printable model name the camera reports.");
  if (!Array.isArray(p.firmware) || !p.firmware.length || p.firmware.some((f) => normalizedFirmware(f) !== f)) issues.push("firmware must list exact versions such as 1.10.");
  if (p.write_status !== "verified" && p.write_status !== "read_only") issues.push("write_status must be verified or read_only.");
  if (!Number.isInteger(p.slots) || p.slots! < 1 || p.slots! > 7) issues.push("slots must be the body's custom-slot count, 1–7.");
  const props = Array.isArray(p.properties) ? p.properties : [];
  const codes = props.map((x) => x?.code);
  if (!props.length || codes.some((c) => typeof c !== "string" || !CODE.test(c)) || new Set(codes).size !== codes.length) issues.push("properties need unique 0xNNNN codes.");
  if (codes.includes("0xd1a5")) issues.push("0xd1a5 is the live image size, never slot data.");
  if (p.cursor !== "0xd18c" || p.name !== "0xd18d") issues.push("cursor and name are 0xd18c and 0xd18d on every known body.");
  const written = new Set(props.filter((x) => x?.written).map((x) => x.code));
  const order = Array.isArray(p.write_order) ? p.write_order : null;
  if (!order || order.some((c) => !written.has(c)) || new Set(order).size !== order.length) issues.push("write_order may list each written property once.");
  if (!Array.isArray(p.mono_skip) || p.mono_skip.some((c) => !order?.includes(c))) issues.push("mono_skip must be a subset of write_order.");
  if (p.write_status === "verified") {
    if (!order?.length) issues.push("A verified profile needs a write order.");
    if (!p.evidence?.fixture) issues.push("A verified profile needs a hardware fixture in tests/fixtures/camera/ (docs/ADD-YOUR-CAMERA.md).");
    for (const check of HARDWARE_CHECKS) if (p.evidence?.checks?.[check] !== "passed") issues.push(`A verified profile needs a passed ${check} check on that body and firmware.`);
  } else if (order?.length || written.size) issues.push("Only a verified profile may mark properties written or carry a write order.");
  return issues;
}

/** A verified profile's fixture must be a supervised record for the same body and firmware, every check passed. */
export function evidenceIssues(profile: CameraProfile, fixture: unknown): string[] {
  if (!object(fixture)) return ["The hardware fixture must be a JSON object."];
  const issues: string[] = [];
  if (fixture.schema_version !== HARDWARE_EVIDENCE_SCHEMA) issues.push(`Fixture schema_version must be ${HARDWARE_EVIDENCE_SCHEMA}.`);
  if (fixture.profile !== profile.id || fixture.model !== profile.model || !profile.firmware.includes(String(fixture.firmware))) issues.push("Fixture body/firmware must match the profile.");
  if (fixture.supervised !== true || fixture.backup_before_write !== true) issues.push("The session must be supervised and start from a fresh backup.");
  const checks = object(fixture.checks) ? fixture.checks : {};
  for (const check of HARDWARE_CHECKS) {
    const c = checks[check];
    if (!object(c) || c.result !== "passed" || typeof c.detail !== "string" || !c.detail.trim()) issues.push(`Fixture check ${check} must be passed, with what was observed.`);
  }
  if (keys(fixture).some((k) => /serial|pairing|slots|hex|bytes/i.test(k))) issues.push("Fixtures hold outcomes only: no serials, pairing data or raw slot bytes.");
  return issues;
}
const keys = (v: unknown): string[] => Array.isArray(v) ? v.flatMap(keys) : object(v) ? Object.entries(v).flatMap(([k, x]) => [k, ...keys(x)]) : [];
