// Removal only. Never registers agents, starts services or restores relay policy.
import fs from 'node:fs';
import path from 'node:path';
export function retire(host,old,root,approvals){
 const next=structuredClone(host),id=old.relay_agent_id??'antenna',changes=[];
 const owned=a=>a&&typeof a.workspace==='string'&&path.resolve(a.workspace)===path.resolve(root,'agent');
 const agents=[...(next.agents?.list??[]).filter(a=>a.id===id),...(Object.hasOwn(next.agents?.entries??{},id)?[next.agents.entries[id]]:[])];
 if(agents.some(a=>!owned(a)))throw Error('relay ownership is ambiguous; review its workspace before retirement');
 if(agents.length){
  if(next.agents.list)next.agents.list=next.agents.list.filter(a=>a.id!==id);
  if(next.agents.entries)delete next.agents.entries[id];
  changes.push('retire attributed relay agent');
 }
 // Broad hook/session visibility and shared credentials cannot be attributed
 // exclusively to Antenna. Keep them; remove only the retired agent allow entry.
 if(next.hooks?.allowedAgentIds&&agents.length)next.hooks.allowedAgentIds=next.hooks.allowedAgentIds.filter(x=>x!==id);
 if(next.hooks?.mappings?.some(m=>m.agentId===id))throw Error('relay hook mapping requires manual ownership review before staging');
 const grants=approvals?structuredClone(approvals):undefined;
 if(grants&&(grants.version!==1||!grants.agents||Array.isArray(grants.agents)))throw Error('unknown approvals schema; review manually');
 if(grants?.agents?.[id]?.allowlist&&!Array.isArray(grants.agents[id].allowlist))throw Error('invalid relay allowlist');
 if(grants?.agents?.[id]?.allowlist?.length){
  if(!agents.length)throw Error('cannot attribute relay shell approvals without its owned agent');
  const known=new Set(['/usr/bin/bash','/usr/bin/echo','/usr/bin/jq','/usr/bin/cat','/bin/bash','/bin/echo','/bin/jq','/bin/cat']);
  const list=grants.agents[id].allowlist;
  grants.agents[id].allowlist=list.filter(e=>!known.has(e.pattern));
  changes.push(`retire ${list.length-grants.agents[id].allowlist.length} known relay shell approvals`);
 }
 return {host:next,approvals:grants,changes};
}
export function requireStopped(){
 if(process.platform!=='linux')throw Error('cutover stop check requires Linux /proc; use documented manual cutover elsewhere');
 for(const name of fs.readdirSync('/proc')){
  if(!/^\d+$/.test(name)||Number(name)===process.pid)continue;
  let args;try{
   if(fs.statSync('/proc/'+name).uid!==process.getuid())continue;
   args=fs.readFileSync('/proc/'+name+'/cmdline','utf8').split('\0').filter(Boolean);
  }catch(e){if(e.code==='ENOENT'||e.code==='ESRCH')continue;throw Error('cannot verify stopped writers');}
  if(args.some(a=>path.basename(a)==='openclaw-gateway')||
     (args.some(a=>/^(openclaw|openclaw\.mjs|entry\.js)$/.test(path.basename(a)))&&args.includes('gateway'))||
     args.some(a=>/^antenna-(relay(?:-exec|-deliver)?|inbox|setup|upgrade)\.sh$/.test(path.basename(a)))||
     args.some(a=>/\/plugin\/(?:cli|pairing|legacy-migration)\.mjs$/.test(a)))throw Error('stop gateway and Antenna writers before cutover; interruption is required');
 }
}
