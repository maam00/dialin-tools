import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync, writeFileSync, truncateSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareCamera, inspectPreparation, normalizedFirmware, type CameraPreparation, type PreparationOptions } from '../../modules/camera/index.js';
import { runCamera } from '../../modules/camera/cli.js';
import type { Recipe } from '../../lib/fuji/recipe.js';

const examples = JSON.parse(readFileSync(new URL('../../examples/camera/own-recipes.json', import.meta.url), 'utf8')) as {recipes: Recipe[]};
const recipe = examples.recipes[0];
const book = JSON.parse(readFileSync(new URL('../../examples/planner/recipes.original.json', import.meta.url), 'utf8'));
const prepare = (input: unknown, slots: (number|string)[] = [2]) => prepareCamera(input, {slots, firmware:'1.10', transport:'usb'});

test('own recipes preserve exact settings and explicit destinations without any execution', () => {
  const p = prepare(examples, ['C2', 'C7']);
  assert.equal(p.validation.valid, true);
  assert.deepEqual(p.placements.map(x => x.slot), [2,7]);
  assert.deepEqual(p.placements.map(x => x.recipe), examples.recipes);
  assert.deepEqual(p.protected_slots, [1,3,4,5,6]);
  assert.equal(p.execution.camera_operations, 0);
  assert.equal(p.execution.provider_calls, 0);
  assert.equal(p.execution.upload, 'NOT_RUN');
  assert.equal(p.transfer_authorized, false);
  assert.equal(p.readiness.usb.state, 'requires_device_checks');
  assert.equal(p.readiness.bluetooth.state, 'blocked');
});

test('invalid or unsupported recipe values fail without coercion, substitution, or dropped fields', () => {
  for (const altered of [
    {...recipe, film_sim:'not a simulation'}, {...recipe, wb_shift_r:'1'}, {...recipe, sharpness:0.5},
    {...recipe, highlight:0.25}, {...recipe, noise_reduction:9}, {...recipe, smooth_skin:'Off'},
    {...recipe, name:'too long for a slot name'}, {...recipe, name:'Café'},
    {...recipe, white_balance:'Kelvin', kelvin:0}, {...recipe, kelvin:6300}, {...recipe, why:8},
    {...recipe, grain:undefined},
  ]) {
    const p = prepare(altered);
    assert.equal(p.validation.valid, false, JSON.stringify(altered));
    assert.deepEqual(p.placements, []);
    assert.equal(p.readiness.usb.state, 'blocked');
  }
});

test('explicit mapping and protection fail closed', () => {
  assert.equal(prepareCamera(recipe).validation.valid, false);
  for (const slots of [[0], [8], ['C0'], [1.1], ['2.0'], [2,2]]) assert.equal(prepare(recipe, slots).validation.valid, false);
  assert.equal(prepareCamera({placements:[{slot:2,recipe}],protected_slots:[2]}, {firmware:'1.10'}).validation.valid, false);
  assert.equal(prepareCamera({placements:[{slot:2,recipe}]}, {slots:[3]}).validation.valid, false);
});

test('recipe books hand off selected settings in explicit ID order without rewriting metadata', () => {
  const ids = [book.recipes[3].id, book.recipes[0].id];
  const p = prepareCamera(book, {recipeIds:ids, slots:[7,2], firmware:'1.10'});
  assert.equal(p.validation.valid,true,JSON.stringify(p.validation.errors));
  assert.equal(p.source_kind,'recipe_book');
  assert.deepEqual(p.placements.map(x=>x.recipe), [book.recipes[3].recipe,book.recipes[0].recipe]);
  assert.deepEqual(p.placements.map(x=>x.slot),[7,2]);
  assert.deepEqual(p.protected_slots,[1,3,4,5,6]);
  for (const recipeIds of [[],[ids[0],ids[0]],['missing'],[ids[0],'missing']]) {
    const invalid=prepareCamera(book,{recipeIds,slots:[7,2],firmware:'1.10'});
    assert.equal(invalid.validation.valid,false);
    assert.deepEqual(invalid.placements,[]);
  }
  assert.equal(prepareCamera(recipe,{recipeIds:ids,slots:[2]}).validation.valid,false);
  assert.equal(prepareCamera({...book,protected_slots:[7]},{recipeIds:ids,slots:[7,2]}).validation.valid,false);
  assert.equal(prepareCamera({...book,schema_version:'dialin.recipes.v999'},{recipeIds:ids,slots:[7,2]}).validation.valid,false);
  assert.equal(prepareCamera(book,{slots:[1,2,3,4,5,6,7],firmware:'1.10'}).validation.valid,true);
});

