import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { importInvocation, runImport } from '../../modules/import/cli.mjs';
import { bluetoothInvocation, runBluetooth } from '../../modules/camera/bluetooth.mjs';
import { root, runProcess } from '../../modules/native-helper.mjs';

function workspace(t) {
  const dir = mkdtempSync(join(tmpdir(), 'dialin-wireless-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true })); return dir;
}
test('wireless help, status and blocked apply never need a native build', () => {
  for (const args of [['import', '--help'], ['camera', 'bluetooth', '--help'], ['native', '--help'], ['camera', 'bluetooth', 'status'], ['camera', 'bluetooth', 'apply']]) {
    const r = spawnSync(process.execPath, ['scripts/dialin.mjs', ...args], { cwd: root, encoding: 'utf8' });
    assert.equal(r.status, args.at(-1) === 'apply' ? 3 : 0, r.stderr);
    if (['apply', 'status'].includes(args.at(-1))) {
      const result = JSON.parse(r.stdout); assert.equal(result.production_writes, 'blocked'); assert.equal(result.device, 'NOT_USED');
    }
  }
  assert.match(readFileSync(join(root, 'ios/DialInCamera/Sources/DialInCamera/SlotWrite/BLESlotWriter.swift'), 'utf8'), /wirelessWritesValidated = false/);
});
test('import refuses ambiguous, mistyped or unsafe options before calling any helper', async (t) => {
  let calls = 0;
  const execute = async () => { calls++; throw new Error('must not be reached'); };
  for (const args of [
    ['wifi', '--dest', 'x'], ['wifi', '--last', '0', '--dest', 'x'], ['wifi', '--last', '2.5', '--dest', 'x'],
    ['wifi', '--all', '--since', '2026-10-19', '--dest', 'x'], ['wifi', '--since', '2026-02-30', '--dest', 'x'],
    ['wifi', '--last', '1', '--dest', 'x', '--dryrun'], ['usb', '--last', '1', '--dest', 'x', '--pair'],
    ['wifi', '--last', '1', '--dest', 'x', '--pair', '--rehearse'],
    ['folder', '--from', 'originals', '--dest', 'originals/copies', '--all'],
  ]) assert.equal(await runImport(args, execute), 2);
  assert.equal(calls, 0);
});
test('Wi-Fi defaults to original JPEG/HEIF and never implicitly pairs', () => {
  const r = importInvocation(['wifi', '--last', '7', '--dest', 'pictures']);
  assert.equal(r.native[0], 'import-wifi'); assert.ok(r.native.includes('--no-raw')); assert.ok(!r.native.includes('--pair'));
  assert.ok(importInvocation(['wifi', '--all', '--dest', 'pictures', '--pair']).native.includes('--pair'));
});
test('folder import resolves symlink destinations before protecting the original tree', (t) => {
  const dir = workspace(t), originals = join(dir, 'originals'), alias = join(dir, 'alias');
  mkdirSync(originals); symlinkSync(originals, alias, process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => importInvocation(['folder', '--from', originals, '--dest', join(alias, 'new'), '--all']), /outside the source/);
  assert.throws(() => importInvocation(['folder', '--from', originals, '--dest', join(originals, '..hidden'), '--all']), /outside the source/);
  assert.throws(() => bluetoothInvocation(['backup', '--workspace', join(dir, 'backup'), '--out', join(dir, 'backup', 'receipt.json')]), /outside the new/);
});
test('import distinguishes complete, dry-run, rehearsal, partial, missing and interrupted outcomes', async (t) => {
  const dir = workspace(t);
  const cases = [
    { flags: [], code: 0, result: 'completed' }, { flags: ['--dry-run'], code: 0, result: 'planned' },
    { flags: ['--rehearse'], code: 0, result: 'fixture_rehearsal' },
    { flags: [], code: 1, result: 'incomplete', failures: [{ name: 'frame.jpg', reason: 'link lost' }] },
    { flags: [], code: 0, result: 'incomplete', missing: true },
    { flags: [], code: 130, result: 'incomplete', signal: 'SIGINT' },
  ];
  for (const [i, c] of cases.entries()) {
    const out = join(dir, `${i}.json`);
    const exit = await runImport(['wifi', '--last', '7', '--dest', join(dir, 'photos'), '--out', out, ...c.flags], async (args) => {
      if (!c.missing) writeFileSync(args[args.indexOf('--result-file') + 1], JSON.stringify({ schema_version: 'dialin.import-summary.v1', saved: 2, failures: c.failures ?? [], interrupted: !!c.signal }));
      return { code: c.code, signal: c.signal ?? null };
    });
    const r = JSON.parse(readFileSync(out, 'utf8'));
    assert.equal(r.result, c.result); assert.equal(exit === 0, c.result !== 'incomplete');
    if (c.flags.includes('--rehearse')) assert.equal(r.device, 'NOT_USED');
    else assert.equal(r.network_restore, 'NOT_VERIFIED');
  }
});
test('existing output is preserved and refuses an operation before device access', async (t) => {
  const dir = workspace(t), out = join(dir, 'receipt.json'); writeFileSync(out, 'keep this');
  let calls = 0; const execute = async () => { calls++; return { code: 0 }; };
  assert.equal(await runImport(['wifi', '--last', '7', '--dest', join(dir, 'photos'), '--out', out], execute), 2);
  assert.equal(await runBluetooth(['backup', '--workspace', join(dir, 'backup'), '--out', out], execute), 2);
  assert.equal(calls, 0); assert.equal(readFileSync(out, 'utf8'), 'keep this');
});
test('Bluetooth trial requires exact scope and explicit lab flags', () => {
  for (const args of [['trial-write', '--review', 'r', '--workspace', 'w'], ['trial-restore', '--trial', 't', '--workspace', 'w', '--lab-single-slot-trial'], ['backup', '--workspace', 'w', '--dry-run'], ['trial-prepare', '--backup', 'b', '--recipe', 'r', '--workspace', 'w', '--slot', 'C8']]) assert.throws(() => bluetoothInvocation(args));
  const write = bluetoothInvocation(['trial-write', '--review', 'r', '--workspace', 'w', '--lab-single-slot-trial', '--i-understand-this-is-experimental']);
  assert.ok(write.native.includes('--lab-single-slot-trial')); assert.ok(write.native.includes('--i-understand-this-is-experimental'));
  const prepare = bluetoothInvocation(['trial-prepare', '--backup', 'b', '--recipe', 'r', '--slot', 'C7', '--workspace', 'w']);
  assert.equal(prepare.native[prepare.native.indexOf('--slot') + 1], '7');
});
test('Bluetooth keeps missing/failed evidence unverified and never promotes production support', async (t) => {
  const dir = workspace(t);
  for (const code of [0, 3]) {
    const ws = join(dir, `check${code}`), out = join(dir, `result${code}.json`);
    const exit = await runBluetooth(['trial-check', '--trial', join(dir, 'prior'), '--workspace', ws, '--out', out, '--lab-single-slot-trial'], async (args) => {
      mkdirSync(ws); writeFileSync(join(ws, 'result.json'), JSON.stringify({ result: code ? 'failed' : 'verified' })); return { code };
    });
    assert.equal(exit, code);
    const r = JSON.parse(readFileSync(out)); assert.equal(r.production_writes, 'blocked'); assert.equal(r.restart, 'OWNER_MUST_CONFIRM');
    assert.equal(r.result, code ? 'not_verified' : 'completed');
  }
  const missing = join(dir, 'missing.json');
  assert.equal(await runBluetooth(['trial-prepare', '--backup', 'b', '--recipe', 'r', '--slot', 'C7', '--workspace', join(dir, 'no-evidence'), '--out', missing], async () => ({ code: 0 })), 3);
});
test('native process execution preserves argument boundaries and exit failures', async () => {
  const argument = 'a space; $(not-a-command)';
  const r = await runProcess(process.execPath, ['-e', 'process.stdout.write(process.argv[1]); process.exitCode=7', argument], { capture: true });
  assert.equal(r.code, 7); assert.equal(r.stdout, argument);
});
