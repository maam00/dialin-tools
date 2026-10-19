import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { prepareCamera } from '../../modules/camera/index.js';
import { PROFILES, X100VI_110, type CameraProfile } from '../../modules/camera/profiles.js';
import { applyUsbPreparation, expectedUsbWrites, guardedUsbPort, inspectUsb, privatePath, readbackMatches, type LowLevelUsbCamera, type UsbCameraPort, type UsbIdentity, type UsbSlot } from '../../modules/camera/usb.js';
import { recipeToPresetValues, type Recipe } from '../../lib/fuji/recipe.js';
import { packPTPString, packU16 } from '../../lib/fuji/vendor/binary.js';
import { translatePresetToUI, translateUIToPresetProps } from '../../lib/fuji/vendor/preset-translate.js';
import { GrainEffect } from '../../lib/fuji/vendor/enums.js';
import type { RawProp } from '../../lib/fuji/vendor/types.js';

const recipe = JSON.parse(readFileSync(new URL('../../examples/camera/own-recipes.json',import.meta.url),'utf8')).recipes[0] as Recipe;
const values=recipeToPresetValues(recipe);
const raw=(id:number,bytes:Uint8Array):RawProp=>({id,name:'',bytes:bytes.slice(),value:new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).getInt16(0,true)});
const clone=(s:UsbSlot):UsbSlot=>({...s,props:s.props.map(p=>({...p,bytes:p.bytes.slice()}))});
function baseline(slot:number):UsbSlot {
  const encoded=new Map(translateUIToPresetProps(values).map(p=>[p.id,p.bytes]));
  return {slot,name:`Original ${slot}`,props:Array.from({length:0xd1a4-0xd18e+1},(_,i)=>0xd18e+i).map(id=>raw(id,encoded.get(id)??packU16(0)))};
}
class FakeCamera implements UsbCameraPort {
  slots=Array.from({length:7},(_,i)=>baseline(i+1)); active=1; writes:number[]=[]; disconnected=false; connected=false; identityReads=0;
  identity:UsbIdentity={model:'X100VI',firmware:'1.10',serial:'SYNTHETIC-TEST-ONLY',canEditSlots:true};
  identityAt?: (count:number)=>UsbIdentity; onWrite?:()=>void; missingRead?:number; rejected=false; interrupt=false; corruptProtected=false; corruptFinal=false;
  collateralTarget=false; collateralFinal=false; extraTargetField=false; removeExtraTargetField=false; targetSnapshotReads=0;
  grainOffStoredAs?:number; // X100VI 1.10 stores a written Grain Off (1) as 6 or 7
  async connect(){this.connected=true;}
  async disconnect(){this.disconnected=true;}
  async readIdentity(){this.identityReads++;return this.identityAt?.(this.identityReads)??this.identity;}
  async readSlot(slot:number){
    this.active=slot;const s=clone(this.slots[slot-1]);
    if(this.writes.length&&slot===2){
      this.targetSnapshotReads++;
      if(this.corruptFinal)s.props.find(p=>p.id===0xd192)!.bytes=packU16(999);
      if(this.collateralFinal&&this.targetSnapshotReads>=2)s.props.find(p=>p.id===0xd18f)!.bytes=packU16(999);
    }
    return s;
  }
  async readProp(id:number){
    if(this.writes.length&&id===this.missingRead)return null;
    const s=this.slots[this.active-1];
    if(id===0xd18d)return {id,name:'',bytes:packPTPString(s.name??''),value:s.name??''};
    return s.props.find(p=>p.id===id)??null;
  }
  async writeSlot(slot:number,name:string,v:typeof values,options:{base:RawProp[];verify:boolean}){
    this.onWrite?.();this.writes.push(slot);this.active=slot;
    const s=this.slots[slot-1];s.name=name;
    for(const p of expectedUsbWrites(v,options.base))s.props=s.props.map(q=>q.id===p.id?raw(p.id,p.bytes):q);
    if(this.grainOffStoredAs!==undefined)s.props=s.props.map(q=>q.id===0xd195&&q.value===1?raw(q.id,packU16(this.grainOffStoredAs!)):q);
    if(this.collateralTarget)s.props.find(p=>p.id===0xd18f)!.bytes=packU16(999);
    if(this.extraTargetField)s.props.push(raw(0xd1a5,packU16(999)));
    if(this.removeExtraTargetField)s.props=s.props.filter(p=>p.id!==0xe123);
    if(this.corruptProtected)this.slots[0].name='Changed';
    if(this.interrupt)throw new Error('synthetic disconnect');
    return {rejected:this.rejected?['synthetic no acknowledgement']:[],mismatched:[]};
  }
}
const prep=()=>prepareCamera({placements:[{slot:2,recipe},{slot:7,recipe:{...recipe,name:'Second'}}]}, {firmware:'1.10',transport:'usb'});
async function scenario(fn:(camera:FakeCamera,path:string)=>Promise<void>){const dir=mkdtempSync(join(tmpdir(),'dialin-camera-usb-'));try{await fn(new FakeCamera(),join(dir,'backup.json'));}finally{rmSync(dir,{recursive:true,force:true});}}

