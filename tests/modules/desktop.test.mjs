import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { mkdtempSync, mkdirSync, cpSync, rmSync, writeFileSync, readFileSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = fileURLToPath(new URL('../../', import.meta.url));
const command = (args, options = {}) => spawnSync(process.execPath, ['scripts/dialin.mjs', ...args], { cwd: root, encoding: 'utf8', timeout: 20000, ...options });

test('published component shortcuts all dispatch help without legacy device entry points', () => {
  const scripts = JSON.parse(readFileSync(join(root,'package.json'),'utf8')).scripts;
  for (const name of ['cam','plan','photos','curate','recipes','dialin']) {
    const [executable,...args] = scripts[name].split(' ');
    assert.equal(executable,'node');
    assert.equal(args[0],'scripts/dialin.mjs');
    const result = spawnSync(process.execPath,[...args,'--help'],{cwd:root,encoding:'utf8',timeout:20000});
    assert.equal(result.status,0,result.stderr);
  }
  assert.equal(scripts.live,undefined);
  assert.equal(scripts.day,undefined);
});

test('every package script points at files that exist in this tree', () => {
  const scripts = JSON.parse(readFileSync(join(root,'package.json'),'utf8')).scripts;
  for (const [name, line] of Object.entries(scripts)) {
    for (const path of line.match(/(?:scripts|tests|modules)\/[\w./-]+\.(?:ts|mjs|js|sh|py)\b/g) ?? []) {
      assert.ok(existsSync(join(root, path)), `npm run ${name} needs ${path}`);
    }
  }
  assert.equal(scripts.bakeoff, undefined, 'bakeoff needs private frames and a paid provider key');
});

test('help and module discovery do not need provider credentials or hardware', () => {
  const result = command(['--help'], { env: { PATH: process.env.PATH, ANTHROPIC_API_KEY: '' } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /No iPhone app is required/);
  const modules = command(['modules']);
  assert.equal(modules.status, 0);
  assert.ok(JSON.parse(modules.stdout).components.some((m) => m.id === 'photos'));
});

test('bootstrap help/doctor/Python components work without node_modules', (t) => {
  const isolated = mkdtempSync(join(tmpdir(), 'dialin-bootstrap-'));
  t.after(() => rmSync(isolated, { recursive: true, force: true }));
  mkdirSync(join(isolated, 'scripts')); mkdirSync(join(isolated, 'modules'));
  cpSync(join(root, 'scripts/dialin.mjs'), join(isolated, 'scripts/dialin.mjs'));
  for (const file of ['catalog.mjs', 'doctor.mjs']) cpSync(join(root, 'modules', file), join(isolated, 'modules', file));
  const help = command(['--help'], { cwd: isolated });
  assert.equal(help.status, 0, help.stderr);
  const doctor = command(['doctor', 'plan'], { cwd: isolated });
  assert.equal(doctor.status, 1);
  assert.equal(JSON.parse(doctor.stdout).checks.find((c) => c.key === 'tsx').status, 'missing');
});

test('unknown commands/options fail without loading live code', () => {
  const result = command(['upload-everything']);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Unknown command/);
  assert.notEqual(command(['doctor', 'no-such-module']).status, 0);
});

test('doctor reports key presence without printing it or implying validity', () => {
  const result = command(['doctor', 'recipes'], { env: { ...process.env, ANTHROPIC_API_KEY: 'test-only-never-print-this' } });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.stdout.includes('test-only-never-print-this'));
  assert.equal(JSON.parse(result.stdout).api_key, 'present_not_verified');
  assert.equal(JSON.parse(result.stdout).device, 'NOT_CHECKED');
});

