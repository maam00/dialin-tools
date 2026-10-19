// Explicit macOS helper setup and process boundary. Importing this module never builds or contacts a device.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { accessSync, closeSync, constants, existsSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = fileURLToPath(new URL('../', import.meta.url));
const stateDir = join(root, '.dialin/native');
const stateFile = join(stateDir, 'helper.json');

export function sourceHash(base = root) {
  const hash = createHash('sha256');
  function visit(path) {
    const absolute = join(base, path);
    if (statSync(absolute).isDirectory()) {
      for (const child of readdirSync(absolute).sort()) visit(`${path}/${child}`);
    } else { hash.update(path); hash.update('\0'); hash.update(readFileSync(absolute)); }
  }
  visit('ios/DialInCamera/Package.swift'); visit('ios/DialInCamera/Sources');
  return hash.digest('hex');
}

export function helperStatus() {
  let binary = null, ready = false;
  try {
    const state = JSON.parse(readFileSync(stateFile, 'utf8'));
    binary = state.binary;
    accessSync(binary, constants.X_OK);
    ready = state.source_sha256 === sourceHash();
  } catch { /* missing or stale setup is reported without running the binary */ }
  return { schema_version: 'dialin.native.v1', ready: ready && process.platform === 'darwin', binary,
    platform: process.platform, device: 'NOT_CHECKED', network: 'NOT_USED',
    ...(!ready ? { fix: 'Run node scripts/dialin.mjs native build on macOS 26+ with Swift 6.2+.' } : {}) };
}

// All helper text is diagnostic. Only the desktop wrapper writes its JSON result to stdout.
export function runProcess(executable, args, { capture = false, cwd = root } = {}) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(executable, args, { cwd, stdio: ['inherit', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '', stopSignal;
    child.stdout.on('data', (chunk) => { if (capture) stdout += chunk; else process.stderr.write(chunk); });
    child.stderr.on('data', (chunk) => process.stderr.write(chunk));
    const interrupt = () => { stopSignal = 'SIGINT'; child.kill('SIGINT'); };
    const terminate = () => { stopSignal = 'SIGTERM'; child.kill('SIGTERM'); };
    process.once('SIGINT', interrupt); process.once('SIGTERM', terminate);
    const detach = () => { process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', terminate); };
    child.once('error', (error) => { detach(); reject(error); });
    child.once('close', (code, signal) => {
      detach(); const stopped = stopSignal ?? signal;
      resolveRun({ code: stopped ? stopped === 'SIGINT' ? 130 : 143 : code ?? 1, signal: stopped ?? null, stdout });
    });
  });
}

export async function runHelper(args) {
  const status = helperStatus();
  if (!status.ready) throw new Error('macOS helper missing or stale. Run node scripts/dialin.mjs native build (macOS 26+, Swift 6.2+). No device was contacted.');
  return runProcess(status.binary, args);
}

// Reserve the requested receipt before any device operation. An existing file/symlink is never followed or replaced.
export function receiptWriter(path) {
  let fd;
  if (path) {
    mkdirSync(dirname(resolve(path)), { recursive: true, mode: 0o700 });
    fd = openSync(path, 'wx', 0o600);
  }
  return (data) => {
    const json = JSON.stringify(data, null, 2) + '\n';
    if (fd === undefined) { process.stdout.write(json); return; }
    try { writeFileSync(fd, json); }
    catch (error) { process.stdout.write(json); throw new Error(`Receipt could not be saved; the outcome is on stdout. ${error.message}`); }
    finally { closeSync(fd); fd = undefined; }
  };
}

export function requireNewDirectory(path) {
  if (!path?.trim()) throw new Error('A new private --workspace directory is required.');
  if (existsSync(path)) throw new Error('Workspace already exists; choose a new directory.');
  return resolve(path);
}

// Resolve existing ancestors too, so a symlink cannot put import output inside the original photo tree.
export function canonicalPath(path) {
  const absolute = resolve(path);
  try { return realpathSync.native(absolute); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const parent = dirname(absolute);
    if (parent === absolute) throw error;
    return join(canonicalPath(parent), absolute.slice(parent.length));
  }
}

export function positiveInteger(value, name, max = 100000) {
  if (!/^[1-9]\d*$/.test(value ?? '') || Number(value) > max) throw new Error(`--${name} must be an integer from 1 to ${max}.`);
  return Number(value);
}

export async function runNative(args) {
  if (!args.length || args.includes('--help')) {
    console.log('native build   Build the optional macOS helper under the shared build lock; no camera/network access.\nnative status  Read-only check for a helper matching the current source.\nRequires macOS 26+ and Swift 6.2+. Device commands never build implicitly.'); return 0;
  }
  if (args.length !== 1 || !['build', 'status'].includes(args[0])) throw new Error('Use native build or native status.');
  if (args[0] === 'status') { const s = helperStatus(); receiptWriter()(s); return s.ready ? 0 : 1; }
  if (process.platform !== 'darwin') throw new Error('The optional native helper requires macOS 26+; photo-folder tools and offline preparation remain portable.');
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const before = sourceHash();
  const common = ['--package-path', join(root, 'ios/DialInCamera'), '--scratch-path', join(stateDir, 'build'), '--configuration', 'release'];
  const built = await runProcess(join(root, 'scripts/with-build-lock.sh'), ['--', 'swift', 'build', ...common, '--product', 'dialin-cam']);
  if (built.code) return built.code;
  const location = await runProcess(join(root, 'scripts/with-build-lock.sh'), ['--', 'swift', 'build', ...common, '--show-bin-path'], { capture: true });
  if (location.code) return location.code;
  if (sourceHash() !== before) throw new Error('Native sources changed during the build. Run native build again before using the helper.');
  const binary = join(location.stdout.trim(), 'dialin-cam');
  accessSync(binary, constants.X_OK);
  // Explicit build refreshes only its own generated cache metadata.
  writeFileSync(stateFile, JSON.stringify({ binary, source_sha256: before }) + '\n', { mode: 0o600 });
  receiptWriter()(helperStatus()); return 0;
}
