/** `camera report`: a read-only USB description of a connected Fujifilm body, safe to attach to a public issue.
 *  It never writes a recipe, name or setting and never backs up or restores. Every command goes through
 *  readOnlyLink: PTP reads, plus the slot edit cursor (D18C) set to C1–C7. Reading C1–Cn needs that cursor on each slot
 *  (there is no other per-slot read); the reads are ordered so the last one returns it to where it was, and the first
 *  slot is read again to show the moves changed nothing. --current-slot-only moves nothing. No USB import here. */
import { createHash } from "node:crypto";
import { basename } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import { packU16, parsePTPStringRaw, PTPReader } from "../../lib/fuji/vendor/binary.js";
import { PTPOp, PTPResp, respName } from "../../lib/fuji/vendor/constants.js";
import { accepts, CAMERA_PROFILE_SCHEMA, HARDWARE_CHECKS, hex4, normalizedFirmware, profileStatus, validateProfile, WIRE_NAMES,
  X100VI_110, type CameraProfile, type SlotProperty, type WriteStatus } from "./profiles.js";

export const CAMERA_REPORT_SCHEMA = "dialin.camera-report.v1";
export const CAMERA_PROFILE_DRAFT_SCHEMA = "dialin.camera-profile-draft.v1";
const CURSOR = 0xd18c, NAME = 0xd18d, USB_MODE = 0xd16e, COMPAT = [0xd186, 0xd187];
// X100VI's slot block is D18E–D1A4; later codes to D1AF are read when a body advertises them. D1A5 is LIVE image size.
const inBlock = (id: number) => id >= 0xd18e && id <= 0xd1af && id !== 0xd1a5;
const READS = new Set<number>([PTPOp.OpenSession, PTPOp.CloseSession, PTPOp.GetDeviceInfo, PTPOp.GetDevicePropDesc, PTPOp.GetDevicePropValue]);
const OP_NAMES: Record<number, string> = Object.fromEntries(Object.entries(PTPOp).map(([k, v]) => [v, k]));

/** The transport surface the report needs; lib/fuji/usb.ts UsbPtp satisfies it. */
export type PtpLink = {
  open(): Promise<void>; close(): Promise<void>; resetTransactions(): void;
  command(op: number, params?: number[]): Promise<{ code: number; params: number[]; data: Uint8Array }>;
  commandWithData(op: number, params: number[], payload: Uint8Array): Promise<{ code: number }>;
};
export type ReportOptions = { includeSlotNames?: boolean; currentSlotOnly?: boolean; releaseMacCameraDaemon?: boolean;
  /** Per command; an unanswered command stops the report (the USB stream can't be trusted after it). */
  timeoutMs?: number; settleMs?: number };
export type ReportDependencies = { link?: () => Promise<PtpLink> };
export type ReportProp = { code: string; bytes?: number; hex?: string; u16?: number; error?: string; withheld?: string };
export type ReportSlot = { slot: number | null; name?: string | null; cursor_ok: boolean; props: ReportProp[] };
export type ReportDescriptor = { code: string; datatype: string; writable: boolean; enum?: number[]; range?: [number, number, number] };
export type CameraReport = {
  schema_version: typeof CAMERA_REPORT_SCHEMA; tool: "dialin camera report";
  camera: { manufacturer: string; model: string; firmware: string; firmware_normalized: string | null; usb_mode: number | null; compatibility_code: string | null };
  dialin: { write_status: WriteStatus; profile: string | null; writes: string };
  ptp: { standard_version: number; vendor_extension_id: number; vendor_extension_version: number; functional_mode: number;
    operations: string[]; events: string[]; device_properties: string[]; capture_formats: string[]; image_formats: string[] };
  slots: { editing_advertised: boolean; mode: "all_slots" | "current_slot_only"; names_included: boolean; block: string[];
    count_read: number; items: ReportSlot[]; descriptors: ReportDescriptor[]; descriptors_refused: Record<string, number>; notes: string[] };
  cursor: { property: "0xd18c"; before: number | null; after: number | null; moves: number; returned: boolean | null;
    first_slot_unchanged: boolean | null; note: string };
  camera_operations: { sent: Record<string, number>; recipe_writes: 0; setting_writes: 0; backup: "NOT_RUN"; restore: "NOT_RUN" };
  privacy: { omitted: string[]; values_read: string };
  errors: { stage: string; error: string }[];
  complete: boolean;
};

