// Fujifilm camera session: read and write the C1–C7 custom-setting slots over PTP.
// Slot protocol (from FilmKit's reverse engineering, confirmed on X100VI):
//   D18C = active slot (1–7), D18D = slot name, D18E–D1A5 = the slot's 24 image settings.
import { packPTPString, packU16, PTPReader, parsePTPStringRaw } from "./vendor/binary.js";
import { PTPOp, PTPResp, respName } from "./vendor/constants.js";
import { MONOCHROME_SIMS } from "./vendor/enums.js";
import { type PresetUIValues, translatePresetToUI, translateUIToPresetProps } from "./vendor/preset-translate.js";
import type { RawProp } from "./vendor/types.js";
import { UsbPtp } from "./usb.js";

const SLOT = 0xd18c;
const NAME = 0xd18d;
const FIRST = 0xd18e;
const LAST = 0xd1a4; // D1A5 is the LIVE image size, not slot data — never read/write it as part of a slot
const DR = 0xd190;
const DR_PRIORITY = 0xd191; // when non-zero, the camera rejects D190/D19D/D19E
const MONO_SKIP = new Set([0xd196, 0xd197, 0xd19a, 0xd19b, 0xd19f]); // colour-only props

// Write order from docs/FUJI_PROTOCOL.md §4.2 (ILFforever X-H2 bench + ctl0v0 X100VI fw1.32).
// Never written: D18E/D18F (image size/quality), D1A3/D1A4 (LMO, colour space), D1A5 (live).
const WRITE_ORDER = [
  0xd192, // film sim
  0xd191, // D-Range Priority (forced Off so DR/tones apply)
  0xd190, // DR
  0xd195, 0xd196, 0xd197, 0xd198, // grain, colour chrome, CC FX blue, smooth skin
  0xd199, 0xd19c, 0xd19a, 0xd19b, // WB, Kelvin (only if WB = Kelvin), shifts
  0xd19d, 0xd19e, 0xd19f, 0xd1a0, 0xd1a1, 0xd1a2, // highlight, shadow, color, sharpness, NR, clarity
];
const WRITE_GAP_MS = 20; // ctl0v0 spaces X100VI writes 20 ms apart

const REJECT_HINT: Record<number, string> = {
  0xd1a2: "clarity skipped (camera must be in single-shot drive mode)",
  0xd1a1: "high-ISO NR not stored in slots",
};

export type Slot = { slot: number; name: string; props: { id: number; hex: string }[] };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const toHex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const fromHex = (h: string) => new Uint8Array(Buffer.from(h, "hex"));

function decode(data: Uint8Array): number | string {
  if (data.length >= 3) {
    const n = data[0];
    const expected = 1 + n * 2;
    if (n >= 2 && (expected === data.length || expected === data.length + 1)) return parsePTPStringRaw(data);
  }
  const v = new DataView(data.buffer, data.byteOffset, data.byteLength);
  if (data.length === 2) return v.getInt16(0, true);
  if (data.length === 4) return v.getInt32(0, true);
  if (data.length === 1) return data[0];
  return toHex(data);
}

export class FujiCamera {
  readonly usb = new UsbPtp();
  model = "";
  properties = new Set<number>();
  onLog: (msg: string) => void = () => {};

  async connect(): Promise<void> {
    await this.usb.open();
    // PTP: OpenSession goes out with transaction ID 0. Reset the counter on every (re)open,
    // otherwise a stale-session retry answers 0x2006 (seen on X-T5).
    this.usb.resetTransactions();
    let { code } = await this.usb.command(PTPOp.OpenSession, [1]);
    if (code === PTPResp.SessionAlreadyOpen) {
      await this.usb.command(PTPOp.CloseSession).catch(() => {});
      this.usb.resetTransactions();
      ({ code } = await this.usb.command(PTPOp.OpenSession, [1]));
    }
    if (code !== PTPResp.OK) throw new Error(`OpenSession failed: ${respName(code)}`);

    const info = await this.usb.command(PTPOp.GetDeviceInfo);
    if (info.code === PTPResp.OK) {
      const r = new PTPReader(info.data);
      r.u16(); r.u32(); r.u16(); r.str(); r.u16();
      r.u16array(); r.u16array();
      this.properties = new Set(r.u16array());
      r.u16array(); r.u16array(); r.str();
      this.model = r.str();
    }
    if (this.properties.size && !this.properties.has(SLOT)) {
      throw new Error(
        `${this.model || "Camera"} doesn't expose custom-slot editing over USB. Check CONNECTION MODE = USB RAW CONV./BACKUP RESTORE.`,
      );
    }
  }

