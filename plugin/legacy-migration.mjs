#!/usr/bin/env node
// Offline preparation only. No live writers, credential rotation, or gateway calls.
import {fileSnapshot,unchanged} from './config-write.mjs';
import {hooksWarning} from './migration-warning.mjs';
import fs from 'node:fs';
import path from 'node:path';
import {createHash,createPublicKey} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {validateConfig} from './policy.mjs';
import {PROFILE,endpoint} from './transport.mjs';
const read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
const need=(condition,message)=>{if(!condition)throw Error(message);};
// Relay releases before session-policy-v1 use one global inbox switch and a
// trusted-peer list. Normalize only in memory; do not rewrite legacy evidence.
function legacyApprovalPolicy(config){
 const hasVersion=Object.hasOwn(config,'session_policy_version');
 const hasPolicies=Object.hasOwn(config,'session_policies');
 const flat=!hasVersion&&!hasPolicies;
 if(!flat)need(hasVersion&&hasPolicies&&config.session_policy_version===1&&
   config.session_policies&&typeof config.session_policies==='object'&&
   !Array.isArray(config.session_policies),'recognized session policy required');
 need(typeof config.inbox_enabled==='boolean','invalid legacy inbox switch');
 const mode=Object.hasOwn(config,'inbox_mode')?config.inbox_mode:(config.inbox_enabled?'on':'off');
 need((flat?['on','off']:['on','off','allowlist']).includes(mode),'unsupported legacy inbox policy');
 need(config.inbox_enabled===(mode!=='off'),'inconsistent legacy inbox mirrors');
 const trusted=config.inbox_auto_approve_peers??[];
 need(Array.isArray(trusted)&&trusted.every(id=>typeof id==='string'),'invalid auto approval list');
 const sessions=flat?{}:config.session_policies;
 for(const entry of Object.values(sessions))need(entry&&typeof entry==='object'&&
   !Array.isArray(entry)&&(!Object.hasOwn(entry,'inbox')||typeof entry.inbox==='boolean'),'invalid legacy session approval');
 return {mode,trusted,sessions,format:flat?'legacy-global-inbox':'session-policy-v1'};
}

