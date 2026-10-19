import { parseArgs } from 'node:util';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { canonicalPath, positiveInteger, receiptWriter, runHelper } from '../native-helper.mjs';

export const IMPORT_HELP = `Import originals with the optional macOS helper. No iPhone app is required.
Setup: node scripts/dialin.mjs doctor import; node scripts/dialin.mjs native build

  import wifi --last 7 --dest .dialin/imported [--pair] [--out receipt.json]
  import usb --since 2026-10-19 --dest .dialin/imported
  import folder --from /path/to/DCIM --all --dest .dialin/imported
  import wifi --rehearse --last 3 --dest .dialin/fake-import

Choose exactly one: --last N, --since YYYY-MM-DD (also today/yesterday), or --all.
JPEG/HEIF by default; --include-raw also copies RAF (Wi-Fi RAF is not hardware-qualified).
--dry-run lists a plan without copying; live USB/Wi-Fi routes STILL contact the camera.
--pair explicitly registers this Mac. Unplug USB before Wi-Fi; Bluetooth wakes the camera,
then Wi-Fi carries photos and temporarily takes this Mac off its usual network.
The helper attempts to rejoin the previous network. Interrupted-session recovery is unqualified.
--rehearse uses a local fake camera only, with no Bluetooth or Wi-Fi change; output is synthetic.
--dest holds dated folders and manifests; reruns resume without overwriting originals.
--out is a new JSON receipt; otherwise JSON goes to stdout. Progress goes to stderr.
Only X100VI 1.10 on the tested Mac has physical Wi-Fi evidence. See modules/import/README.md.`;

export function importInvocation(args) {
  const { values: v, positionals: p } = parseArgs({ args, strict: true, allowPositionals: true, options: {
    dest: { type: 'string' }, from: { type: 'string' }, last: { type: 'string' }, since: { type: 'string' }, all: { type: 'boolean' },
    pair: { type: 'boolean' }, rehearse: { type: 'boolean' }, 'dry-run': { type: 'boolean' }, 'include-raw': { type: 'boolean' }, out: { type: 'string' },
  } });
  if (p.length !== 1 || !['wifi', 'usb', 'folder'].includes(p[0])) throw new Error('Use import wifi, usb or folder.');
  const route = p[0];
  if (!v.dest?.trim()) throw new Error('--dest is required. Choose a local import folder.');
  if ([v.last !== undefined, v.since !== undefined, v.all === true].filter(Boolean).length !== 1) throw new Error('Choose exactly one of --last, --since or --all.');
  if (v.last !== undefined) positiveInteger(v.last, 'last');
  if (v.since !== undefined && !['today', 'yesterday'].includes(v.since)) {
    const d = new Date(`${v.since}T00:00:00Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(v.since) || !Number.isFinite(+d) || d.toISOString().slice(0, 10) !== v.since) throw new Error('--since must be a real YYYY-MM-DD date, today or yesterday.');
  }
  if (route !== 'wifi' && (v.pair || v.rehearse)) throw new Error('--pair and --rehearse apply only to Wi-Fi.');
  if (v.pair && v.rehearse) throw new Error('--rehearse cannot pair a camera. Remove --pair.');
  if (route === 'folder' ? !v.from?.trim() : v.from !== undefined) throw new Error('--from is required only for import folder.');
  if (route === 'folder') {
    const source = canonicalPath(v.from);
    for (const target of [v.dest, v.out].filter(Boolean)) {
      const delta = relative(source, canonicalPath(target));
      if (!delta || delta !== '..' && !delta.startsWith(`..${sep}`) && !isAbsolute(delta)) throw new Error('Import destination and receipt must be outside the source folder.');
    }
  }
  const native = [`import-${route}`, ...(v.from ? [resolve(v.from)] : []), '--dest', resolve(v.dest)];
  for (const name of ['last', 'since']) if (v[name] !== undefined) native.push(`--${name}`, v[name]);
  for (const name of ['all', 'pair', 'rehearse', 'dry-run']) if (v[name]) native.push(`--${name}`);
  if (!v['include-raw']) native.push('--no-raw');
  return { route, native, values: v };
}

export async function runImport(args, execute = runHelper) {
  if (!args.length || args.includes('--help')) { console.log(IMPORT_HELP); return 0; }
  let emit, temp;
  try {
    const { route, native, values: v } = importInvocation(args);
    emit = receiptWriter(v.out);
    temp = mkdtempSync(join(tmpdir(), 'dialin-import-receipt-'));
    const path = join(temp, 'result.json');
    const execution = await execute([...native, '--result-file', path]);
    let details;
    try { details = JSON.parse(readFileSync(path, 'utf8')); } catch { /* no summary if connection failed */ }
    const complete = execution.code === 0 && details?.schema_version === 'dialin.import-summary.v1' && !details.interrupted && details.failures?.length === 0;
    const result = { schema_version: 'dialin.import.v1', route, result: complete ? v.rehearse ? 'fixture_rehearsal' : v['dry-run'] ? 'planned' : 'completed' : 'incomplete',
      native_exit_code: execution.code, ...(execution.signal ? { signal: execution.signal } : {}),
      device: v.rehearse || route === 'folder' ? 'NOT_USED' : 'REQUESTED',
      network_restore: route === 'wifi' && !v.rehearse ? 'NOT_VERIFIED' : 'NOT_APPLICABLE',
      ...(details ? { summary: details } : { note: 'No import summary returned. Read stderr; existing completed files and manifests remain in --dest.' }) };
    const send = emit; emit = null; send(result);
    return complete ? 0 : execution.code || 3;
  } catch (error) {
    if (emit) emit({ schema_version: 'dialin.import.v1', result: 'failed', error: error.message });
    console.error(`import: ${error.message}`); return 2;
  } finally { if (temp) rmSync(temp, { recursive: true, force: true }); }
}
