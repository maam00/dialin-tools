// The dispatcher must not orphan a Python command when it is stopped with SIGTERM: the child gets an interrupt (so its
// own clean-up runs) and the dispatcher reports 143. Uses a synthetic Python script; no photos, camera or network.
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as pause } from 'node:timers/promises';
import { runPython } from '../../scripts/dialin.mjs';

const CHILD = `import pathlib, sys, time
ready, cleaned = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
try:
    ready.write_text("ready")
    time.sleep(30)
except KeyboardInterrupt:
    cleaned.write_text("cleaned up after interrupt")
    sys.exit(130)
`;

async function waitFor(path) {
  for (let i = 0; i < 200 && !existsSync(path); i++) await pause(25);
  assert.ok(existsSync(path), 'the Python child started');
}

test('SIGTERM to the dispatcher interrupts its Python child, which cleans up, and exits 143', { skip: process.platform === 'win32' ? 'POSIX signals' : false }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'dialin-signal-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const script = join(dir, 'child.py'), ready = join(dir, 'ready'), cleaned = join(dir, 'cleaned');
  writeFileSync(script, CHILD);
  const before = process.listenerCount('SIGTERM');
  const running = runPython(script, [ready, cleaned]);
  await waitFor(ready);
  process.emit('SIGTERM', 'SIGTERM'); // the listener runtime path, without signalling the test runner itself
  assert.equal(await running, 143);
  assert.equal(readFileSync(cleaned, 'utf8'), 'cleaned up after interrupt');
  assert.equal(process.listenerCount('SIGTERM'), before, 'the forwarding listener is removed afterwards');
});
