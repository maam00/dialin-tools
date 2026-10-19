#!/usr/bin/env node
// Assemble an exact source snapshot. This never invokes Git, a network client, a camera, or a model.
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';
import { spawnSync } from 'node:child_process';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const RECEIPT = '.source-export.json';
const MEDIA_MANIFEST = 'release/media-manifest.json';
// These three reviewed walkthrough files are the entire media exception, not an extension allowlist.
const REVIEWED_MEDIA = new Map([
  ['docs/media/workflow.gif', 'image/gif'],
  ['docs/media/workflow.mp4', 'video/mp4'],
  ['docs/media/workflow-poster.png', 'image/png'],
]);
const MAX_ARTIFACT_BYTES = 5 * 1024 * 1024;
/** Public configuration generated from reviewed templates, so private folder names never reach the public tree. The
 *  templates ship (the public tree can rebuild itself); the generated paths are never copied from the source. */
export const GENERATED_CONFIG = [
  { path: '.gitignore', template: 'release/templates/gitignore.public', method: 'Generated from release/templates/gitignore.public: only the ignore rules the public tree needs' },
  { path: 'tsconfig.json', template: 'release/templates/tsconfig.public.json', method: 'Generated from release/templates/tsconfig.public.json: typechecks lib, modules, scripts and tests only' },
];
const forbiddenSegments = new Set(['.git', '.env', '.env.local', 'node_modules', '.venv', '__pycache__', '.build', '.swiftpm', 'DerivedData', 'evidence', 'captures', 'backups', '.vercel']);
const sha = (data) => createHash('sha256').update(data).digest('hex');
const json = (value) => Buffer.from(JSON.stringify(value, null, 2) + '\n');

export function safePath(path) {
  if (typeof path !== 'string' || !path || isAbsolute(path) || path.includes('\\') || path.includes('\0') || path.split('/').some((x) => !x || x === '.' || x === '..' || forbiddenSegments.has(x))) throw new Error('Unsafe or forbidden manifest path');
  return path;
}

function regularFile(root, path) {
  let p = root;
  for (const part of safePath(path).split('/')) {
    p = join(p, part);
    if (lstatSync(p).isSymbolicLink()) throw new Error(`Symlink refused: ${path}`);
  }
  if (!lstatSync(p).isFile()) throw new Error(`Not a regular file: ${path}`);
  return p;
}

function paths(root, prefix = '') {
  return readdirSync(join(root, prefix), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, 'en')).flatMap((entry) => {
    const path = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isSymbolicLink()) throw new Error(`Symlink refused: ${path}`);
    return entry.isDirectory() ? paths(root, path) : [path];
  });
}

function transform(path, bytes, policy) {
  if (bytes.includes(0)) return { bytes, changes: [] };
  let text = bytes.toString('utf8');
  if (!Buffer.from(text).equals(bytes)) return { bytes, changes: [] };
  const changes = [];
  for (const rule of policy.rules ?? []) {
    if (rule.paths && !rule.paths.includes(path)) continue;
    const next = rule.regex ? text.replace(new RegExp(rule.regex, rule.flags ?? 'g'), rule.to) : text.split(rule.from).join(rule.to);
    if (next !== text) { changes.push(rule.id); text = next; }
  }
  return { bytes: Buffer.from(text), changes };
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  return (crc ^ 0xffffffff) >>> 0;
}

