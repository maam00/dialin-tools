import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pythonExecutable } from './doctor.mjs';

const json = (path, value) => writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
const cell = (value) => String(value ?? '').replace(/[|\r\n]+/g, ' ').trim();
const signed = (value) => (typeof value === 'number' && value > 0 ? `+${value}` : String(value));

/** A readable account of the rehearsal. The JSON files remain the contract; this never claims more than run.json. */
export function demoSummary({ plan, preparation, edit, receipt }) {
  const looks = plan.plan?.day_looks ?? [];
  const readiness = preparation.readiness ?? {};
  const lines = [
    '# Dial In connected demo (offline fixture)',
    '',
    'Produced by `dialin demo`. It rehearses the file handoffs between planning, camera preparation and curation with bundled original fixtures.',
    'Nothing here is an AI response to your scene, a camera write, or a review of real photographs.',
    '',
    '| Stage | What happened | File |',
    '| --- | --- | --- |',
    '| Planning | A fixed original answer ran through the real planner engine; 0 provider calls | `plan.json` |',
    `| Camera preparation | Offline validation for ${cell(preparation.camera?.model)} firmware ${cell(preparation.camera?.firmware)} over ${cell(preparation.selected_transport)}: ${preparation.validation?.valid ? 'valid' : 'invalid'}; transfer authorized: ${preparation.transfer_authorized ? 'yes' : 'no'} | \`camera-preparation.json\` |`,
    '| Camera write, photo import, visual review, export of originals | Not run | — |',
    '| Curation | Synthetic metadata (no image pixels) validated and sequenced | `curation-input.json` → `edit.json` |',
    '',
    `## Plan: ${cell(plan.plan?.plan?.summary) || 'fixture palette'}`,
    '',
    `Validation status: ${cell(plan.validation?.status)}. Provider calls: ${receipt.provider_calls}.`,
    '',
    '| Slot | Look | Film simulation | White balance | DR | Highlight / Shadow | Color | When |',
    '| --- | --- | --- | --- | --- | --- | --- | --- |',
    ...looks.map((look) => `| C${look.slot} | ${cell(look.name)} | ${cell(look.film_sim)} | ${cell(look.white_balance === 'Kelvin' ? `${look.kelvin}K` : look.white_balance)}${look.wb_shift_r || look.wb_shift_b ? ` ${signed(look.wb_shift_r)}R/${signed(look.wb_shift_b)}B` : ''} | ${cell(look.dynamic_range)} | ${signed(look.highlight)} / ${signed(look.shadow)} | ${signed(look.color)} | ${cell(look.when)} |`),
    '',
    '## Camera preparation',
    '',
    `Targets: ${(preparation.placements ?? []).map((p) => `C${p.slot}`).join(', ') || 'none'}. Protected: ${(preparation.protected_slots ?? []).map((s) => `C${s}`).join(', ') || 'none'}.`,
    ...Object.entries(readiness).map(([transport, state]) => `- ${transport}: \`${cell(state.state)}\` — ${cell(state.reasons?.[0])}`),
    `- ${(preparation.validation?.warnings ?? []).length} warning(s) are listed in \`camera-preparation.json\`. A preparation file is not an upload or a backup.`,
    '',
    `## Edit: ${cell(edit.title)} (${edit.selected_ids?.length ?? 0} of ${(edit.selected_ids?.length ?? 0) + (edit.omitted?.length ?? 0)} synthetic frames)`,
    '',
    'The curation fixture is a separate synthetic harbor-day manifest. The demo links it to the plan through `shoot.plan_revision`; no photograph was opened.',
    '',
    ...(edit.sequence ?? []).map((item) => `${item.position}. \`${cell(item.id)}\` (${cell(item.role)}) — ${cell(item.selection_reason)} ${cell(item.order_reason)} Note: “${cell(item.supplied_note)}”`),
    '',
    `Omitted: ${(edit.omitted ?? []).map((o) => `\`${cell(o.id)}\` (${cell(o.reason).replace(/_/g, ' ')})`).join(', ') || 'none'}.`,
    '',
    '## Do it for real',
    '',
    '- Plan your own shoot with your coding agent: `npm run dialin -- plan --mode agent --text "your shoot" --out .dialin/my-shoot/request.json`; see `modules/planner/README.md`.',
    '- Put your own recipes into chosen slots: `npm run dialin -- camera prepare --in examples/camera/own-recipes.json --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/my-camera.json`.',
    '- Review a folder of your JPEGs: `npm run dialin -- photos prepare --input /path/to/photos --out .dialin/my-photos --intent "your story" --count 8`, then ask your agent to read its `REVIEW.md`.',
    '',
  ];
  return lines.join('\n');
}

export async function runDemo(args) {
  if (args.length === 1 && ['--help', '-h'].includes(args[0])) {
    console.log('Usage: dialin demo --out <new-directory>\nOriginal offline fixture: engine planning → camera preparation → supplied-metadata curation. No visual model or camera operations.\nWrites plan.json, camera-preparation.json, curation-input.json, edit.json, run.json and a readable SUMMARY.md.'); return 0;
  }
  if (args.length !== 2 || args[0] !== '--out' || !args[1] || args[1].startsWith('--')) throw new Error('Usage: dialin demo --out <new-directory>');
  let register;
  try { ({ register } = await import('tsx/esm/api')); }
  catch { throw new Error('TypeScript runtime missing. Run npm ci --ignore-scripts, then retry the demo.'); }
  register();
  const { createPlan } = await import('./planner/index.ts');
  const { prepareCamera } = await import('./camera/index.ts');
  const out = resolve(args[1]);
  // mkdir is deliberately non-recursive for the final directory: never replace another run.
  await mkdir(resolve(out, '..'), { recursive: true });
  try { await mkdir(out, { mode: 0o700 }); }
  catch (error) {
    if (error?.code === 'EEXIST') throw new Error(`${out} already exists. Choose a new --out directory; earlier runs are never replaced.`);
    throw error;
  }
  try {
    const plan = await createPlan({ mode: 'demo' });
    if (plan.validation.status !== 'proposal') throw new Error('The original planning fixture no longer validates; inspect the planner tests.');
    const preparation = prepareCamera(plan, { model: 'X100VI', firmware: '1.10', transport: 'bluetooth' });
    if (!preparation.validation.valid) throw new Error('Camera preparation did not validate; inspect the component handoff before continuing.');
    const input = JSON.parse(await readFile(new URL('../examples/curation/shoot.json', import.meta.url), 'utf8'));
    input.shoot.plan_revision = createHash('sha256').update(JSON.stringify(plan)).digest('hex');
    input.shoot.intent = plan.plan?.plan?.summary || input.shoot.intent;
    await json(resolve(out, 'plan.json'), plan);
    await json(resolve(out, 'camera-preparation.json'), preparation);
    await json(resolve(out, 'curation-input.json'), input);
    const python = pythonExecutable();
    const curation = spawnSync(python, [fileURLToPath(new URL('./curation/cli.py', import.meta.url)), '--input', resolve(out, 'curation-input.json')],
      { encoding: 'utf8', timeout: 20000, maxBuffer: 1024 * 1024, windowsHide: true });
    if (curation.status !== 0 || curation.error) {
      const detail = (curation.error?.message || curation.stderr || '').trim().split('\n').slice(-3).join(' | ');
      throw new Error(`Curation rehearsal failed with ${python}${detail ? `: ${detail}` : ''}. Run node scripts/dialin.mjs doctor curate.`);
    }
    const edit = JSON.parse(curation.stdout);
    if (edit.schema !== 'dialin.curation/1' || edit.status !== 'complete') throw new Error('The synthetic curation fixture did not complete; inspect the curation tests.');
    await json(resolve(out, 'edit.json'), edit);
    const receipt = { schema_version: 'dialin.demo.v1', mode: 'offline_fixture',
      stages: { planning: 'FIXTURE_THROUGH_REAL_ENGINE', camera_preparation: 'OFFLINE_VALIDATED',
        camera_write: 'NOT_RUN', photo_import: 'NOT_RUN', visual_review: 'NOT_RUN', curation: 'SYNTHETIC_METADATA_VALIDATED', original_export: 'NOT_RUN' },
      provider_calls: 0, device_operations: 0,
      artifacts: ['plan.json', 'camera-preparation.json', 'curation-input.json', 'edit.json', 'SUMMARY.md'],
      note: 'This validates component handoffs. It does not establish photographic quality, Bluetooth acceptance or physical transfer.' };
    await writeFile(resolve(out, 'SUMMARY.md'), demoSummary({ plan, preparation, edit, receipt }), { flag: 'wx' });
    await json(resolve(out, 'run.json'), receipt);
    console.log(JSON.stringify({ ...receipt, output: out }, null, 2));
    const shown = relative(process.cwd(), out) || '.';
    console.error(`Demo complete: read ${shown.startsWith('..') ? out : shown}/SUMMARY.md. Fixture rehearsal only; no camera, model or photo review ran.`);
    return 0;
  } catch (error) { await rm(out, { recursive: true, force: true }); throw error; }
}
