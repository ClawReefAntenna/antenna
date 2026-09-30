#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {validateConfig} from './policy.mjs';
import {PROFILE} from './transport.mjs';
try{
 const [command,file,root]=process.argv.slice(2),read=p=>JSON.parse(fs.readFileSync(p,'utf8'));
 if(command==='sources'){
  const report=read(file),changed=Object.entries(report.sourceHashes).filter(([p,h])=>!fs.existsSync(p)||createHash('sha256').update(fs.readFileSync(p)).digest('hex')!==h).map(([p])=>p);
  console.log(JSON.stringify({unchanged:changed.length===0,changed}));if(changed.length)process.exitCode=1;
 }else if(command==='doctor'){
  const host=read(file),old=read(path.join(root,'antenna-config.json')),peers=read(path.join(root,'antenna-peers.json'));
  const c=validateConfig(host.plugins?.entries?.antenna?.config),self=Object.values(peers).filter(p=>p.self===true);
  if(self.length!==1)throw Error('ambiguous retained identity');
  const legacyBearer=fs.readFileSync(path.resolve(root,self[0].token_file),'utf8').trim(),problems=[];
  if(old.transport_profile!==PROFILE)problems.push('legacy send/writer controls not switched');
  if(!host.plugins?.entries?.antenna?.enabled||!host.plugins?.allow?.includes('antenna'))problems.push('plugin disabled or not allowlisted');
  if(host.hooks?.enabled!==false&&(typeof host.hooks?.token!=='string'||host.hooks.token===legacyBearer||host.hooks.token===c.bearer))problems.push('general-hook credential retirement not established');
  if(typeof host.gateway?.auth?.token!=='string'||[legacyBearer,c.bearer].includes(host.gateway.auth.token))problems.push('operator credential separation not established');
  const relay=old.relay_agent_id??'antenna';
  if(host.agents?.list?.some(a=>a.id===relay)||Object.hasOwn(host.agents?.entries??{},relay))problems.push('legacy relay agent still provisioned; review ownership before removal');
  if(host.hooks?.mappings?.some(m=>JSON.stringify(m).includes('antenna')))problems.push('possible old Antenna mapping remains; review manually');
  if(['smart','both'].includes(c.mcs)&&!c.scannerProfile?.validatedIdentity)problems.push('scanner selection not validated');
  console.log(JSON.stringify({staticChecksPassed:problems.length===0,liveIngressVerified:false,problems,required:'After explicit restart, verify plugin admission and denial of old hook/operator paths using the retired peer credential.'}));if(problems.length)process.exitCode=1;
 }else throw Error('sources REPORT | doctor HOST LEGACY_ROOT');
}catch(e){console.error(JSON.stringify({status:'blocked',reason:e.message}));process.exitCode=1;}
