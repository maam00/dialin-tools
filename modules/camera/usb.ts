/** Explicit desktop USB operations. Importing this module never loads USB or contacts a camera. */
import { constants, existsSync, mkdirSync, openSync, closeSync, writeFileSync, fsyncSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { setTimeout as pause } from "node:timers/promises";
import { recipeToPresetValues, type Recipe } from "../../lib/fuji/recipe.js";
import { packPTPString, packU16, PTPReader } from "../../lib/fuji/vendor/binary.js";
import { MONOCHROME_SIMS } from "../../lib/fuji/vendor/enums.js";
import { translateUIToPresetProps, type PresetUIValues } from "../../lib/fuji/vendor/preset-translate.js";
import type { RawProp } from "../../lib/fuji/vendor/types.js";
import { inspectPreparation, type CameraPreparation } from "./index.js";
import { code, normalizedFirmware, profileStatus, verifiedWriters, writerProfile, X100VI_110, type CameraProfile } from "./profiles.js";

export type UsbIdentity = { model: string; firmware: string; serial: string; canEditSlots: boolean };
export type UsbSlot = { slot: number; name: string | null; props: RawProp[] };
export type UsbCameraPort = {
  connect(): Promise<void>; disconnect(): Promise<void>; readIdentity(): Promise<UsbIdentity>;
  readSlot(slot: number): Promise<UsbSlot>; readProp(id: number): Promise<RawProp | null>;
  writeSlot(slot: number, name: string, values: PresetUIValues, options: { base: RawProp[]; verify: boolean; profile?: CameraProfile }): Promise<{ rejected: string[]; mismatched: string[] }>;
};
export type UsbDependencies = { camera?: () => Promise<UsbCameraPort> };
// .native returns the on-disk case, so a differently cased path to this repository cannot pass as outside it on macOS/Windows.
const repoRoot = realpathSync.native(fileURLToPath(new URL("../../", import.meta.url)));
const hex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");
const hash = (text: string) => createHash("sha256").update(text).digest("hex");
// The writer's map (order, mono filter, slot block, readback equivalence) comes from the connected body's verified
// profile. Today that is only X100VI 1.10 (modules/camera/profiles.ts); it is also the default for direct callers.
/** Compare an intended write with its readback. Every property must match byte for byte, except a documented
 *  readback equivalence in the profile: on X100VI 1.10, Grain Off is written as 1 and read back as 6 or 7. */
export function readbackMatches(id: number, expectedHex: string, actualHex: string | undefined, profile: CameraProfile = X100VI_110): boolean {
  if (actualHex === expectedHex) return true;
  return actualHex !== undefined && profile.readback_equivalents.some((e) => code(e.code) === id && e.wrote === expectedHex && e.reads.includes(actualHex));
}

/** Preview/verification uses the actual shared encoder, with the fresh slot as its base. */
export function expectedUsbWrites(values: PresetUIValues, base: RawProp[], profile: CameraProfile = X100VI_110): RawProp[] {
  const encoded = new Map(translateUIToPresetProps(values, base).map((p) => [p.id, p]));
  encoded.set(0xd191, { id: 0xd191, name: "", bytes: packU16(0), value: 0 });
  const mono = MONOCHROME_SIMS.has(values.filmSimulation), skip = new Set(profile.mono_skip.map(code));
  return profile.write_order.map(code).filter((id) => encoded.has(id) && !(mono && skip.has(id))).map((id) => encoded.get(id)!);
}

export type UsbAccessOptions = { releaseMacCameraDaemon?: boolean };
export async function desktopUsbCamera(access: UsbAccessOptions = {}): Promise<UsbCameraPort> {
  const { FujiCamera } = await import("../../lib/fuji/camera.js");
  const camera = new FujiCamera();
  camera.onLog = () => {}; // Raw property/device details do not become public JSON stdout.
  // Explicit opt-in only (--release-macos-camera-daemon): never stop a system daemon implicitly.
  camera.usb.releaseMacCameraDaemon = access.releaseMacCameraDaemon === true;
  camera.usb.onMacCameraDaemonReleased = (pids) => console.error(`camera: stopped macOS ptpcamerad (${pids.length} process${pids.length === 1 ? "" : "es"}) to claim the camera; launchd restarts it.`);
  return guardedUsbPort(camera);
}
/** Low-level dependency seam: tests exercise cursor and acknowledgement refusal without USB. */
export type LowLevelUsbCamera = {
  connect(): Promise<void>; disconnect(): Promise<void>;
  usb: { command(op: number): Promise<{ code: number; data: Uint8Array }> };
  readSlot(slot: number): Promise<{ slot: number; name: string; props: RawProp[] }>;
  selectSlot(slot: number): Promise<void>; readProp(id: number): Promise<RawProp | null>;
  writeProp(id: number, bytes: Uint8Array): Promise<boolean>;
};
export function guardedUsbPort(camera: LowLevelUsbCamera): UsbCameraPort {
  async function requireCursor(slot: number) {
    const selected = await camera.readProp(0xd18c);
    if (!selected || selected.value !== slot) throw new Error("The selected camera slot could not be verified. No recipe was written.");
  }
  return {
    connect: () => camera.connect(), disconnect: () => camera.disconnect(),
    async readIdentity() {
      const result = await camera.usb.command(0x1001); // GetDeviceInfo, no write.
      if (result.code !== 0x2001 || !result.data.length) throw new Error("Camera identity read failed.");
      const r = new PTPReader(result.data);
      r.u16(); r.u32(); r.u16(); r.str(); r.u16(); r.u16array(); r.u16array();
      const props = r.u16array(); r.u16array(); r.u16array(); r.str();
      const model = r.str(), firmware = r.str(), serial = r.str();
      return { model, firmware, serial, canEditSlots: props.includes(0xd18c) };
    },
    async readSlot(slot) {
      const snapshot = await camera.readSlot(slot);
      await requireCursor(slot);
      // The existing lower-level reader replaces missing names with ""; keep missing distinguishable here.
      const name = await camera.readProp(0xd18d);
      return { ...snapshot, name: typeof name?.value === "string" ? name.value : null };
    },
    readProp: (id) => camera.readProp(id),
    async writeSlot(slot, name, values, options) {
      await camera.selectSlot(slot);
      await requireCursor(slot); // An accepted select command alone does not prove which slot is active.
      if (!await camera.writeProp(0xd18d, packPTPString(name))) throw new Error("The camera refused the recipe name.");
      for (const prop of expectedUsbWrites(values, options.base, options.profile)) {
        await pause(20); // Preserve the existing writer's X100VI inter-property gap.
        if (!await camera.writeProp(prop.id, prop.bytes)) {
          // No DR downgrade and no continuation after refusal. The caller records a partial attempt.
          return { rejected: [`Required property 0x${prop.id.toString(16)} was refused.`], mismatched: [] };
        }
      }
      // applyUsbPreparation performs strict independent and final snapshot checks.
      return { rejected: [], mismatched: [] };
    },
  };
}
/** Only a verified profile for the observed model AND the exact declared/observed firmware may write. */
function requireIdentity(id: UsbIdentity, expectedFirmware?: string): CameraProfile {
  const firmware = normalizedFirmware(id.firmware), writer = writerProfile(id.model, firmware);
  const allowed = profileStatus(id.model, firmware).verified_firmware;
  if (!allowed.length) throw new Error(`Refused: the connected camera has no verified writer profile (verified: ${verifiedWriters()}). No recipe was written. To help add it, run \`camera report\` (docs/ADD-YOUR-CAMERA.md).`);
  if (!writer || firmware !== (expectedFirmware ?? firmware)) throw new Error(`Refused: declared and observed firmware must both be a verified profile for this body (${allowed.join(", ")}). No recipe was written.`);
  if (!id.serial.trim() || !id.canEditSlots) throw new Error("Refused: camera identity or custom-slot mode could not be established. No recipe was written.");
  return writer;
}
const sameIdentity = (a: UsbIdentity, b: UsbIdentity) => profileStatus(a.model, a.firmware).profile === profileStatus(b.model, b.firmware).profile
  && normalizedFirmware(a.firmware) === normalizedFirmware(b.firmware) && a.serial === b.serial && b.canEditSlots;
function validateSnapshot(s: UsbSlot, profile: CameraProfile) {
  if (s.name === null || !Array.isArray(s.props) || new Set(s.props.map((p) => p.id)).size !== s.props.length) throw new Error(`C${s.slot} could not be completely backed up. No recipe was written.`);
  const present = new Set(s.props.filter((p) => p.bytes.length >= 2 && typeof p.value === "number").map((p) => p.id));
  // Include inactive memories and unrelated slot controls, not only the old look's writable fields.
  // The profile's block excludes D1A5 (live image size), exactly as in the core reader.
  if (!profile.properties.every((p) => present.has(code(p.code)))) throw new Error(`C${s.slot} has missing settings needed for recovery. No recipe was written.`);
}
async function readSlots(port: UsbCameraPort, profile: CameraProfile): Promise<UsbSlot[]> {
  const slots: UsbSlot[] = [];
  for (let slot = 1; slot <= profile.slots; slot++) {
    const s = await port.readSlot(slot);
    if (s.slot !== slot) throw new Error("Camera returned an unexpected slot identity.");
    validateSnapshot(s, profile); slots.push(s);
  }
  return slots;
}
const serializedSlots = (slots: UsbSlot[]) => slots.map((s) => ({ slot: s.slot, name: s.name,
  props: s.props.map((p) => ({ id: p.id, hex: hex(p.bytes) })).sort((a, b) => a.id - b.id) }));
function targetSnapshotIssues(before: UsbSlot, after: UsbSlot, recipe: Recipe, profile: CameraProfile): string[] {
  if (after.slot !== before.slot) throw new Error("Unexpected target-slot identity.");
  validateSnapshot(after, profile);
  const issues: string[] = [], slot = before.slot;
  const expected = new Map(expectedUsbWrites(recipeToPresetValues(recipe), before.props, profile).map((p) => [p.id, hex(p.bytes)]));
  const oldProps = new Map(before.props.map((p) => [p.id, hex(p.bytes)]));
  const newProps = new Map(after.props.map((p) => [p.id, hex(p.bytes)]));
  if (after.name !== recipe.name) issues.push(`C${slot}: target name snapshot differs.`);
  for (const [id, bytes] of expected) {
    if (!readbackMatches(id, bytes, newProps.get(id), profile)) issues.push(`C${slot}: required property 0x${id.toString(16)} snapshot differs.`);
  }
  // Name and explicit encoder writes are the entire mutation allowlist. Preserve everything else,
  // including inactive controls, unknown extras, and the presence/absence of each non-write field.
  for (const id of new Set([...oldProps.keys(), ...newProps.keys()])) {
    if (!expected.has(id) && oldProps.get(id) !== newProps.get(id)) {
      issues.push(`C${slot}: non-write property 0x${id.toString(16)} changed, appeared or disappeared. Further targets must stop.`);
    }
  }
  return issues;
}

/** Refuse overwrites and in-repository private backups; write, fsync, and read back before permitting a write. */
const insideRepo = (directory: string) => {
  const rel = relative(repoRoot, directory);
  // "..backups" is a child of the repository, not a parent-relative path.
  return !(rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel));
};
export function privatePath(path: string): string {
  const target = resolve(path);
  if (existsSync(target)) throw new Error("Backup destination already exists; choose a new private file.");
  // Resolve the nearest existing ancestor first, so a refused destination creates no directories.
  let existing = dirname(target);
  const missing: string[] = [];
  while (!existsSync(existing) && dirname(existing) !== existing) { missing.unshift(basename(existing)); existing = dirname(existing); }
  const planned = join(realpathSync.native(existing), ...missing);
  if (insideRepo(planned)) throw new Error("Keep raw camera backups outside the repository, in a private directory.");
  mkdirSync(planned, { recursive: true, mode: 0o700 });
  const parent = realpathSync.native(planned);
  if (insideRepo(parent)) throw new Error("Keep raw camera backups outside the repository, in a private directory.");
  return join(parent, basename(target));
}
function saveBackup(path: string, identity: UsbIdentity, slots: UsbSlot[]): { path: string; sha256: string } {
  const target = privatePath(path);
  const content = JSON.stringify({ schema_version: "dialin.usb-slot-backup.v1", model: identity.model,
    firmware: identity.firmware, serial: identity.serial, at: new Date().toISOString(), slots: serializedSlots(slots) }, null, 2) + "\n";
  const fd = openSync(target, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
  try { writeFileSync(fd, content, "utf8"); fsyncSync(fd); } finally { closeSync(fd); }
  const directory = openSync(dirname(target), constants.O_RDONLY);
  try { fsyncSync(directory); } finally { closeSync(directory); }
  if (readFileSync(target, "utf8") !== content) throw new Error("Durable backup verification failed. No recipe was written.");
  return { path: target, sha256: hash(content) };
}

export async function inspectUsb(options: { operation: "info" | "backup"; backupPath?: string } & UsbAccessOptions, deps: UsbDependencies = {}) {
  if (options.operation === "backup" && !options.backupPath) throw new Error("backup requires an explicit private --backup file outside the repository.");
  if (options.backupPath) privatePath(options.backupPath); // Refuse unsafe paths before opening USB.
  const port = await (deps.camera ?? (() => desktopUsbCamera({ releaseMacCameraDaemon: options.releaseMacCameraDaemon })))();
  try {
    await port.connect();
    const identity = await port.readIdentity();
    const profile = requireIdentity(identity), body = { model: profile.model, firmware: normalizedFirmware(identity.firmware) };
    if (options.operation === "info") return { operation: "usb_info", ...body, custom_slots_available: true, recipe_writes: 0 };
    const slots = await readSlots(port, profile);
    if (!sameIdentity(identity, await port.readIdentity())) throw new Error("Camera identity changed during backup. No recipe was written.");
    const backup = saveBackup(options.backupPath!, identity, slots);
    return { operation: "usb_backup", ...body, slots: slots.length, backup, recipe_writes: 0 };
  } finally { await port.disconnect().catch(() => {}); }
}
export type UsbApplyResult = {
  operation: "usb_apply"; result: "verified_current_session" | "not_verified";
  backup: { path: string; sha256: string }; slots_attempted: number[];
  issues: string[]; protected_slots_checked: boolean;
  restart_check: "NOT_RUN"; photographic_quality: "NOT_EVALUATED";
};

/** Explicitly invoked only. A JSON artifact cannot authorize writes. */
export async function applyUsbPreparation(input: unknown, options: { confirmWrite: boolean; backupPath: string } & UsbAccessOptions, deps: UsbDependencies = {}): Promise<UsbApplyResult> {
  if (options.confirmWrite !== true) throw new Error("USB application requires an explicit --confirm-write invocation; preparation alone authorizes nothing.");
  const preparation: CameraPreparation = inspectPreparation(input);
  if (!preparation.validation.valid || !preparation.placements.length || preparation.readiness.usb.state === "blocked") throw new Error("Preparation is invalid or outside the supported camera/firmware profile. No camera contacted.");
  if (preparation.selected_transport !== "usb") throw new Error("Prepare explicitly for --transport usb before USB application.");
  if (!options.backupPath) throw new Error("A new private --backup file is required before writing.");
  privatePath(options.backupPath);
  const port = await (deps.camera ?? (() => desktopUsbCamera({ releaseMacCameraDaemon: options.releaseMacCameraDaemon })))();
  try {
    await port.connect();
    const identity = await port.readIdentity();
    const profile = requireIdentity(identity, preparation.camera.firmware!);
    // The recipes were encoded for the declared body: another verified body never receives them.
    if (profileStatus(preparation.camera.model, preparation.camera.firmware).profile !== profile) throw new Error("Refused: the declared camera and the connected camera are different bodies. No recipe was written.");
    const before = await readSlots(port, profile);
    if (!sameIdentity(identity, await port.readIdentity())) throw new Error("Camera identity changed before writing. No recipe was written.");
    const backup = saveBackup(options.backupPath, identity, before);
    const result: UsbApplyResult = { operation: "usb_apply", result: "not_verified", backup, slots_attempted: [], issues: [], protected_slots_checked: false,
      restart_check: "NOT_RUN", photographic_quality: "NOT_EVALUATED" };
    try {
      for (const { slot, recipe } of preparation.placements) {
        const base = before.find((s) => s.slot === slot)!;
        const values = recipeToPresetValues(recipe);
        result.slots_attempted.push(slot); // An exception may follow a partial write; never report nothing changed.
        const report = await port.writeSlot(slot, recipe.name, values, { base: base.props, verify: true, profile });
        if (report.rejected.length || report.mismatched.length) result.issues.push(`C${slot}: the existing writer reported a refusal, adjustment, or mismatch.`);
        // Existing low-level verification skips missing values. Require every intended field ourselves.
        for (const expected of expectedUsbWrites(values, base.props, profile)) {
          const actual = await port.readProp(expected.id);
          if (!actual || !readbackMatches(expected.id, hex(expected.bytes), hex(actual.bytes), profile)) result.issues.push(`C${slot}: required property 0x${expected.id.toString(16)} is missing or differs.`);
        }
        const name = await port.readProp(0xd18d);
        if (!name || name.value !== recipe.name) result.issues.push(`C${slot}: name readback is missing or differs.`);
        result.issues.push(...targetSnapshotIssues(base, await port.readSlot(slot), recipe, profile));
        // A collateral change must stop the next target, not merely appear in the final report.
        for (const protectedSlot of preparation.protected_slots) {
          const current = await port.readSlot(protectedSlot);
          if (current.slot !== protectedSlot) throw new Error("Unexpected protected-slot identity.");
          validateSnapshot(current, profile);
          if (JSON.stringify(serializedSlots([current])) !== JSON.stringify(serializedSlots([before.find((s) => s.slot === protectedSlot)!]))) {
            result.issues.push(`Protected C${protectedSlot} changed. Further targets were stopped; retain the backup.`);
          }
        }
        if (result.issues.length) break; // Do not start another slot after a partial/unverified result.
      }
      const after = await readSlots(port, profile);
      for (const { slot, recipe } of preparation.placements.filter((p) => result.slots_attempted.includes(p.slot))) {
        const current = after.find((s) => s.slot === slot)!;
        const beforeSlot = before.find((s) => s.slot === slot)!;
        result.issues.push(...targetSnapshotIssues(beforeSlot, current, recipe, profile).map((message) => `Final check: ${message}`));
      }
      for (const slot of preparation.protected_slots) {
        const a = serializedSlots([before.find((s) => s.slot === slot)!]);
        const b = serializedSlots([after.find((s) => s.slot === slot)!]);
        if (JSON.stringify(a) !== JSON.stringify(b)) result.issues.push(`Protected C${slot} changed. Keep the backup and inspect the camera before further writes.`);
      }
      result.protected_slots_checked = true;
      if (!sameIdentity(identity, await port.readIdentity())) result.issues.push("Camera identity changed during verification.");
      if (!result.issues.length && result.slots_attempted.length === preparation.placements.length) result.result = "verified_current_session";
    } catch {
      result.issues.push("The operation stopped after writing may have begun. Camera state is not verified; the durable backup is retained. Do not retry blindly.");
    }
    return result;
  } finally { await port.disconnect().catch(() => {}); }
}
