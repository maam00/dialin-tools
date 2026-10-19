import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { cameraReport, draftProfile, privacyProblems, readOnlyLink, reportSummary, type CameraReport, type PtpLink } from '../../modules/camera/report.js';
import { evidenceIssues, PROFILES, profileStatus, validateProfile, writerProfile, X100VI_110, type CameraProfile } from '../../modules/camera/profiles.js';
import { prepareCamera } from '../../modules/camera/index.js';
import { applyUsbPreparation, type UsbCameraPort } from '../../modules/camera/usb.js';
import { CAMERA_HELP, runCamera } from '../../modules/camera/cli.js';
import { concat, packPTPString, packU16, packU32 } from '../../lib/fuji/vendor/binary.js';
import { PTPOp } from '../../lib/fuji/vendor/constants.js';
import type { Recipe } from '../../lib/fuji/recipe.js';

// Synthetic identities only. The fake answers PTP like a body and records every command it receives.
const SERIAL = 'SYNTHETIC-XT5-0042', OWNER = 'Jane Q. Owner', COPYRIGHT = '(c) Jane Q. Owner 2026', MAC = 'AA:BB:CC:DD:EE:01';
const span = (lo: number, hi: number) => Array.from({ length: hi - lo + 1 }, (_, i) => lo + i);
const READ_ONLY = new Set<number>([PTPOp.OpenSession, PTPOp.CloseSession, PTPOp.GetDeviceInfo, PTPOp.GetDevicePropDesc, PTPOp.GetDevicePropValue]);
const PERSONAL = new Map<number, Uint8Array>([[0xd300, packPTPString(OWNER)], [0xd301, packPTPString(COPYRIGHT)], [0xd302, packPTPString(MAC)], [0xd303, packPTPString(SERIAL)]]);
type Body = { model: string; firmware: string; serial: string; props: number[]; ops: number[]; slots: number; cursor: number;
  refuse?: number[]; hangOn?: { id: number; afterMoves: number }; descriptors?: boolean };
// X-T5-like: no D1A3, two extra slot codes (a 4-byte one and a text one), other ops, personal device properties.
const XT5: Body = { model: 'X-T5', firmware: '1.20', serial: SERIAL, slots: 7, cursor: 3, refuse: [0xd1a2], descriptors: true,
  props: [0x5005, 0xd001, 0xd16e, 0xd186, ...span(0xd18c, 0xd1a2), 0xd1a4, 0xd1a5, 0xd1a6, 0xd1a7, ...PERSONAL.keys()],
  ops: [0x1001, 0x1002, 0x1003, 0x1007, 0x1008, 0x1009, 0x100c, 0x100d, 0x1014, 0x1015, 0x1016, 0x900c, 0x900d] };
const X100VI: Body = { model: 'X100VI', firmware: '1.10', serial: 'SYNTHETIC-X100VI-7', slots: 7, cursor: 7,
  props: [0xd16e, ...span(0xd18c, 0xd1a5)], ops: [0x1001, 0x1002, 0x1003, 0x1014, 0x1015, 0x1016] };

function deviceInfo(b: Body) {
  const list = (xs: number[]) => concat(packU32(xs.length), ...xs.map(packU16));
  return concat(packU16(100), packU32(0x0e), packU16(100), packPTPString('fujifilm.co.jp: 1.0;'), packU16(0),
    list(b.ops), list([0xc001]), list(b.props), list([]), list([0x3801]),
    packPTPString('FUJIFILM'), packPTPString(b.model), packPTPString(b.firmware), packPTPString(b.serial));
}
const enumDesc = (id: number, values: number[]) => concat(packU16(id), packU16(4), new Uint8Array([1]), packU16(values[0]), packU16(values[0]),
  new Uint8Array([2]), packU16(values.length), ...values.map(packU16));