test('explicit confirmation and current readiness precede even camera creation',async()=>{
  let factories=0;const deps={camera:async()=>{factories++;return new FakeCamera();}};
  await assert.rejects(applyUsbPreparation(prep(),{confirmWrite:false,backupPath:'/unused'},deps),/confirm-write/);
  await assert.rejects(applyUsbPreparation({...prep(),selected_transport:'bluetooth'},{confirmWrite:true,backupPath:'/unused'},deps),/transport usb/);
  await assert.rejects(applyUsbPreparation({...prep(),camera:{...prep().camera,firmware:'1.11'}},{confirmWrite:true,backupPath:'/unused'},deps),/profile/);
  assert.equal(factories,0);
});

test('identity, incomplete backup, missing name and changed identity all stop before any recipe write',async()=>{
  for(const mutate of [
    (c:FakeCamera)=>{c.identity.model='X-T5';},(c:FakeCamera)=>{c.identity.firmware='1.10.1';},
    (c:FakeCamera)=>{c.identity.serial='';},(c:FakeCamera)=>{c.identity.canEditSlots=false;},
    (c:FakeCamera)=>{c.slots[0].props=c.slots[0].props.filter(p=>p.id!==0xd19f);},
    (c:FakeCamera)=>{c.slots[0].name=null;},
    (c:FakeCamera)=>{c.identityAt=n=>({...c.identity,serial:n>1?'ANOTHER-SYNTHETIC':c.identity.serial});},
  ])await scenario(async(c,path)=>{mutate(c);await assert.rejects(applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c}));assert.deepEqual(c.writes,[]);assert.equal(existsSync(path),false);assert.equal(c.disconnected,true);});
});

test('durable private backup is complete and exists before first write; receipt excludes identity and bytes',async()=>{
  await scenario(async(c,path)=>{
    c.onWrite=()=>{const b=JSON.parse(readFileSync(path,'utf8'));assert.equal(b.slots.length,7);assert.equal(b.slots[1].name,'Original 2');/* POSIX file modes only */if(process.platform!=='win32')assert.equal(statSync(path).mode&0o777,0o600);};
    const result=await applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c});
    assert.equal(result.result,'verified_current_session');assert.deepEqual(c.writes,[2,7]);assert.equal(result.protected_slots_checked,true);
    assert.equal(result.restart_check,'NOT_RUN');assert.equal(result.photographic_quality,'NOT_EVALUATED');
    assert.ok(!JSON.stringify(result).includes(c.identity.serial));assert.ok(!JSON.stringify(result).includes('props'));
    assert.equal(c.disconnected,true);
  });
});

test('no acknowledgement, missing readback, interruption, final mismatch and protected changes never report success',async()=>{
  for(const mutate of [
    (c:FakeCamera)=>{c.rejected=true;},(c:FakeCamera)=>{c.missingRead=0xd192;},
    (c:FakeCamera)=>{c.missingRead=0xd18d;},(c:FakeCamera)=>{c.interrupt=true;},
    (c:FakeCamera)=>{c.corruptFinal=true;},(c:FakeCamera)=>{c.corruptProtected=true;},
    (c:FakeCamera)=>{c.identityAt=n=>({...c.identity,serial:n>=3?'CHANGED-SYNTHETIC':c.identity.serial});},
  ])await scenario(async(c,path)=>{mutate(c);const result=await applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c});assert.equal(result.result,'not_verified');assert.ok(result.issues.length>0);assert.equal(existsSync(path),true);assert.equal(c.disconnected,true);if(c.rejected||c.missingRead||c.interrupt||c.corruptProtected)assert.deepEqual(c.writes,[2]);});
});

test('a preparation for one body is never written to another verified body',async()=>{
  // Test-only second verified profile, as a future reviewed body would add: the declared and connected bodies must still agree.
  const other={...X100VI_110,id:'X-T50-1.10',model:'X-T50'} as CameraProfile;
  (PROFILES as CameraProfile[]).push(other);
  try{
    await scenario(async(c,path)=>{c.identity.model='X-T50';
      await assert.rejects(applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c}),/declared camera/);
      assert.deepEqual(c.writes,[]);assert.equal(existsSync(path),false);assert.equal(c.disconnected,true);});
  }finally{(PROFILES as CameraProfile[]).splice(PROFILES.indexOf(other),1);}
  assert.deepEqual(PROFILES,[X100VI_110]);
});