export function prepare(root,hostFile,selection){
 root=path.resolve(root);const resolve=f=>path.resolve(root,f),captured=new Map();
 const capture=f=>{f=path.resolve(f);if(!captured.has(f))captured.set(f,fileSnapshot(f));return captured.get(f);};
 const read=f=>JSON.parse(capture(f).raw);

 const old=read(resolve('antenna-config.json')),peers=read(resolve('antenna-peers.json')),host=read(hostFile);
 need(!old.transport_profile,'already migrated or unknown transport');
 const self=Object.entries(peers).filter(([,p])=>p.self===true);need(self.length===1,'exactly one self identity required');
 const approval=legacyApprovalPolicy(old),omittedUnsignedSelf=[];
 for(const k of ['allowed_inbound_peers','allowed_outbound_peers','allowed_inbound_sessions'])need(Array.isArray(old[k])&&old[k].every(v=>typeof v==='string'),'invalid '+k);
 need(['off','dumb','smart','both'].includes(selection.mcs),'explicit MCS choice required');
 need(selection.destinations&&typeof selection.destinations==='object','explicit destinations required');
 const targets=Object.values(selection.destinations);
 need(old.allowed_inbound_sessions.every(k=>targets.includes(k))&&targets.every(k=>old.allowed_inbound_sessions.includes(k)),'destination mapping must preserve the exact allowed target set');
 const tokenPath=resolve(self[0][1].token_file),token=capture(tokenPath);
 need(!(token.mode&0o077)&&Buffer.byteLength(token.raw)<=16384,'private local bearer file required');
 const bearer=token.raw.trim();
 const c={schemaVersion:2,policyRevision:'four-modes-v2',receiver:self[0][0],bearer,peers:{},destinations:selection.destinations,mcs:selection.mcs,inbox:'off',maxBodyChars:old.max_message_length,inboxFile:selection.inboxFile,replayFile:selection.replayFile};
 if(selection.scannerModel)c.scannerModel=selection.scannerModel;
 const inputs=[resolve('antenna-config.json'),resolve('antenna-peers.json'),hostFile,tokenPath];
 for(const id of old.allowed_inbound_peers){
  const p=peers[id];
  // The setup-created self entry carries local identity, not a remote signing
  // pin. Keep it in contacts; explicitly report the omitted native self grant.
  // Partially configured/signed self entries must pass the ordinary validation.
  if(id===self[0][0]&&['auth_mode','signing_public_key_file','signing_private_key_file'].every(k=>!Object.hasOwn(p,k))){
   omittedUnsignedSelf.push(id);continue;
  }
  need(p?.auth_mode==='ed25519-v1','legacy plaintext peer requires explicit re-pairing');
  const keyPath=resolve(p.signing_public_key_file),pem=capture(keyPath).raw;
  need(createPublicKey(pem).asymmetricKeyType==='ed25519','invalid peer signing pin');inputs.push(keyPath);
  const approvals={};
  for(const [alias,key] of Object.entries(c.destinations))approvals[alias]=approval.mode==='allowlist'?approval.sessions[key]?.inbox===true:approval.mode==='on'&&!approval.trusted.includes(id);
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
 for(const f of [c.inboxFile,c.replayFile]){
  need(path.resolve(f)===f,'new state paths must be normalized');
  let exists=false;try{fs.lstatSync(f);exists=true;}catch(e){if(e.code!=='ENOENT')throw e;}
  need(!exists,'new state paths must be absent; legacy state is never overwritten');
  let parent=path.dirname(f);while(!fs.existsSync(parent))parent=path.dirname(parent);
  need(fs.realpathSync(parent)===parent,'new state parent must not be symlinked');
 }
 const outbound=structuredClone(peers);
 // Retain already-configured plaintext transport; disclose it in the preview.
 for(const p of Object.values(outbound))if(typeof p.url==='string'&&p.url.startsWith('http://'))p.allow_http=true;
 for(const [id,p] of Object.entries(selection.outbound??{})){
  need(Object.hasOwn(outbound,id)&&old.allowed_outbound_peers.includes(id),'unknown or denied outbound peer');
  need(!omittedUnsignedSelf.includes(id),'unsigned self-peer requires signing setup before native outbound selection');
  endpoint(outbound[id].url,outbound[id].allow_http===true);
  need(typeof p.default_target==='string'&&p.default_target.length>0,'receiver-approved destination required');
  need(p.profile===PROFILE,'unsupported target profile');
  outbound[id].transport_profile=PROFILE;outbound[id].default_target=p.default_target;
 }
 for(const f of inputs)capture(f);
 for(const f of [c.inboxFile,c.replayFile])need(!inputs.some(p=>path.resolve(p)===path.resolve(f)),'state path overlaps migration input');
 need(!Object.hasOwn(host,'$include'),'resolved host JSON required');
 const stagedHost=structuredClone(host);stagedHost.plugins??={};stagedHost.plugins.entries??={};
 need(!stagedHost.plugins.entries.antenna?.enabled,'disable plugin before staging migration');
 need(!stagedHost.plugins.entries.antenna?.config,'existing native policy requires schema export, not legacy overwrite');
 stagedHost.plugins.entries.antenna={...(stagedHost.plugins.entries.antenna??{}),enabled:false,config:c};
 const blockers=['Stop Antenna ingress and all legacy writers before cutover.', 'Verify selected runtime destinations exist; preparation is offline.', 'Install/load plugin, restart explicitly, and verify signed admission and operator separation before advertising migration.'];
 if(pending)blockers.push(`${pending} unresolved legacy inbox items: preserve file read-only; resolve explicitly or request a newly signed resend. No conversion, drain or automatic release.`);
 if(['smart','both'].includes(c.mcs))blockers.push('Select and validate a registered scanner model before activation.');
 const report={policyConversion:approval.format,omittedUnsignedSelf,warnings:[hooksWarning,...omittedUnsignedSelf.map(id=>`Unsigned self-peer ${id} retained in contacts without native inbound access; configure signed self-messaging separately if needed.`)],profile:PROFILE,compatibility:'documented manual migration',activation:false,receiver:c.receiver,peers:Object.keys(c.peers),destinations:c.destinations,legacyPending:pending,httpPeers:Object.entries(outbound).filter(([,p])=>p.allow_http===true).map(([id])=>id),unmigratedOutbound:old.allowed_outbound_peers.filter(id=>outbound[id]?.transport_profile!==PROFILE),blockers,sourceHashes:Object.fromEntries([...captured].map(([p,s])=>[p,createHash('sha256').update(s.raw).digest('hex')]))};
 for(const s of captured.values())unchanged(s);
 return {report,host:stagedHost,config:{...old,transport_profile:PROFILE},peers:outbound};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{
  const [root,host,selectionFile,output]=process.argv.slice(2);const result=prepare(root,host,read(selectionFile));
  if(output){
  fs.mkdirSync(output,{mode:0o700});
  try{for(const [name,value] of Object.entries(result))fs.writeFileSync(path.join(output,name+'.json'),JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});}
  catch(e){for(const f of fs.readdirSync(output))fs.unlinkSync(path.join(output,f));fs.rmdirSync(output);throw e;}
 }
  console.log(JSON.stringify(result.report));
 }catch(e){console.error(JSON.stringify({status:'blocked',reason:e instanceof SyntaxError?'invalid JSON input':e.message}));process.exitCode=1;}
}
