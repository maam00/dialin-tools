/** Dial In recipe bench. Original figure and model, MIT.
 * Geometry and page styles use Anatomy by Ryan (MIT), pinned below.
 * Rebuild: node build-anatomy.mjs --anatomy-root /path/to/anatomy --out anatomy.html --audit
 * No device, provider, browser or network operation is performed by this build.
 */
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve,dirname,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const args=process.argv.slice(2), arg=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const ROOT=arg('--anatomy-root');
if(!ROOT) throw new Error('Pass --anatomy-root pointing to the pinned Anatomy source checkout.');
const PIN='1482e8469b0a9e0d8cc18ea2740a01423d29ae80';
if(execFileSync('git',['-C',ROOT,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==PIN) throw new Error('Anatomy revision differs from the reviewed pin.');
const k=await import(pathToFileURL(resolve(ROOT,'kit/iso-kit.mjs')));
const G=await import(pathToFileURL(resolve(ROOT,'kit/lathe.mjs')));
const A=await import(pathToFileURL(resolve(ROOT,'kit/audit.mjs')));
const OUT=resolve(arg('--out','anatomy.html'));
const theme=args.includes('--dark')?'dark':'light';
const license=readFileSync(join(ROOT,'LICENSE'),'utf8');
// Exact normalized output of the newly authored, fictional Miami demonstration.
// Source plan SHA256: ee31e01853f5dde41be774251fb218f2a23e7679157793b81c13079d3692071e
// Host-agent proposal finalized offline, 2026-10-19. No camera or photo judgment.
const LOOKS=[
 {slot:1,name:'Morning soft',film_sim:'Astia',when:'Faces need soft, gentle tones'},
 {slot:2,name:'Noon color',film_sim:'Reala Ace',when:'Colorful walls with bright sunlit edges'},
 {slot:3,name:'Street B&W',film_sim:'Acros+Ye',when:'Gesture and shape matter more than color'},
 {slot:4,name:'Cafe shade',film_sim:'Pro Neg Hi',when:'Faces or details look flat in shade'},
 {slot:5,name:'Water sunset',film_sim:'Velvia',when:'Sky and water color lead the picture'},
 {slot:6,name:'Dinner light',film_sim:'Pro Neg Std',when:'Faces and food under indoor lighting'},
 {slot:7,name:'Neon color',film_sim:'Eterna',when:'Bright colored signs against darker streets'},
];
const W=840,H=460,STEP=32,MOVE=[-STEP*6,0,0];
const BASE={x:-236,y:-76,w:472,d:156,r:9};
const P=k.fitProjection([...k.boxCorners(BASE,-7,10),[-62,-58,91],[62,5,91]],W,H,{pad:53,azimuth:36,elevation:35});
const R=A.recorder(P), parts=[];
const at=(p)=>k.iso(p,P), esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
const line=(d,tone='lo',free=false)=>k.lineSvg(d,{tone,free});
const dots=(p,tone='mid',size=.48)=>k.dotsSvg(p.map(at),{tone,size});
function put(name,paths,shape,center,{tone='mid',inner='',slot=0,moving=false}={}){
 const item=R.put({name,piece:moving?'magazine':'stand',at:center,move:moving?MOVE:[0,0,0],svg:k.solidSvg(paths,{tone,inner}),shapes:[R.solid(shape)]});
 Object.assign(item,{name,slot,moving}); parts.push({name,kind:shape.kind,slot,moving}); return item;
}
function box(name,plan,z,h,opt={}){
 const inner=(opt.seam?line(k.sideSeam(plan,z+h*.55,P,6),'faint'):'')+(opt.detail??'');
 return put(name,k.slabOf(plan,z,h,P,6,Math.min(.7,h/3)),A.slab(plan,z,h,{name},6),[plan.x+plan.w/2,plan.y+plan.d/2,z+h/2],{...opt,inner});
}
function round(name,x,y,r,z,h,opt={}){
 const inner=(opt.knurl?line(k.knurl(x,y,r,z,z+h,Math.ceil(r*5),P,.1),'lo'):'')+(opt.detail??'');
 return put(name,k.cylinder(x,y,r,z,h,P,48,.4),A.cylinder(x,y,r,z,h,{name}),[x,y,z+h/2],{...opt,inner});
}
function horizontal(name,F,a,b,r,opt={}){
 return put(name,G.disc(a,b,r,F,P,{steps:64}),A.disc(F,a,b,r,{name}),G.pointOf(F,(a+b)/2,0,0),opt);
}
// 9 base solids: four rubber pads, four feet and the bedplate.
for(const [i,[x,y]] of k.corners(BASE,20).entries()){
 round(`stand.pad.${i}`,x,y,8,-7,2,{tone:'lo'});
 round(`stand.foot.${i}`,x,y,6,-5,5,{tone:'lo'});
}
box('stand.bedplate',BASE,0,10,{tone:'lo',detail:dots(k.corners(BASE,11).map(([x,y])=>[x,y,10]))});
for(const [i,y] of [23,61].entries())box(`stand.rail.${i}`,{x:-218,y,w:436,d:4,r:.7},10,4,{tone:'mid',detail:dots([-210,210].map(x=>[x,y+2,14]))});
for(const [i,x] of [-224,218].entries())box(`stand.stop.${i}`,{x,y:20,w:6,d:48,r:1},10,9,{detail:dots([[x+3,25,19],[x+3,62,19]])});
// Magazine strokes over both rails, never through the camera fixture.
box('magazine.bed',{x:-16,y:23,w:224,d:42,r:2},14,4,{moving:true});
for(let i=0;i<7;i++){
 const x=i*STEP,slot=i+1,o={slot,moving:true};
 const shell={x:x-12,y:29,w:24,d:28,r:1.9};
 box(`cartridge.${slot}.shell`,shell,18,16,{...o,tone:'hi',seam:true});
 box(`cartridge.${slot}.cap`,shell,34,2,{...o,tone:'hi',detail:dots([[x-8,33,36],[x+8,33,36]],'lo',.4)});
 box(`cartridge.${slot}.inlay`,{x:x-8,y:33,w:16,d:11,r:.7},36,.5,{...o,tone:'lo',detail:[-3,0,3].map((dy,j)=>line(k.lineOnTop([x-5,38+dy],[x+5-j*2,38+dy],36.5,P),'faint',true)).join('')});
 for(const dx of [-7,7])box(`cartridge.${slot}.pull-post.${dx}`,{x:x+dx-1,y:51,w:2,d:3,r:.4},36,4,{...o,tone:'mid'});
 box(`cartridge.${slot}.pull`,{x:x-8,y:51,w:16,d:3,r:.6},40,2,{...o,tone:'mid'});
}
// A recognizable camera fixture. Its lens faces the selection station, not a fake screen.
box('camera.plinth',{x:-66,y:-67,w:132,d:53,r:4},10,8,{tone:'mid',detail:dots([[-60,-61,18],[60,-61,18],[-60,-20,18],[60,-20,18]])});
for(const x of [-44,34])box(`camera.mount.${x}`,{x,y:-56,w:10,d:35,r:1},18,4,{tone:'mid'});
const BODY={x:-55,y:-58,w:110,d:40,r:6};
box('camera.bottom-trim',BODY,22,5,{tone:'mid'});
box('camera.body',BODY,27,45,{tone:'hi',seam:true,detail:line(k.sideSeam(BODY,33,P,6),'faint')});
box('camera.top-trim',BODY,72,6,{tone:'hi',detail:dots([[-47,-50,78],[47,-50,78]],'lo',.4)});
box('camera.grip',{x:40,y:-18,w:15,d:5,r:2},29,40,{tone:'mid'});
box('camera.finder',{x:-45,y:-53,w:25,d:28,r:3},78,8,{tone:'mid',detail:line(k.planOutline({x:-41,y:-49,w:17,d:20,r:2},86,P),'lo')});
const F=G.frameAlong([-8,-18,53],[0,1,0]);
horizontal('camera.lens.mount',F,0,4,21,{tone:'mid'});
horizontal('camera.lens.barrel',F,4,16,18,{tone:'hi'});
horizontal('camera.lens.rim',F,16,20,19,{tone:'mid'});
horizontal('camera.lens.glass',F,20,20.6,15,{tone:'lo'});
round('camera.shutter-dial',31,-38,10,78,5,{tone:'hi',knurl:true,detail:line(k.ring(31,-38,7,83,P,48),'faint')});
round('camera.shutter-button',31,-38,3.5,83,2,{tone:'mid'});
// The index is physically fixed to the rail; its pointer projects into the open gap.
box('stand.index-post',{x:-2,y:9,w:4,d:9,r:.6},10,5,{tone:'mid'});
const pointer=[[-4,18],[4,18],[0,23]];
put('stand.index-pointer',k.extrude(pointer,15,1,P),A.extruded(pointer,15,1,{name:'stand.index-pointer'}),[0,20,15.5],{tone:'hi'});
const ruler={x:-208,y:70,w:416,d:5,r:.7};
const ticks=k.topTicks(-200,200,4,8,70,10.6,[1.3,3.5],P);
box('stand.ruler',ruler,10,.6,{tone:'lo',detail:line(ticks.minor,'faint')+line(ticks.major,'lo')});
// True geometry, all points in the complete linear stroke. No hand-biased depth keys.
const STATES=Array.from({length:25},(_,i)=>i/24);
A.settle(R,P,{states:STATES});
R.items.sort((a,b)=>a.key-b.key);
if(args.includes('--audit')) A.auditOrExit(R,P,{frames:STATES,apart:1});
const basis=A.cameraBasis(P), axis=k.axisVector(P,[1,0,0]);
const items=R.items.map(it=>`<g class="part" data-name="${it.name}" data-slot="${it.slot}" data-moving="${it.moving?1:0}" data-key="${it.key}" data-lift="${G.dot3(it.move,basis.V)}">${it.svg}</g>`).join('');
const svg=k.figureSvg({width:W,height:H,label:'A camera-shaped fixture on a precision bench. A magazine carries seven proposed recipe cartridges. Its selected cartridge aligns with a fixed pointer. Conceptual offline preparation, not a real camera operation.',body:`<path class="iso-halo" d="${k.haloOf(BASE,-7,10,P)}"/><g id="parts">${items}</g>`});
const live=`
const LOOKS=${JSON.stringify(LOOKS)}, axis=${JSON.stringify(axis)}, STEP=${STEP}, TRAVEL=${STEP*6};
const stage=document.querySelector('.iso-stage'), layer=document.querySelector('#parts'), readout=document.querySelector('[data-readout]');
const parts=[...layer.children].map(el=>({el,k:+el.dataset.key,lift:+el.dataset.lift,moving:el.dataset.moving==='1',slot:+el.dataset.slot}));
const buttons=[...document.querySelectorAll('[data-select]')], use=document.querySelector('#use'), status=document.querySelector('#status');
const tourButton=document.querySelector('#tour'), still=matchMedia('(prefers-reduced-motion: reduce)');
let position=0,target=0,clock=0,frame=0,last=0,visible=false,touring=!still.matches,paused=false,hover=false,focused=false,quiet=0,explicitTour=false,direction=1,lastOrder='',lastAligned=-1;
function describe(i){return 'C'+LOOKS[i].slot+' · '+LOOKS[i].name+' · '+LOOKS[i].film_sim;}
function draw(){
 const share=position/6, nearest=Math.round(position), aligned=Math.abs(position-nearest)<.015;
 for(const p of parts){if(p.moving)p.el.setAttribute('transform','translate('+(-STEP*position*axis[0]).toFixed(3)+' '+(-STEP*position*axis[1]).toFixed(3)+')'); p.el.toggleAttribute('data-lit',aligned&&p.slot===nearest+1);}
 const ordered=[...parts].sort((a,b)=>(a.k+a.lift*share)-(b.k+b.lift*share)), order=ordered.map(p=>p.el.dataset.name).join('|');
 if(order!==lastOrder){const f=document.createDocumentFragment();for(const p of ordered)f.append(p.el);layer.append(f);lastOrder=order;}
 readout.textContent=aligned?describe(nearest):'Indexing toward C'+(target+1)+' · offline plan';
 use.textContent=aligned?LOOKS[nearest].when:'Matching a proposed look to its chosen slot.';
 buttons.forEach((b,i)=>b.setAttribute('aria-pressed',String(i===target)));
 if(aligned&&lastAligned!==nearest){lastAligned=nearest;stage.setAttribute('aria-label','Recipe bench. '+describe(nearest)+'. Arrow keys choose a look.');if(focused)status.textContent=describe(nearest);}
 document.documentElement.dataset.slot=aligned?String(nearest+1):'moving';
}
function syncTour(){tourButton.textContent=paused?'Play tour':'Pause tour';tourButton.disabled=still.matches;tourButton.title=still.matches?'Tour is disabled by your reduced-motion preference':'';}
function stop(){if(frame)cancelAnimationFrame(frame);frame=0;last=0;}
function run(){if(!frame&&visible&&!document.hidden&&!still.matches)frame=requestAnimationFrame(tick);}
function tick(now){frame=0;const dt=last?Math.min((now-last)/1000,1/30):1/60;last=now;quiet=Math.max(0,quiet-dt);
 touring=!paused&&!still.matches&&(explicitTour||(!hover&&!focused))&&quiet===0;
 if(touring){clock+=dt;if(clock>2.9){clock=0;if(target===6)direction=-1;else if(target===0)direction=1;target+=direction;}}
 position+=(target-position)*(1-Math.exp(-dt/.26));if(Math.abs(target-position)<.0008)position=target;draw();
 if(visible&&!document.hidden&&(touring||quiet>0||position!==target))run();}
function choose(i){explicitTour=false;target=Math.max(0,Math.min(6,i));clock=0;quiet=3.6;if(still.matches){position=target;draw();}else run();}
buttons.forEach((b,i)=>b.addEventListener('click',()=>choose(i)));
for(const p of parts.filter(p=>p.slot))p.el.addEventListener('pointerdown',()=>choose(p.slot-1));
stage.addEventListener('keydown',e=>{let next=null;const from=touring?Math.round(position):target;if(['ArrowRight','ArrowUp'].includes(e.key))next=from+1;if(['ArrowLeft','ArrowDown'].includes(e.key))next=from-1;if(e.key==='Home')next=0;if(e.key==='End')next=6;if(next!==null){e.preventDefault();choose(next);}if(e.key==='Escape'){paused=true;syncTour();}if(e.key===' '){e.preventDefault();paused=!paused;syncTour();run();}});
const plate=document.querySelector('.iso-plate');
plate.addEventListener('pointerenter',()=>{hover=true;});plate.addEventListener('pointerleave',()=>{hover=false;quiet=3.6;run();});
document.querySelector('#figure').addEventListener('focusin',()=>{focused=true;status.textContent=describe(Math.round(position));});
document.querySelector('#figure').addEventListener('focusout',e=>{if(!e.currentTarget.contains(e.relatedTarget)){focused=false;quiet=3.6;run();}});
tourButton.addEventListener('click',()=>{paused=!paused;explicitTour=!paused;quiet=0;syncTour();run();});
new IntersectionObserver(entries=>{visible=entries[entries.length-1].isIntersecting;if(visible)run();else stop();},{rootMargin:'120px 0px'}).observe(stage);
document.addEventListener('visibilitychange',()=>document.hidden?stop():run());
still.addEventListener('change',()=>{stop();if(still.matches){position=target;draw();}else run();syncTour();});
document.querySelector('#theme').addEventListener('click',()=>{document.body.dataset.theme=document.body.dataset.theme==='light'?'dark':'light';document.querySelector('#theme').textContent=document.body.dataset.theme==='light'?'Dark theme':'Light theme';});
syncTour();draw();
`;
const card=k.plateHtml({fig:'FIG. 01',title:'Seven looks. Your choice.',hint:'Tap a cartridge · use arrow keys',readout:'C1 · Morning soft · Astia',keys:[{mark:'lit',label:'The aligned recipe'},{mark:'raised',label:'Seven proposed looks'}],caption:'Conceptual illustration of an offline plan. Actual USB writing is separately authorized and qualified only on the tested X100VI 1.10 / Mac setup. No camera was operated.',body:`<div class="iso-stage" tabindex="0" role="group" aria-label="Recipe bench. Arrow keys choose a look.">${svg}</div>`});
const controls=`<div class="selects" role="group" aria-label="Choose a proposed camera slot">${LOOKS.map((r,i)=>`<button type="button" data-select="${i}" aria-pressed="${i===0}" title="${esc(r.name+' · '+r.film_sim)}">C${r.slot}</button>`).join('')}</div><p id="use">${LOOKS[0].when}</p><div class="tools"><button type="button" id="tour">Pause tour</button><button type="button" id="theme">${theme==='light'?'Dark':'Light'} theme</button><span>Illustration, not a camera connection</span></div><span class="sr-only" id="status" aria-live="polite"></span>`;
const css=`<style>
html{color-scheme:light dark}
.iso[data-theme="light"]{--anatomy-mid:#596167;--anatomy-lo:#80898f;--anatomy-faint:#b5bbc0;--anatomy-hi:#23282c;--anatomy-muted:#687078;--anatomy-top:#f7f8f8;--anatomy-shade-0:#ccd1d4;--anatomy-shade-1:#d9dde0;--anatomy-shade-2:#e5e8e9;--anatomy-shade-3:#f0f2f3}
.iso[data-theme="dark"]{--anatomy-page:#101215;--anatomy-card:#14171b;--anatomy-paper:#14171b;--anatomy-face:#252b31;--anatomy-top:#3b434b;--anatomy-shade-0:#1b2025;--anatomy-shade-1:#242b32;--anatomy-shade-2:#2d363e;--anatomy-shade-3:#35414b;--anatomy-hi:#d9e0e6;--anatomy-mid:#a5b4bf;--anatomy-lo:#758894;--anatomy-faint:#475964;--anatomy-muted:#9daab4;--anatomy-lit-top:#63737e;--anatomy-lit-shade:#45545e}
.iso{margin:0;background:var(--anatomy-paper);font-family:ui-sans-serif,system-ui,-apple-system,sans-serif}.iso .iso-page{width:min(860px,100%);padding:16px 22px 20px;margin:auto;box-sizing:border-box}.intro{display:flex;align-items:baseline;justify-content:space-between;gap:16px;margin:0 0 14px}.intro h1{font-size:19px;font-weight:600;letter-spacing:-.03em;margin:0}.intro p{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--anatomy-muted);margin:0}.iso-figure{margin:14px 0 18px}.iso-plate{border-radius:12px;padding:32px 14px}.iso-plate .iso-svg{max-height:360px}.iso-stage{touch-action:pan-y}.iso-plate-corner{font-size:11px}.iso-plate-corner[data-corner="readout"]{max-width:70%;text-align:right}.part[data-slot]:not([data-slot="0"]){cursor:pointer}.part[data-lit] .iso-solid{--anatomy-hi:var(--anatomy-lit);--anatomy-mid:var(--anatomy-lit);--anatomy-top:var(--anatomy-lit-top)}.part[data-lit] .iso-edge{stroke:var(--anatomy-lit);stroke-width:1}.part[data-lit] .iso-top{fill:var(--anatomy-lit-top)}.selects{display:grid;grid-template-columns:repeat(7,1fr);gap:8px;margin:18px 0 10px}.selects button,.tools button{font:500 12px ui-monospace,SFMono-Regular,monospace;color:var(--anatomy-muted);border:1px solid var(--anatomy-faint);background:transparent;border-radius:6px;min-height:38px;cursor:pointer}.selects button[aria-pressed="true"]{color:var(--anatomy-hi);border-color:var(--anatomy-hi);background:var(--anatomy-shade-3)}button:focus-visible,.iso-stage:focus-visible{outline:2px solid var(--anatomy-hi);outline-offset:4px}#use{min-height:20px;font-size:13px;margin:12px 0 18px;color:var(--anatomy-muted)}.tools{display:flex;align-items:center;gap:9px;flex-wrap:wrap}.tools button{padding:0 12px;min-height:32px}.tools span{font-size:11px;color:var(--anatomy-muted);margin-left:auto}.tools button:disabled{opacity:.5;cursor:default}.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}.iso-caption{font-size:12px;max-width:760px;line-height:1.55}.iso-legend{gap:18px;font-size:11px}@media(max-width:520px){.iso .iso-page{padding:18px 12px}.intro{align-items:flex-start;flex-direction:column;gap:5px}.intro h1{font-size:15px}.iso-plate-corner{font-size:9px}.iso-plate-corner[data-corner="hint"]{display:none}.iso-plate-corner[data-corner="readout"]{max-width:94%;left:12px;right:12px;text-align:left}.selects{gap:5px}.tools span{width:100%;margin-left:0}.iso-caption{font-size:11px}.iso-legend{flex-wrap:wrap}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;animation:none!important;transition:none!important}}
</style>`;
const body=`<section id="figure"><header class="intro"><h1>Dial In · Seven looks for your Fuji.</h1><p>Describe the shoot. Review the recipes.</p></header>${card}${controls}</section>`;
let html=k.pageHtml({title:'Dial In — seven-look recipe bench',theme,body,script:live,width:1020});
html=html.replace('</head>',css+'</head>').replace('<html','<!-- Anatomy geometry and styles: '+license.replaceAll('--','—')+' -->\n<html');
mkdirSync(dirname(OUT),{recursive:true});writeFileSync(OUT,html);
const receipt={schema:'dialin.anatomy-figure.v1',anatomy_revision:PIN,plan_sha256:'ee31e01853f5dde41be774251fb218f2a23e7679157793b81c13079d3692071e',theme,parts:parts.length,part_list:parts,stroke_states:STATES.length,hardware_operations:0,provider_calls:0,html_sha256:createHash('sha256').update(html).digest('hex'),browser_checks:'NOT_RUN'};
if(arg('--receipt'))writeFileSync(arg('--receipt'),JSON.stringify(receipt,null,2)+'\n');
console.log(JSON.stringify({out:OUT,parts:parts.length,bytes:Buffer.byteLength(html),sha256:receipt.html_sha256,theme}));
