import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import test from 'node:test';
import { inflateSync } from 'node:zlib';
import { assemble, auditTree, GENERATED_CONFIG, geometricPNG, readRecipeCatalog, safePath, syntheticBackup } from '../../scripts/public-release/export.mjs';

// POSIX-only behavior: Windows symlinks need extra privileges and file modes have no 0o755/0o600 equivalent.
const WINDOWS = process.platform === 'win32' ? 'POSIX symlink/file-mode behavior' : false;

function setup(t) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dialin-release-test-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const sourceRoot = join(dir, 'source'); mkdirSync(sourceRoot);
  writeFileSync(join(sourceRoot, 'README.md'), 'Original source\n');
  return { dir, sourceRoot, output: join(dir, 'candidate'), manifest: { files: ['README.md'] }, generate: false };
}

test('release selection ships original recipe guidance and no private recipe catalog, its tooling or its tests', () => {
  const manifest = JSON.parse(readFileSync(new URL('../../release/source-manifest.json', import.meta.url), 'utf8'));
  const files = new Set(manifest.files.map((entry) => typeof entry === 'string' ? entry : entry.path));
  for (const required of ['data/recipes/original-book.json', 'lib/plan/expert-knowledge.ts', 'lib/plan/expert-references.ts',
    'modules/recipes/knowledge.ts', 'modules/recipes/analysis.ts', 'modules/recipes/scenarios.ts', 'modules/planner/sources.ts',
    'tests/modules/recipe-scenarios.test.ts', 'tests/fixtures/recipe-catalog.fixture.json']) assert.ok(files.has(required), required);
  for (const privateFile of ['data/recipe-knowledge/catalog.json', 'data/recipe-knowledge/README.md', 'docs/RECIPE-KNOWLEDGE.md', 'docs/RECIPE-SCENARIO-VALIDATION.md',
    'scripts/export-recipe-knowledge.ts', 'scripts/discover-recipe-universe.py', 'scripts/extract-recipe-facts.py', 'scripts/tests/test_recipe_facts.py',
    'tests/modules/recipe-catalog.private.test.ts']) assert.ok(!files.has(privateFile), privateFile);
  assert.ok(![...files].some((path) => path.startsWith('data/recipe-knowledge/') || path.startsWith('data/recipe-universe/')));
});

test('release selection ships the community-practice priors, their generator and tests', () => {
  const manifest = JSON.parse(readFileSync(new URL('../../release/source-manifest.json', import.meta.url), 'utf8'));
  const files = new Set(manifest.files.map((entry) => typeof entry === 'string' ? entry : entry.path));
  for (const required of ['data/recipe-space/priors.json', 'modules/recipes/space.ts', 'scripts/build-recipe-space.ts', 'tests/modules/recipe-space.test.ts']) assert.ok(files.has(required), required);
});

// An invented private catalog: the audit must find its host, publisher, IDs and titles without ever returning them.
const syntheticCatalog = {
  articles: [{ id: 'syn-0011aabb', title: 'Lighthouse Amber', aliases: ['Light House Amber'], source_url: 'https://www.recipes-journal.example/2025/01/01/lighthouse-amber/', index_urls: ['https://recipes-journal.example/recipes/'], publisher: 'Harbor Recipe Journal' }],
  references: [
    { id: 'syn-0011aabb--variant-1', article_id: 'syn-0011aabb', title: 'Lighthouse Amber (Sensor A)', article_title: 'Lighthouse Amber', variant_name: 'Lighthouse Amber (Sensor A)', source_url: 'https://www.recipes-journal.example/2025/01/01/lighthouse-amber/', publisher: 'Harbor Recipe Journal' },
    { id: 'syn-0022ccdd', article_id: 'syn-0011aabb', title: '“Classic Chrome”', article_title: 'Lighthouse Amber', variant_name: null, source_url: 'https://www.recipes-journal.example/2025/01/01/lighthouse-amber/', publisher: 'Harbor Recipe Journal' },
    { id: 'syn-0033eeff', article_id: 'syn-0011aabb', title: '[unnamed public settings block 1]', article_title: 'Lighthouse Amber', variant_name: null, source_url: 'https://www.recipes-journal.example/2025/01/01/lighthouse-amber/', publisher: 'Harbor Recipe Journal' },
  ],
};

