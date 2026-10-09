#!/usr/bin/env node
// Explicit stopped-host cutover. Partial failure stays unavailable; no automatic
// rollback, service restart, old inbox conversion, credential rotation or grant.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {prepare} from '../plugin/legacy-migration.mjs';
import {fileSnapshot,snapshot,unchanged,replaceJSON} from '../plugin/config-write.mjs';
import {retire,requireStopped} from './retire.mjs';
const hash=raw=>createHash('sha256').update(raw).digest('hex');
const exists=file=>{try{fs.lstatSync(file);return true;}catch(e){if(e.code==='ENOENT')return false;throw e;}};
const encode=value=>JSON.stringify(value,null,2)+'\n';
const put=(file,raw)=>{const fd=fs.openSync(file,'wx',0o600);try{fs.writeFileSync(fd,raw);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}};
export function stage(root,hostFile,selectionFile,output,approvalsFile){
 root=fs.realpathSync(root);hostFile=path.resolve(hostFile);
 const selection=snapshot(selectionFile),host=snapshot(hostFile),config=snapshot(path.join(root,'antenna-config.json')),peers=snapshot(path.join(root,'antenna-peers.json'));
 const defaultApprovals=path.join(path.dirname(hostFile),'exec-approvals.json');
 approvalsFile??=exists(defaultApprovals)?defaultApprovals:undefined;
 const approvals=approvalsFile?snapshot(approvalsFile):null;
 const result=prepare(root,hostFile,selection.value),retired=retire(result.host,config.value,root,approvals?.value);
 result.host=retired.host;
 // Never guess whether a filename is obsolete. Explicitly selected raw-message
 // leftovers are only removed after stopping writers; inbox/recovery never match.
 const cleanup=(selection.value.obsoleteTemps??[]).map(item=>{
  if(item.obsolete!==true||typeof item.path!=='string')throw Error('temporary cleanup requires explicit obsolete attribution');
  const f=fileSnapshot(item.path),base=path.basename(f.file);
  const known=/^antenna-(relay-msg|envelope|body|canonical|pinned-key)\.[A-Za-z0-9]{6}$/.test(base)||
    (path.dirname(f.file)==='/tmp/antenna-relay'&&/^msg-[A-Za-z0-9_-]+\.txt$/.test(base));
  if(!known||!f.file.startsWith('/tmp/')||(f.mode&0o077)||hash(f.raw)!==item.sha256)throw Error('temporary file is not a confirmed private obsolete relay input');
  if(Object.hasOwn(result.report.sourceHashes,f.file))throw Error('cleanup overlaps retained migration source');
  return f;
 });
 const targets=[{before:host,after:result.host},{before:config,after:result.config},{before:peers,after:result.peers}];
 if(approvals)targets.push({before:approvals,after:retired.approvals});
 if(new Set([...targets.map(x=>x.before.file),...cleanup.map(x=>x.file)]).size!==targets.length+cleanup.length)throw Error('overlapping migration paths');
 for(const s of [selection,...targets.map(x=>x.before),...cleanup])unchanged(s);
 const sourceHashes={...result.report.sourceHashes,[selection.file]:hash(selection.raw)};
 if(approvals)sourceHashes[approvals.file]=hash(approvals.raw);
 const report={...result.report,retirement:retired.changes,temporaryFiles:cleanup.length,sourceHashes};
 if(!output)return {...report,dryRun:true};
 output=path.resolve(output);fs.mkdirSync(output,{mode:0o700});
 try{
  const plan={schema:1,root,report,absentSources:approvals?[]:[defaultApprovals],newState:[result.host.plugins.entries.antenna.config.inboxFile,result.host.plugins.entries.antenna.config.replayFile],targets:[],cleanup:[]};
  targets.forEach(({before,after},i)=>{
   const raw=encode(after);put(path.join(output,`before-${i}.json`),before.raw);put(path.join(output,`after-${i}.json`),raw);
   plan.targets.push({file:before.file,before:hash(before.raw),after:hash(raw),index:i});
  });
  cleanup.forEach((s,i)=>{put(path.join(output,`temp-${i}.txt`),s.raw);plan.cleanup.push({file:s.file,hash:hash(s.raw),index:i});});
  put(path.join(output,'plan.json'),encode(plan));
  put(path.join(output,'RECOVERY.txt'),'Keep gateway and writers stopped after any interruption. before-*.json are private recovery copies, NOT a command to restore the retired relay. Rerun apply with this exact stage to finish only unchanged/planned files. Native inbox/replay and legacy holds are never converted or deleted. To abandon cutover keep Antenna disabled and recover unrelated settings manually; do not restore the old agent or shell grants.\n');
  const dir=fs.openSync(output,'r');try{fs.fsyncSync(dir);}finally{fs.closeSync(dir);}
  return {...report,staged:output,dryRun:false,activation:false};
 }catch(e){
  // Only files made in this new staging directory; originals are untouched.
  for(const f of fs.readdirSync(output))fs.unlinkSync(path.join(output,f));fs.rmdirSync(output);throw e;
 }
}
export function apply(output){
 requireStopped();output=path.resolve(output);
 if(fs.realpathSync(output)!==output||(fs.statSync(output).mode&0o077))throw Error('private unlinked staging directory required');
 const plan=snapshot(path.join(output,'plan.json')).value;
 if(plan.schema!==1||!Array.isArray(plan.targets)||!Array.isArray(plan.cleanup))throw Error('invalid cutover plan');
 if(plan.absentSources.some(f=>exists(f)))throw Error('new approvals appeared; stage again');
 if(!Array.isArray(plan.newState)||plan.newState.some(f=>exists(f)))throw Error('new native state appeared; preserve it and review cutover');
 const known=new Set(plan.targets.map(x=>x.file));
 // Check all payloads and sources before the first write; an interrupted apply
 // can resume only while every target is exactly its original or planned bytes.
 const targets=plan.targets.map(t=>{
  const before=fileSnapshot(path.join(output,`before-${t.index}.json`)),after=snapshot(path.join(output,`after-${t.index}.json`)),current=snapshot(t.file);
  if(hash(before.raw)!==t.before||hash(after.raw)!==t.after||![t.before,t.after].includes(hash(current.raw)))throw Error('cutover target or recovery bytes changed');
  return {t,current,after};
 });
 for(const [file,h] of Object.entries(plan.report.sourceHashes))if(!known.has(file)&&hash(fileSnapshot(file).raw)!==h)throw Error('migration source changed; stage again');
 for(const t of plan.cleanup){
  if(hash(fileSnapshot(path.join(output,`temp-${t.index}.txt`)).raw)!==t.hash)throw Error('temporary recovery copy changed');
  if(exists(t.file)&&hash(fileSnapshot(t.file).raw)!==t.hash)throw Error('temporary input changed; preserve it');
 }
 for(const {t,current,after} of targets){requireStopped();unchanged(current);if(hash(current.raw)!==t.after)replaceJSON(current,after.value);}
 // Only after relay unprovisioning and transport switch, with writers stopped.
 for(const t of plan.cleanup){requireStopped();if(exists(t.file)){
  const current=fileSnapshot(t.file);if(hash(current.raw)!==t.hash)throw Error('temporary input changed');unchanged(current);fs.unlinkSync(t.file);
 }}
 return {applied:true,activation:false,restartRequired:true,legacyInbox:'preserved',recovery:output};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))try{
 const [command,...args]=process.argv.slice(2);
 if(command==='stage')console.log(JSON.stringify(stage(...args)));
 else if(command==='apply'&&args[1]==='--writers-stopped')console.log(JSON.stringify(apply(args[0])));
 else throw Error('stage ROOT HOST SELECTION [NEW_STAGE [APPROVALS_JSON]] | apply STAGE --writers-stopped (stop gateway and all writers first; no restart performed)');
}catch(e){console.error(JSON.stringify({status:'blocked',reason:e instanceof SyntaxError?'invalid JSON input':e.message}));process.exitCode=1;}