class FakeBody implements PtpLink {
  calls: { op: number; params: number[]; payload?: number[] }[] = []; opened = false; closed = false; moves = 0; cursor: number;
  slots = new Map<number, Map<number, Uint8Array>>(); names: string[];
  constructor(public body: Body) {
    this.cursor = body.cursor;
    this.names = span(1, body.slots).map((s) => `Jane's Kodak ${s}`);
    const sims = [0x14, 0x0b, 0x15, 0x05, 0x13, 0x0d, 0x01]; // 0x15: a code the X100VI map doesn't know
    for (const s of span(1, body.slots)) this.slots.set(s, new Map<number, Uint8Array>(body.props.filter((id) => id >= 0xd18e && id <= 0xd1a7 && id !== 0xd1a5).map((id) => [id,
      id === 0xd192 ? packU16(sims[s - 1]) : id === 0xd190 ? packU16(200) : id === 0xd195 ? packU16(1 + (s % 5)) : id === 0xd196 ? packU16(2)
        : id === 0xd199 ? packU16(0x0002) : id === 0xd19c ? packU16(6300) : id === 0xd1a1 ? packU16(0x8000)
          : id === 0xd1a6 ? packU32(7) : id === 0xd1a7 ? packPTPString("Jane's note") : packU16(s)])));
  }
  state() { return JSON.stringify([...this.slots].map(([s, m]) => [s, [...m].map(([id, b]) => [id, [...b]])])) + this.names.join('|'); }
  async open() { this.opened = true; }
  async close() { this.closed = true; }
  resetTransactions() {}
  async command(op: number, params: number[] = []) {
    this.calls.push({ op, params: [...params] });
    const ok = (data: Uint8Array = new Uint8Array()) => ({ code: 0x2001, params: [], data }), no = (code: number) => ({ code, params: [], data: new Uint8Array() });
    if (op === PTPOp.OpenSession || op === PTPOp.CloseSession) return ok();
    if (op === PTPOp.GetDeviceInfo) return ok(deviceInfo(this.body));
    const id = params[0];
    if (op === PTPOp.GetDevicePropDesc) return this.body.descriptors && id === 0xd192 ? ok(enumDesc(id, [1, 2, 3, 0x0b, 0x14, 0x15])) : no(0x2002);
    if (op !== PTPOp.GetDevicePropValue) return no(0x2005);
    if (this.body.hangOn?.id === id && this.moves >= this.body.hangOn.afterMoves) return new Promise<never>(() => {});
    if (!this.body.props.includes(id)) return no(0x200a);
    if (this.body.refuse?.includes(id)) return no(0x2002);
    if (id === 0xd18c) return ok(packU16(this.cursor));
    if (id === 0xd18d) return ok(packPTPString(this.names[this.cursor - 1]));
    if (id === 0xd16e) return ok(packU16(6));
    if (id === 0xd186) return ok(packPTPString(`${this.body.model}_0120`));
    return ok(this.slots.get(this.cursor)?.get(id) ?? PERSONAL.get(id) ?? packU16(0));
  }
  async commandWithData(op: number, params: number[], payload: Uint8Array) {
    this.calls.push({ op, params: [...params], payload: [...payload] });
    if (op === PTPOp.SetDevicePropValue && params[0] === 0xd18c) {
      const v = payload[0] | (payload[1] << 8);
      if (v < 1 || v > this.body.slots) return { code: 0x201c };
      this.cursor = v; this.moves++; return { code: 0x2001 };
    }
    // A real body would apply any other write; the fake does too, so a stray write shows up in state().
    if (op === PTPOp.SetDevicePropValue) this.slots.get(this.cursor)?.set(params[0], payload.slice());
    return { code: 0x2001 };
  }
}
const run = async (body: Body, options: Parameters<typeof cameraReport>[0] = {}) => {
  const fake = new FakeBody(body), before = fake.state();
  const report = await cameraReport({ settleMs: 0, ...options }, { link: async () => fake });
  return { fake, before, report, json: JSON.stringify(report) };
};
const writes = (fake: FakeBody) => fake.calls.filter((c) => !READ_ONLY.has(c.op));
function assertPrivate(json: string, { names = false } = {}) {
  for (const secret of [SERIAL, OWNER, COPYRIGHT, MAC, ...(names ? [] : ['Jane', 'Kodak'])]) assert.ok(!json.includes(secret), secret);
  for (const encoding of ['latin1', 'utf16le'] as const) assert.ok(!json.toLowerCase().includes(Buffer.from(SERIAL, encoding).toString('hex')), encoding);
  assert.doesNotMatch(json, /([0-9a-f]{2}[:-]){5}[0-9a-f]{2}/i);
  assert.deepEqual(privacyProblems(json, SERIAL), []);
}

