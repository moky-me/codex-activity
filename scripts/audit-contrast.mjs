// Dev-only audit: use the official apca-w3 0.1.9 module; no app runtime dependency.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
if (!process.argv[2]) {
  throw Error('Pass the path to apca-w3/src/apca-w3.js as the first argument');
}
const {calcAPCA,fontLookupAPCA}=await import(pathToFileURL(path.resolve(process.argv[2])).href);
const source=fs.readFileSync('Sources/ActivityPanelStyle/PanelStyle.swift','utf8');
const pair=(match)=>{if(!match)throw Error('Missing palette token');return [match[1],match[2]].map(x=>'#'+x);};
const token=(name)=>pair(source.match(new RegExp('static func '+name+'\\([^}]+?color\\(0x([0-9a-f]{6}),0x([0-9a-f]{6})')));
const statusOffset=source.indexOf('static func statusText');
const stateColor=(section,name)=>pair(section.match(new RegExp('case \\.'+name+': return color\\(0x([0-9a-f]{6}),0x([0-9a-f]{6})')));
const status=(name)=>stateColor(source.slice(statusOffset),name);
const backgrounds=['panel','card','cardHover'].map(token);
const states=[['Running','running'],['Ready','completed'],['Attention','needsInput'],['Error','failed']];
const targets=[
  ['Primary text',token('ink'),90,4.5],
  ['Secondary / paused / unknown text',token('muted'),75,4.5],
  ['Project name',token('project'),null,4.5],
  ...states.map(([label,name])=>[label+' text',status(name),75,4.5]),
  ['Tokens at rest',token('tokenTotal'),null,4.5,['card','cardHover'].map(token)],
  ['Tokens on hover',token('project'),null,4.5,[token('controlHover')]],
  ['Observation while period menu is open',token('ink'),null,4.5,[token('controlPressed')]],
];
function luminance(hex) {
  const weights=[0.2126,0.7152,0.0722];
  return weights.reduce((sum,weight,i)=>{
    const srgb=parseInt(hex.slice(1+2*i,3+2*i),16)/255;
    const linear=srgb<=0.04045 ? srgb/12.92 : ((srgb+0.055)/1.055)**2.4;
    return sum+linear*weight;
  },0);
}
function wcag(a,b) {
  const [lo,hi]=[luminance(a),luminance(b)].sort((x,y)=>x-y);
  return (hi+0.05)/(lo+0.05);
}
let report='# Contrast audit\n\nPalette from [OpenAI Apps SDK UI primitives](https://github.com/openai/apps-sdk-ui/blob/0f00143c7a639906f1621fe58e1b6be7b5bea46d/src/styles/variables-primitive.css). Official apca-w3 0.1.9 (0.0.98G-4g) and WCAG 2.2 contrast ratios for opaque sRGB colors. Covers the panel, normal cards, and hover. Native menus and alerts retain macOS styling and are outside this numeric audit. Decorative separators and outlines are outside the text and icon measurements.\n\n| Role | Light color | Min light Lc | Dark color | Min dark Lc | Target Lc | Min WCAG light | Min WCAG dark |\n|---|---|---:|---|---:|---:|---:|---:|\n';
let failed = false;
for(const [name,colors,target,ratioTarget,surfaces=backgrounds] of targets){
 const min=[0,1].map(i=>Math.min(...surfaces.map(bg=>Math.abs(calcAPCA(colors[i],bg[i])))));
 const ratios=[0,1].map(i=>Math.min(...surfaces.map(bg=>wcag(colors[i],bg[i]))));
 if((target !== null && min.some(x=>x<target)) || ratios.some(x=>x<ratioTarget)) {
   failed = true;
   console.error(`${name} below target: APCA ${min}; WCAG ${ratios}`);
 }
 report+=`| ${name} | ${colors[0]} | ${min[0].toFixed(1)} | ${colors[1]} | ${min[1].toFixed(1)} | ${target ?? "—"} | ${ratios[0].toFixed(2)}:1 | ${ratios[1].toFixed(2)}:1 |\n`;
}
report+='\nValues are absolute Lc magnitudes (dark mode is reverse polarity). Primary text target >=90; secondary/status text >=75. Project names and token controls use the WCAG AA text threshold of 4.5:1. General text rows cover panel, card and cardHover. Token rows use their actual resting or hover surfaces. Observation is measured on the pressed period surface. Decorative status stripes are excluded. These are palette targets, not blanket accessibility certification. Existing compact typography is retained. Retina backing pixels are not CSS font-size pixels; no automatic point-to-CSS conversion or SF font equivalence is assumed.\n\nReference font lookup, minimum CSS px (not a certification of the native SF rendering):\n\n| Lc | Weight 300 | Weight 400 | Weight 700 |\n|---|---:|---:|---:|\n';
for(const lc of [75,90]){const a=fontLookupAPCA(lc);report+=`| ${lc} | ${a[3]} | ${a[4]} | ${a[7]} |\n`;}
report+='\n[Official implementation and font lookup](https://github.com/Myndex/apca-w3#readme). [Readability guidance](https://git.apcacontrast.com/documentation/APCA_in_a_Nutshell).\n\nBoth themes use neutral card surfaces. Status is expressed through text and a short stripe at the right edge. Native menus, VoiceOver require separate checks.\n';
report+=failed ? '\nSome measured pairs are below their targets. See stderr and the role table.\n' : '\nAll measured pairs meet their stated targets.\n';
fs.writeFileSync(process.argv[3]??'docs/contrast-audit.md',report);
console.log(report.split('\n').slice(4,17).join('\n'));
if (failed) process.exitCode = 1;
