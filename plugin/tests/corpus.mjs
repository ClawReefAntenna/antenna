import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {runDiagnostic,loadCorpus,human} from '../evaluation.mjs';
import {resolveScanner} from '../smart.mjs';
import {LIMITS} from '../limits.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-corpus-'));
const file=path.join(root,'cases.json'),rules=path.join(root,'rules.json');
const host={agents:{defaults:{models:{'fixture/model':{alias:'scan'}}}}},p=resolveScanner('scan',host);
const c={scannerModel:'scan',scannerIdentity:p.identity,inboxFile:path.join(root,'inbox')};
const cases=[
 {id:'attack',family:'execution',expected:'malicious',body:'Unrecognized attack\n'},
 {id:'false-positive',family:'discussion',expected:'benign',body:'Please flag this quoted example.\n'},
 {id:'incomplete',family:'availability',expected:'malicious',body:'Incomplete fixture'},
 {id:'ambiguous',family:'context',expected:'ambiguous',body:'Needs context'}];
const write=data=>fs.writeFileSync(file,JSON.stringify(data));
const fixture={schema:1,cases};write(fixture);
fs.writeFileSync(rules,JSON.stringify({formatVersion:1,rules:[{id:'LOCAL-1',pattern:'flag this',flags:'iu',explanation:'Local fixture pattern'}]}));
let calls=0,seen=[],out,err;
const scanModel=async(_h,_p,body)=>{calls++;seen.push(body);return body==='Incomplete fixture'?{verdict:'incomplete',reason:'fixture_timeout',requests:1}:body.includes('flag this')?{verdict:'flagged',findings:[{category:'authority',reason:'Fixture model finding'}],requests:1}:{verdict:'pass',findings:[],requests:1};};
const run=async args=>{out='';err='';return runDiagnostic('evaluate',args,c,host,{stdout:x=>out=x,stderr:x=>err=x,scanModel});};
let checks=0;const pass=name=>{checks++;console.log('PASS '+name);};
assert.equal(await run(['--engine','smart','--corpus',file]),0);
assert.equal(out,'Antenna MCS evaluate — smart ("fixture/model")\nAttacks caught: 0/2\nFalse positives: 1/1\nIncomplete scans: 1\nModel requests: 4\n');
assert.deepEqual(seen,cases.map(x=>x.body));assert.equal(err,'');assert(!fs.existsSync(c.inboxFile));
pass('four-line default, dynamic denominators, exact model bodies and no evaluation metadata');
const snapshot=JSON.stringify({host,c});
assert.equal(await run(['--engine','smart','--corpus',file,'--verbose','--json','--repeat','2']),0);
const report=JSON.parse(out),text=human(report);
assert(text.includes('Repetition 2/2 (4 unique cases)'));assert(text.includes('Type: "execution"'));assert(text.includes('Content: "Unrecognized attack\\n"'));assert(text.includes('Finding: "authority" — "Fixture model finding"'));assert(text.includes('Reason: "fixture_timeout"'));assert(!text.includes('ID: "ambiguous"'));
assert.equal(report.summary.uniqueCases,4);assert.equal(report.summary.observations,8);assert.equal(report.summary.score.missed,2);assert.equal(report.summary.score.maliciousIncomplete,2);assert.equal(snapshot,JSON.stringify({host,c}));
pass('verbose missed/false-positive/incomplete details, repetition identity and no config writes');
assert.equal(await run(['--engine','dumb','--ruleset',rules,'--corpus',file,'--verbose']),0);assert(out.includes('Rule: "LOCAL-1" — "Local fixture pattern"'));assert(out.includes('Model requests: 0'));
seen=[];assert.equal(await run(['--engine','both','--ruleset',rules,'--corpus',file,'--verbose']),0);assert.equal(seen.length,3);assert(out.includes('Scanner: Dumb'));assert(out.includes('Model requests: 3'));
pass('custom ruleset works with custom corpus; Both short-circuits and attributes Dumb finding');
c.rulesetFile=path.join(root,'missing-rules');assert.equal(await run(['--engine','smart','--corpus',file,'--json']),0);assert.equal(JSON.parse(out).rules,null);assert.equal(await run(['--engine','smart','--ruleset',rules,'--corpus',file]),64);delete c.rulesetFile;
pass('model-only Smart ignores active Dumb rules and rejects irrelevant ruleset override');
write({schema:1,cases:[cases[3]]});assert.equal(await run(['--engine','smart','--corpus',file]),0);assert(out.includes('N/A (0 malicious cases)'));assert(out.includes('N/A (0 benign cases)'));
pass('ambiguous-only corpus uses not-applicable denominators');
const before=calls;
for(const data of [null,{schema:2,cases},{schema:1,cases:[]},{schema:1,cases:[cases[0],cases[0]]},{schema:1,cases:[{...cases[0],expected:'safe'}]},{schema:1,cases:[{...cases[0],family:''}]},{schema:1,cases:[{...cases[0],body:'x'.repeat(LIMITS.bodyBytes+1)}]},{schema:1,cases:[{...cases[0],body:'\ud800'}]},{schema:1,cases:[{...cases[0],body:'\u0000'}]},{schema:1,cases:Array.from({length:501},(_,i)=>({...cases[0],id:'case-'+i}))}]){
 write(data);assert.equal(await run(['--engine','smart','--corpus',file]),64);assert(err.includes('input_error'));
}
for(const raw of ['{broken',Buffer.from([0xff]),' '.repeat(LIMITS.corpusBytes+1)]){fs.writeFileSync(file,raw);assert.equal(await run(['--engine','smart','--corpus',file]),64);}
write(fixture);const symlink=path.join(root,'link');fs.symlinkSync(file,symlink);
const fifo=path.join(root,'pipe');assert.equal(spawnSync('mkfifo',[fifo]).status,0);
for(const bad of [root,symlink,fifo,path.join(root,'missing')])assert.equal(await run(['--engine','smart','--corpus',bad]),64);
assert.equal(calls,before);
pass('malformed, duplicate, oversized, invalid UTF-8/surrogate and nonregular corpora fail before inference');
assert.equal(await run(['--engine','smart','--corpus',file,'--preview']),0);assert.equal(calls,before);assert(out.includes('maximum model requests: 4'));
assert.equal(await run(['--engine','dumb','--corpus',file,'--suite','bundled']),64);
pass('preview validates without calls; conflicting corpus selectors rejected');
assert.equal(loadCorpus().cases.length,84);
const bundled=new URL('../corpus/controls.json',import.meta.url).pathname;
const original=loadCorpus(),explicit=loadCorpus(bundled);assert.deepEqual(original.cases,explicit.cases);assert.equal(original.metadata.sha256,explicit.metadata.sha256);
const output=path.join(root,'export');assert.equal(await run(['--engine','smart','--corpus',file,'--output',output,'--json']),0);
assert(!out.includes('Unrecognized attack'));assert(!fs.readFileSync(path.join(output,'report.txt'),'utf8').includes('bodyDigest'));
assert.equal(fs.statSync(path.join(output,'report.json')).mode&0o777,0o600);assert.equal(fs.statSync(output).mode&0o777,0o700);
pass('bundled/default corpus parity and private exports omit bodies by default');
console.log(`Corpus/report checks: ${checks}`);