// Format/container checks complement the exact reviewed digest. They do not decode video, establish
// provenance, or establish visual/metadata privacy; the ordinary privacy audit still scans every byte.
function mediaFormat(bytes, type) {
  if (type === 'image/gif') return bytes.length >= 14 && /^(?:GIF87a|GIF89a)$/.test(bytes.subarray(0, 6).toString('latin1'))
    && bytes.readUInt16LE(6) > 0 && bytes.readUInt16LE(8) > 0 && bytes.at(-1) === 0x3b;
  if (type === 'image/png') {
    if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return false;
    let at = 8, image = false;
    while (at + 12 <= bytes.length) {
      const length = bytes.readUInt32BE(at), end = at + length + 12;
      if (end > bytes.length) return false;
      const kind = bytes.subarray(at + 4, at + 8).toString('latin1');
      if (bytes.readUInt32BE(end - 4) !== crc32(bytes.subarray(at + 4, end - 4))) return false;
      if (at === 8 && (kind !== 'IHDR' || length !== 13 || !bytes.readUInt32BE(at + 8) || !bytes.readUInt32BE(at + 12))) return false;
      if (kind === 'IDAT') image = true;
      if (kind === 'IEND') return length === 0 && image && end === bytes.length;
      at = end;
    }
    return false;
  }
  if (type === 'video/mp4') {
    let at = 0;
    const kinds = new Set();
    while (at + 8 <= bytes.length) {
      let length = bytes.readUInt32BE(at), header = 8;
      const kind = bytes.subarray(at + 4, at + 8).toString('latin1');
      if (length === 1) {
        if (at + 16 > bytes.length) return false;
        const large = bytes.readBigUInt64BE(at + 8);
        if (large > BigInt(bytes.length - at)) return false;
        length = Number(large); header = 16;
      } else if (length === 0) length = bytes.length - at;
      if (length < header || at + length > bytes.length || (at === 0 && kind !== 'ftyp')) return false;
      if (kind === 'ftyp') {
        if (at !== 0 || length < header + 8 || (length - header) % 4) return false;
        const brands = [bytes.subarray(at + header, at + header + 4).toString('latin1')];
        for (let i = at + header + 8; i < at + length; i += 4) brands.push(bytes.subarray(i, i + 4).toString('latin1'));
        if (!brands.some((brand) => ['isom', 'iso2', 'mp41', 'mp42', 'avc1'].includes(brand))) return false;
      }
      kinds.add(kind); at += length;
    }
    return at === bytes.length && kinds.has('ftyp') && kinds.has('moov') && kinds.has('mdat');
  }
  return false;
}

function checkMediaBytes(entry, bytes) {
  if (bytes.length !== entry.bytes || sha(bytes) !== entry.sha256 || !mediaFormat(bytes, entry.mime_type)) {
    throw new Error(`Reviewed media content/format mismatch: ${entry.path}`);
  }
}

function reviewedMedia(root) {
  if (!existsSync(join(root, MEDIA_MANIFEST))) return new Map();
  const file = regularFile(root, MEDIA_MANIFEST);
  let manifest;
  try {
    if (lstatSync(file).size > 16384) throw new Error();
    manifest = JSON.parse(readFileSync(file, 'utf8'));
  } catch { throw new Error('Invalid reviewed media manifest'); }
  const keys = (value, expected) => value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).sort().join(',') === [...expected].sort().join(',');
  if (!keys(manifest, ['schema_version', 'assets']) || manifest.schema_version !== 'dialin.reviewed-media.v1'
    || !Array.isArray(manifest.assets) || manifest.assets.length > REVIEWED_MEDIA.size) throw new Error('Invalid reviewed media manifest');
  const approved = new Map();
  for (const entry of manifest.assets) {
    if (!keys(entry, ['path', 'mime_type', 'bytes', 'sha256']) || !REVIEWED_MEDIA.has(entry.path)
      || entry.mime_type !== REVIEWED_MEDIA.get(entry.path) || approved.has(entry.path)
      || !Number.isSafeInteger(entry.bytes) || entry.bytes <= 0 || entry.bytes > MAX_ARTIFACT_BYTES
      || typeof entry.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(entry.sha256)) throw new Error('Invalid reviewed media entry');
    const asset = regularFile(root, entry.path);
    if (lstatSync(asset).size !== entry.bytes) throw new Error(`Reviewed media size mismatch: ${entry.path}`);
    checkMediaBytes(entry, readFileSync(asset));
    approved.set(entry.path, entry);
  }
  return approved;
}