test('existing backup destination is refused before camera connection',async()=>{
  await scenario(async(c,path)=>{writeFileSync(path,'keep this');await assert.rejects(applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c}),/already exists/);assert.equal(c.connected,false);assert.equal(readFileSync(path,'utf8'),'keep this');});
});

test('target-slot collateral changes stop subsequent targets and cannot pass the final snapshot',async()=>{
  for(const mutate of [
    (c:FakeCamera)=>{c.collateralTarget=true;},
    (c:FakeCamera)=>{c.extraTargetField=true;},
    (c:FakeCamera)=>{c.slots[1].props.push(raw(0xe123,packU16(123)));c.removeExtraTargetField=true;},
    (c:FakeCamera)=>{c.collateralFinal=true;},
  ])await scenario(async(c,path)=>{
    mutate(c);
    const result=await applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c});
    assert.equal(result.result,'not_verified');
    assert.ok(result.issues.some(x=>x.includes('non-write property')));
    assert.equal(existsSync(path),true);
    if(c.collateralFinal){assert.deepEqual(c.writes,[2,7]);assert.ok(result.issues.some(x=>x.startsWith('Final check:')));}
    else assert.deepEqual(c.writes,[2]);
  });
});

test('info omits serial and backup returns only a private receipt',async()=>{
  await scenario(async(c,path)=>{const info=await inspectUsb({operation:'info'},{camera:async()=>c});assert.equal(info.recipe_writes,0);assert.ok(!JSON.stringify(info).includes(c.identity.serial));const backup=await inspectUsb({operation:'backup',backupPath:path},{camera:async()=>c});assert.equal(backup.recipe_writes,0);assert.equal(existsSync(path),true);assert.deepEqual(c.writes,[]);});
});

test('desktop adapter verifies cursor before any recipe mutation and stops at a refused property',async()=>{
  let cursor:number|null=1;let refused:number|undefined;const writes:number[]=[];
  const low:LowLevelUsbCamera={
    connect:async()=>{},disconnect:async()=>{},usb:{command:async()=>({code:0x2001,data:new Uint8Array()})},
    readSlot:async(slot)=>({...baseline(slot),name:'Original'}), selectSlot:async()=>{},
    readProp:async(id)=>id===0xd18c&&cursor!==null?raw(id,packU16(cursor)):null,
    writeProp:async(id)=>{writes.push(id);return id!==refused;},
  };
  const adapter=guardedUsbPort(low);
  await assert.rejects(adapter.writeSlot(2,recipe.name,values,{base:baseline(2).props,verify:true}),/selected/);assert.deepEqual(writes,[]);
  cursor=null;await assert.rejects(adapter.writeSlot(2,recipe.name,values,{base:baseline(2).props,verify:true}));assert.deepEqual(writes,[]);
  cursor=2;refused=0xd190;const report=await adapter.writeSlot(2,recipe.name,values,{base:baseline(2).props,verify:true});
  assert.equal(report.rejected.length,1);assert.deepEqual(writes,[0xd18d,0xd192,0xd191,0xd190]); // No DR fallback or later fields.
});

test('in-repository backup destinations are refused before camera creation and without creating folders',async()=>{
  const repo=realpathSync(new URL('../..',import.meta.url));
  const dir=mkdtempSync(join(tmpdir(),'dialin-camera-usb-repo-'));
  try{
    const posix=process.platform!=='win32'; // Windows symlinks need extra privileges; modes are POSIX-only
    if(posix)symlinkSync(join(repo,'tests'),join(dir,'linked-into-repo'));
    let factories=0;const deps={camera:async()=>{factories++;return new FakeCamera();}};
    // Case-insensitive volumes (default macOS/Windows) reach the repository through a differently cased path.
    const variant=join(dirname(repo),basename(repo).toUpperCase()===basename(repo)?basename(repo).toLowerCase():basename(repo).toUpperCase());
    const caseVariants=variant!==repo&&existsSync(variant)?[join(variant,'backup.json'),join(variant,'new-case-folder','backup.json')]:[];
    for(const path of [join(repo,'backup.json'),join(repo,'..dialin-backups','nested','backup.json'),...(posix?[join(dir,'linked-into-repo','new-folder','backup.json')]:[]),...caseVariants]){
      assert.throws(()=>privatePath(path),/outside the repository/,path);
      await assert.rejects(applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},deps),/outside the repository/);
      await assert.rejects(inspectUsb({operation:'backup',backupPath:path},deps),/outside the repository/);
    }
    assert.equal(existsSync(join(repo,'..dialin-backups')),false);
    assert.equal(existsSync(join(repo,'tests','new-folder')),false);
    assert.equal(factories,0);
    const outside=privatePath(join(dir,'private backups','backup.json'));
    assert.equal(outside,join(realpathSync(dir),'private backups','backup.json'));
    if(posix)assert.equal(statSync(join(dir,'private backups')).mode&0o777,0o700);
  }finally{rmSync(dir,{recursive:true,force:true});}
});

