// Explicit macOS software integration check, separate from npm test. A loopback fake only; no camera or radios.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { helperStatus, runProcess } from '../../modules/native-helper.mjs';
import { runImport } from '../../modules/import/cli.mjs';

const status = helperStatus();
assert.ok(status.ready, 'Run node scripts/dialin.mjs native build first (macOS 26+, Swift 6.2+).');
const dir = mkdtempSync(join(tmpdir(), 'dialin-native-wireless-'));
try {
  // Even if validation regresses, --rehearse confines these cases to the built-in fake camera.
  for (const args of [['--dryrun'], ['--last', '0'], ['--port', '999999'], ['--pair'], ['--since', 'invalid'], ['--last']]) {
    const r = await runProcess(status.binary, ['import-wifi', '--rehearse', '--dest', join(dir, 'invalid'), ...args], { capture: true });
    assert.notEqual(r.code, 0, `native validation accepted ${args}`);
    assert.ok(!r.stdout.includes('REHEARSAL:'), 'validation must run before starting even the fake transport');
  }
  const dest = join(dir, 'imported'), first = join(dir, 'first.json'), second = join(dir, 'second.json');
  assert.equal(await runImport(['wifi', '--rehearse', '--last', '3', '--dest', dest, '--out', first]), 0);
  const a = JSON.parse(readFileSync(first));
  assert.equal(a.result, 'fixture_rehearsal'); assert.equal(a.device, 'NOT_USED');
  assert.ok(a.summary.saved > 0); assert.ok(a.summary.bytes > 0); assert.deepEqual(a.summary.failures, []);
  const manifests = a.summary.folders.map(folder => [join(folder, 'manifest.json'), readFileSync(join(folder, 'manifest.json'), 'utf8')]);
  const originals = manifests.flatMap(([path, text]) => JSON.parse(text).files.map(entry => {
    const file = join(path, '..', entry.file);
    return [file, createHash('sha256').update(readFileSync(file)).digest('hex')];
  }));
  assert.equal(await runImport(['wifi', '--rehearse', '--last', '3', '--dest', dest, '--out', second]), 0);
  const b = JSON.parse(readFileSync(second)); assert.equal(b.summary.saved, 0);
  // Undated files may need downloading before EXIF supplies the day and detects the duplicate.
  // The pre-download plan's already_imported count can therefore remain zero.
  for (const [path, original] of manifests) assert.equal(readFileSync(path, 'utf8'), original, 'repeat import must not replace originals or rewrite completed manifests');
  for (const [path, hash] of originals) assert.equal(createHash('sha256').update(readFileSync(path)).digest('hex'), hash);
  console.log('Native wireless smoke passed: strict parsing, fake-camera reconnect/resume, JSON receipt and duplicate preservation. Hardware: NOT RUN.');
} finally { rmSync(dir, { recursive: true, force: true }); }
