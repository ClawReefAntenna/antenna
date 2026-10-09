// Production regression plus optional actual-tag setup fixture qualification.
// Run without arguments for flat/session fixtures, or with an extracted, set-up
// legacy installation root. No source fixture or live host is modified.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {generateKeyPairSync,createHash} from 'node:crypto';
import {stage,apply} from './cutover.mjs';
const supplied=process.argv[2];
const base=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-legacy-compat-'));
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const results=[];
try{
 const formats=supplied?[JSON.parse(fs.readFileSync(path.join(supplied,'antenna-config.json'))).session_policy_version===1?'session':'flat']:['flat','session'];
 for(const format of formats)for(const mode of (format==='flat'?['on','off']:['on','off','allowlist']))for(const trusted of [false,true])for(const signedSelf of [false,true]){
  const root=fs.mkdtempSync(path.join(base,'case-'));
  if(supplied)fs.cpSync(supplied,root,{recursive:true});
  const write=(name,value)=>fs.writeFileSync(path.join(root,name),typeof value==='string'?value:JSON.stringify(value),{mode:0o600});
  const read=name=>JSON.parse(fs.readFileSync(path.join(root,name),'utf8'));
  if(!supplied){write('antenna-config.json',{relay_agent_id:'antenna',allowed_inbound_sessions:['agent:research:main','agent:research:other'],inbox_enabled:true,inbox_auto_approve_peers:[],inbox_queue_path:'antenna-inbox.json',max_message_length:10000,...(format==='session'?{session_policy_version:1,session_policies:{'agent:research:main':{inbox:true},'agent:research:other':{inbox:false}}}:{})});write('token','fixture-self-credential-'.repeat(3));write('antenna-peers.json',{self:{self:true,token_file:'token',url:'https://self.example'}});}
  const old=read('antenna-config.json'),peers=read('antenna-peers.json');
  const self=Object.keys(peers).find(k=>peers[k].self===true);assert(self);
  const key=generateKeyPairSync('ed25519');
  write('compat-pin.pem',key.publicKey.export({type:'spki',format:'pem'}));write('compat-key.pem',key.privateKey.export({type:'pkcs8',format:'pem'}));
  for(const id of ['trusted','ordinary'])peers[id]={auth_mode:'ed25519-v1',signing_public_key_file:'compat-pin.pem',url:id==='trusted'?'http://trusted.example':'https://ordinary.example'};
  if(signedSelf)Object.assign(peers[self],{auth_mode:'ed25519-v1',signing_public_key_file:'compat-pin.pem'});
  old.allowed_inbound_peers=[self,'trusted','ordinary'];old.allowed_outbound_peers=[self,'trusted','ordinary'];old.inbox_enabled=mode!=='off';old.inbox_auto_approve_peers=trusted?['trusted']:[];
  if(format==='session'){
   old.inbox_mode=mode;
   for(const [i,target] of old.allowed_inbound_sessions.entries())old.session_policies[target]={...(old.session_policies[target]??{}),inbox:i===0};
  }else delete old.inbox_mode;
  write('antenna-config.json',old);write('antenna-peers.json',peers);
  const queue=[{status:'pending',body:'keep pending'},{status:'approved',body:'keep unsent'},{status:'failed',body:'keep uncertain'},{status:'delivered'},{status:'denied'}];write('antenna-inbox.json',queue);write('antenna-lists.json',{research:[{peer:'trusted'}]});write('antenna-public-groups.json',{registration:'retain'});
  const host={gateway:{auth:{token:'separate-operator-fixture'}},hooks:{token:'retain-shared-hook',allowedAgentIds:['antenna','other']},tools:{sessions:{visibility:'all'}},agents:{list:[{id:'antenna',workspace:path.join(root,'agent')},{id:'other',workspace:'/unrelated'}]},plugins:{entries:{other:{enabled:true}}}};
  write('host.json',host);write('exec-approvals.json',{version:1,agents:{antenna:{allowlist:[{pattern:'/usr/bin/bash'},{pattern:'/custom/retain'}]},other:{allowlist:[{pattern:'/usr/bin/bash'}]}}});
  const selection={mcs:'dumb',destinations:Object.fromEntries(old.allowed_inbound_sessions.map((target,i)=>['destination'+i,target])),inboxFile:path.join(root,'native-inbox.json'),replayFile:path.join(root,'native-replay.json'),outbound:{trusted:{profile:'antenna-plugin-v2',default_target:'research'},ordinary:{profile:'antenna-plugin-v2',default_target:'research'}}};write('selection.json',selection);
  const hostFile=path.join(root,'host.json'),selectionFile=path.join(root,'selection.json'),output=path.join(root,'staging');
  const snapshot=()=>{const files={};const walk=dir=>{for(const item of fs.readdirSync(dir,{withFileTypes:true})){const f=path.join(dir,item.name);if(item.isDirectory())walk(f);else if(item.isFile())files[path.relative(root,f)]=hash(f);}};walk(root);return files;};
  const originalPeers=fs.readFileSync(path.join(root,'antenna-peers.json'));
  const before=snapshot();assert(stage(root,hostFile,selectionFile).dryRun);assert.deepEqual(snapshot(),before);
  // A remote plaintext record never gets the local-self exception.
  delete peers.ordinary.auth_mode;write('antenna-peers.json',peers);assert.throws(()=>stage(root,hostFile,selectionFile),/plaintext peer/);peers.ordinary.auth_mode='ed25519-v1';write('antenna-peers.json',peers);
  if(!signedSelf){
   peers[self].auth_mode='legacy';write('antenna-peers.json',peers);assert.throws(()=>stage(root,hostFile,selectionFile),/plaintext peer/);delete peers[self].auth_mode;write('antenna-peers.json',peers);
   selection.outbound[self]={profile:'antenna-plugin-v2',default_target:'research'};write('selection.json',selection);assert.throws(()=>stage(root,hostFile,selectionFile),/unsigned self-peer/);delete selection.outbound[self];write('selection.json',selection);
  }
  if(format==='flat'){
   for(const invalid of [{...old,session_policy_version:1},{...old,session_policies:{}},{...old,inbox_mode:'allowlist',inbox_enabled:true},{...old,inbox_enabled:'false'}]){write('antenna-config.json',invalid);assert.throws(()=>stage(root,hostFile,selectionFile),/policy|switch/);}
   write('antenna-config.json',old);
  }
  write('selection.json',{...selection,destinations:{...selection.destinations,extra:'agent:unauthorized:main'}});assert.throws(()=>stage(root,hostFile,selectionFile),/exact allowed target set/);write('selection.json',selection);
  fs.writeFileSync(path.join(root,'antenna-peers.json'),originalPeers);
  assert.deepEqual(snapshot(),before);
  const report=stage(root,hostFile,selectionFile,output);assert.equal(report.legacyPending,3);assert.deepEqual(report.omittedUnsignedSelf,signedSelf?[]:[self]);
  assert.equal(fs.statSync(output).mode&0o777,0o700);for(const file of fs.readdirSync(output))assert.equal(fs.statSync(path.join(output,file)).mode&0o777,0o600);
  const plan=JSON.parse(fs.readFileSync(path.join(output,'plan.json')));
  const staged=JSON.parse(fs.readFileSync(path.join(output,'after-0.json'))).plugins.entries.antenna.config;
  for(const id of ['trusted','ordinary',...(signedSelf?[self]:[])]){
   assert.deepEqual(staged.peers[id].destinations,Object.keys(selection.destinations));assert.equal(staged.peers[id].publicKey,fs.readFileSync(path.join(root,'compat-pin.pem'),'utf8'));
   for(const [i,alias] of Object.keys(selection.destinations).entries())assert.equal(staged.peers[id].approvalByDestination[alias],mode==='allowlist'?i===0:mode==='on'&&!(trusted&&id==='trusted'));
  }
  assert.equal(Object.hasOwn(staged.peers,self),signedSelf);
  // Source drift refuses before writes; restore exact source and deliberately
  // interrupt the second replacement to exercise recovery for every scenario.
  const pin=fs.readFileSync(path.join(root,'compat-pin.pem'));fs.appendFileSync(path.join(root,'compat-pin.pem'),'\n');assert.throws(()=>apply(output),/source changed/);fs.writeFileSync(path.join(root,'compat-pin.pem'),pin);
  const rename=fs.renameSync;let replacements=0;
  try{fs.renameSync=(...args)=>{if(++replacements===2)throw Error('fixture interruption');return rename(...args);};assert.throws(()=>apply(output),/fixture interruption/);}finally{fs.renameSync=rename;}
  assert.equal(read('host.json').plugins.entries.antenna.enabled,false);assert.deepEqual(read('antenna-inbox.json'),queue);
  assert(apply(output).applied);assert(apply(output).applied);
  const after=read('host.json');assert.equal(after.plugins.entries.antenna.enabled,false);assert.deepEqual(after.plugins.entries.antenna.config,staged);assert.deepEqual(after.gateway,host.gateway);assert.deepEqual(after.tools,host.tools);assert.deepEqual(after.agents.list,[host.agents.list[1]]);assert.equal(after.hooks.token,host.hooks.token);assert.deepEqual(after.hooks.allowedAgentIds,['other']);assert.deepEqual(after.plugins.entries.other,host.plugins.entries.other);
  assert.deepEqual(read('exec-approvals.json').agents.antenna.allowlist,[{pattern:'/custom/retain'}]);assert.deepEqual(read('exec-approvals.json').agents.other,{allowlist:[{pattern:'/usr/bin/bash'}]});
  for(const [file,digest] of Object.entries(before))if(!['host.json','antenna-config.json','antenna-peers.json','exec-approvals.json'].includes(file))assert.equal(hash(path.join(root,file)),digest,file);
  assert.deepEqual(read('antenna-config.json'),{...old,transport_profile:'antenna-plugin-v2'});
  const expectedPeers=structuredClone(peers);for(const id of ['trusted','ordinary'])Object.assign(expectedPeers[id],{transport_profile:'antenna-plugin-v2',default_target:'research'});expectedPeers.trusted.allow_http=true;assert.deepEqual(read('antenna-peers.json'),expectedPeers);
  assert(!fs.existsSync(selection.inboxFile));assert(!fs.existsSync(selection.replayFile));for(const target of plan.targets)assert(fs.existsSync(path.join(output,`before-${target.index}.json`)));
  after.unrelatedLaterChange=true;write('host.json',after);assert.throws(()=>apply(output),/changed/);
  results.push({format,mode,trusted,signedSelf,stage:true,apply:true,interruptedRecovery:true});
 }
 console.log(JSON.stringify({fixture:supplied?'actual tagged setup':'synthetic regression',passed:results.length,cases:results}));
}finally{fs.rmSync(base,{recursive:true,force:true});}