test('recipe knowledge commands read an installed catalog named by DIALIN_RECIPE_CATALOG', () => {
  const env = { ...process.env, DIALIN_RECIPE_CATALOG: join(root, 'tests/fixtures/recipe-catalog.fixture.json'), DIALIN_RECIPE_CATALOG_FIXTURE: '1' };
  const source = command(['recipes', 'sources', '--query', 'Harbor Glow 400', '--limit', '10'], { env });
  assert.equal(source.status, 0, source.stderr);
  assert.equal(source.stderr, '');
  const catalog = JSON.parse(source.stdout);
  assert.equal(catalog.matches.length, 2);
  assert.ok(catalog.matches.every((match) => match.reference.source_url.startsWith('https://recipes.example/')));
  assert.ok(catalog.matches.some((match) => Object.keys(match.reference.source_facts.fields).length > 5));
  const context = command(['recipes', 'knowledge', '--query', 'family portraits in mixed light', '--limit', '4'], { env });
  assert.equal(context.status, 0, context.stderr);
  const parsed = JSON.parse(context.stdout);
  assert.equal(parsed.planner_context.retrieval.available_references, 19);
  assert.equal(parsed.planner_context.retrieval.visual_assessment, 'not_performed');
  assert.equal(command(['recipes', 'knowledge', '--limit', '25'], { env }).status, 1);
  assert.equal(command(['recipes', 'sources', '--file', 'unused.json'], { env }).status, 1);
  // A real catalog may not use reserved fixture hosts: without the fixture flag this file is refused, loudly.
  const unflagged = command(['recipes', 'sources'], { env: { ...env, DIALIN_RECIPE_CATALOG_FIXTURE: '' } });
  assert.equal(unflagged.status, 1);
  assert.match(unflagged.stderr, /reserved fixture host/);
});

test('without a private catalog, sources/knowledge/analyze print one note and the built-in guidance, never crash', () => {
  for (const [label, value] of [['default path absent', join(tmpdir(), 'dialin-no-catalog-here.json')], ['disabled', 'none']]) {
    const env = { ...process.env, DIALIN_RECIPE_CATALOG: value, DIALIN_RECIPE_CATALOG_FIXTURE: '' };
    for (const args of [['sources'], ['sources', '--query', 'anything', '--full'], ['knowledge', '--query', 'family portraits in open shade'], ['knowledge', '--full'], ['analyze']]) {
      const result = command(['recipes', ...args], { env });
      assert.equal(result.status, 0, `${label} ${args.join(' ')}: ${result.stderr}`);
      const lines = result.stderr.trim().split('\n');
      assert.equal(lines.length, 1, result.stderr);
      assert.match(lines[0], new RegExp(`^recipes ${args[0]}: `));
      assert.match(lines[0], /20 film-simulation profiles, 31 setting rules and 10 original directions/);
      assert.match(lines[0], /set DIALIN_RECIPE_CATALOG=\/path\/to\/catalog\.json/);
      const output = JSON.parse(result.stdout);
      assert.equal(output.catalog.installed, false);
      assert.equal(output.source, 'built_in_guidance');
      assert.equal(output.built_in_guidance.original_directions, 10);
      if (args[0] === 'knowledge') {
        assert.equal(output.planner_context.retrieval.selection_status, 'no_catalog_installed');
        if (args.includes('--full')) assert.match(output.planner_context.context, /ORIGINAL RECIPE GUIDANCE/);
      }
    }
  }
  const list = command(['recipes', 'list'], { env: { ...process.env, DIALIN_RECIPE_CATALOG: 'none' } });
  assert.equal(list.status, 0, list.stderr);
  assert.equal(JSON.parse(list.stdout).total_records, 10);
});

test('photo doctor rejects an installed but incompatible preview library', (t) => {
  const isolated = mkdtempSync(join(tmpdir(), 'dialin-old-pillow-'));
  t.after(() => rmSync(isolated, { recursive: true, force: true }));
  writeFileSync(join(isolated, 'PIL.py'), '__version__ = "10.0.0"\n');
  const result = command(['doctor', 'photos'], {env: {...process.env, PYTHONPATH:isolated}});
  assert.equal(result.status,1);
  const pillow = JSON.parse(result.stdout).checks.find((c)=>c.key==='pillow');
  assert.equal(pillow.status,'missing');
  assert.match(pillow.detail,/10\.0\.0/);
});