test('the publisher-content audit finds a catalog host, publisher, ID or title in any public file without returning it', (t) => {
  const args = setup(t);
  const leaks = {
    'host.md': 'See https://recipes-journal.example/2025/ for details.\n',
    'www-host.md': 'Mirror: WWW.RECIPES-JOURNAL.EXAMPLE\n',
    'publisher.md': 'Inspired by harbor  recipe\njournal articles.\n',
    'id.json': '{"id":"syn-0011aabb--variant-1"}\n',
    'title.ts': 'const look = "Lighthouse Amber (Sensor A)";\n',
    'alias.md': 'Try Light House Amber tonight.\n',
    'curly.md': 'Uses \u201cLighthouse Amber\u201d.\n',
  };
  for (const [name, text] of Object.entries(leaks)) writeFileSync(join(args.sourceRoot, name), text);
  // Fujifilm simulation names, placeholders, a lower-case phrase and a longer different word are not findings.
  writeFileSync(join(args.sourceRoot, 'clean.md'), 'Classic Chrome and Acros. [unnamed public settings block 1]. A lighthouse amber glow. LighthouseAmberish.\n');
  const manifest = { files: [...Object.keys(leaks), 'clean.md'] };
  assert.throws(() => assemble({ ...args, manifest, recipeCatalog: syntheticCatalog }), (error) => {
    const byPath = Object.fromEntries(Object.keys(leaks).map((path) => [path, error.findings.filter((f) => f.path === path).map((f) => f.rule)]));
    assert.deepEqual(byPath['host.md'], ['publisher-source-host']);
    assert.deepEqual(byPath['www-host.md'], ['publisher-source-host']);
    assert.deepEqual(byPath['publisher.md'], ['publisher-name']);
    assert.deepEqual(byPath['id.json'], ['catalog-reference-id']);
    assert.deepEqual(byPath['title.ts'], ['catalog-recipe-title']);
    assert.deepEqual(byPath['alias.md'], ['catalog-recipe-title']);
    assert.deepEqual(byPath['curly.md'], ['catalog-recipe-title']);
    assert.ok(!error.findings.some((f) => f.path === 'clean.md'), JSON.stringify(error.findings));
    const serialized = JSON.stringify(error.findings).toLowerCase();
    for (const secret of ['recipes-journal', 'harbor recipe', 'lighthouse', 'syn-00']) assert.ok(!serialized.includes(secret), secret);
    return true;
  });
  assert.equal(existsSync(args.output), false);
  assert.equal(existsSync(`${args.output}.assembling`), false);
});

test('a catalog title wrapped across a line or spaced differently is still found', (t) => {
  const args = setup(t);
  const leaks = { 'wrapped.md': 'This look borrows from Lighthouse\nAmber at dusk.\n', 'spaced.md': 'Lighthouse  Amber (Sensor\tA)\n' };
  for (const [name, text] of Object.entries(leaks)) writeFileSync(join(args.sourceRoot, name), text);
  writeFileSync(join(args.sourceRoot, 'clean.md'), 'LighthouseAmberish, and a lighthouse\namber glow.\n');
  assert.throws(() => assemble({ ...args, manifest: { files: [...Object.keys(leaks), 'clean.md'] }, recipeCatalog: syntheticCatalog }), (error) => {
    for (const path of ['wrapped.md', 'spaced.md']) assert.deepEqual(error.findings.filter((f) => f.path === path).map((f) => f.rule), ['catalog-recipe-title'], path);
    assert.ok(!error.findings.some((f) => f.path === 'clean.md'), JSON.stringify(error.findings));
    return true;
  });
});

test('a personal selection is refused without its private catalog; a clean tree passes and the receipt keeps only counts', (t) => {
  const args = setup(t);
  const policy = { schema_version: 'dialin.private-copy-transforms.v1', rules: [] };
  const manifest = { files: ['README.md'], requires_copy_policy: true };
  assert.throws(() => assemble({ ...args, manifest, policy }), /needs the private recipe catalog/);
  assert.equal(existsSync(args.output), false);
  const receipt = assemble({ ...args, manifest, policy, recipeCatalog: syntheticCatalog });
  assert.equal(receipt.audit.passed, true);
  assert.deepEqual(receipt.audit.publisher_content, { checked: true, terms: { hosts: 1, publishers: 1, ids: 4, titles: 3 } });
  assert.ok(!JSON.stringify(receipt).includes('Lighthouse'));
  assert.equal(readRecipeCatalog(args.sourceRoot, 'none'), null);
  assert.equal(readRecipeCatalog(args.sourceRoot, join(args.dir, 'missing.json')), null);
});