test('an X-T5-like body gets a full report: its own property list, no identity, and no writes beyond the edit cursor', async () => {
  const { fake, before, report, json } = await run(XT5);
  assert.equal(report.schema_version, 'dialin.camera-report.v1');
  assert.equal(report.complete, true);
  assert.deepEqual([report.camera.model, report.camera.firmware, report.camera.usb_mode, report.camera.compatibility_code], ['X-T5', '1.20', 6, 'X-T5_0120']);
  assert.deepEqual([report.dialin.write_status, report.dialin.profile], ['unknown', null]);
  assert.match(report.dialin.writes, /^Unsupported/);
  assert.ok(report.ptp.device_properties.includes('0xd1a6') && report.ptp.operations.includes('0x900c'));
  assert.ok(report.slots.block.includes('0xd1a6') && !report.slots.block.includes('0xd1a3') && !report.slots.block.includes('0xd1a5'));
  assert.deepEqual(report.slots.items.map((i) => i.slot), [1, 2, 3, 4, 5, 6, 7]);
  assert.ok(report.slots.items.every((i) => i.cursor_ok && !('name' in i)));
  const c3 = report.slots.items[2].props;
  assert.deepEqual(c3.find((p) => p.code === '0xd192'), { code: '0xd192', bytes: 2, hex: '1500', u16: 0x15 });
  assert.deepEqual(c3.find((p) => p.code === '0xd1a6'), { code: '0xd1a6', bytes: 4, hex: '07000000' });
  assert.deepEqual(c3.find((p) => p.code === '0xd1a2'), { code: '0xd1a2', error: 'GeneralError' }); // refused, skipped, recorded
  assert.match(c3.find((p) => p.code === '0xd1a7')!.withheld!, /text/);
  assert.equal(c3.length, report.slots.block.length); // reading continued past the refusal
  assert.deepEqual(report.slots.descriptors.map((d) => d.code), ['0xd192']);
  // Reads, plus only the edit cursor; it ends where it started and the camera's slots are byte-identical.
  assert.ok(writes(fake).every((c) => c.op === PTPOp.SetDevicePropValue && c.params[0] === 0xd18c), JSON.stringify(writes(fake)));
  assert.deepEqual(writes(fake).map((c) => c.payload![0]), [4, 5, 6, 7, 1, 2, 3]);
  assert.equal(fake.state(), before);
  assert.equal(fake.cursor, 3);
  assert.deepEqual([report.cursor.before, report.cursor.after, report.cursor.moves, report.cursor.returned, report.cursor.first_slot_unchanged], [3, 3, 7, true, true]);
  assert.deepEqual([report.camera_operations.recipe_writes, report.camera_operations.setting_writes, report.camera_operations.backup, report.camera_operations.restore], [0, 0, 'NOT_RUN', 'NOT_RUN']);
  // Never asked for personal device properties or the slot names; never sent an object, backup or restore op.
  assert.ok(!fake.calls.some((c) => c.op === PTPOp.GetDevicePropValue && [0xd18d, ...PERSONAL.keys()].includes(c.params[0])));
  assert.ok(!fake.calls.some((c) => [0x1008, 0x1009, 0x100c, 0x100d, 0x900c, 0x900d].includes(c.op)));
  assert.equal(fake.closed, true);
  assertPrivate(json);
  assert.equal(reportSummary(report, '/somewhere/report.json')[0], "Your X-T5 1.20 report is ready; nothing on the camera was changed; attach report.json to a 'Camera report' issue.");
  assert.match(reportSummary(report).join('\n'), /back on C3[\s\S]*writes stay unsupported \(status unknown\)[\s\S]*Not included: serial number/);
});

test('--current-slot-only sends no SetDevicePropValue at all', async () => {
  const { fake, before, report, json } = await run(XT5, { currentSlotOnly: true });
  assert.deepEqual(writes(fake), []);
  assert.equal(fake.state(), before);
  assert.deepEqual(report.slots.items.map((i) => i.slot), [3]);
  assert.deepEqual([report.cursor.moves, report.cursor.returned, report.slots.mode], [0, null, 'current_slot_only']);
  assertPrivate(json);
});

