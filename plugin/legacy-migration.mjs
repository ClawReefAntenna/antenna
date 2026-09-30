#!/usr/bin/env node
// Offline preparation only. No live writers, credential rotation, or gateway calls.
import fs from 'node:fs';
import path from 'node:path';
import {createHash,createPublicKey} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {validateConfig} from './policy.mjs';
import {PROFILE,endpoint} from './transport.mjs';
const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const hash=p=>createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const need=(condition,message)=>{if(!condition)throw Error(message);};
export function prepare(root,hostFile,selection){
 root=path.resolve(root);const resolve=f=>path.resolve(root,f);
 const old=read(resolve('antenna-config.json')),peers=read(resolve('antenna-peers.json')),host=read(hostFile);
 need(!old.transport_profile,'already migrated or unknown transport');
 const self=Object.entries(peers).filter(([,p])=>p.self===true);need(self.length===1,'exactly one self identity required');
 need(old.session_policy_version===1&&old.session_policies&&typeof old.session_policies==='object','recognized session policy required');
 for(const k of ['allowed_inbound_peers','allowed_outbound_peers','allowed_inbound_sessions'])need(Array.isArray(old[k])&&old[k].every(v=>typeof v==='string'),'invalid '+k);
 need(['off','dumb','smart','both'].includes(selection.mcs),'explicit MCS choice required');
 need(selection.destinations&&typeof selection.destinations==='object','explicit destinations required');
 const targets=Object.values(selection.destinations);
 need(old.allowed_inbound_sessions.every(k=>targets.includes(k))&&targets.every(k=>old.allowed_inbound_sessions.includes(k)),'destination mapping must preserve the exact allowed target set');
 const policyMode=old.inbox_mode??(old.inbox_enabled?'on':'off');need(['off','on','allowlist'].includes(policyMode),'unsupported inbox policy');
 need(typeof old.inbox_enabled==='boolean'&&old.inbox_enabled===(policyMode!=='off'),'inconsistent legacy inbox mirrors');
 need(!old.inbox_auto_approve_peers||Array.isArray(old.inbox_auto_approve_peers),'invalid auto approval list');
 const tokenPath=resolve(self[0][1].token_file),st=fs.lstatSync(tokenPath);
 need(st.isFile()&&!(st.mode&0o077)&&st.size<=16384,'private local bearer file required');
 const bearer=fs.readFileSync(tokenPath,'utf8').trim();
 const c={schemaVersion:2,policyRevision:'four-modes-v2',receiver:self[0][0],bearer,peers:{},destinations:selection.destinations,mcs:selection.mcs,inbox:'off',maxBodyChars:old.max_message_length,inboxFile:selection.inboxFile,replayFile:selection.replayFile};
 if(selection.scannerModel)c.scannerModel=selection.scannerModel;
 const inputs=[resolve('antenna-config.json'),resolve('antenna-peers.json'),hostFile,tokenPath];
 for(const id of old.allowed_inbound_peers){
  const p=peers[id];need(p?.auth_mode==='ed25519-v1','legacy plaintext peer requires explicit re-pairing');
  const keyPath=resolve(p.signing_public_key_file),pem=fs.readFileSync(keyPath,'utf8');
  need(createPublicKey(pem).asymmetricKeyType==='ed25519','invalid peer signing pin');inputs.push(keyPath);
  const approvals={};
  for(const [alias,key] of Object.entries(c.destinations))approvals[alias]=policyMode==='allowlist'?old.session_policies[key]?.inbox===true:policyMode==='on'&&!(old.inbox_auto_approve_peers??[]).includes(id);
  c.peers[id]={publicKey:pem,destinations:Object.keys(c.destinations),approvalByDestination:approvals};
 }
 validateConfig(c);
 const queue=resolve(old.inbox_queue_path??'antenna-inbox.json');
 let pending=0;
 if(fs.existsSync(queue)){
  const rows=read(queue);need(Array.isArray(rows),'unknown legacy inbox schema');inputs.push(queue);
  need(rows.every(r=>r&&typeof r==='object'&&['pending','approved','delivered','denied','failed'].includes(r.status)),'unknown legacy inbox disposition');
  pending=rows.filter(r=>!['delivered','denied'].includes(r.status)).length;
 }
 for(const file of ['antenna-lists.json','antenna-public-groups.json'])if(fs.existsSync(resolve(file)))inputs.push(resolve(file));
 for(const f of [c.inboxFile,c.replayFile])need(!fs.existsSync(f),'new state paths must be absent; legacy state is never overwritten');
 const outbound=structuredClone(peers);
 // Retain already-configured plaintext transport; disclose it in the preview.
 for(const p of Object.values(outbound))if(typeof p.url==='string'&&p.url.startsWith('http://'))p.allow_http=true;
 for(const [id,p] of Object.entries(selection.outbound??{})){
  need(Object.hasOwn(outbound,id)&&old.allowed_outbound_peers.includes(id),'unknown or denied outbound peer');
  endpoint(outbound[id].url,outbound[id].allow_http===true);
  need(typeof p.default_target==='string'&&p.default_target.length>0,'receiver-approved destination required');
  need(p.profile===PROFILE,'unsupported target profile');
  outbound[id].transport_profile=PROFILE;outbound[id].default_target=p.default_target;
 }
 const stagedHost=structuredClone(host);stagedHost.plugins??={};stagedHost.plugins.entries??={};
 need(!stagedHost.plugins.entries.antenna?.enabled,'disable plugin before staging migration');
 stagedHost.plugins.entries.antenna={enabled:false,config:c};
 const blockers=['Stop Antenna ingress and all legacy writers before cutover.', 'Retire peer-known general-hook authority and coordinate every other hook consumer.', 'Verify selected runtime destinations exist; preparation is offline.', 'Install/load plugin, restart explicitly, and probe old hook denial before advertising migration.'];
 if(pending)blockers.push(`${pending} unresolved legacy inbox items: preserve file read-only; resolve explicitly or request a newly signed resend. No conversion, drain or automatic release.`);
 if(['smart','both'].includes(c.mcs))blockers.push('Select and validate a registered scanner model before activation.');
 const report={profile:PROFILE,compatibility:'documented manual migration',activation:false,receiver:c.receiver,peers:Object.keys(c.peers),destinations:c.destinations,legacyPending:pending,httpPeers:Object.entries(outbound).filter(([,p])=>p.allow_http===true).map(([id])=>id),unmigratedOutbound:old.allowed_outbound_peers.filter(id=>outbound[id]?.transport_profile!==PROFILE),blockers,sourceHashes:Object.fromEntries(inputs.map(p=>[path.resolve(p),hash(p)]))};
 return {report,host:stagedHost,config:{...old,transport_profile:PROFILE},peers:outbound};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{
  const [root,host,selectionFile,output]=process.argv.slice(2);const result=prepare(root,host,read(selectionFile));
  if(output){fs.mkdirSync(output,{mode:0o700});for(const [name,value] of Object.entries(result))fs.writeFileSync(path.join(output,name+'.json'),JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});}
  console.log(JSON.stringify(result.report));
 }catch(e){console.error(JSON.stringify({status:'blocked',reason:e.message}));process.exitCode=1;}
}