test('native recipe enum validity does not become confirmed Bluetooth encoding or write readiness', () => {
  const p = prepare({...recipe, film_sim:'Astia'});
  assert.equal(p.validation.valid, true);
  assert.equal(p.readiness.usb.state, 'requires_device_checks');
  assert.equal(p.encoding.settings_file_mapping_confirmed, false);
  assert.ok(p.encoding.unconfirmed.some(x => x.path === 'C2.film_sim'));
  assert.equal(p.readiness.bluetooth.state, 'blocked');
  assert.equal(prepareCamera(recipe, {slots:[1], firmware:'1.11'}).readiness.usb.state, 'blocked');
  for (const version of ['1.10beta','1.10.1','x1.10']) assert.equal(normalizedFirmware(version),null);
  assert.equal(normalizedFirmware('Ver 1.10'),'1.10');
});

test('planner import uses authoritative write slots and never writes kept or unknown looks', () => {
  const input = {schema_version:'dialin.planner.v1',plan:{
    day_looks:[{...recipe,slot:7,status:'new',recipe_known:true},{...examples.recipes[1],slot:2,status:'kept',recipe_known:true}],
    write:{slots:[7]},protected_slots:[2],
  }};
  const p = prepareCamera(input, {firmware:'1.10',transport:'usb'});
  assert.equal(p.validation.valid,true);
  assert.deepEqual(p.placements.map(x=>x.slot),[7]);
  assert.ok(p.protected_slots.includes(2));
  assert.deepEqual(p.placements[0].recipe,recipe);
  for (const bad of [
    {...input,plan:{...input.plan,write:{slots:[2]}}},
    {...input,plan:{...input.plan,day_looks:[{...recipe,slot:7,status:'new',recipe_known:false}]}},
    {...input,plan:{...input.plan,day_looks:[...input.plan.day_looks,input.plan.day_looks[0]]}},
  ]) assert.equal(prepareCamera(bad,{firmware:'1.10'}).validation.valid,false);
});

test('supplied protection cannot disappear through malformed planner or recipe envelopes', () => {
  const planner = (protection: Record<string, unknown>) => ({schema_version:'dialin.planner.v1',plan:{
    day_looks:[{...recipe,slot:2,status:'new',recipe_known:true}],write:{slots:[2]},...protection,
  }});
  for (const value of ['C2', {C2:true}, null, true, 2]) {
    const cases = [
      prepareCamera(planner({protected_slots:value}),{firmware:'1.10',transport:'usb'}),
      prepareCamera({placements:[{slot:2,recipe}],protected_slots:value},{firmware:'1.10',transport:'usb'}),
      prepareCamera({recipes:[recipe],protected_slots:value},{slots:[2],firmware:'1.10',transport:'usb'}),
      prepareCamera(recipe,{slots:[2],firmware:'1.10',protectedSlots:value} as unknown as PreparationOptions),
    ];
    for (const p of cases) {
      assert.equal(p.validation.valid,false);
      assert.ok(p.validation.errors.some(x=>x.code==='invalid_protection'));
      assert.deepEqual(p.placements,[]);
      assert.equal(p.readiness.usb.state,'blocked');
      assert.equal(p.execution.camera_operations,0);
    }
  }
  for (const protection of [{}, {protected_slots:undefined}, {protected_slots:[]}]) {
    assert.equal(prepareCamera(planner(protection),{firmware:'1.10'}).validation.valid,true);
  }
  assert.equal(prepareCamera(planner({protected_slots:[2]}),{firmware:'1.10'}).validation.valid,false);
  assert.equal(prepareCamera({recipes:[recipe],protected_slots:[2]},{slots:[2],firmware:'1.10'}).validation.valid,false);
  assert.equal(prepareCamera([recipe],{slots:[2],firmware:'1.10'}).validation.valid,true);
  assert.equal(prepareCamera(recipe,{slots:[2],firmware:'1.10'}).validation.valid,true);
});

