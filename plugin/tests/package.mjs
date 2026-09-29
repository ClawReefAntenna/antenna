import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {resolveProfile,readyProfile,credentialFor,migrate} from '../policy.mjs';
import {profileIdentity} from '../scanners.mjs';
import {Inbox} from '../inbox.mjs';
const dir=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-package-'));
const file=path.join(dir,'openclaw.json'),policyFile=path.join(dir,'policy.json'),profileFile=path.join(dir,'profile.json');
const cli=fileURLToPath(new URL('../cli.mjs',import.meta.url));
const write=(f,v)=>fs.writeFileSync(f,JSON.stringify(v),{mode:0o600});
const policy={schemaVersion:2,receiver:'beta',bearer:'x'.repeat(32),peers:{alpha:{publicKey:'fixture',destinations:['work']}},destinations:{work:'agent:test:work'},inboxFile:path.join(dir,'inbox.json'),replayFile:path.join(dir,'replay.json')};
let calls=0,invalid=false;
const server=http.createServer(async(req,res)=>{
 calls++;let raw='';for await(const chunk of req)raw+=chunk;
 const body=JSON.parse(raw);
 assert.equal(body.tools,undefined);assert.equal(body.stream,false);assert.equal(body.store,false);
 res.setHeader('Content-Type','application/json');
 res.end(JSON.stringify({choices:[{finish_reason:'stop',message:{role:'assistant',content:JSON.stringify({schema:1,verdict:invalid?'flagged':'pass',findings:invalid?[{category:'authority',reason:'fixture'}]:[]})}}]}));
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const profile={baseUrl:'http://127.0.0.1:'+server.address().port+'/v1',model:'fixture',locality:'local',tokenParameter:'max_tokens',jsonObject:true,maxInputBytes:4096};
async function run(...args){
 return new Promise(resolve=>{
  const child=spawn(process.execPath,[cli,file,...args]);let out='',err='';
  child.stdout.on('data',x=>out+=x);child.stderr.on('data',x=>err+=x);
  child.on('exit',code=>resolve({code,out,err}));
 });
}
let checks=0;
function check(name,fn){fn();checks++;console.log('PASS '+name);}
try{
 write(file,{gateway:{port:19879},unrelated:{keep:true}});write(policyFile,policy);write(profileFile,profile);
 let r=await run('init',policyFile);
 check('clean initialization is disabled and preserves unrelated host config',()=>{assert.equal(r.code,0);const h=JSON.parse(fs.readFileSync(file));assert.equal(h.plugins.entries.antenna.enabled,false);assert.deepEqual(h.unrelated,{keep:true});assert.equal(h.plugins.entries.antenna.config.mcs,'dumb');});
 r=await run('mode','smart');
 check('unvalidated Smart cannot be selected',()=>assert.equal(r.code,1));
 r=await run('check',profileFile);
 check('connection check does not activate or save profile',()=>{assert.equal(r.code,0);assert.equal(JSON.parse(fs.readFileSync(file)).plugins.entries.antenna.config.scannerProfile,undefined);});
 r=await run('select',profileFile);
 check('explicit selection validates one profile',()=>assert.equal(r.code,0));
 for(const mode of ['off','dumb','smart','both'])assert.equal((await run('mode',mode)).code,0);
 r=await run('mode','off','alpha');await run('mode','smart');
 check('global mode preserves peer override',()=>{assert.equal(r.code,0);assert.equal(JSON.parse(fs.readFileSync(file)).plugins.entries.antenna.config.peers.alpha.mcs,'off');});
 const beforeCalls=calls; r=await run('status');
 check('status is local and excludes bearer',()=>{assert.equal(r.code,0);assert.equal(calls,beforeCalls);assert.ok(!r.out.includes(policy.bearer));});
 const saved=fs.readFileSync(file,'utf8');invalid=true;r=await run('select',profileFile);
 check('failed compatibility leaves configuration byte-identical',()=>{assert.equal(r.code,1);assert.equal(fs.readFileSync(file,'utf8'),saved);});invalid=false;
 const inbox=new Inbox(policy.inboxFile);
 const held=inbox.create({from:'alpha',message_id:'held',body:'Exact 🕵️\n'},'agent:test:work',{mode:'smart',approval:true});
 inbox.change(held.id,r=>{r.state='held';r.reasons.push('MCS flagged');});
 const bytes=fs.readFileSync(policy.inboxFile);
 const host=JSON.parse(saved);host.plugins.entries.antenna.config.schemaVersion=1;host.plugins.entries.antenna.config.policyRevision='combined-smart-v1';host.plugins.entries.antenna.config.peers.alpha.mcs='smart';write(file,host);
 const pre=fs.readFileSync(file,'utf8');r=await run('migrate');
 check('upgrade preview is read-only and maps combined Smart to Both',()=>{assert.equal(r.code,0);assert.equal(JSON.parse(r.out).mcs,'both');assert.equal(JSON.parse(r.out).peers.alpha,'both');assert.equal(fs.readFileSync(file,'utf8'),pre);});
 r=await run('migrate','--apply');
 check('upgrade preserves exact holds, credentials and unrelated config',()=>{assert.equal(r.code,0);assert.deepEqual(fs.readFileSync(policy.inboxFile),bytes);const h=JSON.parse(fs.readFileSync(file));assert.equal(h.plugins.entries.antenna.config.bearer,policy.bearer);assert.equal(h.unrelated.keep,true);});
 r=await run('inbox','show',held.id);
 check('inbox review escapes controls and preserves body',()=>{assert.equal(r.code,0);assert.equal(JSON.parse(r.out).fields.body,'Exact 🕵️\n');assert.ok(r.out.includes('\\n'));});
 r=await run('inbox','discard',held.id);
 check('discard changes disposition without delivery',()=>{assert.equal(r.code,0);assert.equal(inbox.get(held.id).state,'discarded');});
 check('unknown legacy schemas rejected',()=>assert.throws(()=>migrate({...policy,schemaVersion:1})));
 const modelHost={models:{providers:{local:{api:'openai-completions',baseUrl:profile.baseUrl,models:[{id:'fixture'}]}}},agents:{defaults:{models:{'local/fixture':{alias:'scanner'}}}}};
 const p=resolveProfile({...profile,configuredModel:'scanner'},modelHost);p.validatedIdentity=profileIdentity(p);
 check('configured alias resolves and destination drift invalidates selection',()=>{assert.equal(readyProfile(p,modelHost).validatedIdentity,p.validatedIdentity);modelHost.models.providers.local.baseUrl='http://localhost:1234/v1';assert.equal(readyProfile(p,modelHost).validatedIdentity,undefined);});
 const keyFile=path.join(dir,'key');fs.writeFileSync(keyFile,'synthetic-one',{mode:0o600});
 check('credential rotation uses same reference and rejects public files',()=>{assert.equal(credentialFor({credentialRef:{file:keyFile}}),'synthetic-one');fs.writeFileSync(keyFile,'synthetic-two');assert.equal(credentialFor({credentialRef:{file:keyFile}}),'synthetic-two');fs.chmodSync(keyFile,0o644);assert.throws(()=>credentialFor({credentialRef:{file:keyFile}}));});
 check('inline credential fields rejected',()=>assert.throws(()=>resolveProfile({...profile,apiKey:'synthetic'},{})));
 check('remote plaintext endpoint rejected',()=>assert.throws(()=>resolveProfile({...profile,baseUrl:'http://example.com/v1'},{})));
 console.log(JSON.stringify({packageChecks:checks,fixtureCalls:calls,externalCalls:0}));
}finally{server.close();}