const message = (e: unknown) => e instanceof Error ? e.message : String(e);
const u16 = (d: Uint8Array) => d[0] | (d[1] << 8);
function timed<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${what}: no answer within ${ms} ms`)), ms);
    promise.then((v) => { clearTimeout(timer); resolve(v); }, (e) => { clearTimeout(timer); reject(e); });
  });
}

/** The only path from report code to the camera: read operations, and the D18C edit cursor set to C1–C7. */
export function readOnlyLink(link: PtpLink, timeoutMs = 10_000) {
  const sent: Record<string, number> = {};
  const count = (k: string) => { sent[k] = (sent[k] ?? 0) + 1; };
  return {
    sent,
    read(op: number, params: number[] = []) {
      if (!READS.has(op)) return Promise.reject(new Error(`camera report refused PTP operation ${hex4(op)}: it only reads.`));
      count(OP_NAMES[op]);
      return timed(link.command(op, params), timeoutMs, `${OP_NAMES[op]}${op === PTPOp.GetDevicePropValue || op === PTPOp.GetDevicePropDesc ? ` ${hex4(params[0])}` : ""}`);
    },
    moveCursor(slot: number) {
      if (!Number.isInteger(slot) || slot < 1 || slot > 7) return Promise.reject(new Error("camera report refused an edit-cursor value outside C1–C7."));
      count("SetDevicePropValue 0xd18c (slot edit cursor)");
      return timed(link.commandWithData(PTPOp.SetDevicePropValue, [CURSOR], packU16(slot)), timeoutMs, `edit cursor to C${slot}`);
    },
  };
}

export function parseDeviceInfo(data: Uint8Array) {
  const r = new PTPReader(data);
  const standard = r.u16(), vendorId = r.u32(), vendorVersion = r.u16(); r.str(); const mode = r.u16();
  const operations = r.u16array(), events = r.u16array(), properties = r.u16array(), capture = r.u16array(), image = r.u16array();
  const manufacturer = r.str(), model = r.str(), firmware = r.str(), serial = r.remaining ? r.str() : "";
  return { standard, vendorId, vendorVersion, mode, operations, events, properties, capture, image, manufacturer, model, firmware, serial };
}
function descriptor(id: number, data: Uint8Array): ReportDescriptor | null {
  try {
    const r = new PTPReader(data); r.u16();
    const type = r.u16(), writable = r.u8() === 1;
    if (type < 1 || type > 6) return null;
    r.valueByType(type); r.valueByType(type); // factory default and current value: not recorded
    const form = r.u8(), base = { code: hex4(id), datatype: hex4(type), writable };
    if (form === 1) return { ...base, range: [Number(r.valueByType(type)), Number(r.valueByType(type)), Number(r.valueByType(type))] };
    if (form === 2) return { ...base, enum: Array.from({ length: r.u16() }, () => Number(r.valueByType(type))) };
    return base;
  } catch { return null; }
}
const looksLikeText = (d: Uint8Array) => d.length >= 3 && d[0] >= 1 && 1 + 2 * d[0] === d.length;
function entry(id: number, data: Uint8Array, names: boolean): ReportProp {
  const base = { code: hex4(id), bytes: data.length };
  if (data.length > 32) return { ...base, withheld: "longer than 32 bytes" };
  if (!names && looksLikeText(data)) return { ...base, withheld: "text; shared only with --include-slot-names" };
  return { ...base, hex: Buffer.from(data).toString("hex"), ...(data.length === 2 ? { u16: u16(data) } : {}) };
}

/** Anything identifying in the serialized report: the serial (as text or as hex bytes) or a MAC-like address. */
export function privacyProblems(json: string, serial: string): string[] {
  const problems: string[] = [], s = serial.trim(), text = json.toLowerCase();
  if (s.length >= 6 && [s, Buffer.from(s, "latin1").toString("hex"), Buffer.from(s, "utf16le").toString("hex")].some((v) => text.includes(v.toLowerCase()))) problems.push("serial number");
  if (/\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b/i.test(json)) problems.push("MAC-like address");
  return problems;
}

async function desktopLink(releaseMacCameraDaemon: boolean): Promise<PtpLink> {
  const { UsbPtp } = await import("../../lib/fuji/usb.js");
  const usb = new UsbPtp();
  usb.releaseMacCameraDaemon = releaseMacCameraDaemon; // Explicit opt-in only, exactly as camera usb.
  usb.onMacCameraDaemonReleased = (pids) => console.error(`camera: stopped macOS ptpcamerad (${pids.length} process${pids.length === 1 ? "" : "es"}) to claim the camera; launchd restarts it.`);
  return usb;
}

/** Read-only. Throws only when nothing could be read (no camera, claim refused, no device info) or on a privacy hit. */
export async function cameraReport(options: ReportOptions = {}, deps: ReportDependencies = {}): Promise<CameraReport> {
  const link = await (deps.link ?? (() => desktopLink(options.releaseMacCameraDaemon === true)))();
  const ro = readOnlyLink(link, options.timeoutMs ?? 10_000), settle = options.settleMs ?? 100, names = options.includeSlotNames === true;
  const errors: CameraReport["errors"] = [], notes: string[] = [], items: ReportSlot[] = [], descriptors: ReportDescriptor[] = [];
  const refused: Record<string, number> = {};
  const cursor = { before: null as number | null, after: null as number | null, moves: 0, current: null as number | null, returned: null as boolean | null, same: null as boolean | null };
  let info: ReturnType<typeof parseDeviceInfo> | null = null, stage = "connect", broken = false, usbMode: number | null = null, compat: string | null = null;
  let block: number[] = [];
  const value = async (id: number): Promise<{ data: Uint8Array } | { error: string }> => {
    const r = await ro.read(PTPOp.GetDevicePropValue, [id]);
    return r.code === PTPResp.OK && r.data.length ? { data: r.data } : { error: r.code === PTPResp.OK ? "empty value" : respName(r.code) };
  };
  const cursorAt = async () => { const v = await value(CURSOR); return "data" in v && v.data.length === 2 ? u16(v.data) : null; };
  const readSlot = async (slot: number | null): Promise<ReportSlot> => {
    stage = slot === null ? "read current slot" : `read C${slot}`;
    const props: ReportProp[] = [];
    for (const id of block) { const v = await value(id); props.push("data" in v ? entry(id, v.data, names) : { code: hex4(id), error: v.error }); }
    const item: ReportSlot = { slot, cursor_ok: false, props };
    if (names) { const n = await value(NAME); item.name = "data" in n ? parsePTPStringRaw(n.data) : null; }
    item.cursor_ok = slot !== null && (await cursorAt()) === slot;
    return item;
  };
  const select = async (slot: number): Promise<"ok" | "refused" | "unexpected"> => {
    stage = `edit cursor to C${slot}`;
    const r = await ro.moveCursor(slot);
    cursor.moves++;
    if (settle) await pause(settle); // D18C settles 50–100 ms (docs/FUJI_PROTOCOL.md §4.1)
    cursor.current = await cursorAt();
    if (r.code !== PTPResp.OK) { notes.push(`C${slot}: the camera refused the edit cursor (${respName(r.code)}).`); return "refused"; }
    return cursor.current === slot ? "ok" : "unexpected";
  };

  await link.open(); // A refused claim or a missing camera throws here, before anything was sent.
  try {
    stage = "open session"; link.resetTransactions();
    let { code } = await ro.read(PTPOp.OpenSession, [1]);
    if (code === PTPResp.SessionAlreadyOpen) { await ro.read(PTPOp.CloseSession); link.resetTransactions(); ({ code } = await ro.read(PTPOp.OpenSession, [1])); }
    if (code !== PTPResp.OK) throw new Error(`OpenSession failed: ${respName(code)}`);
    stage = "device info";
    const di = await ro.read(PTPOp.GetDeviceInfo);
    if (di.code !== PTPResp.OK || !di.data.length) throw new Error(`GetDeviceInfo failed: ${respName(di.code)}`);
    info = parseDeviceInfo(di.data);
    const advertised = new Set(info.properties), max = Math.min(7, profileStatus(info.model, info.firmware).body?.slots ?? 7);
    stage = "USB mode";
    const mode = await value(USB_MODE);
    usbMode = "data" in mode && mode.data.length === 2 ? u16(mode.data) : null;
    for (const id of COMPAT.filter((c) => advertised.has(c))) {
      const v = await value(id), text = "data" in v ? parsePTPStringRaw(v.data) : "";
      if (/^[A-Za-z0-9 .+-]{1,24}_[0-9A-Fa-f]{4}$/.test(text)) { compat = text; break; } // "<Model>_<fw>"; anything else is withheld
    }
    block = [...advertised].filter(inBlock).sort((a, b) => a - b);
    if (info.operations.includes(PTPOp.GetDevicePropDesc) && advertised.has(CURSOR)) {
      stage = "property descriptors";
      for (const id of [CURSOR, ...block]) { // Never D18D: its descriptor carries the current slot name.
        const r = await ro.read(PTPOp.GetDevicePropDesc, [id]);
        const d = r.code === PTPResp.OK && r.data.length ? descriptor(id, r.data) : null;
        if (d) descriptors.push(d); else { const why = r.code === PTPResp.OK ? "unparsed" : respName(r.code); refused[why] = (refused[why] ?? 0) + 1; }
      }
    }
    if (!advertised.has(CURSOR)) notes.push("The camera does not advertise custom-slot editing (0xd18c). Set CONNECTION MODE to USB RAW CONV./BACKUP RESTORE and run the report again.");
    else {
      stage = "edit cursor"; cursor.before = cursor.current = await cursorAt();
      const k = cursor.before;
      if (k === null || k < 1 || k > max) {
        notes.push(`The edit cursor read ${k ?? "nothing"}, outside C1–C${max}. Only the block at the current cursor was read; the cursor was not moved.`);
        items.push(await readSlot(null));
      } else {
        const first = await readSlot(k);
        items.push(first);
        if (options.currentSlotOnly) notes.push(`--current-slot-only: read C${k} only; the edit cursor was not moved.`);
        else {
          // Rotate k+1…max, then 1…k−1; stop going up at the first refused slot (a 4-slot body refuses C5).
          let stop = false;
          for (let s = k + 1; s <= max && !stop; s++) {
            const r = await select(s);
            if (r === "ok") items.push(await readSlot(s));
            else { if (r === "unexpected") stop = true; else notes.push(`C${s} could not be selected; read as the end of this body's slots.`); break; }
          }
          for (let s = 1; s < k && !stop; s++) {
            const r = await select(s);
            if (r === "ok") items.push(await readSlot(s)); else stop = true;
          }
          if (stop) notes.push(`The edit cursor did not land where asked (it reads ${cursor.current ?? "nothing"}); further slots were not read.`);
          if (cursor.moves) {
            const back = await select(k);
            cursor.returned = back === "ok";
            if (back === "ok") { const again = await readSlot(k); cursor.same = JSON.stringify(again.props) === JSON.stringify(first.props); }
            if (cursor.same === false) notes.push(`C${k} read differently before and after the cursor moves. Please mention this in the issue.`);
          }
        }
      }
      stage = "final cursor read"; cursor.after = await cursorAt();
      if (cursor.moves) cursor.returned = cursor.after === k;
    }
  } catch (error) {
    broken = true; // A refused property is recorded and skipped; an exception or silence ends the session.
    errors.push({ stage, error: message(error) });
  } finally {
    if (!broken) await ro.read(PTPOp.CloseSession).catch(() => {}); // after a timeout the stream may be out of step: just release
    await link.close().catch(() => {});
  }
  if (!info) throw new Error(`No report: ${errors.map((e) => `${e.stage}: ${e.error}`).join("; ") || "the camera sent no device information"}.`);

  const status = profileStatus(info.model, info.firmware), slotItems = items.sort((a, b) => (a.slot ?? 0) - (b.slot ?? 0));
  const hexes = (codes: number[]) => [...codes].sort((a, b) => a - b).map(hex4);
  const report: CameraReport = {
    schema_version: CAMERA_REPORT_SCHEMA, tool: "dialin camera report",
    camera: { manufacturer: info.manufacturer, model: info.model, firmware: info.firmware, firmware_normalized: normalizedFirmware(info.firmware), usb_mode: usbMode, compatibility_code: compat },
    dialin: { write_status: status.status, profile: status.profile?.id ?? null,
      writes: status.status === "verified" ? "Supported for this exact body and firmware through camera usb apply. This report wrote nothing."
        : `Unsupported. Dial In writes only to verified profiles; this ${status.status === "read_only" ? "firmware is not verified" : "body has no profile"}. See docs/ADD-YOUR-CAMERA.md.` },
    ptp: { standard_version: info.standard, vendor_extension_id: info.vendorId, vendor_extension_version: info.vendorVersion, functional_mode: info.mode,
      operations: hexes(info.operations), events: hexes(info.events), device_properties: hexes(info.properties),
      capture_formats: hexes(info.capture), image_formats: hexes(info.image) },
    slots: { editing_advertised: info.properties.includes(CURSOR), mode: options.currentSlotOnly ? "current_slot_only" : "all_slots",
      names_included: names, block: block.map(hex4), count_read: slotItems.filter((i) => i.slot !== null).length, items: slotItems,
      descriptors, descriptors_refused: refused, notes },
    cursor: { property: "0xd18c", before: cursor.before, after: broken ? null : cursor.after, moves: cursor.moves, returned: broken && cursor.moves ? false : cursor.returned,
      first_slot_unchanged: cursor.same,
      note: "D18C is the slot edit cursor: it picks which custom slot USB reads and edits, not the bank you shoot with, and moving it writes no recipe value. Reading C1–Cn needs it on each slot; the report puts it back where it was." },
    camera_operations: { sent: ro.sent, recipe_writes: 0, setting_writes: 0, backup: "NOT_RUN", restore: "NOT_RUN" },
    privacy: { omitted: ["serial number", "Y-number", "MAC address", "owner name", "copyright", ...(names ? [] : ["slot names"])],
      values_read: "Only the USB mode, the edit cursor, the <model>_<firmware> compatibility code and the custom-slot block were read; no other device property value." },
    errors, complete: !broken,
  };
  const leaks = privacyProblems(JSON.stringify(report), info.serial);
  if (leaks.length) throw new Error(`Privacy check failed (${leaks.join(", ")}); no report was produced.${names ? " Try without --include-slot-names." : ""}`);
  return report;
}