test('artifact reinspection recomputes claims and preserves mapping', () => {
  const p = prepare(recipe);
  const forged = {...p, transfer_authorized:true, execution:{camera_operations:1}, validation:{valid:true}, placements:[{slot:2,recipe:{...recipe,clarity:20}}]};
  const again = inspectPreparation(forged);
  assert.equal(again.validation.valid,false);
  assert.equal(again.transfer_authorized,false);
  assert.equal(again.execution.camera_operations,0);
});

test('CLI prepares original JSON to a new file and refuses overwrite', async () => {
  const dir = mkdtempSync(join(tmpdir(),'dialin-camera-cli-'));
  const originalError = console.error;
  try {
    const out=join(dir,'new shoot','prepared.json');
    const args=['prepare','--in',new URL('../../examples/camera/own-recipes.json',import.meta.url).pathname,'--slots','C2,C7','--firmware','1.10','--transport','usb','--out',out];
    assert.equal(await runCamera(args),0);
    const p=JSON.parse(readFileSync(out,'utf8')) as CameraPreparation;
    assert.equal(p.validation.valid,true);
    console.error=()=>{};
    assert.equal(await runCamera(args),2);
    assert.equal(await runCamera(['prepare','--in','unused','--slots','1','--confirm-write']),2);
  } finally {console.error=originalError;rmSync(dir,{recursive:true,force:true});}
});

test('CLI checks input type and size before reading it', async () => {
  const dir = mkdtempSync(join(tmpdir(),'dialin-camera-input-'));
  const originalError = console.error; const messages: string[] = [];
  try {
    console.error=(m:string)=>{messages.push(String(m));};
    const big=join(dir,'big.json'); writeFileSync(big,'[]'); truncateSync(big,2_000_001);
    assert.equal(await runCamera(['prepare','--in',big,'--slots','C2']),2);
    assert.equal(await runCamera(['prepare','--in',dir,'--slots','C2']),2);
    const inputs=[big,dir];
    if (process.platform !== 'win32') { assert.equal(await runCamera(['inspect','--in','/dev/zero']),2); inputs.push('/dev/zero'); }
    assert.equal(messages.length,inputs.length);
    assert.match(messages[0],/exceeds 2 MB/);
    for (const message of messages.slice(1)) assert.match(message,/regular JSON file/);
  } finally {console.error=originalError;rmSync(dir,{recursive:true,force:true});}
});

test('an invalid preparation explains itself on stderr, with alias hints that are never applied', async () => {
  const dir = mkdtempSync(join(tmpdir(),'dialin-camera-hints-'));
  const originalError = console.error; const lines: string[] = [];
  try {
    console.error=(m:string)=>{lines.push(String(m));};
    const { film_sim, sharpness, ...rest } = recipe as Recipe & Record<string, unknown>;
    const input=join(dir,'mine.json'), out=join(dir,'prep.json');
    writeFileSync(input, JSON.stringify([{...rest, film_simulation: film_sim, sharpening: sharpness, wb_shift: 'R+2 B-4'}]));
    assert.equal(await runCamera(['prepare','--in',input,'--slots','C2','--firmware','1.10','--out',out]),2);
    const p=JSON.parse(readFileSync(out,'utf8')) as CameraPreparation;
    assert.equal(p.validation.valid,false); assert.deepEqual(p.placements,[]);
    const text=lines.join('\n');
    assert.match(text,/not valid \(\d+ issues\)/);
    assert.match(text,/film_simulation → did you mean film_sim\?/);
    assert.match(text,/sharpening → did you mean sharpness\?/);
    assert.match(text,/wb_shift → did you mean wb_shift_r and wb_shift_b/);
    assert.ok(text.includes(`Full result: ${out}`) || text.includes('Full result: '+join(realpathSync(dir),'prep.json')));
    lines.length=0;
    assert.equal(await runCamera(['prepare','--in',input,'--slots','C2','--release-macos-camera-daemon']),2);
    assert.match(lines.join('\n'),/--release-macos-camera-daemon is not accepted by prepare/);
  } finally {console.error=originalError;rmSync(dir,{recursive:true,force:true});}
});
