// The offline desktop contract. No model, native build, camera, or radio operation.
import { existsSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { root, diagnose, describeDoctor, pythonExecutable } from '../modules/doctor.mjs';

for (const component of ['demo', 'photos']) {
  const report = diagnose(component);
  if (!report.ready) { console.error(`${describeDoctor(report)}\nInstall the missing prerequisites (see CONTRIBUTING.md), then rerun npm run check:desktop.`); process.exit(1); }
}
const nodeTests = readdirSync(join(root, 'tests/modules')).filter((name) => /\.test\.(ts|mjs)$/.test(name)).sort().map((name) => join('tests/modules', name));
const steps = [
  ['TypeScript', process.execPath, ['node_modules/typescript/bin/tsc', '--noEmit']],
  ['Desktop Node components', process.execPath, ['--import', 'tsx', '--test', ...nodeTests]],
  ['Portable photo and curation components', pythonExecutable(), ['-m', 'unittest', 'discover', '-s', 'tests/modules', '-p', '*_test.py']],
  ['Offline photo example checks', pythonExecutable(), ['-m', 'unittest', 'discover', '-s', 'examples/photos', '-p', 'test_*.py']],
  // The private Studio is not part of the public source; its regressions run only where it exists.
  ...(existsSync(join(root, 'studio/tests')) ? [
    ['Existing Studio sequence regressions', pythonExecutable(), ['-m', 'unittest', 'discover', '-s', 'studio/tests', '-p', 'test_series_undo.py']],
    ['Studio identity defaults', pythonExecutable(), ['-m', 'unittest', 'discover', '-s', 'studio/tests', '-p', 'test_identity_context.py']],
  ] : []),
];
for (const [name, executable, args] of steps) {
  console.log(`\n${name}`);
  const result = spawnSync(executable, args, { cwd: root, stdio: 'inherit', timeout: 120000, windowsHide: true });
  if (result.error || result.status !== 0) { console.error(`${name} failed.`); process.exit(result.status || 1); }
}
console.log('\nOffline desktop checks passed. Live models, native builds, physical cameras and photographic preference: NOT RUN.');