/** The stderr summary. The JSON stays the contract. */
export function reportSummary(r: CameraReport, outPath?: string): string[] {
  const body = `${r.camera.model || "camera"} ${r.camera.firmware}`.trim(), file = outPath ? basename(outPath) : "the JSON from stdout (save it as report.json)";
  const untouched = !r.cursor.moves || r.cursor.returned === true;
  const lines = [r.complete
    ? `Your ${body} report is ready; ${untouched ? "nothing on the camera was changed" : "no recipe, name or setting was written"}; attach ${file} to a 'Camera report' issue.`
    : `Your ${body} report is partial (${r.errors.map((e) => `${e.stage}: ${e.error}`).join("; ")}); no recipe, name or setting was written. You can still attach ${file}; say it is partial.`];
  if (r.cursor.moves && r.cursor.returned) lines.push(`  To read each slot the edit cursor moved ${r.cursor.moves} times and is back on C${r.cursor.before}; it doesn't change recipes or the bank you shoot with.`);
  if (r.cursor.moves && !r.cursor.returned) lines.push(`  The slot edit cursor was left on ${r.cursor.after ? `C${r.cursor.after}` : "an unknown slot"} (it was C${r.cursor.before}). It only picks which slot USB tools edit; recipes and your shooting bank are unchanged.`);
  for (const note of r.slots.notes) lines.push(`  ${note}`);
  lines.push(r.dialin.write_status === "verified" ? `  The ${body} is Dial In's verified writer profile; this report still wrote nothing.`
    : `  Dial In does not write recipes to the ${body}: writes stay unsupported (status ${r.dialin.write_status}) until a supervised test on this body passes (docs/ADD-YOUR-CAMERA.md).`);
  lines.push(`  Not included: serial number, Y-number, MAC address, owner and copyright text${r.slots.names_included ? "" : ", slot names"}. Open the file and check it before posting.`);
  return lines;
}

