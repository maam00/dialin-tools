import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

test('desktop demo composes real boundaries and marks unperformed device/visual stages', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'dialin-composed-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const out = join(dir, 'demo');
  const result = spawnSync(process.execPath, ['scripts/dialin.mjs', 'demo', '--out', out], {
    cwd: fileURLToPath(new URL('../../', import.meta.url)), encoding: 'utf8', timeout: 20000,
    env: { ...process.env, ANTHROPIC_API_KEY: '', DIALIN_MODEL_TRANSPORT: 'cli', DIALIN_CLAUDE: '/must-not-run' },
  });
  assert.equal(result.status, 0, result.stderr);
  const read = (name) => JSON.parse(readFileSync(join(out, name), 'utf8'));
  const receipt = read('run.json'), plan = read('plan.json'), preparation = read('camera-preparation.json'), edit = read('edit.json');
  assert.equal(receipt.provider_calls, 0);
  assert.equal(receipt.device_operations, 0);
  assert.equal(receipt.stages.visual_review, 'NOT_RUN');
  assert.equal(receipt.stages.photo_import, 'NOT_RUN');
  assert.equal(preparation.validation.valid, true);
  assert.equal(preparation.transfer_authorized, false);
  assert.equal(preparation.readiness.bluetooth.state, 'blocked');
  assert.deepEqual(preparation.placements.map((p) => p.slot), plan.plan.write.slots);
  assert.equal(edit.selected_ids[0], 'arrival');
  assert.equal(edit.selected_ids.at(-1), 'return');
  assert.ok(edit.selected_ids.includes('boarding'));
  assert.ok(!edit.selected_ids.includes('test-frame'));
  const repeat = spawnSync(process.execPath, ['scripts/dialin.mjs', 'demo', '--out', out], {
    cwd: fileURLToPath(new URL('../../', import.meta.url)), encoding: 'utf8', timeout: 20000,
  });
  assert.notEqual(repeat.status, 0);
  assert.match(repeat.stderr, /already exists\. Choose a new --out directory/);
  assert.doesNotMatch(repeat.stderr, /EEXIST/);
  assert.deepEqual(read('run.json'), receipt);
  assert.ok(receipt.artifacts.includes('SUMMARY.md'));
  const summary = readFileSync(join(out, 'SUMMARY.md'), 'utf8');
  assert.match(summary, /offline fixture/);
  assert.match(summary, /Nothing here is an AI response to your scene, a camera write, or a review of real photographs/);
  assert.match(summary, /Camera write, photo import, visual review, export of originals \| Not run/);
  for (const slot of plan.plan.write.slots) assert.match(summary, new RegExp(`\\| C${slot} \\|`));
  assert.match(summary, /bluetooth: `blocked`/);
  assert.match(summary, /no photograph was opened/);
  assert.ok(!summary.includes(dir), 'the readable summary does not embed local paths');
  assert.match(result.stderr, /SUMMARY\.md/);
});

test('demo explains a missing TypeScript runtime and creates nothing', (t) => {
  const isolated = mkdtempSync(join(tmpdir(), 'dialin-demo-bootstrap-'));
  t.after(() => rmSync(isolated, { recursive: true, force: true }));
  const root = fileURLToPath(new URL('../../', import.meta.url));
  mkdirSync(join(isolated, 'scripts')); mkdirSync(join(isolated, 'modules'));
  cpSync(join(root, 'scripts/dialin.mjs'), join(isolated, 'scripts/dialin.mjs'));
  for (const file of ['catalog.mjs', 'doctor.mjs', 'demo.mjs']) cpSync(join(root, 'modules', file), join(isolated, 'modules', file));
  const result = spawnSync(process.execPath, ['scripts/dialin.mjs', 'demo', '--out', 'demo-run'], { cwd: isolated, encoding: 'utf8', timeout: 20000 });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /TypeScript runtime missing\. Run npm ci --ignore-scripts/);
  assert.equal(existsSync(join(isolated, 'demo-run')), false);
});
