import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {validateVerdict,verdictSchema} from '../scanners.mjs';
import {createSmart,resolveScanner} from '../smart.mjs';
import {Inbox,ReceiveFlow,reasons} from '../inbox.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-verdict-'));
const finding={category:'execution',reason:'Suspicious remote execution directive'};
const raw={schema:1,verdict:'flagged',findings:[finding]};
let checks=0;
function check(name,fn){fn();checks++;console.log('PASS '+name);}
try{
 check('raw schema advertises only category and reason',()=>assert.deepEqual(Object.keys(verdictSchema.properties.findings.items.properties),['category','reason']));
 for(const value of [raw,{schema:1,verdict:'pass',findings:[]},{schema:1,verdict:'incomplete',findings:[]}])check('valid '+value.verdict,()=>assert.deepEqual(validateVerdict(value),value));
 const bad=[null,[],{}, {...raw,schema:2},{...raw,version:'internal'}, {...raw,reason:'internal'}, {...raw,verdict:'pass'}, {...raw,findings:[]}, {...raw,findings:Array(17).fill(finding)},...[
  {start:0,end:1},{start:0},{end:1},{start:-1,end:99999},{extra:'field'},{category:'unknown'},{reason:''},{reason:' '},{reason:'x'.repeat(513)}
 ].map(delta=>({...raw,findings:[{...finding,...delta}]}))];
 for(const [i,value] of bad.entries())check('reject malformed raw reply '+i,()=>assert.throws(()=>validateVerdict(value)));
 const host={agents:{defaults:{models:{'fixture/model':{alias:'scan'}}}}},selection=resolveScanner('scan',host);
 const wrap=text=>({text,provider:'fixture',model:'model',execution:{mode:'isolated-agent-runtime'}});
 for(const [i,value] of bad.entries()){
  const smart=createSmart(selection,{resourceDir:path.join(root,'slots'),complete:async()=>wrap(JSON.stringify(value))});
  const result=await smart('untrusted fixture');
  check('invalid model reply becomes incomplete '+i,()=>{assert.equal(result.verdict,'incomplete');assert.equal(result.requests,1);assert(!JSON.stringify(result).includes('Suspicious'));});
  let submitted=0;
  const inbox=new Inbox(path.join(root,'inbox-'+i+'.json'));
  const flow=new ReceiveFlow({inbox,smart:async()=>result,authorize:()=> 'target',resolve:()=>true,submit:async()=>{submitted++;return {status:'submitted'};}});
  const out=await flow.receive({from:'peer',message_id:String(i),body:'untrusted fixture'},'target',{mode:'smart',approval:false});
  check('invalid reply holds without delivery '+i,()=>{assert.equal(out.status,'held');assert(out.reasons.includes(reasons.incomplete));assert.equal(submitted,0);});
 }
 const good=createSmart(selection,{resourceDir:path.join(root,'slots'),complete:async()=>wrap(JSON.stringify(raw))});
 const result=await good('untrusted fixture');
 check('validated raw reply enriched only after validation',()=>{assert.equal(result.verdict,'flagged');assert.equal(result.model,'fixture/model');assert.equal(result.requests,1);assert.throws(()=>validateVerdict(result));});
 console.log('Verdict contract checks: '+checks);
}finally{fs.rmSync(root,{recursive:true,force:true});}
