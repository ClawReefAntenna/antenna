import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {snapshot,replaceJSON} from '../config-write.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-writes-')),file=path.join(root,'host.json');
const original='{ "unrelated": {"secret":"private-fixture"}, "plugins": {} }\n';
try{
 fs.writeFileSync(file,original,{mode:0o600});
 let before=snapshot(file);const next={...before.value,plugins:{entries:{antenna:{enabled:false}}}};
 const result=replaceJSON(before,next);
 assert.equal(fs.readFileSync(path.join(result.backup,'before.json'),'utf8'),original);
 assert.equal(fs.statSync(result.backup).mode&0o777,0o700);
 assert.equal(fs.statSync(path.join(result.backup,'before.json')).mode&0o777,0o600);
 assert.equal(fs.statSync(file).mode&0o777,0o600);
 assert.deepEqual(snapshot(file).value.unrelated,before.value.unrelated);
 assert.equal(replaceJSON(snapshot(file),next).saved,false);
 assert.throws(()=>replaceJSON(before,next),/changed/);
 before=snapshot(file);fs.mkdirSync(file+'.antenna-lock');assert.throws(()=>replaceJSON(before,{...next,a:1}),/EEXIST/);fs.rmdirSync(file+'.antenna-lock');
 fs.symlinkSync(file,path.join(root,'link'));assert.throws(()=>snapshot(path.join(root,'link')),/symlink/);
 fs.linkSync(file,path.join(root,'hard'));assert.throws(()=>snapshot(file),/owned regular/);fs.unlinkSync(path.join(root,'hard'));
 assert.throws(()=>replaceJSON(before,{...next,a:1},{validate:()=>{throw Error('invalid policy');}}),/invalid policy/);
 assert.equal(fs.readFileSync(file,'utf8'),before.raw);
 before=snapshot(file);
 const rename=fs.renameSync;
 try{fs.renameSync=()=>{throw Error('simulated disk failure');};assert.throws(()=>replaceJSON(before,{...next,a:1}),/disk failure/);}finally{fs.renameSync=rename;}
 assert.equal(fs.readFileSync(file,'utf8'),before.raw);assert(!fs.existsSync(file+'.antenna-lock'));assert(!fs.readdirSync(root).some(f=>f.endsWith('.tmp')));
 // An uncooperative editor changes the destination while the temporary output is
 // being written. The final comparison must refuse without overwriting that edit.
 const write=fs.writeFileSync;try{fs.writeFileSync=(...args)=>{const r=write(...args);if(typeof args[0]==='number')write(file,'{"external":true}\n');return r;};assert.throws(()=>replaceJSON(before,{...next,a:1}),/changed/);}finally{fs.writeFileSync=write;}
 assert.deepEqual(snapshot(file).value,{external:true});
 fs.writeFileSync(file,'{"$include":"elsewhere"}');assert.throws(()=>snapshot(file),/includes/);
 console.log('PASS private exact backup, no-op, unrelated preservation, stale edits, lock, link/include rejection, failure cleanup and late concurrent edit');
}finally{fs.rmSync(root,{recursive:true,force:true});}
