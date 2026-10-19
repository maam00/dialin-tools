import { parseArgs } from 'node:util';
import { mkdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { positiveInteger, receiptWriter, requireNewDirectory, runHelper } from '../native-helper.mjs';

export const BLUETOOTH_HELP = `Bluetooth on the desktop (macOS 26+, Swift 6.2+). Setup: dialin native build

  camera bluetooth status                              Offline support report
  camera bluetooth backup --workspace .dialin/ble-backup [--pair]
  camera bluetooth trial-prepare --backup .dialin/ble-backup/settings.dat --recipe look.json --slot C7 --workspace .dialin/ble-review
  camera bluetooth trial-write --review .dialin/ble-review --workspace .dialin/ble-write --lab-single-slot-trial --i-understand-this-is-experimental
  camera bluetooth trial-check --trial .dialin/ble-write --workspace .dialin/ble-check --lab-single-slot-trial
  camera bluetooth trial-restore --trial .dialin/ble-write --workspace .dialin/ble-restore --lab-single-slot-trial --i-understand-this-is-experimental

Production Bluetooth recipe loading remains BLOCKED. apply always refuses, before any device call.
The trial is one explicitly selected slot on X100VI 1.10 only. prepare is offline; review its REVIEW.txt.
write takes a fresh identity-bound backup, preserves other slots and reads back. check must be run after
the owner power-cycles the camera; the command cannot prove that a restart happened. restore puts the
original selected slot back onto a fresh backup and verifies it. No trial flips the production gate.
Unplug USB before live Bluetooth operations. Pairing happens only with --pair on backup.
Every --workspace must be new and private; it contains camera identity/settings. Never publish it.
--out optionally saves a new JSON receipt. Progress is stderr. See docs/WIRELESS.md.`;

const lab = 'lab-single-slot-trial', consent = 'i-understand-this-is-experimental';
export function bluetoothInvocation(args) {
  const { values: v, positionals: p } = parseArgs({ args, strict: true, allowPositionals: true, options: {
    workspace: { type: 'string' }, backup: { type: 'string' }, recipe: { type: 'string' }, slot: { type: 'string' }, review: { type: 'string' }, trial: { type: 'string' },
    pair: { type: 'boolean' }, [lab]: { type: 'boolean' }, [consent]: { type: 'boolean' }, out: { type: 'string' },
  } });
  const operation = p[0];
  const allowed = { status: ['out'], apply: ['out'], backup: ['workspace', 'pair', 'out'],
    'trial-prepare': ['workspace', 'backup', 'recipe', 'slot', 'out'],
    'trial-write': ['workspace', 'review', lab, consent, 'out'],
    'trial-check': ['workspace', 'trial', lab, 'out'], 'trial-restore': ['workspace', 'trial', lab, consent, 'out'] };
  if (p.length !== 1 || !allowed[operation]) throw new Error('Unknown Bluetooth command. Use camera bluetooth --help.');
  for (const key of Object.keys(v)) if (!allowed[operation].includes(key)) throw new Error(`--${key} is not accepted by ${operation}.`);
  if (['status', 'apply'].includes(operation)) return { operation, values: v, native: [] };
  const workspace = requireNewDirectory(v.workspace);
  if (v.out) {
    const delta = relative(workspace, resolve(v.out));
    if (!delta || delta !== '..' && !delta.startsWith(`..${sep}`) && !isAbsolute(delta)) throw new Error('--out receipt must be outside the new --workspace.');
  }
  const required = (key) => { if (!v[key]?.trim()) throw new Error(`--${key} is required.`); return resolve(v[key]); };
  let native;
  if (operation === 'backup') native = ['ble-backup', join(workspace, 'settings.dat'), ...(v.pair ? ['--pair'] : [])];
  else if (operation === 'trial-prepare') {
    const slot = positiveInteger(v.slot?.replace(/^C/i, ''), 'slot', 7);
    native = ['ble-trial-prepare', required('backup'), '--recipe', required('recipe'), '--slot', String(slot), '--out', workspace];
  } else {
    if (!v[lab] || operation !== 'trial-check' && !v[consent]) throw new Error(`The supervised trial requires --${lab}${operation === 'trial-check' ? '' : ` and --${consent}`}. Nothing was sent.`);
    const key = operation === 'trial-write' ? 'review' : 'trial';
    native = [`ble-${operation}`, `--${key}`, required(key), '--out', workspace, `--${lab}`, ...(v[consent] ? [`--${consent}`] : [])];
  }
  return { operation, values: v, native, workspace };
}

export async function runBluetooth(args, execute = runHelper) {
  if (!args.length || args.includes('--help')) { console.log(BLUETOOTH_HELP); return 0; }
  let emit;
  try {
    const { operation, values: v, native, workspace } = bluetoothInvocation(args);
    emit = receiptWriter(v.out);
    const base = { schema_version: 'dialin.bluetooth.v1', operation, production_writes: 'blocked',
      supported_usb_profile: 'X100VI 1.10 on the tested macOS host' };
    if (operation === 'status' || operation === 'apply') {
      emit({ ...base, result: 'blocked', device: 'NOT_USED', reason: 'Production Bluetooth recipe writes await completed physical acceptance. USB-C is the supported write path; the supervised Bluetooth trial is experimental.' }); emit = null;
      return operation === 'status' ? 0 : 3;
    }
    if (operation === 'backup') {
      mkdirSync(dirname(workspace), { recursive: true, mode: 0o700 });
      mkdirSync(workspace, { mode: 0o700 });
    }
    const execution = await execute(native);
    let details, artifact;
    if (operation === 'backup') {
      const file = join(workspace, 'settings.dat');
      try { artifact = { file, bytes: statSync(file).size }; } catch { /* failed before backup saved */ }
    } else {
      try { details = JSON.parse(readFileSync(join(workspace, operation === 'trial-prepare' ? 'review.json' : 'result.json'), 'utf8')); } catch { /* failed before recording */ }
    }
    const complete = execution.code === 0 && Boolean(artifact || details);
    const send = emit; emit = null;
    send({ ...base, result: complete ? operation === 'trial-prepare' ? 'prepared_offline' : 'completed' : 'not_verified',
      native_exit_code: execution.code, ...(execution.signal ? { signal: execution.signal } : {}), workspace,
      ...(artifact ? { backup: artifact } : {}), ...(details ? { details } : {}),
      device: operation === 'trial-prepare' ? 'NOT_USED' : 'REQUESTED',
      ...(operation === 'trial-check' ? { restart: 'OWNER_MUST_CONFIRM' } : {}) });
    return complete ? 0 : execution.code || 3;
  } catch (error) {
    if (emit) emit({ schema_version: 'dialin.bluetooth.v1', result: 'failed', production_writes: 'blocked', error: error.message });
    console.error(`bluetooth: ${error.message}`); return 2;
  }
}