test('slot names appear only with --include-slot-names, and a report containing the serial is never produced', async () => {
  const { report, json } = await run(XT5, { includeSlotNames: true });
  assert.deepEqual(report.slots.items.map((i) => i.name), span(1, 7).map((s) => `Jane's Kodak ${s}`));
  const text = report.slots.items[0].props.find((p) => p.code === '0xd1a7')!; // text slot values follow the same opt-in, as raw bytes
  assert.equal(text.hex, Buffer.from(packPTPString("Jane's note")).toString('hex')); assert.equal(text.withheld, undefined);
  assertPrivate(json, { names: true });
  const leaky = new FakeBody(XT5); leaky.names[2] = SERIAL;
  await assert.rejects(cameraReport({ includeSlotNames: true, settleMs: 0 }, { link: async () => leaky }), /Privacy check failed \(serial number\)/);
});

test('a 4-slot body: probing stops at the first refused slot and the cursor returns', async () => {
  const { fake, before, report } = await run({ ...XT5, model: 'X-S20', slots: 4, cursor: 2 });
  assert.deepEqual(writes(fake).map((c) => c.payload![0]), [3, 4, 5, 1, 2]); // C5 refused; C6/C7 never tried
  assert.deepEqual(report.slots.items.map((i) => i.slot), [1, 2, 3, 4]);
  assert.ok(report.slots.notes.some((n) => /C5 could not be selected/.test(n)));
  assert.equal(fake.cursor, 2); assert.equal(fake.state(), before); assert.equal(report.cursor.returned, true);
});

test('an unanswered property ends the session: partial report, recorded error, no further camera commands', async () => {
  const { fake, before, report } = await run({ ...XT5, hangOn: { id: 0xd192, afterMoves: 1 } }, { timeoutMs: 30 });
  assert.equal(report.complete, false);
  assert.match(report.errors[0].stage, /read C4/); assert.match(report.errors[0].error, /no answer within 30 ms/);
  const hang = fake.calls.findIndex((c) => c.op === PTPOp.GetDevicePropValue && c.params[0] === 0xd192 && fake.calls.indexOf(c) > fake.calls.findIndex((x) => x.op === PTPOp.SetDevicePropValue));
  assert.deepEqual(fake.calls.slice(hang + 1), []); // no cursor return, no CloseSession over an out-of-step stream
  assert.equal(fake.closed, true); assert.equal(fake.state(), before);
  assert.deepEqual([report.cursor.after, report.cursor.returned], [null, false]);
  assert.match(reportSummary(report).join('\n'), /partial[\s\S]*left on an unknown slot \(it was C3\)/);
});

test('an edit cursor outside C1–Cn is never moved', async () => {
  const { fake, report } = await run({ ...XT5, cursor: 0 });
  assert.deepEqual(writes(fake), []);
  assert.deepEqual(report.slots.items.map((i) => i.slot), [null]);
  assert.ok(report.slots.notes.some((n) => /read 0, outside C1–C7/.test(n)));
});

test('the read-only link refuses every other operation and any cursor value outside C1–C7 before sending', async () => {
  const fake = new FakeBody(XT5), ro = readOnlyLink(fake);
  for (const op of [PTPOp.SetDevicePropValue, PTPOp.SendObjectInfo, PTPOp.SendObject, PTPOp.GetObject, PTPOp.DeleteObject, 0x100e, 0x900c]) await assert.rejects(ro.read(op, [0xd192]), /only reads/);
  for (const slot of [0, 8, 1.5, 0x8001]) await assert.rejects(ro.moveCursor(slot), /outside C1–C7/);
  assert.deepEqual(fake.calls, []);
});