test('Grain Off read back as 6 or 7 verifies; writes still send 1 and every other difference stays strict',async()=>{
  const grainWrite=(base:RawProp[])=>expectedUsbWrites(values,base).find(p=>p.id===0xd195)!;
  const storedSeven=baseline(2).props.map(p=>p.id===0xd195?raw(p.id,packU16(7)):p);
  assert.equal(recipe.grain,'Off');
  assert.deepEqual([...grainWrite(storedSeven).bytes],[1,0]); // never writes 6/7, even over a slot that holds 7
  for(const stored of [6,7])await scenario(async(c,path)=>{
    c.grainOffStoredAs=stored;
    const result=await applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c});
    assert.equal(result.result,'verified_current_session',JSON.stringify(result.issues));
    assert.deepEqual(result.issues,[]);assert.deepEqual(c.writes,[2,7]);
  });
  for(const stored of [0,2,5,8])await scenario(async(c,path)=>{
    c.grainOffStoredAs=stored;
    const result=await applyUsbPreparation(prep(),{confirmWrite:true,backupPath:path},{camera:async()=>c});
    assert.equal(result.result,'not_verified',String(stored));
    assert.ok(result.issues.some(x=>x.includes('0xd195')));assert.deepEqual(c.writes,[2]);
  });
  assert.equal(readbackMatches(0xd195,'0100','0700'),true);
  assert.equal(readbackMatches(0xd195,'0200','0700'),false); // grain on: exact
  assert.equal(readbackMatches(0xd196,'0100','0700'),false); // other properties: exact
  assert.equal(readbackMatches(0xd195,'0100',undefined),false);
  for(const stored of [1,6,7])assert.equal(translatePresetToUI([raw(0xd195,packU16(stored))]).grainEffect,GrainEffect.Off);
});

test('macOS camera-daemon release is explicit, darwin-only, exclusive-access-only and bounded',async()=>{
  const { claimCamera } = await import('../../lib/fuji/claim.js');
  const busy=()=>new Error('LIBUSB_ERROR_ACCESS: could not open interface for exclusive access (0xe00002c5)');
  const harness=(failures:number,error=busy)=>{let calls=0,released=0;return{claim:async()=>{if(calls++<failures)throw error();},release:()=>{released++;return [4242];},get calls(){return calls;},get released(){return released;}};};
  // Default: no flag → one claim, no process touched, honest macOS guidance.
  let h=harness(1);
  await assert.rejects(claimCamera(h.claim,{platform:'darwin',release:h.release,delayMs:1}),(e:Error)=>/kill -9 \$\(pgrep -x -U/.test(e.message)&&/--release-macos-camera-daemon/.test(e.message)&&/did not release it on macOS 27/.test(e.message));
  assert.equal(h.released,0);assert.equal(h.calls,1);
  // Opt-in on another platform, or for a different error: never stops anything.
  h=harness(1);await assert.rejects(claimCamera(h.claim,{platform:'linux',releaseMacCameraDaemon:true,release:h.release,delayMs:1}),/USB permissions/);assert.equal(h.released,0);
  h=harness(1,()=>new Error('LIBUSB_ERROR_NO_DEVICE'));await assert.rejects(claimCamera(h.claim,{platform:'darwin',releaseMacCameraDaemon:true,release:h.release,delayMs:1}));assert.equal(h.released,0);
  // Opt-in on macOS: stop, retry, succeed.
  h=harness(2);const seen:number[][]=[];
  assert.deepEqual(await claimCamera(h.claim,{platform:'darwin',releaseMacCameraDaemon:true,release:h.release,delayMs:1,onRelease:(p)=>seen.push(p)}),{releasedPids:[4242,4242]});
  assert.equal(h.calls,3);assert.equal(seen.length,2);
  // A daemon that keeps winning: bounded attempts, then a clear refusal.
  h=harness(99);await assert.rejects(claimCamera(h.claim,{platform:'darwin',releaseMacCameraDaemon:true,release:h.release,delayMs:1,attempts:5}),/even after stopping ptpcamerad/);
  assert.equal(h.released,5);assert.equal(h.calls,6);
});