test('a symlinked checkout path still runs commands instead of exiting silently', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'dialin-linked-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const link = join(dir, 'checkout');
  symlinkSync(root, link, process.platform === 'win32' ? 'junction' : 'dir');
  const help = spawnSync(process.execPath, [join(link, 'scripts', 'dialin.mjs'), '--help'], { encoding: 'utf8', timeout: 20000 });
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /First success/);
  const unknown = spawnSync(process.execPath, [join(link, 'scripts', 'dialin.mjs'), 'upload-everything'], { encoding: 'utf8', timeout: 20000 });
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /Unknown command/);
});

test('doctor prints a human summary on stderr and keeps stdout as JSON', () => {
  const result = command(['doctor', 'recipes']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).component, 'recipes');
  assert.match(result.stderr, /^doctor recipes: READY/);
  const broken = command(['doctor', 'curate'], { env: { ...process.env, DIALIN_PYTHON: join(tmpdir(), 'dialin-no-such-python') } });
  assert.equal(broken.status, 1);
  assert.match(broken.stderr, /NOT READY[\s\S]*missing python: Install Python 3\.10\+/);
});

test('doctor without a component requires core components but only reports the optional import helper', async () => {
  const { diagnose, describeDoctor } = await import('../../modules/doctor.mjs');
  const report = diagnose();
  const imported = report.components.find((c) => c.id === 'import');
  assert.equal(imported.optional, true);
  assert.equal(report.ready, report.components.every((c) => c.ready || c.optional));
  const text = describeDoctor({ component: 'all', ready: true,
    components: [{ id: 'recipes', ready: true }, { id: 'import', ready: false, optional: true, missing: ['macos', 'swift'] }],
    checks: [{ key: 'node', status: 'ready' }, { key: 'macos', status: 'missing', fix: 'Use an SD-card reader.' }] });
  assert.match(text, /READY/);
  assert.match(text, /missing macos \(optional import helper\)/);
  assert.match(text, /SD-card reader or OS import/);
  const python = command(['doctor', 'curate'], { env: { ...process.env, DIALIN_PYTHON: join(tmpdir(), 'dialin-no-such-python') } });
  assert.equal(JSON.parse(python.stdout).ready, false);
  const all = command(['doctor'], { env: { ...process.env, DIALIN_PYTHON: join(tmpdir(), 'dialin-no-such-python') } });
  assert.equal(all.status, 1, 'a missing core prerequisite still fails the overall check');
});

test('Python discovery falls back to the platform launcher name without a local environment', async (t) => {
  const isolated = mkdtempSync(join(tmpdir(), 'dialin-python-'));
  t.after(() => rmSync(isolated, { recursive: true, force: true }));
  mkdirSync(join(isolated, 'modules'));
  for (const file of ['catalog.mjs', 'doctor.mjs']) cpSync(join(root, 'modules', file), join(isolated, 'modules', file));
  const { pythonExecutable } = await import(pathToFileURL(join(isolated, 'modules', 'doctor.mjs')).href);
  assert.equal(pythonExecutable({}, 'win32'), 'python');
  assert.equal(pythonExecutable({}, 'linux'), 'python3');
  assert.equal(pythonExecutable({}, 'darwin'), 'python3');
  assert.equal(pythonExecutable({ DIALIN_PYTHON: 'custom-python' }, 'win32'), 'custom-python');
});

test('closing a pipe early is not reported as a crash', async () => {
  const child = spawn(process.execPath, ['scripts/dialin.mjs', 'recipes', 'analyze'], { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  child.stdout.once('data', () => child.stdout.destroy());
  const code = await new Promise((resolve) => child.once('close', resolve));
  assert.equal(code, 0, stderr);
  assert.doesNotMatch(stderr, /EPIPE|Unhandled/);
});