test('X100VI 1.10 report: verified status, seven slots, cursor back on C7, nothing written', async () => {
  const { fake, before, report, json } = await run(X100VI);
  assert.deepEqual([report.dialin.write_status, report.dialin.profile, report.slots.count_read], ['verified', 'X100VI-1.10', 7]);
  assert.deepEqual(writes(fake).map((c) => c.payload![0]), [1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(report.slots.block, span(0xd18e, 0xd1a4).map((n) => `0x${n.toString(16)}`));
  assert.equal(fake.state(), before); assert.equal(report.cursor.first_slot_unchanged, true);
  assert.ok(!json.includes('SYNTHETIC-X100VI-7'));
  assert.match(reportSummary(report).join('\n'), /verified writer profile; this report still wrote nothing/);
});

test('only X100VI 1.10 is a verified writer, backed by a passed hardware fixture', () => {
  assert.deepEqual(PROFILES.filter((p) => p.write_status === 'verified').map((p) => p.id), ['X100VI-1.10']);
  for (const p of PROFILES) {
    assert.deepEqual(validateProfile(p), [], p.id);
    if (p.write_status !== 'verified') continue;
    const fixture = new URL(`../../${p.evidence.fixture}`, import.meta.url);
    assert.ok(existsSync(fixture), p.evidence.fixture!);
    assert.deepEqual(evidenceIssues(p, JSON.parse(readFileSync(fixture, 'utf8'))), [], p.id);
  }
  assert.deepEqual(X100VI_110.properties.map((p) => p.code), span(0xd18e, 0xd1a4).map((n) => `0x${n.toString(16)}`));
  assert.equal(profileStatus('FUJIFILM X100VI', 'Ver 1.10').status, 'verified');
  assert.equal(profileStatus('X100VI', '1.31').status, 'read_only');
  assert.equal(profileStatus('X-T5', '1.20').status, 'unknown');
  assert.equal(writerProfile('X100VI', '1.31'), null); assert.equal(writerProfile('X-T5', '1.20'), null);
  const unproven: CameraProfile = { ...X100VI_110, evidence: { ...X100VI_110.evidence, checks: { ...X100VI_110.evidence.checks, restart_persistence: 'not_run' } } };
  assert.ok(validateProfile(unproven).some((i) => /restart_persistence/.test(i)));
  assert.ok(validateProfile({ ...X100VI_110, evidence: { ...X100VI_110.evidence, fixture: null } }).some((i) => /hardware fixture/.test(i)));
  const fixture = JSON.parse(readFileSync(new URL('../fixtures/camera/X100VI-1.10.hardware.json', import.meta.url), 'utf8'));
  assert.ok(evidenceIssues(X100VI_110, { ...fixture, serial: 'X' }).length > 0);
  assert.ok(evidenceIssues(X100VI_110, { ...fixture, firmware: '1.31' }).length > 0);
});

test('a report becomes a read-only draft profile with a diff against the X100VI map, and can never become a writer', async () => {
  const { report } = await run(XT5);
  const draft = draftProfile(JSON.parse(JSON.stringify(report)));
  assert.equal(draft.schema_version, 'dialin.camera-profile-draft.v1');
  assert.deepEqual([draft.profile.id, draft.profile.write_status, draft.profile.slots, draft.profile.write_order], ['X-T5-1.20', 'read_only', 7, []]);
  assert.deepEqual(draft.validation, []);
  assert.deepEqual(draft.diff.properties_extra, ['0xd1a6', '0xd1a7']);
  assert.deepEqual(draft.diff.properties_missing, ['0xd1a3']);
  assert.deepEqual(draft.diff.byte_lengths.map((b) => b.code), ['0xd1a6', '0xd1a7']);
  assert.ok(draft.diff.values_outside_reference.some((v) => v.field === 'film_sim' && v.value === 0x15 && v.slot === 3));
  assert.deepEqual(draft.diff.unreadable.map((u) => [u.code, u.error, u.slots.length]), [['0xd1a2', 'GeneralError', 7]]);
  assert.ok(draft.profile.film_sims.includes('Reala Ace') && draft.profile.film_sims.includes('Classic Chrome'));
  assert.deepEqual(draft.diff.descriptors.enums, ['0xd192']);
  assert.ok(Object.values(draft.profile.evidence.checks).every((c) => c === 'not_run'));
  // A forged report that claims to be the verified body still yields only a read-only draft; PROFILES is code.
  const forged = { ...report, camera: { ...report.camera, model: 'X100VI', firmware: '1.10', firmware_normalized: '1.10' } } as CameraReport;
  assert.equal(draftProfile(forged).profile.write_status, 'read_only');
  assert.equal(PROFILES.length, 1);
  assert.ok(validateProfile({ ...draft.profile, write_status: 'verified' }).some((i) => /hardware fixture/.test(i)));
  for (const bad of [{}, { ...report, schema_version: 'x' }, { ...report, camera: { ...report.camera, model: 'X\u0000T5' } },
    { ...report, slots: { ...report.slots, items: [{ slot: 9, props: [] }] } }]) assert.throws(() => draftProfile(bad), /Not a usable/);
});

test('prepare and USB apply still refuse bodies without a verified profile, before any camera contact', async () => {
  const recipe = JSON.parse(readFileSync(new URL('../../examples/camera/own-recipes.json', import.meta.url), 'utf8')).recipes[0] as Recipe;
  const xt5 = prepareCamera(recipe, { model: 'X-T5', slots: [2], firmware: '1.20', transport: 'usb' });
  assert.equal(xt5.validation.valid, false); assert.equal(xt5.readiness.usb.state, 'blocked');
  assert.ok(xt5.validation.errors.some((e) => e.code === 'unsupported_model' && /camera report/.test(e.message)));
  assert.equal(prepareCamera(recipe, { slots: [2], firmware: '1.31', transport: 'usb' }).readiness.usb.state, 'blocked');
  const good = prepareCamera(recipe, { slots: [2], firmware: '1.10', transport: 'usb' });
  assert.equal(good.readiness.usb.state, 'requires_device_checks');
  let factories = 0, writeCalls = 0;
  await assert.rejects(applyUsbPreparation({ ...good, camera: { ...good.camera, model: 'X-T5' } }, { confirmWrite: true, backupPath: '/unused' },
    { camera: async () => { factories++; throw new Error('no'); } }), /outside the supported camera\/firmware profile/);
  assert.equal(factories, 0);
  const dir = mkdtempSync(join(tmpdir(), 'dialin-camera-report-'));
  try {
    const port = { connect: async () => {}, disconnect: async () => {}, readProp: async () => null,
      readIdentity: async () => ({ model: 'X-T5', firmware: '1.10', serial: 'SYNTHETIC', canEditSlots: true }),
      readSlot: async () => { throw new Error('must not read slots'); }, writeSlot: async () => { writeCalls++; return { rejected: [], mismatched: [] }; } } as unknown as UsbCameraPort;
    await assert.rejects(applyUsbPreparation(good, { confirmWrite: true, backupPath: join(dir, 'b.json') }, { camera: async () => port }), /no verified writer profile[\s\S]*camera report/);
    assert.equal(writeCalls, 0); assert.equal(existsSync(join(dir, 'b.json')), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('CLI: report accepts only its read-only flags; profile turns a saved report into a draft file', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'dialin-camera-profile-')), originalError = console.error, lines: string[] = [];
  try {
    console.error = (m: string) => { lines.push(String(m)); };
    assert.match(CAMERA_HELP, /camera report --current-slot-only --out/);
    for (const args of [['report', '--in', 'x.json'], ['report', '--confirm-write'], ['report', '--backup', join(dir, 'b.json')], ['profile']]) assert.equal(await runCamera(args), 2, args.join(' '));
    assert.ok(lines.some((l) => /--in is not accepted by report/.test(l)) && lines.some((l) => /--confirm-write is not accepted by report/.test(l)));
    const { report } = await run(XT5);
    const input = join(dir, 'report.json'), out = join(dir, 'draft.json');
    writeFileSync(input, JSON.stringify(report));
    assert.equal(await runCamera(['profile', '--in', input, '--out', out]), 0);
    assert.equal(JSON.parse(readFileSync(out, 'utf8')).profile.write_status, 'read_only');
    writeFileSync(join(dir, 'junk.json'), '{"schema_version":"dialin.camera-preparation.v1"}');
    assert.equal(await runCamera(['profile', '--in', join(dir, 'junk.json')]), 2);
  } finally { console.error = originalError; rmSync(dir, { recursive: true, force: true }); }
});
