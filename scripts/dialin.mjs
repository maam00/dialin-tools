#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { components } from '../modules/catalog.mjs';
import { describeDoctor, diagnose, pythonExecutable } from '../modules/doctor.mjs';

const help = `Dial In — photography tools for your computer and coding agent.

First success (no camera, no API key):
  npm ci --ignore-scripts
  npm run dialin -- demo --out .dialin/demo     then read .dialin/demo/SUMMARY.md

Commands:
  modules                        List the independent components (JSON)
  doctor [component]             Read-only setup check; no model, camera or network use
  recipes <list|search|sources|knowledge|analyze|validate>
                                 Recipe books, original guidance, optional private catalog (recipes --help)
  plan --help                    Plan with Codex/Claude Code, a fixed fixture, or your own API key
  camera --help                  Prepare recipes for chosen slots; USB writes are separate explicit commands
  photos --help                  Photo folder → previews/focus crops → agent review → copied selects
  curate --help                  Validate and sequence supplied photo judgments
  demo --out <new-directory>     Connected offline rehearsal with fixture data

Run as: npm run dialin -- <command>, or node scripts/dialin.mjs <command>.
Results are JSON on stdout, or new files with --out (existing files are never replaced).
Nothing runs when you clone or install. Bluetooth modified-recipe writes remain blocked.
Guides: README.md, docs/AGENT-WORKFLOW.md, modules/<component>/README.md. No iPhone app is required.`;

async function typescriptModule(path) {
  let register;
  try { ({ register } = await import('tsx/esm/api')); }
  catch { throw new Error('TypeScript runtime missing. Run npm ci --ignore-scripts, then retry. Help, doctor and Python commands work without it.'); }
  register();
  return import(new URL(path, import.meta.url).href);
}
export function runPython(script, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(pythonExecutable(), [fileURLToPath(new URL(script, import.meta.url)), ...args], { stdio: 'inherit', windowsHide: true });
    const interrupt = () => child.kill('SIGINT');
    // A harness that stops Node with SIGTERM must not orphan the Python child, which would keep writing. It is
    // forwarded as SIGINT so the command's own interrupt clean-up removes partial output, then this exits 143.
    let terminated = false;
    const terminate = () => { terminated = true; child.kill('SIGINT'); };
    const detach = () => { process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', terminate); };
    process.once('SIGINT', interrupt);
    process.once('SIGTERM', terminate);
    child.once('error', () => { detach(); reject(new Error('Python could not start. Run node scripts/dialin.mjs doctor curate for setup instructions.')); });
    child.once('close', (code, signal) => { detach(); resolve(terminated ? 143 : code ?? (signal === 'SIGINT' ? 130 : 1)); });
  });
}
export async function main(argv) {
  const [command = 'help', ...args] = argv;
  if (['help', '--help', '-h'].includes(command)) { console.log(help); return 0; }
  if (command === 'modules') {
    if (args.length) throw new Error('Usage: dialin modules');
    console.log(JSON.stringify({ schema_version: 'dialin.modules.v1', components }, null, 2)); return 0;
  }
  if (command === 'doctor') {
    if (args.length > 1) throw new Error('Usage: dialin doctor [component]');
    const report = diagnose(args[0]);
    console.log(JSON.stringify(report, null, 2));
    console.error(describeDoctor(report));
    return report.ready ? 0 : 1;
  }
  if (command === 'photos') return runPython('../modules/photos/cli.py', args);
  if (command === 'curate') return runPython('../modules/curation/cli.py', args);
  if (command === 'plan') return (await typescriptModule('../modules/planner/cli.ts')).runPlanner(args);
  if (command === 'recipes') return (await typescriptModule('../modules/recipes/cli.ts')).runRecipes(args);
  if (command === 'camera') return (await typescriptModule('../modules/camera/cli.ts')).runCamera(args);
  if (command === 'demo') return (await import('../modules/demo.mjs')).runDemo(args);
  throw new Error(`Unknown command '${command}'. Run node scripts/dialin.mjs --help.`);
}

// Compare real paths: a symlinked checkout (macOS /tmp, a linked home folder, a Windows junction or drive-letter case)
// must still run the command instead of silently exiting 0.
function invokedDirectly() {
  if (!process.argv[1]) return false;
  try {
    const entry = realpathSync.native(process.argv[1]);
    const self = realpathSync.native(fileURLToPath(import.meta.url));
    return process.platform === 'win32' ? entry.toLowerCase() === self.toLowerCase() : entry === self;
  } catch { return false; }
}
if (invokedDirectly()) {
  // Piping into head/less may close stdout early; that is not a command failure.
  process.stdout.on('error', (error) => { if (error.code === 'EPIPE') process.exit(process.exitCode ?? 0); throw error; });
  main(process.argv.slice(2)).then((code) => { process.exitCode = code; }).catch((error) => {
    console.error(`dialin: ${error instanceof Error ? error.message : 'Command failed.'}`); process.exitCode = 1;
  });
}