// ---------- maintainers: report → draft read-only profile + diff against the X100VI map ----------

const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const CODE = /^0x[0-9a-f]{4}$/;
/** A submitted report is untrusted data: check its shape before using any of it. */
export function readReport(input: unknown): CameraReport {
  const fail = (why: string): never => { throw new Error(`Not a usable ${CAMERA_REPORT_SCHEMA} report: ${why}.`); };
  if (!object(input) || input.schema_version !== CAMERA_REPORT_SCHEMA) fail("schema_version");
  const r = input as Record<string, any>;
  if (!object(r.camera) || typeof r.camera.model !== "string" || !/^[\x20-\x7e]{1,40}$/.test(r.camera.model) || typeof r.camera.firmware !== "string" || r.camera.firmware.length > 24) fail("camera model/firmware");
  if (!object(r.ptp) || !["operations", "device_properties"].every((k) => Array.isArray(r.ptp[k]) && r.ptp[k].every((c: unknown) => typeof c === "string" && CODE.test(c)))) fail("ptp code lists");
  if (!object(r.slots) || !Array.isArray(r.slots.items) || r.slots.items.length > 8) fail("slots");
  for (const item of r.slots.items) {
    if (!object(item) || !(item.slot === null || (typeof item.slot === "number" && Number.isInteger(item.slot) && item.slot >= 1 && item.slot <= 7)) || !Array.isArray(item.props) || item.props.length > 64) fail("slot item");
    for (const p of item.props) if (!object(p) || typeof p.code !== "string" || !CODE.test(p.code) || (p.hex !== undefined && !(typeof p.hex === "string" && /^[0-9a-f]{0,64}$/.test(p.hex)))) fail("slot property");
  }
  if (r.slots.descriptors !== undefined && !Array.isArray(r.slots.descriptors)) fail("descriptors");
  return input as unknown as CameraReport;
}
const raw = (hexText: string, signed?: boolean) => { const v = Number.parseInt(hexText.slice(2, 4) + hexText.slice(0, 2), 16); return signed && v >= 0x8000 ? v - 0x10000 : v; };
const unique = (xs: number[]) => [...new Set(xs)].sort((a, b) => a - b);