test('exact selection excludes untracked secrets and source history, preserving the source', (t) => {
  const args = setup(t);
  writeFileSync(join(args.sourceRoot, '.env'), 'PRIVATE_VALUE=do-not-copy\n');
  mkdirSync(join(args.sourceRoot, '.git')); writeFileSync(join(args.sourceRoot, '.git', 'config'), 'private remote');
  const receipt = assemble(args);
  assert.deepEqual(receipt.files.map((r) => r.path), ['README.md']);
  assert.equal(auditTree(args.output, receipt.files).passed, true);
  assert.equal(readFileSync(join(args.sourceRoot, '.env'), 'utf8'), 'PRIVATE_VALUE=do-not-copy\n');
  assert.equal(existsSync(join(args.output, '.git')), false);
});

test('path traversal and forbidden segments cannot enter a positive manifest', (t) => {
  const args = setup(t);
  for (const path of ['../outside', '/absolute', 'x/../../outside', '.git/config', 'a/.env', 'a//b', 'a\\b', 'node_modules/x.js']) {
    assert.throws(() => safePath(path), /Unsafe|forbidden/);
    assert.throws(() => assemble({ ...args, manifest: { files: [path] } }));
  }
  assert.equal(existsSync(args.output), false);
});

test('duplicate destinations and missing sources fail before creating a candidate', (t) => {
  const args = setup(t);
  assert.throws(() => assemble({ ...args, manifest: { files: ['README.md', 'README.md'] } }), /Duplicate/);
  assert.throws(() => assemble({ ...args, manifest: { files: ['missing.txt'] } }));
  assert.equal(existsSync(args.output), false);
});

test('a personal source selection cannot silently omit its required copy policy', (t) => {
  const args = setup(t);
  assert.throws(() => assemble({ ...args, manifest: { ...args.manifest, requires_copy_policy: true } }), /requires its private copy policy/);
  assert.equal(existsSync(args.output), false);
});

test('leaf and parent symlinks are refused', { skip: WINDOWS }, (t) => {
  const args = setup(t);
  const outside = join(args.dir, 'outside'); mkdirSync(outside); writeFileSync(join(outside, 'file.txt'), 'outside');
  symlinkSync(join(outside, 'file.txt'), join(args.sourceRoot, 'leaf.txt'));
  symlinkSync(outside, join(args.sourceRoot, 'linked'));
  for (const path of ['leaf.txt', 'linked/file.txt']) assert.throws(() => assemble({ ...args, manifest: { files: [path] } }), /Symlink/);
  assert.equal(existsSync(args.output), false);
});

test('existing destinations, unsafe local output and symlink output ancestors are refused', (t) => {
  const args = setup(t);
  mkdirSync(args.output); writeFileSync(join(args.output, 'keep.txt'), 'preserve');
  assert.throws(() => assemble(args), /already exists/);
  assert.equal(readFileSync(join(args.output, 'keep.txt'), 'utf8'), 'preserve');
  assert.throws(() => assemble({ ...args, output: join(args.sourceRoot, 'public') }), /beneath .dialin/);
  if (WINDOWS) return; // symlink ancestor check below needs POSIX symlinks
  symlinkSync(args.dir, join(args.dir, 'alias'));
  assert.throws(() => assemble({ ...args, output: join(args.dir, 'alias', 'new') }), /symlink/);
});

test('secret injection fails without printing matched secret bytes or retaining staging', (t) => {
  const args = setup(t);
  const key = ['sk-ant-', 'A'.repeat(40)].join('');
  writeFileSync(join(args.sourceRoot, 'README.md'), `key=${key}\n`);
  assert.throws(() => assemble(args), (error) => {
    assert.equal(JSON.stringify(error.findings).includes(key), false);
    assert.ok(error.findings.some((f) => f.rule === 'provider-key'));
    return true;
  });
  assert.equal(existsSync(args.output), false);
  assert.equal(existsSync(`${args.output}.assembling`), false);
});

test('private denylist verifies paired identity without returning its value', (t) => {
  const args = setup(t), privateValue = 'PRIVATE_TEST_PAIRING_BYTES';
  writeFileSync(join(args.sourceRoot, 'README.md'), privateValue);
  assert.throws(() => assemble({ ...args, policy: { deny: [{ id: 'private-pairing', value: privateValue }] } }), (error) => {
    assert.deepEqual(error.findings, [{ path: 'README.md', rule: 'private-pairing' }]); return true;
  });
});

test('unapproved binary source is refused', (t) => {
  const args = setup(t); writeFileSync(join(args.sourceRoot, 'capture.dat'), Buffer.from([1, 0, 2]));
  assert.throws(() => assemble({ ...args, manifest: { files: ['capture.dat'] } }), /Unapproved source binary/);
});

