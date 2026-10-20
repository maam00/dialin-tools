/** Dial In's seven-look illustration. Original composition, MIT.
 * Camera geometry: Anatomy by Ryan (MIT), pinned below.
 * This build performs no camera, model or network operation.
 */
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
const args=process.argv.slice(2), arg=(name,fallback)=>args.includes(name)?args[args.indexOf(name)+1]:fallback;
const ROOT=arg('--anatomy-root'), OUT=arg('--out-dir');
if(!ROOT || !OUT) throw new Error('Pass --anatomy-root and a new --out-dir.');
const PIN='1482e8469b0a9e0d8cc18ea2740a01423d29ae80';
if(execFileSync('git',['-C',ROOT,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!==PIN) throw new Error('Anatomy revision differs from the reviewed pin.');
const k=await import(pathToFileURL(resolve(ROOT,'kit/iso-kit.mjs')));
const G=await import(pathToFileURL(resolve(ROOT,'kit/lathe.mjs')));
const A=await import(pathToFileURL(resolve(ROOT,'kit/audit.mjs')));
const license=readFileSync(join(ROOT,'LICENSE'),'utf8');
// Same seven normalized proposals as the original fictional Miami example.
// Plan SHA256: ee31e01853f5dde41be774251fb218f2a23e7679157793b81c13079d3692071e
const LOOKS=['Morning soft','Noon color','Street B&W','Cafe shade','Water sunset','Dinner light','Neon color'];
const WIDTH=1200,HEIGHT=640,FPS=25,SECONDS=7;
const W=600,H=440;
const P=k.fitProjection(k.boxCorners({x:-55,y:-58,w:110,d:61,r:0},22,64),W,H,{pad:25,azimuth:32,elevation:24});
// The camera's bottom trim supports the connected body and lens assembly.
const R=A.recorder(P,{ground:shape=>shape.name==='camera.bottom-trim'}),parts=[];
const at=(p)=>k.iso(p,P), esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
const line=(d,tone='lo',free=false)=>k.lineSvg(d,{tone,free});
const dots=(p,tone='mid',size=.48)=>k.dotsSvg(p.map(at),{tone,size});
function put(name,paths,shape,center,{tone='mid',inner=''}={}){
 const item=R.put({name,piece:'camera',at:center,move:[0,0,0],svg:k.solidSvg(paths,{tone,inner}),shapes:[R.solid(shape)]});
 parts.push({name,kind:shape.kind}); return item;
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

// A single fixed camera: no bedplate, rails, cartridges, or moving geometry.
A.settle(R,P,{states:[0]});
R.items.sort((a,b)=>a.key-b.key);
if(args.includes('--audit')){
 A.auditOrExit(R,P,{frames:[0],apart:1});
 if(process.exitCode) throw new Error('Camera geometry audit failed.');
}
const geometry=R.items.map(it=>it.svg).join('');
const cameraStyles=`
.iso-fill{fill:#e8e5dc;stroke:none}
.iso-top{fill:#f8f6f0;stroke:none}
.iso-shade[data-shade="0"]{fill:#a7aaa1}
.iso-shade[data-shade="1"]{fill:#c2c4ba}
.iso-shade[data-shade="2"]{fill:#d5d6cc}
.iso-shade[data-shade="3"]{fill:#e5e5dc}
.iso-line{fill:none;stroke:#5d635b;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round}
.iso-line[data-tone="hi"]{stroke:#333e34;stroke-width:2}
.iso-line[data-tone="mid"]{stroke:#586153;stroke-width:1.5}
.iso-line[data-tone="faint"]{stroke:#b4b8ab;stroke-width:.8}
.iso-bevel{opacity:.6}.iso-crease{opacity:.7}
text{font-family:'Avenir Next','Trebuchet MS',sans-serif;fill:#26372c}
`;
const ease=x=>1-(1-x)**4;
function weights(t){
 const current=Math.floor(t)%7, phase=t-Math.floor(t), fade=phase<.84?0:ease((phase-.84)/.16);
 return LOOKS.map((_,i)=>i===current?1-fade:i===(current+1)%7?fade:0);
}
function figure(t=0,animated=false){
 const opacities=weights(t);
 const highlights=LOOKS.map((_,i)=>`<g class="highlight h${i}" opacity="${opacities[i].toFixed(4)}"><rect x="666" y="${130+i*61}" width="484" height="57" fill="#e2e9dc"/><rect x="666" y="${130+i*61}" width="4" height="57" fill="#426547"/></g>`).join('');
 const labels=LOOKS.map((name,i)=>`<text x="689" y="${168+i*61}" font-size="25" fill="#54634e">C${i+1}</text><text x="755" y="${168+i*61}" font-size="29" font-weight="500">${esc(name)}</text>`).join('');
 // Crossfade only the highlight. Names and camera stay fixed, including at the loop seam.
 const animation=animated?`@keyframes select{0%,12%{opacity:1}14.2857%,97.7143%{opacity:0}100%{opacity:1}}.highlight{animation:select 7s cubic-bezier(.25,1,.5,1) infinite}${LOOKS.map((_,i)=>`.h${i}{animation-delay:${i-7}s}`).join('')}@media(prefers-reduced-motion:reduce){.highlight{animation:none;opacity:0}.h0{opacity:1}}`:'';
 return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}" role="img" aria-labelledby="title desc"><title id="title">Seven proposed looks for your camera</title><desc id="desc">A stationary camera beside seven recipe names, C1 through C7. Each slot highlights in turn. A conceptual illustration of an offline plan.</desc><style>${cameraStyles}${animation}</style><rect width="1200" height="640" fill="#f5f3ed"/><text x="48" y="80" style="font-family:Georgia,serif" font-size="47" letter-spacing="-1.2">Seven looks. Your choice.</text><g transform="translate(30 145)">${geometry}</g>${highlights}${labels}</svg>`;
}
mkdirSync(OUT,{recursive:false});
const notice='<!-- Camera geometry: '+license.replaceAll('--','—')+' -->';
const still=notice+'\n'+figure(0);
writeFileSync(join(OUT,'workflow.svg'),still);
const html=`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'"><title>Dial In · Seven looks</title><style>body{margin:0;background:#f5f3ed;color:#26372c}main{max-width:900px;margin:auto}svg{display:block;width:100%;height:auto}p{margin:0;padding:12px 24px 24px;font:14px/1.5 system-ui,sans-serif}a{color:inherit}</style></head><body>${notice}<main>${figure(0,true)}<p>Seven proposed looks for an offline plan. No camera connection or upload is shown.</p></main></body></html>`;
writeFileSync(join(OUT,'anatomy.html'),html);
// Optional raster export uses an explicitly supplied local resvg module and local FFmpeg.
// It re-renders vector paths at 2x the README display size; there is no browser recording.
const renderer=arg('--renderer');
if(renderer){
 const {Resvg}=await import(pathToFileURL(resolve(renderer)));
 const render=svg=>new Resvg(svg,{font:{loadSystemFonts:true}}).render().asPng();
 writeFileSync(join(OUT,'workflow-poster.png'),render(figure(0)));
 const frames=join(OUT,'frames');mkdirSync(frames);
 for(let n=0;n<FPS*SECONDS;n++)writeFileSync(join(frames,`${String(n).padStart(4,'0')}.png`),render(figure(n/FPS)));
 execFileSync('ffmpeg',['-v','error','-framerate',String(FPS),'-i',join(frames,'%04d.png'),'-filter_complex','[0:v]split[a][b];[a]palettegen=stats_mode=diff:max_colors=128[p];[b][p]paletteuse=dither=none:diff_mode=rectangle','-loop','0',join(OUT,'workflow.gif')],{stdio:'inherit'});
 execFileSync('ffmpeg',['-v','error','-framerate',String(FPS),'-i',join(frames,'%04d.png'),'-c:v','libx264','-crf','17','-pix_fmt','yuv420p','-movflags','+faststart',join(OUT,'workflow.mp4')],{stdio:'inherit'});
}
console.log(JSON.stringify({out:resolve(OUT),width:WIDTH,height:HEIGHT,seconds:SECONDS,fps:FPS,parts:parts.length,camera_movement:false,hardware_operations:0,provider_calls:0}));
