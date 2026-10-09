import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash,generateKeyPairSync} from 'node:crypto';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {prepare} from '../plugin/legacy-migration.mjs';
import {policyFor} from '../plugin/inbox.mjs';
import {stage,apply} from './cutover.mjs';
import {retire,requireStopped} from './retire.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-cutover-'));
const temp=path.join('/tmp','antenna-relay-msg.'+path.basename(root).slice(-6));
const write=(name,value)=>fs.writeFileSync(path.join(root,name),typeof value==='string'?value:JSON.stringify(value),{mode:0o600});
const read=name=>JSON.parse(fs.readFileSync(path.join(root,name),'utf8'));
const hash=raw=>createHash('sha256').update(raw).digest('hex');
const hostFile=path.join(root,'host.json'),selFile=path.join(root,'selection.json'),grantsFile=path.join(root,'approvals.json');
const key=generateKeyPairSync('ed25519').publicKey.export({type:'spki',format:'pem'});
const old={relay_agent_id:'antenna',session_policy_version:1,session_policies:{'agent:owner:main':{inbox:true},'agent:owner:other':{inbox:false}},allowed_inbound_peers:['trusted','ordinary'],allowed_outbound_peers:['trusted','ordinary'],allowed_inbound_sessions:['agent:owner:main','agent:owner:other'],inbox_mode:'on',inbox_enabled:true,inbox_auto_approve_peers:['trusted'],max_message_length:10000};
const host={gateway:{auth:{token:'operator-fixture'}},hooks:{enabled:true,token:'preserve-hooks',allowedAgentIds:['antenna','other'],allowedSessionKeyPrefixes:['hook:','agent:owner:'],mappings:[{id:'other',agentId:'other'}]},tools:{sessions:{visibility:'all'}},agents:{list:[{id:'antenna',workspace:path.join(root,'agent'),sandbox:{mode:'off'}},{id:'other',workspace:'/unrelated'}]},plugins:{entries:{other:{enabled:true}}}};
const peers={self:{self:true,auth_mode:'ed25519-v1',token_file:'token'},trusted:{auth_mode:'ed25519-v1',signing_public_key_file:'pin',url:'http://trusted.test'},ordinary:{auth_mode:'ed25519-v1',signing_public_key_file:'pin',url:'https://ordinary.test'}};
const selection={mcs:'off',destinations:{work:'agent:owner:main',other:'agent:owner:other'},inboxFile:path.join(root,'native-inbox'),replayFile:path.join(root,'native-replay'),outbound:{trusted:{profile:'antenna-plugin-v2',default_target:'work'}}};
try{
 write('token','private-fixture-'.repeat(4));write('pin',key);write('host.json',host);write('antenna-peers.json',peers);
 write('antenna-inbox.json',[{status:'pending',body:'hold'},{status:'approved',body:'unsent'},{status:'failed',body:'uncertain'},{status:'delivered'},{status:'denied'}]);
 write('antenna-lists.json',{staff:[{peer:'trusted'}]});write('antenna-public-groups.json',{retain:true});
 let combinations=0;
 for(const mode of ['off','on','allowlist'])for(const trusted of [false,true])for(const inbox of [false,true]){
  const cfg=structuredClone(old);cfg.inbox_mode=mode;cfg.inbox_enabled=mode!=='off';cfg.inbox_auto_approve_peers=trusted?['trusted']:[];cfg.session_policies['agent:owner:main'].inbox=inbox;write('antenna-config.json',cfg);
  const r=prepare(root,hostFile,selection),c=r.host.plugins.entries.antenna.config;
  for(const peer of ['trusted','ordinary'])for(const destination of ['work','other']){
   const expected=mode==='allowlist'?(destination==='work'&&inbox):mode==='on'&&!(peer==='trusted'&&trusted);
   assert.equal(policyFor(c,c.peers[peer],destination).approval,expected);combinations++;
  }
  assert.equal(r.peers.trusted.url,peers.trusted.url);assert.equal(r.peers.trusted.allow_http,true);assert.equal(r.peers.ordinary.url,peers.ordinary.url);assert.equal(r.report.legacyPending,3);
 }
 console.log(`PASS ${combinations} relay permission combinations; exact HTTP/HTTPS URLs; unresolved holds`);
 write('antenna-config.json',{...old,session_policies:{'agent:owner:main':{inbox:'false'}}});assert.throws(()=>prepare(root,hostFile,selection),/approval/);
 write('antenna-config.json',old);write('selection.json',selection);
 write('approvals.json',{version:1,agents:{antenna:{allowlist:[{pattern:'/usr/bin/bash'},{pattern:'/usr/bin/jq'},{pattern:'/custom/keep'}]},other:{allowlist:[{pattern:'/usr/bin/bash'}]}},socket:{path:'keep'}});
 const frozen={};for(const f of fs.readdirSync(root))frozen[f]=fs.readFileSync(path.join(root,f),'utf8');
 assert.equal(stage(root,hostFile,selFile).dryRun,true);for(const [f,raw] of Object.entries(frozen))assert.equal(fs.readFileSync(path.join(root,f),'utf8'),raw);
 assert.throws(()=>retire({...host,agents:{list:[{id:'antenna',workspace:'/somebody-else'}]}},old,root),/ownership/);
 assert.throws(()=>retire({...host,hooks:{mappings:[{agentId:'antenna'}]}},old,root),/mapping/);
 fs.writeFileSync(temp,'obsolete envelope',{flag:'wx',mode:0o600});selection.obsoleteTemps=[{path:temp,obsolete:true,sha256:hash('obsolete envelope')}];write('selection.json',selection);
 const failedStage=path.join(root,'failed-stage'),open=fs.openSync;
 try{fs.openSync=(file,...args)=>{if(typeof file==='string'&&file===path.join(failedStage,'after-1.json'))throw Error('staging disk failure');return open(file,...args);};assert.throws(()=>stage(root,hostFile,selFile,failedStage,grantsFile),/staging disk failure/);}finally{fs.openSync=open;}
 assert(!fs.existsSync(failedStage));assert.equal(fs.readFileSync(hostFile,'utf8'),frozen['host.json']);
 const both=retire({...host,agents:{...host.agents,entries:{antenna:{workspace:path.join(root,'agent')},unrelated:{workspace:'/another'}}}},old,root);
 assert(!Object.hasOwn(both.host.agents.entries,'antenna'));assert(both.host.agents.entries.unrelated);assert.equal(both.host.agents.list.length,1);
 assert.throws(()=>retire(host,old,root,{version:99,agents:{}}),/approvals schema/);
 for(const invalid of [{...selection,replayFile:selection.inboxFile},{...selection,inboxFile:path.join(root,'token')},{...selection,inboxFile:root+'/unused/../alias'}])assert.throws(()=>prepare(root,hostFile,invalid));
 fs.symlinkSync(path.join(root,'missing'),path.join(root,'dangling'));assert.throws(()=>prepare(root,hostFile,{...selection,inboxFile:path.join(root,'dangling')}),/must be absent/);fs.unlinkSync(path.join(root,'dangling'));
 const staged=path.join(root,'stage');const report=stage(root,hostFile,selFile,staged,grantsFile);
 assert(!JSON.stringify(report).includes('private-fixture'));assert.equal(fs.statSync(staged).mode&0o777,0o700);
 for(const f of fs.readdirSync(staged))assert.equal(fs.statSync(path.join(staged,f)).mode&0o777,0o600);
 // Changes in dependencies and new native state are detected before any write.
 write('pin',key+'\n');assert.throws(()=>apply(staged),/source changed/);write('pin',key);
 write('native-inbox',{retain:'new hold'});assert.throws(()=>apply(staged),/state appeared/);assert.deepEqual(read('native-inbox'),{retain:'new hold'});fs.unlinkSync(path.join(root,'native-inbox'));
 const hostAfter=path.join(staged,'after-0.json'),savedAfter=fs.readFileSync(hostAfter);fs.appendFileSync(hostAfter,' ');assert.throws(()=>apply(staged),/recovery bytes changed/);fs.writeFileSync(hostAfter,savedAfter);
 assert.throws(()=>stage(root,hostFile,selFile,staged,grantsFile),/EEXIST/);
 const invalidSelection={...selection,obsoleteTemps:[{path:path.join(root,'antenna-inbox.json'),obsolete:true,sha256:hash(frozen['antenna-inbox.json'])}]};write('selection.json',invalidSelection);assert.throws(()=>stage(root,hostFile,selFile),/confirmed private/);write('selection.json',selection);
 // A live relay process blocks all mutation before cleanup.
 const sleeper=path.join(root,'antenna-relay.sh');fs.writeFileSync(sleeper,'sleep 20\n');
 const child=spawn('bash',[sleeper],{detached:true});await once(child,'spawn');
 try{assert.throws(()=>apply(staged),/stop gateway/);assert(fs.existsSync(temp));assert.equal(fs.readFileSync(hostFile,'utf8'),frozen['host.json']);}finally{process.kill(-child.pid,'SIGTERM');await once(child,'exit');}
 requireStopped();
 // Interrupted cutover leaves its private preimages, disables host first and
 // retains the old queue. A second invocation can resume exact planned bytes.
 const rename=fs.renameSync;let writes=0;
 try{fs.renameSync=(...args)=>{if(++writes===2)throw Error('interrupted fixture');return rename(...args);};assert.throws(()=>apply(staged),/interrupted fixture/);}finally{fs.renameSync=rename;}
 assert.equal(read('host.json').plugins.entries.antenna.enabled,false);assert.equal(fs.readFileSync(path.join(root,'antenna-inbox.json'),'utf8'),frozen['antenna-inbox.json']);assert(fs.existsSync(temp));
 assert.equal(apply(staged).applied,true);assert(!fs.existsSync(temp));assert.equal(apply(staged).applied,true);
 const after=read('host.json');assert.deepEqual(after.agents.list,[host.agents.list[1]]);assert.deepEqual(after.hooks.allowedAgentIds,['other']);assert.equal(after.hooks.token,host.hooks.token);assert.deepEqual(after.tools,host.tools);assert.deepEqual(after.plugins.entries.other,host.plugins.entries.other);
 assert.deepEqual(read('approvals.json').agents.antenna.allowlist,[{pattern:'/custom/keep'}]);assert.deepEqual(read('approvals.json').agents.other,JSON.parse(frozen['approvals.json']).agents.other);
 for(const f of ['token','pin','antenna-inbox.json','antenna-lists.json','antenna-public-groups.json'])assert.equal(fs.readFileSync(path.join(root,f),'utf8'),frozen[f]);
 const changed=read('host.json');changed.unrelated='later-edit';write('host.json',changed);assert.throws(()=>apply(staged),/changed/);assert.equal(read('host.json').unrelated,'later-edit');
 console.log('PASS dry-run, private staging, stopped-writer enforcement, attributed retirement, narrow shell cleanup, held-data preservation, interrupted resume, idempotence and concurrent-edit refusal');
}finally{fs.rmSync(root,{recursive:true,force:true});if(fs.existsSync(temp))fs.unlinkSync(temp);}
