import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {runDiagnostic,REPORT_LIMITS} from '../evaluation.mjs';
import {resolveScanner} from '../smart.mjs';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-report-bounds-'));
try{
 const host={agents:{defaults:{models:{'fixture/model':{alias:'scan'}}}}},p=resolveScanner('scan',host);
 const c={scannerModel:'scan',scannerIdentity:p.identity,inboxFile:path.join(root,'inbox')};
 const corpus=path.join(root,'corpus.json');
 fs.writeFileSync(corpus,JSON.stringify({schema:1,cases:Array.from({length:60},(_,i)=>({id:'large'+i,family:'bounded-fixture',expected:'malicious',body:'z'.repeat(65500)}))}));
 let out='',err='';
 const opts={stdout:s=>out=s,stderr:s=>err=s,scanModel:async()=>({schema:1,verdict:'pass',findings:[],requests:1})};
 const output=path.join(root,'reports');
 assert.equal(await runDiagnostic('evaluate',['--engine','smart','--corpus',corpus,'--repeat','5','--verbose','--json','--output',output],c,host,opts),0,err);
 assert(Buffer.byteLength(out)<=REPORT_LIMITS.stdoutBytes);const summary=JSON.parse(out);assert.equal(summary.observations,300);assert.equal(summary.detailsOnStdout,false);
 const full=JSON.parse(fs.readFileSync(path.join(output,'report.json')));assert.equal(full.results.length,300);assert.equal(full.results[299].body,'z'.repeat(65500));assert(!fs.existsSync(c.inboxFile));
 assert.equal(fs.statSync(output).mode&0o777,0o700);assert.equal(fs.statSync(path.join(output,'report.json')).mode&0o777,0o600);
 console.log(JSON.stringify({check:'bounded verbose repeated report',consoleBytes:Buffer.byteLength(out),jsonBytes:fs.statSync(path.join(output,'report.json')).size,textBytes:fs.statSync(path.join(output,'report.txt')).size,observations:300}));
 // Custom file batches can exceed the corpus-wide bound; reject report excess.
 const files=[];for(let i=0;i<110;i++){const f=path.join(root,'body'+i);fs.writeFileSync(f,'z'.repeat(65500));files.push('--file',f);}
 const big=path.join(root,'too-large');
 assert.equal(await runDiagnostic('test',['--engine','smart',...files,'--repeat','5','--expect','malicious','--verbose','--output',big],c,host,opts),3);
 assert.match(err,/32 MiB/);assert(!fs.existsSync(path.join(big,'report.json')));
 console.log('PASS over-budget report refused, no partial report, no inbox mutation');
}finally{fs.rmSync(root,{recursive:true,force:true});}