test('allowed binary formats still receive secret scans', (t) => {
  const args = setup(t);
  const key = ['sk-ant-', 'Z'.repeat(40)].join('');
  writeFileSync(join(args.sourceRoot, 'font.woff2'), Buffer.concat([Buffer.from([0, 1, 2]), Buffer.from(key)]));
  assert.throws(() => assemble({ ...args, manifest: { files: ['font.woff2'] } }), (error) => {
    assert.ok(error.findings.some((f) => f.rule === 'provider-key'));
    assert.equal(JSON.stringify(error.findings).includes(key), false); return true;
  });
});

test('recorded copy transforms preserve the input; content and modes are deterministic', { skip: WINDOWS }, (t) => {
  const args = setup(t); chmodSync(join(args.sourceRoot, 'README.md'), 0o755);
  const policy = { rules: [{ id: 'sample', from: 'Original', to: 'Public' }] };
  const first = assemble({ ...args, policy });
  const second = assemble({ ...args, output: `${args.output}-second`, policy });
  assert.deepEqual(first, second);
  assert.equal(readFileSync(join(args.sourceRoot, 'README.md'), 'utf8'), 'Original source\n');
  assert.equal(first.files[0].mode, '755');
  assert.deepEqual(first.source_records[0].transforms, ['sample']);
});

test('readback catches modified bytes, mode changes and unexpected files', { skip: WINDOWS }, (t) => {
  const args = setup(t), receipt = assemble(args);
  writeFileSync(join(args.output, 'README.md'), 'changed');
  chmodSync(join(args.output, 'README.md'), 0o755);
  writeFileSync(join(args.output, 'unexpected.txt'), 'extra');
  const rules = auditTree(args.output, receipt.files).errors.map((f) => f.rule);
  assert.ok(rules.includes('sha256')); assert.ok(rules.includes('exact-file-list')); assert.ok(rules.includes('file-mode'));
});

test('synthetic backup has only deliberate header/name/checksum fields and no captured payload', () => {
  const b = inflateSync(syntheticBackup()); assert.equal(b.length, 70524);
  assert.equal(b.subarray(0x34, 0x38).toString(), 'TEST');
  assert.equal(b.subarray(0xf800 + 6 * 0x400 + 0x1e5, 0xf800 + 6 * 0x400 + 0x1e5 + 7).toString(), 'TEST C7');
  assert.ok(b.filter((v) => v !== 0).length < 150);
  assert.deepEqual(syntheticBackup(), syntheticBackup());
});

test('generated PNG contains only image data chunks, no source image or EXIF', () => {
  const b = geometricPNG(32), kinds = []; let at = 8;
  while (at < b.length) { const size = b.readUInt32BE(at); kinds.push(b.subarray(at + 4, at + 8).toString()); at += 12 + size; }
  assert.deepEqual(kinds, ['IHDR', 'IDAT', 'IEND']); assert.deepEqual(b, geometricPNG(32));
});

test('private deny patterns honor flags and never return the matched value', (t) => {
  const args = setup(t), privateValue = 'Private Venue Name';
  writeFileSync(join(args.sourceRoot, 'README.md'), `Lunch at ${privateValue.toUpperCase()}.\n`);
  assert.throws(() => assemble({ ...args, policy: { deny_patterns: [{ id: 'private-venue', regex: '\\bprivate venue name\\b', flags: 'i' }] } }), (error) => {
    assert.deepEqual(error.findings, [{ path: 'README.md', rule: 'private-venue' }]);
    assert.equal(JSON.stringify(error.findings).toLowerCase().includes(privateValue.toLowerCase()), false); return true;
  });
  assert.equal(existsSync(args.output), false);
});

test('the CLI runs when invoked through a symlinked path and fails closed on a missing candidate', { skip: WINDOWS }, (t) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dialin-release-link-')));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  symlinkSync(fileURLToPath(new URL('../../scripts', import.meta.url)), join(dir, 'scripts'));
  const run = spawnSync(process.execPath, [join(dir, 'scripts', 'public-release', 'export.mjs'), 'audit', '--out', join(dir, 'missing-candidate')], { encoding: 'utf8', timeout: 60000 });
  assert.equal(run.status, 1, run.stdout + run.stderr);
  assert.match(run.stderr, /missing-candidate\.source-export\.json/);
});

// The public .gitignore and tsconfig.json are generated from reviewed templates: private folder names stay out.
const template = (name) => readFileSync(new URL(`../../release/templates/${name}`, import.meta.url), 'utf8');
const PRIVATE_NAMES = /studio|darkroom|prototypes|bakeoff|tools\/|backups|vercel|gstack|ios\/DialIn\/|plans|vite|\bsrc\b|\bapi\b/i;

