import {LIMITS} from './limits.mjs';
import fs from 'node:fs';
import path from 'node:path';
import {profileIdentity} from './scanners.mjs';
export const modes=['off','dumb','smart','both'];
const modelModes=new Set(['smart','both']);
export function credentialFor(p) {
 const r=p?.credentialRef;
 if(!r)return undefined;
 let value;
 if(r.env&&/^[A-Z_][A-Z0-9_]*$/.test(r.env))value=process.env[r.env];
 else if(r.file&&path.isAbsolute(r.file)){
  const st=fs.lstatSync(r.file);
  if(!st.isFile()||(st.mode&0o077)||st.size>16384)throw Error('credential file must be private, regular and bounded');
  value=fs.readFileSync(r.file,'utf8').trim();
 }else throw Error('unsupported credential reference');
 if(!value||/[\r\n]/.test(value))throw Error('credential unavailable');
 return value;
}
function credentialIdentity(ref){
 if(!ref)return 'none';
 if(Object.keys(ref).length!==1)throw Error('one credential reference required');
 if(ref.env&&/^[A-Z_][A-Z0-9_]*$/.test(ref.env))return 'env:'+ref.env;
 if(ref.file&&path.isAbsolute(ref.file))return 'file:'+ref.file;
 throw Error('unsupported credential reference');
}
export function resolveProfile(input,host){
 const allowed=['baseUrl','model','locality','tokenParameter','jsonObject','maxInputBytes','strictSchema','reasoningEffort','credentialRef','credentialIdentity','validatedIdentity','configuredModel'];
 if(!input||Object.keys(input).some(k=>!allowed.includes(k)))throw Error('unknown profile field; use a credential reference, never an inline key');
 const p=structuredClone(input);
 if(p.strictSchema!==undefined&&typeof p.strictSchema!=='boolean')throw Error('invalid schema capability');
 if(p.reasoningEffort!==undefined&&!['none','minimal','low','medium','high','xhigh'].includes(p.reasoningEffort))throw Error('invalid reasoning effort');
 if(p.configuredModel){
  const aliases=[];
  for(const [id,value] of Object.entries(host.agents?.defaults?.models??{}))
   if(id===p.configuredModel||value.alias===p.configuredModel)aliases.push(id);
  const id=aliases.length===1?aliases[0]:p.configuredModel;
  if(aliases.length>1)throw Error('ambiguous model alias');
  const split=id.indexOf('/'),provider=host.models?.providers?.[id.slice(0,split)];
  const model=id.slice(split+1);
  if(split<1||!provider||provider.api!=='openai-completions'||!provider.models?.some(x=>x.id===model))
   throw Error('configured model requires an explicit OpenAI-compatible provider; native subscription auth is not an HTTP credential');
  p.baseUrl=provider.baseUrl;p.model=model;
  // Credentials are explicitly referenced, never copied out of runtime config.
 }
 p.credentialIdentity=credentialIdentity(p.credentialRef);
 const u=new URL(p.baseUrl);
 if(u.protocol!=='https:'&&!['127.0.0.1','localhost','[::1]'].includes(u.hostname))throw Error('remote scanner requires HTTPS');
 profileIdentity(p);
 return p;
}
export function readyProfile(p,host){
 try {
  const resolved=resolveProfile(p,host);
  if(profileIdentity(resolved)!==p.validatedIdentity)return {...resolved,validatedIdentity:undefined};
  return resolved;
 }catch{return {...p,validatedIdentity:undefined};}
}
export function validateConfig(input,{requireReady=false,host={}}={}){
 const c=structuredClone(input);
 if(c.schemaVersion!==2)throw Error('explicit schema migration required');
 c.mcs??='dumb';c.inbox??='on';c.maxBodyChars??=65536;
 c.maxActiveSmart??=LIMITS.active;
 if(!Number.isInteger(c.maxActiveSmart)||c.maxActiveSmart<1||c.maxActiveSmart>LIMITS.active)throw Error('maxActiveSmart must be 1 or 2');
 if(!modes.includes(c.mcs)||!['on','off'].includes(c.inbox))throw Error('invalid mode');
 if(typeof c.receiver!=='string'||!c.receiver||typeof c.bearer!=='string'||c.bearer.length<32)throw Error('receiver and private bearer required');
 if(!c.peers||Array.isArray(c.peers)||!c.destinations||Array.isArray(c.destinations))throw Error('invalid peer/destination map');
 for(const peer of Object.values(c.peers)){
  if(!['default',...modes].includes(peer.mcs??'default')||!Array.isArray(peer.destinations)||typeof peer.publicKey!=='string')throw Error('invalid peer policy');
 }
 for(const target of Object.values(c.destinations))if(typeof target!=='string'||!target.startsWith('agent:'))throw Error('invalid destination');
 for(const f of ['inboxFile','replayFile'])if(typeof c[f]!=='string'||!path.isAbsolute(c[f]))throw Error('absolute state paths required');
 if(c.inboxFile===c.replayFile)throw Error('state paths must differ');
 if(!Number.isInteger(c.maxBodyChars)||c.maxBodyChars<1||c.maxBodyChars>1000000)throw Error('invalid body bound');
 if(requireReady&&[c.mcs,...Object.values(c.peers).map(p=>p.mcs)].some(m=>modelModes.has(m))){
  if(!c.scannerProfile||!readyProfile(c.scannerProfile,host).validatedIdentity)throw Error('validate scanner selection before enabling Smart/Both');
  credentialFor(c.scannerProfile);
 }
 return c;
}
export function migrate(input){
 if(input.schemaVersion===2)return validateConfig(input);
 if(input.schemaVersion!==1||input.policyRevision!=='combined-smart-v1')throw Error('unknown legacy schema; manual migration required');
 const c=structuredClone(input);
 if(c.mcs==='smart')c.mcs='both';
 for(const p of Object.values(c.peers??{}))if(p.mcs==='smart')p.mcs='both';
 c.schemaVersion=2;c.policyRevision='four-modes-v2';
 return validateConfig(c);
}