/** Draft profile (always read_only) plus what differs from the verified X100VI 1.10 map. Never enables writes. */
export function draftProfile(input: unknown, reference: CameraProfile = X100VI_110) {
  const report = readReport(input), refProps = new Map(reference.properties.map((p) => [p.code, p]));
  type Seen = { lengths: Set<number>; values: { slot: number | null; v: number }[]; errors: Map<string, (number | null)[]> };
  const seen = new Map<string, Seen>();
  for (const item of report.slots.items) for (const p of item.props) {
    const o: Seen = seen.get(p.code) ?? { lengths: new Set(), values: [], errors: new Map() };
    seen.set(p.code, o);
    if (p.bytes !== undefined) o.lengths.add(p.bytes);
    if (p.hex?.length === 4) o.values.push({ slot: item.slot, v: raw(p.hex, refProps.get(p.code)?.signed) });
    if (p.error) o.errors.set(p.error, [...(o.errors.get(p.error) ?? []), item.slot]);
  }
  const enums = new Map((report.slots.descriptors ?? []).filter((d) => d?.enum && CODE.test(d.code)).map((d) => [d.code, d.enum!]));
  const properties: SlotProperty[] = [...seen.keys()].sort().map((c) => {
    const known = refProps.get(c);
    return { code: c, field: known?.field ?? `unknown_${c}`, written: false, ...(known?.signed ? { signed: true } : {}),
      ...(enums.has(c) ? { values: enums.get(c)! } : {}), observed: unique(seen.get(c)!.values.map((x) => x.v)) };
  });
  const named = (c: string) => [...new Set((enums.get(c) ?? seen.get(c)?.values.map((x) => x.v) ?? []).map((v) => WIRE_NAMES[c]?.[v]).filter((n): n is string => !!n))];
  const fw = report.camera.firmware_normalized ?? normalizedFirmware(report.camera.firmware);
  const slotNumbers = report.slots.items.map((i) => i.slot).filter((s): s is number => s !== null);
  const profile: CameraProfile = {
    schema_version: CAMERA_PROFILE_SCHEMA, id: `${report.camera.model.replace(/[^\w.+-]+/g, "")}-${fw ?? "unknown"}`, model: report.camera.model,
    firmware: fw ? [fw] : [], write_status: "read_only", slots: slotNumbers.length ? Math.max(...slotNumbers) : 0, name_max: null,
    cursor: "0xd18c", name: "0xd18d", properties, write_order: [], mono_skip: [], readback_equivalents: [],
    film_sims: named("0xd192"), grains: named("0xd195"), color_chrome: named("0xd196"), white_balances: named("0xd199"),
    required_operations: reference.required_operations,
    evidence: { fixture: null, checks: Object.fromEntries(HARDWARE_CHECKS.map((c) => [c, "not_run"])) as CameraProfile["evidence"]["checks"],
      source: `camera report sha256 ${createHash("sha256").update(JSON.stringify(report)).digest("hex")}` },
  };
  const advertised = new Set(report.ptp.device_properties);
  const outside: { code: string; field: string; slot: number | null; value: number }[] = [];
  for (const [c, o] of seen) {
    const ref = refProps.get(c);
    if (ref && (ref.values || ref.range)) for (const { slot, v } of o.values) if (!accepts(ref, v) && v !== -1 && v !== 0xffff) outside.push({ code: c, field: ref.field, slot, value: v });
  }
  const diff = {
    reference: reference.id,
    slot_editing: { report: advertised.has(reference.cursor), reference: true },
    slot_count: { report: profile.slots, reference: reference.slots },
    properties_missing: reference.properties.map((p) => p.code).filter((c) => !advertised.has(c)),
    properties_extra: [...advertised].filter((c) => inBlock(Number.parseInt(c.slice(2), 16)) && !refProps.has(c)).sort(),
    operations_missing: reference.required_operations.filter((op) => !report.ptp.operations.includes(op)),
    byte_lengths: [...seen].filter(([, o]) => [...o.lengths].some((l) => l !== 2)).map(([c, o]) => ({ code: c, report: [...o.lengths].sort(), reference: 2 })),
    values_outside_reference: outside,
    unreadable: [...seen].flatMap(([c, o]) => [...o.errors].map(([error, slots]) => ({ code: c, error, slots }))),
    descriptors: { parsed: report.slots.descriptors?.length ?? 0, enums: [...enums.keys()] },
  };
  return {
    schema_version: CAMERA_PROFILE_DRAFT_SCHEMA, profile, diff, validation: validateProfile(profile),
    write_status_note: "read_only: this draft cannot enable writes. Only a reviewed profile in modules/camera/profiles.ts that meets the hardware bar is verified.",
    next_steps: [
      "Check the diff: extra or missing property codes, other byte lengths and values outside the X100VI map are where this body differs.",
      "observed values are what this camera's slots hold now, not the body's full list of supported settings; descriptor enums, when present, are the camera's own list.",
      "To list the body, add the reviewed profile to PROFILES in modules/camera/profiles.ts as read_only. That changes no write behavior.",
      "Writes need the supervised hardware bar in docs/ADD-YOUR-CAMERA.md, recorded in tests/fixtures/camera/.",
    ],
  };
}