// Original, deterministic geometric placeholder. Only IHDR/IDAT/IEND chunks; no EXIF or other metadata.
export function geometricPNG(size, wood = false) {
  const rows = Buffer.alloc(size * (1 + size * 3));
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    const radius = Math.hypot(x - (size - 1) / 2, y - (size - 1) / 2) / size;
    const stripe = (Math.floor(y / Math.max(1, size / 24)) % 2) * 8;
    const rgb = wood ? [203 - stripe, 185 - stripe, 154 - stripe] : radius > 0.27 && radius < 0.35 ? [230, 102, 46] : [28, 32, 30];
    const i = y * (size * 3 + 1) + 1 + x * 3;
    rows[i] = rgb[0]; rows[i + 1] = rgb[1]; rows[i + 2] = rgb[2];
  }
  const chunk = (kind, data) => {
    const type = Buffer.from(kind), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(data.length); checksum.writeUInt32BE(crc32(Buffer.concat([type, data])));
    return Buffer.concat([length, type, data, checksum]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]);
}

export function syntheticBackup() {
  const bytes = Buffer.alloc(70524);
  bytes.write('FUJIFILMX-BACKUP', 0); bytes.write('0100', 0x10); bytes.write('X100VI', 0x14); bytes.write('TEST', 0x34);
  bytes.writeUInt32LE(0xa8, 0x98); bytes.writeUInt32LE(bytes.length - 0xa8, 0xa0);
  for (let slot = 0; slot < 7; slot++) bytes.write(`TEST C${slot + 1}`, 0xf800 + slot * 0x400 + 0x1e5);
  let sum = 0; for (let i = 0xa8; i < bytes.length; i++) if (i < 0x108 || i >= 0x10c) sum += bytes[i];
  bytes.writeUInt16LE((sum + 0x1234) & 0xffff, 0x108);
  return deflateSync(bytes);
}