function generatingSource(t, { listGenerated = false, omitTemplates = false } = {}) {
  const args = setup(t);
  const put = (path, text) => { mkdirSync(join(args.sourceRoot, path, '..'), { recursive: true }); writeFileSync(join(args.sourceRoot, path), text); };
  for (const guide of ['camera', 'import', 'ble']) put(`release/templates/${guide}.md`, `# Synthetic ${guide} guide\n`);
  put('release/fixtures/synthetic-day.json', '{"synthetic": true}\n');
  put('release/templates/gitignore.public', template('gitignore.public'));
  put('release/templates/tsconfig.public.json', template('tsconfig.public.json'));
  put('.gitignore', 'node_modules\nstudio/**/img/\nios/DialIn/build/\n');
  put('tsconfig.json', '{"include": ["src", "api"]}\n');
  const files = ['README.md', 'release/templates/camera.md', 'release/templates/import.md', 'release/templates/ble.md', 'release/fixtures/synthetic-day.json',
    ...(omitTemplates ? [] : ['release/templates/gitignore.public', 'release/templates/tsconfig.public.json']), ...(listGenerated ? ['.gitignore', 'tsconfig.json'] : [])];
  return { ...args, generate: true, manifest: { schema_version: 'dialin.public-source-manifest.v1', files } };
}

test('the public .gitignore and tsconfig.json are generated from their templates, with provenance, never copied from the source', (t) => {
  const args = generatingSource(t);
  const receipt = assemble(args);
  assert.equal(receipt.audit.passed, true, JSON.stringify(receipt.audit.errors));
  assert.equal(readFileSync(join(args.output, '.gitignore'), 'utf8'), template('gitignore.public'));
  assert.equal(readFileSync(join(args.output, 'tsconfig.json'), 'utf8'), template('tsconfig.public.json'));
  const provenance = JSON.parse(readFileSync(join(args.output, 'release/ASSET-PROVENANCE.json'), 'utf8'));
  for (const config of GENERATED_CONFIG) assert.ok(provenance.assets.some((asset) => asset.path === config.path && asset.method.includes(config.template)), config.path);
  const publicManifest = JSON.parse(readFileSync(join(args.output, 'release/source-manifest.json'), 'utf8'));
  assert.ok(!publicManifest.files.includes('.gitignore') && !publicManifest.files.includes('tsconfig.json'), 'generated paths are rebuilt, not selected');
  assert.ok(publicManifest.files.includes('release/templates/gitignore.public') && publicManifest.files.includes('release/templates/tsconfig.public.json'), 'the public tree can rebuild them');
  assert.doesNotMatch(readFileSync(join(args.output, '.gitignore'), 'utf8'), /studio|ios\/DialIn\//);
});

test('a selection that lists a generated config path, or omits its template, is refused before any output', (t) => {
  const listed = generatingSource(t, { listGenerated: true });
  assert.throws(() => assemble(listed), /must not list \.gitignore, tsconfig\.json \(generated from templates\)/);
  assert.equal(existsSync(listed.output), false);
  const missing = generatingSource(t, { omitTemplates: true });
  assert.throws(() => assemble(missing), /must list release\/templates\/gitignore\.public, release\/templates\/tsconfig\.public\.json/);
  assert.equal(existsSync(missing.output), false);
  // Without generation (tests, audits of a fixed list) nothing is required or replaced.
  const plain = setup(t);
  assert.deepEqual(assemble(plain).files.map((r) => r.path), ['README.md']);
});

test('the public templates hold only what the public tree needs', () => {
  const gitignore = template('gitignore.public');
  const rules = gitignore.split('\n').filter((line) => line && !line.startsWith('#'));
  for (const required of ['node_modules', '.venv/', '.dialin/', '.env*', '__pycache__/', '.build-lock', 'ios/DialInCamera/.build', 'ble/.venv/', 'ble/captures/', '.DS_Store', '*.RAF', '*.raf', '*.HIF', '*.hif', 'dist']) {
    assert.ok(rules.includes(required), required);
  }
  assert.equal(rules.length, 15, rules.join(' '));
  assert.doesNotMatch(gitignore, PRIVATE_NAMES);
  const pub = JSON.parse(template('tsconfig.public.json'));
  assert.deepEqual(pub.include, ['lib', 'modules', 'scripts', 'tests']);
  assert.deepEqual(pub.compilerOptions.types, ['node', 'w3c-web-usb']);
  // Same compiler options as this checkout's tsconfig.json, apart from the type packages (in the public tree it is this file).
  const local = JSON.parse(readFileSync(new URL('../../tsconfig.json', import.meta.url), 'utf8'));
  const { types: _a, ...options } = pub.compilerOptions, { types: _b, ...localOptions } = local.compilerOptions;
  assert.deepEqual(options, localOptions);
});
