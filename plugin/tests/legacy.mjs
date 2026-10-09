import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {generateKeyPairSync,verify} from 'node:crypto';
import {buildMessage,sendEnvelope,PROFILE} from '../transport.mjs';
import {canonical,parse} from '../envelope.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-legacy-'));
const key=generateKeyPairSync('ed25519'),privateKey=key.privateKey.export({type:'pkcs8',format:'pem'}),publicKey=key.publicKey.export({type:'spki',format:'pem'});
const body='Exact 🕵️ bytes\n\n',wire=buildMessage({from:'alpha',to:'beta',target:'work',body,privateKey});
const fields=parse(Buffer.from(wire),1000);
assert.equal(fields.body,body);assert(verify(null,canonical(fields),key.publicKey,Buffer.from(fields.signature.slice(11),'base64')));
let calls=0,reply={status:'held'},code=202,redirect=false;
const server=http.createServer((req,res)=>{calls++;let raw='';req.on('data',b=>raw+=b);req.on('end',()=>{assert.equal(req.url,'/antenna/v1/receive');assert.equal(raw,wire);res.writeHead(redirect?302:code,redirect?{location:'/hooks/agent'}:{'Content-Type':'application/json'});res.end(JSON.stringify(reply));});});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const target={origin:`http://127.0.0.1:${server.address().port}`,profile:PROFILE,bearer:'x'.repeat(32),allowHttp:true};
try{
 for(const status of ['held','submitted']){reply={status};assert.equal((await sendEnvelope(target,wire)).status,status);}
 code=504;reply={status:'unknown'};assert.equal((await sendEnvelope(target,wire)).status,'unknown');
 code=403;reply={status:'rejected'};assert.equal((await sendEnvelope(target,wire)).status,'rejected');
 code=200;reply={status:'delivered'};assert.equal((await sendEnvelope(target,wire)).status,'unknown');
 redirect=true;assert.equal((await sendEnvelope(target,wire)).status,'unknown');assert.equal(calls,6);
 assert.throws(()=>sendEnvelope({...target,profile:'legacy'},wire));assert.throws(()=>sendEnvelope({...target,allowHttp:false},wire));assert.equal(calls,6);
}finally{await new Promise(r=>server.close(r));}
const write=(name,value)=>fs.writeFileSync(path.join(root,name),typeof value==='string'?value:JSON.stringify(value),{mode:0o600});
write('token','x'.repeat(32));write('key.pem',publicKey);
console.log('PASS exact v2 signature/body; held/submitted/unknown/rejected; no redirect/retry/fallback');
// Offline contact exchange: export warning when hooks retained, pinned import,
// no permission grant, and retired legacy writer guard.
const {execFileSync}=await import('node:child_process');
const pairing=new URL('../pairing.mjs',import.meta.url).pathname;
const contact=path.join(root,'contact.json'),hostFile=path.join(root,'export-host.json');
write('antenna-peers.json',{beta:{self:true,url:'https://beta.test',signing_public_key_file:'key.pem'}});
write('export-host.json',{gateway:{auth:{token:'operator-not-shared'}},hooks:{token:'x'.repeat(32)},plugins:{entries:{antenna:{config:{receiver:'beta',bearer:'x'.repeat(32),destinations:{work:'agent:beta:main'}}}}}});
const retained=JSON.parse(execFileSync(process.execPath,[pairing,'export',root,hostFile,contact]));assert.equal(retained.warnings.length,1);fs.unlinkSync(contact);
const shared=JSON.parse(fs.readFileSync(hostFile));shared.gateway.auth.token='x'.repeat(32);write('export-host.json',shared);assert.throws(()=>execFileSync(process.execPath,[pairing,'export',root,hostFile,contact],{stdio:'pipe'}));shared.gateway.auth.token='operator-not-shared';write('export-host.json',shared);
const exportHost=JSON.parse(fs.readFileSync(hostFile,'utf8'));exportHost.hooks.token='new-host-private';write('export-host.json',exportHost);
execFileSync(process.execPath,[pairing,'export',root,hostFile,contact]);assert.equal(fs.statSync(contact).mode&0o777,0o600);
const receiver=path.join(root,'recipient');fs.mkdirSync(receiver);fs.writeFileSync(path.join(receiver,'antenna-peers.json'),'{}');fs.writeFileSync(path.join(receiver,'antenna-config.json'),'{"allowed_outbound_peers":[]}');
execFileSync(process.execPath,[pairing,'import',receiver,contact,'beta','work']);assert.equal(JSON.parse(fs.readFileSync(path.join(receiver,'antenna-peers.json'))).beta.transport_profile,PROFILE);assert.deepEqual(JSON.parse(fs.readFileSync(path.join(receiver,'antenna-config.json'))).allowed_outbound_peers,[]);
const changed=JSON.parse(fs.readFileSync(contact));changed.public_key=generateKeyPairSync('ed25519').publicKey.export({type:'spki',format:'pem'});fs.writeFileSync(contact,JSON.stringify(changed));
assert.throws(()=>execFileSync(process.execPath,[pairing,'import',receiver,contact,'beta','work'],{stdio:'pipe'}));
console.log('PASS contact scope gate, private output, pin continuity and no permission changes');
// Exercise retained shell entrypoints rather than only the transport library.
const {execFile}=await import('node:child_process');const {promisify}=await import('node:util');const run=promisify(execFile);
const shellRoot=path.join(root,'shell');fs.mkdirSync(shellRoot);
for(const part of ['scripts','lib','plugin'])fs.cpSync(new URL('../../'+part,import.meta.url).pathname,path.join(shellRoot,part),{recursive:true,filter:src=>!src.includes('/node_modules')&&!src.includes('/tests/')});
fs.writeFileSync(path.join(shellRoot,'private.pem'),privateKey,{mode:0o600});fs.writeFileSync(path.join(shellRoot,'token'),'x'.repeat(32),{mode:0o600});
let shellCalls=0;const exact='\ufeffExact shell 🕵️\n\n';
const receiverServer=http.createServer((req,res)=>{let raw='';req.on('data',b=>raw+=b);req.on('end',()=>{shellCalls++;assert.equal(req.url,'/antenna/v1/receive');assert.equal(parse(Buffer.from(raw),10000).body,exact);res.writeHead(202,{'Content-Type':'application/json'});res.end('{"status":"held"}');});});
await new Promise(r=>receiverServer.listen(0,'127.0.0.1',r));
try{
 const url='http://127.0.0.1:'+receiverServer.address().port;
 fs.writeFileSync(path.join(shellRoot,'antenna-config.json'),JSON.stringify({transport_profile:PROFILE,max_message_length:10000,allowed_outbound_peers:['beta']}));
 fs.writeFileSync(path.join(shellRoot,'antenna-peers.json'),JSON.stringify({alpha:{self:true,auth_mode:'ed25519-v1',url:'https://alpha.test',signing_private_key_file:'private.pem'},beta:{url,allow_http:true,auth_mode:'ed25519-v1',token_file:'token',transport_profile:PROFILE,default_target:'work'}}));
 fs.writeFileSync(path.join(shellRoot,'antenna-lists.json'),JSON.stringify({staff:[{peer:'beta'}]}));
 const direct=await run('bash',[path.join(shellRoot,'scripts/antenna-send.sh'),'beta',exact]);assert.equal(JSON.parse(direct.stdout).status,'held');
 const list=await run('bash',[path.join(shellRoot,'scripts/antenna-list-send.sh'),'@staff',exact]);assert.equal(JSON.parse(list.stdout).results[0].sender.status,'held');assert.equal(shellCalls,2);
 for(const name of ['setup','upgrade','pair','exchange','uninstall','inbox'])await assert.rejects(run('bash',[path.join(shellRoot,`scripts/antenna-${name}.sh`)]));
 assert.equal(shellCalls,2);
}finally{await new Promise(r=>receiverServer.close(r));}
console.log('PASS shell direct/list transport, UTF-8 BOM/trailing LF, and retired writer guards');
await assert.rejects(run('bash',[path.join(shellRoot,'scripts/antenna-doctor.sh'),'--fix-hints']));
try{await run('python3',[path.join(shellRoot,'scripts/antenna-readiness.py'),'--json']);assert.fail('legacy readiness must fail');}catch(e){assert.equal(JSON.parse(e.stdout||e.stderr).status,'blocked');}
try{await run('python3',[path.join(shellRoot,'scripts/antenna-backup.py'),'restore','unused.age','--to',shellRoot]);assert.fail('legacy restore must fail');}catch(e){assert.match(e.stderr+e.stdout,/INCOMPATIBLE_TARGET|HOST_REQUIRED|INVALID_HOST|MISSING_STATE|TERMINAL_REQUIRED/);}
console.log('PASS migrated Doctor/readiness/restore cannot recommend or restore legacy state');