const checks = [
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ['provider-key', /\b(?:sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{32,}|AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{30,})\b/],
  ['owner-absolute-path', /(?:\/Users\/|C:\\Users\\)[A-Za-z0-9_.-]+(?:\/|\\)/],
  ['signing-team', /DEVELOPMENT_TEAM\s*[:=]\s*["']?[A-Z0-9]{10}\b/],
  ['private-photo-volume', /\/Volumes\/[A-Za-z0-9 _-]+\/Photos\//],
];

// Fujifilm film-simulation names and a few generic words used in look names ("Hard Noir") are vocabulary, not recipe titles.
const CAMERA_VOCABULARY = new Set(['provia', 'provia std', 'provia standard', 'standard provia', 'velvia', 'velvia vivid', 'astia', 'astia soft', 'classic chrome',
  'reala ace', 'pro neg', 'pro neg hi', 'pro neg std', 'classic neg', 'classic negative', 'nostalgic neg', 'nostalgic negative', 'eterna',
  'eterna bleach bypass', 'bleach bypass', 'acros', 'monochrome', 'sepia', 'noir']);
const vocabularyKey = (title) => title.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const quotes = (text) => text.replace(/[‘’]/g, "'").replace(/[“”]/g, '"');
const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Publisher-content terms, built in memory from the private recipe catalog at audit time. They are never written,
 *  returned in findings or printed: a finding names only the file and the rule. */
export function publisherTerms(catalog) {
  if (!catalog || !Array.isArray(catalog.references) || !Array.isArray(catalog.articles)) throw new Error('The private recipe catalog is not a dialin.recipe-knowledge.v1 catalog');
  const records = [...catalog.articles, ...catalog.references];
  const hosts = new Set(), names = new Set(), ids = new Set(), titles = new Set();
  for (const record of records) {
    for (const url of [record.source_url, ...(record.index_urls ?? [])]) if (typeof url === 'string') hosts.add(new URL(url).hostname.replace(/^www\./, ''));
    if (typeof record.publisher === 'string') names.add(record.publisher);
    if (typeof record.id === 'string') ids.add(record.id);
    for (const title of [record.title, record.article_title, record.variant_name, ...(record.aliases ?? [])]) {
      if (typeof title !== 'string') continue;
      const clean = quotes(title).replace(/^["']+|["']+$/g, '').trim();
      if (clean.length < 3 || clean.startsWith('[') || CAMERA_VOCABULARY.has(vocabularyKey(clean))) continue;
      titles.add(clean);
    }
  }
  const alternation = (values, pattern = escapeRegex) => [...values].sort((a, b) => b.length - a.length).map(pattern).join('|');
  // A title wrapped across a line or spaced differently in prose is still the title.
  const spaced = (title) => title.split(/\s+/).map(escapeRegex).join('\\s+');
  const boundary = (body, flags) => body ? new RegExp(`(?<![\\p{L}\\p{N}])(?:${body})(?![\\p{L}\\p{N}])`, flags) : null;
  return {
    counts: { hosts: hosts.size, publishers: names.size, ids: ids.size, titles: titles.size },
    rules: [
      ['publisher-source-host', boundary(alternation(hosts), 'iu')],
      // The publisher's name with any spacing ("Example Recipe Journal", "ExampleRecipeJournal").
      ['publisher-name', boundary([...names].map((name) => name.split(/\s+/).map(escapeRegex).join('\\s*')).join('|'), 'iu')],
      ['catalog-reference-id', boundary(alternation(ids), 'u')],
      // Case-sensitive: titles are proper names; prose such as "warm memory" is not a title "Warm Memory".
      ['catalog-recipe-title', boundary(alternation(titles, spaced), 'u')],
    ].filter(([, pattern]) => pattern),
  };
}

export function auditTree(root, records, policy = {}, terms = null) {
  const errors = [];
  const actual = paths(root);
  let media = new Map();
  try { media = reviewedMedia(root); } catch { errors.push({ path: MEDIA_MANIFEST, rule: 'reviewed-media' }); }
  if (records) {
    for (const entry of records) safePath(entry.path);
    const expected = records.map((x) => x.path).sort();
    if (JSON.stringify([...actual].sort()) !== JSON.stringify(expected)) errors.push({ rule: 'exact-file-list' });
    for (const entry of records) {
      const p = join(root, entry.path);
      if (!existsSync(p) || sha(readFileSync(p)) !== entry.sha256) errors.push({ path: entry.path, rule: 'sha256' });
      if (existsSync(p) && entry.mode && (lstatSync(p).mode & 0o777).toString(8) !== entry.mode) errors.push({ path: entry.path, rule: 'file-mode' });
    }
  }
  for (const path of actual) {
    try { safePath(path); } catch { errors.push({ path, rule: 'forbidden-path' }); continue; }
    const approvedMedia = media.has(path);
    if (REVIEWED_MEDIA.has(path) && !approvedMedia) errors.push({ path, rule: 'unreviewed-media' });
    if (/\.(?:p12|pfx|mobileprovision|pem|key|RAF|raf|HIF|hif|log|zip|gz|gif|mp4|mov)$/i.test(path) && !approvedMedia) errors.push({ path, rule: 'forbidden-artifact' });
    const bytes = readFileSync(join(root, path));
    if (bytes.length > MAX_ARTIFACT_BYTES) errors.push({ path, rule: 'oversized-artifact' });
    if (bytes.includes(0)) {
      if (!approvedMedia && !/\.(?:png|woff2|zlib)$/.test(path)) errors.push({ path, rule: 'unapproved-binary' });
    }
    // Scan ASCII/UTF-8 and UTF-16 strings even in the few allowed binaries.
    const text = bytes.toString('utf8') + '\n' + bytes.toString('utf16le');
    for (const [label, pattern] of checks) if (pattern.test(text)) errors.push({ path, rule: label });
    for (const item of policy.deny ?? []) if (text.toLowerCase().includes(item.value.toLowerCase())) errors.push({ path, rule: item.id });
    for (const item of policy.deny_patterns ?? []) if (new RegExp(item.regex, item.flags ?? '').test(text)) errors.push({ path, rule: item.id });
    if (terms) { const normalized = quotes(text); for (const [rule, pattern] of terms.rules) if (pattern.test(normalized)) errors.push({ path, rule }); }
  }
  return { schema_version: 'dialin.public-source-audit.v1', passed: errors.length === 0, file_count: actual.length,
    publisher_content: terms ? { checked: true, terms: terms.counts } : { checked: false }, errors };
}

export function assemble({ sourceRoot, output, manifest, policy = {}, generate = true, recipeCatalog = null }) {
  if (manifest.requires_copy_policy && policy.schema_version !== 'dialin.private-copy-transforms.v1') throw new Error('This source selection requires its private copy policy; export refused');
  // A personal source selection is audited against the private recipe catalog; without it, refuse rather than skip.
  if (manifest.requires_copy_policy && !recipeCatalog) throw new Error('The publisher-content audit needs the private recipe catalog (DIALIN_RECIPE_CATALOG or data/recipe-knowledge/catalog.json); export refused');
  const terms = recipeCatalog ? publisherTerms(recipeCatalog) : null;
  sourceRoot = resolve(sourceRoot); output = resolve(output);
  if (lstatSync(sourceRoot).isSymbolicLink()) throw new Error('Source root symlink refused');
  const rel = relative(sourceRoot, output);
  if (output === sourceRoot || (rel && !rel.startsWith(`..${sep}`) && rel !== '..' && !rel.startsWith(`.dialin${sep}`))) throw new Error('Output must be external or beneath .dialin/');
  for (let p = output; p !== dirname(p); p = dirname(p)) if (existsSync(p) && lstatSync(p).isSymbolicLink()) throw new Error('Output symlink refused');
  if (existsSync(output)) throw new Error('Output already exists; choose a new candidate path');
  const selections = manifest.files.map((x) => typeof x === 'string' ? { source: x, path: x } : x);
  if (generate) {
    const listed = GENERATED_CONFIG.filter((g) => selections.some((x) => x.path === g.path)).map((g) => g.path);
    const missing = GENERATED_CONFIG.filter((g) => !selections.some((x) => x.path === g.template)).map((g) => g.template);
    if (listed.length || missing.length) throw new Error(`release/source-manifest.json must ${listed.length ? `not list ${listed.join(', ')} (generated from templates)` : ''}${listed.length && missing.length ? ' and must ' : ''}${missing.length ? `list ${missing.join(', ')}` : ''}; export refused`);
  }
  const destinations = selections.map((x) => safePath(x.path));
  if (new Set(destinations).size !== destinations.length) throw new Error('Duplicate destination');
  // Complete source validation before creating any output.
  const selected = selections.map((x) => ({ ...x, source: safePath(x.source), sourceFile: regularFile(sourceRoot, x.source) }));
  const media = reviewedMedia(sourceRoot);
  if (media.size && !selected.some((x) => x.source === MEDIA_MANIFEST && x.path === MEDIA_MANIFEST)) throw new Error('The reviewed media manifest must ship unchanged with its assets');
  for (const path of media.keys()) if (!selected.some((x) => x.source === path && x.path === path)) throw new Error('Every reviewed media path must be selected without remapping');
  for (const entry of selected) if (REVIEWED_MEDIA.has(entry.path) && !media.has(entry.path)) throw new Error(`Unreviewed media: ${entry.path}`);
  mkdirSync(dirname(output), { recursive: true });
  const staging = `${output}.assembling`;
  if (existsSync(staging)) throw new Error('Staging path already exists');
  mkdirSync(staging);
  const sourceRecords = [];
  const write = (path, bytes, executable = false) => { safePath(path); mkdirSync(dirname(join(staging, path)), { recursive: true }); writeFileSync(join(staging, path), bytes); chmodSync(join(staging, path), executable ? 0o755 : 0o644); };
  try {
    for (const entry of selected) {
      const original = readFileSync(entry.sourceFile);
      const approvedMedia = media.get(entry.path);
      if (approvedMedia) checkMediaBytes(approvedMedia, original);
      if (original.includes(0) && !entry.path.endsWith('.woff2') && !approvedMedia) throw new Error(`Unapproved source binary: ${entry.path}`);
      const result = approvedMedia || entry.path === MEDIA_MANIFEST ? { bytes: original, changes: [] } : transform(entry.source, original, policy);
      write(entry.path, result.bytes, approvedMedia ? false : !!(lstatSync(entry.sourceFile).mode & 0o111));
      sourceRecords.push({ source: entry.source, path: entry.path, source_sha256: sha(original), transforms: result.changes });
    }
    const generated = [];
    const add = (path, bytes, method) => { write(path, bytes); generated.push({ path, method }); };
    if (generate) {
      // The public tree ships the Fujifilm tools only; the phone app, Darkroom, Post, Studio and finishing tools stay private.
      const publicGuides = { camera: 'ios/DialInCamera/README.md', import: 'ios/DialInCamera/IMPORT.md', ble: 'ble/README.md' };
      for (const [template, path] of Object.entries(publicGuides)) add(path, readFileSync(join(sourceRoot, `release/templates/${template}.md`)), 'Reviewed source-authored public module guide');
      for (const config of GENERATED_CONFIG) add(config.path, readFileSync(join(staging, config.template)), config.method);
      add('ios/DialInCamera/Tests/DialInCameraTests/Fixtures/ble-settings-synthetic.zlib', syntheticBackup(), 'syntheticBackup: zero-filled bytes, TEST identity, TEST C1-C7 and synthetic checksum');
      // License records follow the shipped license files only, so a public notice never points at an absent text.
      if (selections.some((x) => x.path === 'third_party/license-sources.json')) {
        const sources = JSON.parse(readFileSync(join(staging, 'third_party/license-sources.json'), 'utf8'));
        const shipped = new Set(selections.map((x) => x.path));
        add('third_party/license-sources.json', json({ ...sources, sources: sources.sources.filter((s) => shipped.has(s.license_file)) }), 'Shipped components only, filtered from the reviewed license records');
      }
      add('data/recipe-universe/README.md', Buffer.from('# Optional local recipe research\n\nNo third-party recipes, recipe catalog or research snapshot is distributed. Dial In\'s own guidance is the original direction book in `data/recipes/original-book.json` and the setting rules and film-simulation profiles in `lib/plan/`; start with `npm run recipes -- knowledge --query "your scene"`.\n\nThe adapters in `lib/recipes/` read a research dataset you supply locally (`npm run recipes -- search --catalog DIRECTORY`), and the planner can read your own catalog named by `DIALIN_RECIPE_CATALOG`. Whether you may use a third party\'s recipes is between you and their author; code licensing does not cover it.\n'), 'Source-authored note: no recipe catalog or research snapshot is distributed');
      const python = process.env.DIALIN_RELEASE_PYTHON || 'python3';
      const vectorGenerator = join(staging, 'ios/DialInCamera/Tests/make-look-patch-vectors.py');
      if (existsSync(vectorGenerator)) {
        const result = spawnSync(python, ['-I', '-B', vectorGenerator], { cwd: staging, encoding: 'utf8', timeout: 120000, env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } });
        if (result.status !== 0) throw new Error('Synthetic look-patch vector regeneration failed');
        generated.push({ path: 'ios/DialInCamera/Tests/DialInCameraTests/Fixtures/look-patch-vectors.json', method: 'Included synthetic Python generator; fresh tree has no real backups' });
      }
      const publicExclusions = manifest.public_exclusions ?? [...new Set((manifest.excluded_assets ?? []).map((entry) => entry.reason))].map((reason) => ({ reason }));
      const sanitizedExamples = [];
      add('release/ASSET-PROVENANCE.json', json({ schema_version: 'dialin.asset-provenance.v1', assets: generated, sanitized_examples: sanitizedExamples, excluded_source_categories: publicExclusions, note: 'Synthetic fixtures establish software behavior only; no camera, model, image quality or photographer acceptance is claimed.' }), 'Assembly provenance');
      // The public snapshot can reproduce itself without private copy policies or original input paths.
      add('release/source-manifest.json', json({ schema_version: manifest.schema_version, description: 'Exact public source selection. Generated assets are rebuilt by scripts/public-release/export.mjs.', files: [...new Set([...selections.map((x) => x.path), 'release/source-manifest.json'])].sort(), public_exclusions: publicExclusions, excluded_families: manifest.excluded_families ?? [] }), 'Public self-export selection; private source-to-destination policy is omitted');
    }
    const fileRecords = paths(staging).map((path) => ({ path, bytes: readFileSync(join(staging, path)).length, mode: (lstatSync(join(staging, path)).mode & 0o777).toString(8), sha256: sha(readFileSync(join(staging, path))) }));
    const audit = auditTree(staging, fileRecords, policy, terms);
    if (!audit.passed) { const failure = new Error(`Export audit failed: ${audit.errors.length} findings`); failure.findings = audit.errors; throw failure; }
    renameSync(staging, output);
    const receipt = { schema_version: 'dialin.public-source-export.v1', file_count: fileRecords.length, total_bytes: fileRecords.reduce((n, r) => n + r.bytes, 0), source_records: sourceRecords, generated, excluded_assets: manifest.excluded_assets ?? [], excluded_families: manifest.excluded_families ?? [], files: fileRecords, audit };
    writeFileSync(`${output}${RECEIPT}`, json(receipt));
    return receipt;
  } catch (error) { rmSync(staging, { recursive: true, force: true }); throw error; }
}

/** The private recipe catalog for the publisher-content audit: --recipe-catalog, DIALIN_RECIPE_CATALOG, then the default path. */
export function readRecipeCatalog(sourceRoot, explicit = undefined) {
  const configured = explicit ?? process.env.DIALIN_RECIPE_CATALOG;
  if (configured && /^(?:none|off)$/i.test(configured.trim())) return null;
  const path = configured ? resolve(configured) : join(sourceRoot, 'data/recipe-knowledge/catalog.json');
  return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null;
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  const option = (flag, fallback) => args.includes(flag) ? args[args.indexOf(flag) + 1] : fallback;
  const sourceRoot = resolve(option('--source', ROOT));
  const policyPath = option('--policy', join(sourceRoot, 'release/copy-transforms.private.json'));
  const policy = existsSync(policyPath) ? JSON.parse(readFileSync(policyPath, 'utf8')) : {};
  const output = option('--out');
  if (!output || !['assemble', 'audit'].includes(command)) throw new Error('Usage: node scripts/public-release/export.mjs assemble|audit --out <new candidate path> [--source <root>] [--policy <private policy>] [--recipe-catalog <private catalog.json>]');
  const recipeCatalog = readRecipeCatalog(sourceRoot, option('--recipe-catalog'));
  if (command === 'assemble') {
    const manifest = JSON.parse(readFileSync(join(sourceRoot, 'release/source-manifest.json'), 'utf8'));
    const receipt = assemble({ sourceRoot, output, manifest, policy, recipeCatalog });
    console.log(JSON.stringify({ candidate: resolve(output), receipt: `${resolve(output)}${RECEIPT}`, file_count: receipt.file_count, total_bytes: receipt.total_bytes, audit: receipt.audit }, null, 2));
  } else {
    const receipt = JSON.parse(readFileSync(`${resolve(output)}${RECEIPT}`, 'utf8'));
    if (policy.schema_version === 'dialin.private-copy-transforms.v1' && !recipeCatalog) throw new Error('The publisher-content audit needs the private recipe catalog (DIALIN_RECIPE_CATALOG or data/recipe-knowledge/catalog.json)');
    const result = auditTree(resolve(output), receipt.files, policy, recipeCatalog ? publisherTerms(recipeCatalog) : null);
    console.log(JSON.stringify(result, null, 2)); if (!result.passed) process.exitCode = 1;
  }
}
if (process.argv[1] && (() => { // Same file even through a symlinked path (macOS /tmp), case-insensitive on Windows.
  try { const a = realpathSync.native(process.argv[1]), b = realpathSync.native(fileURLToPath(import.meta.url)); return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b; }
  catch { return false; } })()) {
  try { main(); } catch (error) { console.error(JSON.stringify({ error: error.message, findings: error.findings ?? [] }, null, 2)); process.exitCode = 1; }
}