  async disconnect(): Promise<void> {
    await this.usb.command(PTPOp.CloseSession).catch(() => {});
    await this.usb.close();
  }

  async readProp(id: number): Promise<RawProp | null> {
    const { code, data } = await this.usb.command(PTPOp.GetDevicePropValue, [id]);
    if (code !== PTPResp.OK || !data.length) return null;
    return { id, name: "", bytes: data, value: decode(data) };
  }

  async writeProp(id: number, bytes: Uint8Array): Promise<boolean> {
    const { code } = await this.usb.commandWithData(PTPOp.SetDevicePropValue, [id], bytes);
    return code === PTPResp.OK;
  }

  async selectSlot(slot: number): Promise<void> {
    if (!(await this.writeProp(SLOT, packU16(slot)))) throw new Error(`Camera refused to select C${slot}`);
    await sleep(100); // D18C is an edit cursor; let it settle (FilmKit/ILFforever wait 50–100 ms)
  }

  async readSlot(slot: number): Promise<{ slot: number; name: string; props: RawProp[] }> {
    await this.selectSlot(slot);
    const nameProp = await this.readProp(NAME);
    const props: RawProp[] = [];
    for (let id = FIRST; id <= LAST; id++) {
      const p = await this.readProp(id);
      if (p) props.push(p);
    }
    return { slot, name: typeof nameProp?.value === "string" ? nameProp.value : "", props };
  }

  async readAll(): Promise<Slot[]> {
    const out: Slot[] = [];
    for (let s = 1; s <= 7; s++) {
      const { name, props } = await this.readSlot(s);
      out.push({ slot: s, name, props: props.map((p) => ({ id: p.id, hex: toHex(p.bytes) })) });
    }
    return out;
  }

  slotValues(props: RawProp[]): PresetUIValues {
    return translatePresetToUI(props);
  }

  /**
   * Write a look into a slot, in the camera's accepted order, then read every value back
   * (a camera can answer OK and not apply). `base` is the slot's current props.
   * `keepDrPriority` re-applies the slot's own D-Range Priority after the tones (for restore).
   */
  async writeSlot(
    slot: number,
    name: string,
    values: PresetUIValues,
    opts: { base?: RawProp[]; verify?: boolean; keepDrPriority?: boolean } = {},
  ): Promise<{ rejected: string[]; mismatched: string[] }> {
    const base = opts.base ?? (await this.readSlot(slot)).props;
    const encoded = new Map(translateUIToPresetProps(values, base).map((p) => [p.id, p.bytes]));
    encoded.set(DR_PRIORITY, packU16(0));
    const mono = MONOCHROME_SIMS.has(values.filmSimulation);
    const props = WRITE_ORDER.filter((id) => encoded.has(id) && !(mono && MONO_SKIP.has(id))).map((id) => ({
      id,
      bytes: encoded.get(id)!,
    }));

    await this.selectSlot(slot);
    // Name first: FilmKit (X100VI) and AlPeFe do this; AlPeFe saw corrupted names otherwise.
    if (!(await this.writeProp(NAME, packPTPString(name)))) throw new Error(`Camera refused name for C${slot}`);
    const rejected: string[] = [];
    const written: { id: number; bytes: Uint8Array }[] = [];
    for (const p of props) {
      await sleep(WRITE_GAP_MS);
      if (await this.writeProp(p.id, p.bytes)) {
        written.push(p);
        continue;
      }
      // DR400/DR200 are refused when the camera's current ISO is below their minimum: step down.
      if (p.id === DR) {
        const want = new DataView(p.bytes.buffer, p.bytes.byteOffset).getUint16(0, true);
        let ok = 0;
        for (const v of [200, 100].filter((v) => v < want)) {
          if (await this.writeProp(DR, packU16(v))) { ok = v; break; }
        }
        if (ok) {
          written.push({ id: DR, bytes: packU16(ok) });
          rejected.push(`DR stepped down to DR${ok} (camera ISO too low for more)`);
          continue;
        }
      }
      rejected.push(REJECT_HINT[p.id] ?? `0x${p.id.toString(16)}=${toHex(p.bytes)}`);
    }

    const drp = base.find((p) => p.id === DR_PRIORITY);
    if (opts.keepDrPriority && drp && toHex(drp.bytes) !== "0000") await this.writeProp(DR_PRIORITY, drp.bytes);

    const mismatched: string[] = [];
    if (opts.verify ?? true) {
      for (const p of written) {
        const rb = await this.readProp(p.id);
        if (rb && toHex(rb.bytes) !== toHex(p.bytes)) mismatched.push(`0x${p.id.toString(16)} wrote ${toHex(p.bytes)} read ${toHex(rb.bytes)}`);
      }
      const rbName = await this.readProp(NAME);
      if (rbName && rbName.value !== name) mismatched.push(`name wrote "${name}" read "${rbName.value}"`);
    }
    this.onLog(
      `C${slot} "${name}": ${written.length}/${props.length} written` +
        (rejected.length ? ` · ${rejected.join(" · ")}` : "") +
        (mismatched.length ? ` · DIDN'T STICK: ${mismatched.join(", ")}` : ""),
    );
    return { rejected, mismatched };
  }

