import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { components, component } from './catalog.mjs';

export const root = fileURLToPath(new URL('../', import.meta.url));
// The repository's .venv wins; DIALIN_PYTHON overrides it. Windows installs normally provide `python`, not `python3`.
export function pythonExecutable(env = process.env, platform = process.platform) {
  if (env.DIALIN_PYTHON) return env.DIALIN_PYTHON;
  const local = fileURLToPath(new URL('../.venv/bin/python', import.meta.url));
  const windows = fileURLToPath(new URL('../.venv/Scripts/python.exe', import.meta.url));
  return existsSync(local) ? local : existsSync(windows) ? windows : platform === 'win32' ? 'python' : 'python3';
}
function available(name) {
  try { import.meta.resolve(name); return true; } catch { return false; }
}
function probe(executable, args) {
  const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 10000, windowsHide: true });
  return { ok: result.status === 0 && !result.error, text: (result.stdout || result.stderr || '').trim().split('\n')[0] };
}
export function diagnose(id = 'all') {
  const selected = id === 'all' ? components : [component(id)];
  const needs = new Set(selected.flatMap((entry) => entry.needs));
  const checks = [];
  function check(key, ok, detail, fix) { checks.push({ key, status: ok ? 'ready' : 'missing', detail, ...(ok ? {} : { fix }) }); }
  if (needs.has('node')) {
    const [major, minor] = process.versions.node.split('.').map(Number);
    check('node', major > 22 || major === 22 && minor >= 12, `Node ${process.versions.node}`, 'Install Node.js 22.12 or later.');
  }
  if (needs.has('tsx')) check('tsx', available('tsx/esm/api'), 'TypeScript command runtime', 'Run npm ci --ignore-scripts from this repository.');
  if (needs.has('sdk')) check('sdk', available('@anthropic-ai/sdk'), 'Planner engine dependency; no API request is made by doctor', 'Run npm ci --ignore-scripts. Agent and demo modes need no API key.');
  const python = pythonExecutable();
  if (needs.has('python')) {
    const p = probe(python, ['-c', 'import sys; print("Python " + sys.version.split()[0]); sys.exit(0 if sys.version_info >= (3, 10) else 1)']);
    check('python', p.ok, p.ok ? p.text : 'Python 3.10+ unavailable', 'Install Python 3.10+ or set DIALIN_PYTHON to its executable.');
  }
  if (needs.has('pillow')) {
    const p = probe(python, ['-c', 'import PIL; print("Pillow " + PIL.__version__)']);
    const version = /^Pillow (\d+)\.(\d+)(?:\.|$)/.exec(p.text);
    const supported = version && (Number(version[1]) > 11 || Number(version[1]) === 11 && Number(version[2]) >= 3) && Number(version[1]) < 14;
    check('pillow', p.ok && Boolean(supported), p.ok ? `${p.text}; supported range >=11.3,<14` : 'Photo preview dependency unavailable', 'Create .venv and install modules/photos/requirements.txt; see modules/photos/README.md.');
  }
  if (needs.has('macos')) {
    const os = process.platform === 'darwin' ? probe('sw_vers', ['-productVersion']) : { ok: false, text: '' };
    check('macos', os.ok && Number.parseInt(os.text, 10) >= 26, os.ok ? `macOS ${os.text}; helper requires 26+` : 'Existing native import helper requires macOS 26+', 'Use an SD-card reader or OS import, then photos prepare on supported desktop platforms.');
  }
  if (needs.has('swift')) {
    check('native_import_source', existsSync(new URL('../ios/DialInCamera/Package.swift', import.meta.url)), 'Optional macOS camera helper source', 'Use the complete repository source, including ios/DialInCamera, for this optional helper.');
    const s = process.platform === 'darwin' ? probe('swift', ['--version']) : { ok: false, text: '' };
    const version = /Swift version (\d+)\.(\d+)/i.exec(s.text);
    const supported = version && (Number(version[1]) > 6 || Number(version[1]) === 6 && Number(version[2]) >= 2);
    check('swift', s.ok && Boolean(supported), s.ok ? s.text : 'Optional macOS helper build tool unavailable', 'Install the Swift 6.2+ macOS toolchain for this optional helper. No iPhone app is required.');
  }
  const status = new Map(checks.map((c) => [c.key, c.status === 'ready']));
  const summary = selected.map((entry) => {
    const missing = entry.needs.filter((need) => !status.get(need) || (need === 'swift' && !status.get('native_import_source')));
    return { id: entry.id, ready: missing.length === 0, ...(entry.optional ? { optional: true } : {}), ...(missing.length ? { missing } : {}) };
  });
  // An explicitly requested component must be ready. With no component, optional platform helpers are reported, not required.
  const ready = id === 'all' ? summary.every((c) => c.ready || c.optional) : checks.every((c) => c.status === 'ready');
  return { schema_version: 'dialin.doctor.v1', component: id, ready, components: summary, checks,
    api_key: process.env.ANTHROPIC_API_KEY?.trim() ? 'present_not_verified' : 'absent_optional',
    device: 'NOT_CHECKED', network: 'NOT_USED', changes: 'NONE',
    note: 'Dependency checks only. No provider availability, hardware compatibility, transfer, or image quality is verified.' };
}

/** A short human summary of a doctor report; the JSON report stays the machine contract. */
export function describeDoctor(report) {
  const scope = report.component === 'all' ? 'all components' : report.component;
  const lines = [`doctor ${scope}: ${report.ready ? 'READY' : 'NOT READY'}`];
  if (report.component === 'all') {
    lines.push(`  ${report.components.map((c) => `${c.id}${c.optional ? ' (optional)' : ''} ${c.ready ? 'ready' : `missing ${c.missing.join('+')}`}`).join(' · ')}`);
  }
  const required = new Set(report.components.filter((c) => !c.optional).flatMap((c) => component(c.id).needs));
  for (const c of report.checks.filter((entry) => entry.status !== 'ready')) {
    const optional = report.component === 'all' && !required.has(c.key === 'native_import_source' ? 'swift' : c.key);
    lines.push(`  missing ${c.key}${optional ? ' (optional import helper)' : ''}: ${c.fix}`);
  }
  if (report.component === 'all' && report.ready && report.components.some((c) => c.optional && !c.ready)) {
    lines.push('  The optional macOS import helper is not needed; an SD-card reader or OS import works with photos prepare.');
  }
  return lines.join('\n');
}
