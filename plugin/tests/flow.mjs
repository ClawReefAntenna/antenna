import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {Inbox,ReceiveFlow,policyFor,reasons} from '../inbox.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-mcs-inbox-'));
const results=[];
async function test(name,fn){await fn();results.push({name,passed:true});console.log('PASS '+name);}
function setup(options={}){
 const inbox=new Inbox(path.join(root,randomUUID(),'inbox.json'),options.limits);
 const calls={dumb:0,smart:0,submit:0};let allowed=true,target='local-work',exists=true;
 const flow=new ReceiveFlow({inbox,authorize:()=>{if(!allowed)throw Error('revoked');return target;},resolve:()=>exists,
  submit:async()=>{calls.submit++;if(options.throwSubmit)throw Error('lost connection');return {status:'submitted'};},
  dumb:options.noEngine?undefined:async()=>{calls.dumb++;if(options.throwScan)throw Error('scanner failure');return {verdict:options.dumb??'pass',version:'TEST-FIXTURE-ONLY'};},
  smart:options.noEngine?undefined:async()=>{calls.smart++;return {verdict:options.smart??'pass',version:'TEST-FIXTURE-ONLY'};}});
 return {flow,inbox,calls,revoke:()=>allowed=false,remap:()=>target='other',missing:()=>exists=false};
}
const fields=()=>({from:'alpha',to:'beta',message_id:randomUUID(),target_session:'work',body:'Exact 🕵️ body\n\n'});
const policy=(mode='dumb',approval=false)=>({mode,approval,revision:'test'});
for(const mode of ['off','dumb','smart','both'])for(const approval of [false,true]){
 await test(mode+' / ordinary approval '+approval,async()=>{
  const x=setup(),out=await x.flow.receive(fields(),'local-work',policy(mode,approval));
  assert.equal(out.status,approval?'held':'submitted');assert.equal(x.calls.submit,approval?0:1);
  assert.equal(x.calls.dumb,['dumb','both'].includes(mode)?1:0);assert.equal(x.calls.smart,['smart','both'].includes(mode)?1:0);
  if(approval){assert.deepEqual(out.reasons,[reasons.approval]);await x.flow.release(out.id,[reasons.approval]);assert.equal(x.calls.submit,1);}
 });
}
await test('no durable spool for Off / no approval',async()=>{const x=setup();await x.flow.receive(fields(),'local-work',policy('off'));assert.equal(fs.existsSync(x.inbox.file),false);});
for(const outcome of ['flagged','incomplete'])await test('Smart does not invoke Dumb '+outcome,async()=>{
 const x=setup({dumb:outcome}),out=await x.flow.receive(fields(),'local-work',policy('smart'));
 assert.equal(out.status,'submitted');assert.equal(x.calls.dumb,0);assert.equal(x.calls.smart,1);
});
await test('Smart never falls back to Dumb',async()=>{
 const x=setup();x.flow.smart=undefined;
 assert.deepEqual((await x.flow.receive(fields(),'local-work',policy('smart'))).reasons,[reasons.incomplete]);assert.equal(x.calls.dumb,0);
 x.flow.smart=async()=>{throw Error('unavailable');};
 assert.deepEqual((await x.flow.receive(fields(),'local-work',policy('smart'))).reasons,[reasons.incomplete]);assert.equal(x.calls.dumb,0);
});
for(const outcome of ['flagged','incomplete'])await test('Both short circuits on Dumb '+outcome,async()=>{
 const x=setup({dumb:outcome}),out=await x.flow.receive(fields(),'local-work',policy('both'));
 assert.deepEqual(out.reasons,[reasons[outcome]]);assert.equal(x.calls.dumb,1);assert.equal(x.calls.smart,0);
});
await test('Both missing Dumb holds; missing Smart never downgrades',async()=>{
 const x=setup();x.flow.dumb=undefined;
 assert.deepEqual((await x.flow.receive(fields(),'local-work',policy('both'))).reasons,[reasons.incomplete]);assert.equal(x.calls.smart,0);
 const y=setup();y.flow.smart=undefined;
 assert.deepEqual((await y.flow.receive(fields(),'local-work',policy('both'))).reasons,[reasons.incomplete]);assert.equal(y.calls.submit,0);
});
await test('All four global and explicit peer modes resolve',async()=>{
 for(const mode of ['off','dumb','smart','both']){
 assert.equal(policyFor({mcs:mode,inbox:'off'},{},'work').mode,mode);
 assert.equal(policyFor({mcs:'off',inbox:'off'},{mcs:mode},'work').mode,mode);
 }
});
for(const mode of ['smart','both'])for(const outcome of ['flagged','incomplete','invalid'])await test(mode+' '+outcome+' holds independently',async()=>{
 const x=setup({smart:outcome}),out=await x.flow.receive(fields(),'local-work',policy(mode));
 assert.equal(out.status,'held');assert.equal(x.calls.submit,0);assert.equal(x.calls.smart,1);
 assert.deepEqual(out.reasons,[reasons[outcome==='flagged'?'flagged':'incomplete']]);
});
await test('unioned holds; bulk approval excludes MCS; explicit partial release',async()=>{
 const x=setup({dumb:'flagged'}),out=await x.flow.receive(fields(),'local-work',policy('dumb',true));
 assert.deepEqual(out.reasons,[reasons.approval,reasons.flagged]);assert.deepEqual(await x.flow.approveOrdinary(),[]);
 assert.deepEqual((await x.flow.release(out.id,[reasons.approval])).reasons,[reasons.flagged]);
 assert.equal(x.calls.submit,0);assert.equal((await x.flow.release(out.id,[reasons.flagged])).status,'submitted');
 await assert.rejects(x.flow.release(out.id,[reasons.flagged]));assert.equal(x.calls.submit,1);
});
await test('policy Off does not release existing holds',async()=>{
 const x=setup({dumb:'flagged'}),out=await x.flow.receive(fields(),'local-work',policy());
 await x.flow.receive(fields(),'local-work',policy('off'));assert.equal(x.inbox.get(out.id).state,'held');assert.equal(x.calls.submit,1);
});
for(const change of ['revoke','remap','missing'])await test('release rechecks '+change,async()=>{
 const x=setup(),out=await x.flow.receive(fields(),'local-work',policy('off',true));x[change]();
 await assert.rejects(x.flow.release(out.id,[reasons.approval]));assert.equal(x.calls.submit,0);assert.equal(x.inbox.get(out.id).state,'held');
});
await test('concurrent release submits once',async()=>{
 const x=setup(),out=await x.flow.receive(fields(),'local-work',policy('off',true));
 await Promise.allSettled([x.flow.release(out.id,[reasons.approval]),x.flow.release(out.id,[reasons.approval])]);assert.equal(x.calls.submit,1);
});
await test('duplicate pending work has one payload and one scan',async()=>{
 const x=setup(),f=fields();await Promise.allSettled([x.flow.receive(f,'local-work',policy('dumb',true)),x.flow.receive(f,'local-work',policy('dumb',true))]);
 assert.equal(x.inbox.read().items.length,1);assert.equal(x.calls.dumb,1);assert.equal(x.calls.submit,0);
});
await test('pending scan survives restart as incomplete; dispatch becomes unknown',async()=>{
 const x=setup(),a=x.inbox.create(fields(),'local-work',policy('smart',true)),b=x.inbox.create(fields(),'local-work',policy());
 x.inbox.change(b.id,r=>r.state='dispatching');new Inbox(x.inbox.file).recover();
 assert.deepEqual(x.inbox.get(a.id).reasons,[reasons.approval,reasons.incomplete]);assert.equal(x.inbox.get(b.id).state,'unknown');
 await assert.rejects(x.flow.release(b.id,[]));assert.equal(x.calls.submit,0);
});
await test('submission uncertainty is non-retryable',async()=>{
 const x=setup({throwSubmit:true}),out=await x.flow.receive(fields(),'local-work',policy('off',true));
 assert.equal((await x.flow.release(out.id,[reasons.approval])).status,'unknown');await assert.rejects(x.flow.release(out.id,[]));assert.equal(x.calls.submit,1);
});
await test('persistence failure after submission reports unknown, never known failure',async()=>{
 const x=setup(),out=await x.flow.receive(fields(),'local-work',policy('off',true));
 x.flow.submit=async()=>{x.calls.submit++;fs.mkdirSync(x.inbox.file+'.lock');return {status:'submitted'};};
 assert.equal((await x.flow.release(out.id,[reasons.approval])).status,'unknown');
 assert.equal(x.inbox.get(out.id).state,'dispatching');assert.equal(x.calls.submit,1);
});
await test('body integrity and restrictive persistence',async()=>{
 const x=setup(),f=fields(),out=await x.flow.receive(f,'local-work',policy('off',true));
 assert.equal(x.inbox.get(out.id).fields.body,f.body);assert.equal(fs.statSync(x.inbox.file).mode&0o777,0o600);
 const db=JSON.parse(fs.readFileSync(x.inbox.file));db.items[0].fields.body+='changed';fs.writeFileSync(x.inbox.file,JSON.stringify(db));
 await assert.rejects(x.flow.release(out.id,[reasons.approval]));assert.equal(x.calls.submit,0);
});
await test('capacity never evicts another hold or starts scan',async()=>{
 const x=setup({limits:{maxItems:1}});await x.flow.receive(fields(),'local-work',policy('dumb',true));
 await assert.rejects(x.flow.receive(fields(),'local-work',policy('dumb',true)));assert.equal(x.inbox.read().items.length,1);assert.equal(x.calls.dumb,1);
});
await test('corruption and stale lock fail closed',async()=>{
 const x=setup();fs.writeFileSync(x.inbox.file,'bad json');await assert.rejects(x.flow.receive(fields(),'local-work',policy()));assert.equal(x.calls.submit,0);
 const y=setup();fs.mkdirSync(y.inbox.file+'.lock');await assert.rejects(y.flow.receive(fields(),'local-work',policy()));assert.equal(y.calls.dumb,0);
});
await test('missing and throwing scanners hold incomplete',async()=>{
 for(const options of [{noEngine:true},{throwScan:true}]){const x=setup(options);assert.deepEqual((await x.flow.receive(fields(),'local-work',policy())).reasons,[reasons.incomplete]);assert.equal(x.calls.submit,0);}
});
await test('discarded content cannot release',async()=>{
 const x=setup(),out=await x.flow.receive(fields(),'local-work',policy('off',true));x.inbox.discard(out.id);await assert.rejects(x.flow.release(out.id,[reasons.approval]));assert.equal(x.calls.submit,0);
});
await test('peer inheritance and invalid policy',async()=>{
 assert.equal(policyFor({mcs:'dumb',inbox:'off'},{},'work').mode,'dumb');
 assert.equal(policyFor({mcs:'dumb',inbox:'off'},{mcs:'off'},'work').mode,'off');
 assert.equal(policyFor({mcs:'dumb',inbox:'off',approvalByDestination:{work:true}},{},'work').approval,true);
 assert.throws(()=>policyFor({mcs:'typo',inbox:'off'},{},'work'));
});
fs.writeFileSync(path.join(root,'flow-results.json'),JSON.stringify({scope:'Isolated orchestration; injected scanner fixtures, not scanner implementation/quality qualification',passed:results.length,results},null,2));