  // ---------- whole-camera settings file (FUJIFILMX-BACKUP), the same file XApp moves over Bluetooth ----------

  /** Download the settings backup: object handle 0, format 0x5000 (libfuji fuji_usb.c:173-241). */
  async getSettingsFile(): Promise<Uint8Array> {
    const info = await this.usb.command(PTPOp.GetObjectInfo, [0]);
    if (info.code !== PTPResp.OK) throw new Error(`GetObjectInfo(0) failed: ${respName(info.code)}`);
    const obj = await this.usb.command(PTPOp.GetObject, [0]);
    if (obj.code !== PTPResp.OK) throw new Error(`GetObject(0) failed: ${respName(obj.code)}`);
    return obj.data;
  }

  /**
   * Restore a settings backup. Overwrites EVERY camera setting, not one slot.
   * Must be the first operation after a power cycle in RAW CONV./BACKUP RESTORE mode.
   * ObjectInfo must be exactly 1076 bytes (helios fuji_settings.py:111-121; libfuji's 1088 gets 0x200F).
   */
  async putSettingsFile(file: Uint8Array): Promise<void> {
    const magic = Buffer.from(file.subarray(0, 16)).toString("latin1");
    if (magic !== "FUJIFILMX-BACKUP") throw new Error("Not a FUJIFILMX-BACKUP file");
    if (file.length > 100_000) throw new Error("Backup file is suspiciously large");
    const oi = new Uint8Array(1076);
    const v = new DataView(oi.buffer);
    v.setUint32(0, 0, true); // StorageID
    v.setUint16(4, 0x5000, true); // ObjectFormat
    v.setUint16(6, 0, true); // ProtectionStatus
    v.setUint32(8, file.length, true); // ObjectCompressedSize
    const r1 = await this.usb.commandWithData(PTPOp.SendObjectInfo, [0, 0], oi);
    if (r1.code !== PTPResp.OK) throw new Error(`SendObjectInfo refused: ${respName(r1.code)}`);
    const r2 = await this.usb.commandWithData(PTPOp.SendObject, [], file);
    if (r2.code !== PTPResp.OK) {
      throw new Error(
        `SendObject refused: ${respName(r2.code)} (0x200F = bad checksum, or not a clean session — power-cycle and make restore the first thing you do)`,
      );
    }
    this.onLog(`restored ${file.length}-byte settings file — power-cycle the camera so every setting takes effect`);
  }

  /** Put a backup taken with readAll() back. Goes through the encoder so write order is the one the camera accepts. */
  async restore(slots: Slot[]): Promise<void> {
    for (const s of slots) {
      const props: RawProp[] = s.props.map((p) => {
        const bytes = fromHex(p.hex);
        return { id: p.id, name: "", bytes, value: decode(bytes) };
      });
      await this.writeSlot(s.slot, s.name, translatePresetToUI(props), { base: props, keepDrPriority: true });
    }
  }
}
