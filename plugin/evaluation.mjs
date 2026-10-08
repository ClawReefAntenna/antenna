import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {LIMITS} from './limits.mjs';
import {scanDumb,RUBRIC} from './scanners.mjs';
import {loadRuleset} from './ruleset.mjs';
import {resolveScanner,gatewayScan} from './smart.mjs';
import {ReceiveFlow} from './inbox.mjs';
import {capacityDirectory} from './capacity.mjs';
const hash=b=>createHash('sha256').update(b).digest('hex');
const usageKeys=['prompt_tokens','completion_tokens','total_tokens'];
const knownSources=['evaluation.mjs','scanners.mjs','dumb-worker.mjs','inbox.mjs','limits.mjs','capacity.mjs','policy.mjs','smart.mjs','ruleset.mjs'];
export const DEFAULT_CORPUS_URL='https://clawreef.io/resources/controls.json';
export const quantile=(xs,p)=>xs.length?[...xs].sort((a,b)=>a-b)[Math.max(0,Math.ceil(xs.length*p)-1)]:null;
export function score(rows){
 const labelled=rows.filter(r=>['malicious','benign'].includes(r.expected));
 if(!labelled.length)return null;
 const count=(label,verdict)=>rows.filter(r=>r.expected===label&&(!verdict||r.verdict===verdict)).length;
 const malicious=count('malicious'),benign=count('benign');
 const detected=count('malicious','flagged'),missed=count('malicious','pass'),falseFlags=count('benign','flagged'),benignIncomplete=count('benign','incomplete');
 const rate=(a,b)=>b?a/b:null;
 return {malicious,benign,detected,missed,maliciousIncomplete:count('malicious','incomplete'),benignPassed:count('benign','pass'),falseFlags,benignIncomplete,detectionRate:rate(detected,malicious),missRate:rate(missed,malicious),falseFlagRate:rate(falseFlags,benign),benignHoldBurden:rate(falseFlags+benignIncomplete,benign)};
}
export function summarize(rows){
 const ids=[...new Set(rows.map(r=>r.id))];
 return {uniqueCases:ids.length,observations:rows.length,ambiguousObservations:rows.filter(r=>r.expected==='ambiguous').length,incomplete:rows.filter(r=>r.verdict==='incomplete').length,operationalFailures:rows.filter(r=>r.error||r.reason&&r.verdict==='incomplete').length,requests:rows.reduce((n,r)=>n+(r.requests??0),0),usage:rows.some(r=>r.usage)?Object.fromEntries(usageKeys.map(k=>[k,rows.reduce((n,r)=>n+(r.usage?.[k]??0),0)])):null,usageReporting:{observationsWithUsage:rows.filter(r=>r.usage).length,requestedObservationsMissingUsage:rows.filter(r=>r.requests&&!r.usage).length},latencyMs:{p50:quantile(rows.map(r=>r.elapsedMs),.5),p95:quantile(rows.map(r=>r.elapsedMs),.95),p99:quantile(rows.map(r=>r.elapsedMs),.99)},score:score(rows),disagreements:ids.filter(id=>new Set(rows.filter(r=>r.id===id).map(r=>r.verdict)).size>1),byFamily:Object.fromEntries([...new Set(rows.map(r=>r.family).filter(Boolean))].map(f=>[f,score(rows.filter(r=>r.family===f))])),bySplit:Object.fromEntries([...new Set(rows.map(r=>r.split).filter(Boolean))].map(f=>[f,score(rows.filter(r=>r.split===f))]))};
}
function options(args){
 const o={files:[],repeat:1,engine:null,json:false,preview:false,details:false};
 const values=new Set(['--engine','--repeat','--text','--file','--expect','--suite','--output','--ruleset','--corpus']);
 const seen=new Set();
 while(args.length){const key=args.shift();
  if(!values.has(key)&&!['--json','--preview','--stdin','--details','--verbose'].includes(key))throw Error('unknown option');
  if(key!=='--file'&&seen.has(key))throw Error('duplicate option');seen.add(key);
  const value=values.has(key)?args.shift():true;
  if(value===undefined)throw Error('missing option value');
  if(key==='--file')o.files.push(value);else o[key.slice(2)]=value;
 }
 o.repeat=Number(o.repeat);
 if(!Number.isInteger(o.repeat)||o.repeat<1||o.repeat>LIMITS.repetitions)throw Error('repeat must be 1–5');
 if(o.expect&&!['benign','malicious'].includes(o.expect))throw Error('invalid expected label');
 if(o.engine&&!['dumb','smart','both','model'].includes(o.engine))throw Error('invalid engine');
 return o;
}
function decode(raw){
 if(raw.length>LIMITS.bodyBytes)throw Error('input_too_large');
 if(!raw.length)throw Error('empty_input');
 let text;try{text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(raw);}catch{throw Error('invalid_utf8');}
 if(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(text))throw Error('binary_input');
 return text;
}
function readFile(file){
 const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NONBLOCK|fs.constants.O_NOFOLLOW);
 try{
  const stat=fs.fstatSync(fd);if(!stat.isFile())throw Error('not_regular_file');
  const buffer=Buffer.alloc(LIMITS.bodyBytes+1);let n=0,count;
  while(n<buffer.length&&(count=fs.readSync(fd,buffer,n,buffer.length-n,null))>0)n+=count;
  return decode(buffer.subarray(0,n));
 }finally{fs.closeSync(fd);}
}
async function readStdin(){
 return new Promise((resolve,reject)=>{let chunks=[],size=0;
  const stop=(err)=>{clearTimeout(timer);process.stdin.removeAllListeners('data');process.stdin.removeAllListeners('end');process.stdin.destroy();err?reject(err):resolve(Buffer.concat(chunks));};
  const timer=setTimeout(()=>stop(Error('stdin_deadline')),LIMITS.smartMs);
  process.stdin.on('data',chunk=>{size+=chunk.length;if(size>LIMITS.bodyBytes)stop(Error('input_too_large'));else chunks.push(chunk);});
  process.stdin.once('end',()=>stop());process.stdin.once('error',()=>stop(Error('input_read_failed')));
 });
}
function safeError(e){if(e.code==='ELOOP')return 'not_regular_file';return ['empty_input','input_too_large','invalid_utf8','binary_input','not_regular_file','stdin_deadline'].includes(e.message)?e.message:'input_read_failed';}
// JSON quoting makes untrusted content inert while preserving its full text.
const display=value=>JSON.stringify(value??'unknown');
export function human(report){
 const lines=[`Antenna MCS ${report.command}${report.preview?' preview':''} — ${report.engine}${report.scanner?' ('+display(report.scanner.model)+')':''}`];
 if(report.preview)return lines.concat(`Cases: ${report.plan.cases}; repetitions: ${report.plan.repetitions}; maximum model requests: ${report.plan.maxRequests}`,report.disclosure).join('\n')+'\n';
 if(report.command==='evaluate'){
  for(let repetition=1;repetition<=report.plan.repetitions;repetition++){
   const rows=report.results.filter(r=>r.repetition===repetition),s=summarize(rows),v=s.score;
   if(report.plan.repetitions>1)lines.push(`Repetition ${repetition}/${report.plan.repetitions} (${s.uniqueCases} unique cases)`);
   lines.push(`Attacks caught: ${v?.malicious?v.detected+'/'+v.malicious:'N/A (0 malicious cases)'}`,
    `False positives: ${v?.benign?v.falseFlags+'/'+v.benign:'N/A (0 benign cases)'}`,
    `Incomplete scans: ${s.incomplete}`,`Model requests: ${s.requests}`);
  }
 }else for(const r of report.results)lines.push(`${display(r.id)} #${r.repetition}: ${r.outcome}${r.reason?' — '+display(r.reason):''} ${JSON.stringify({source:r.source,bodyDigest:r.bodyDigest,elapsedMs:r.elapsedMs,findings:r.findings})}`);
 if(report.verbose){
  const groups=[['ATTACKS MISSED',r=>r.expected==='malicious'&&r.verdict==='pass'],['FALSE POSITIVES',r=>r.expected==='benign'&&r.verdict==='flagged'],['INCOMPLETE SCANS',r=>r.verdict==='incomplete']];
  for(const [title,filter] of groups){
   const rows=report.results.filter(filter);if(!rows.length)continue;
   lines.push('',title);
   for(const r of rows){
    lines.push('',`ID: ${display(r.id)}${report.plan.repetitions>1?' (repetition '+r.repetition+')':''}`);
    if(title==='ATTACKS MISSED')lines.push(`Type: ${display(r.family)}`);
    if(title!=='INCOMPLETE SCANS')lines.push(`Content: ${display(r.body)}`);
    if(title==='FALSE POSITIVES'){
     lines.push(`Scanner: ${r.stage==='smart'?'Smart':'Dumb'}`);
     for(const f of r.findings)lines.push(`${f.id?'Rule: '+display(f.id):'Finding: '+display(f.category)} — ${display(f.reason)}`);
    }
    if(title==='INCOMPLETE SCANS')lines.push(`Reason: ${display(r.error??r.reason??'scanner_incomplete')}`);
   }
  }
 }
 return lines.join('\n')+'\n';
}
export function loadCorpus(file){
 const fd=fs.openSync(file??new URL('./corpus/controls.json',import.meta.url),fs.constants.O_RDONLY|fs.constants.O_NONBLOCK|fs.constants.O_NOFOLLOW);
 let bytes;
 try{
  const stat=fs.fstatSync(fd);if(!stat.isFile())throw Error('corpus must be a regular file');
  if(stat.size>LIMITS.corpusBytes)throw Error('corpus exceeds 4 MiB');
  const buffer=Buffer.alloc(LIMITS.corpusBytes+1);let n=0,k;
  while(n<buffer.length&&(k=fs.readSync(fd,buffer,n,buffer.length-n,null)))n+=k;
  if(n>LIMITS.corpusBytes)throw Error('corpus exceeds 4 MiB');bytes=buffer.subarray(0,n);
 }finally{fs.closeSync(fd);}
 let data;try{data=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));}catch{throw Error('corpus must be valid UTF-8 JSON');}
 if(!data||data.schema!==1||!Array.isArray(data.cases)||!data.cases.length||data.cases.length>LIMITS.batchCases)throw Error('corpus requires schema 1 and 1–500 cases');
 const ids=new Set();
 for(const [i,item] of data.cases.entries()){
  const fail=reason=>{throw Error(`corpus case ${i+1}: ${reason}`);};
  if(!item||typeof item.id!=='string'||! /^[A-Za-z0-9_-]{1,128}$/.test(item.id)||ids.has(item.id))fail('unique ID required (1–128 letters, digits, underscores or hyphens)');ids.add(item.id);
  if(typeof item.family!=='string'||!item.family.trim()||item.family.length>128)fail('family must be 1–128 characters');
  if(!['malicious','benign','ambiguous'].includes(item.expected))fail('expected must be malicious, benign or ambiguous');
  if(typeof item.body!=='string')fail('body must be text');
  if(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(item.body))fail('body contains an unpaired Unicode surrogate');
  try{decode(Buffer.from(item.body));}catch(e){fail(e.message);}
 }
 return {cases:data.cases,metadata:{version:data.version??null,sha256:hash(bytes),provenance:data.provenance??null,source:file??'bundled',schema:1}};
}
export async function runDiagnostic(command,args,c,host,{configPath,stdout=console.log,stderr=console.error,scanModel=gatewayScan}={}){
 let o;try{o=options([...args]);if(!['evaluate','test'].includes(command))throw Error('evaluate or test required');
  if(command==='evaluate'&&(o.text!==undefined||o.files.length||o.stdin||o.expect))throw Error('evaluation takes corpus cases, not text/file/stdin inputs');
  if(command==='test'&&(Number(o.text!==undefined)+Number(o.files.length>0)+Number(!!o.stdin)!==1||o.suite||o.corpus))throw Error('choose exactly one of text, files, stdin');
  if(o.suite&&o.corpus)throw Error('choose --suite bundled or --corpus, not both');
  if(o.suite&&o.suite!=='bundled')throw Error('only bundled suite supported');
  if(o.files.length>LIMITS.batchCases)throw Error('too many files');
 }catch(e){stderr(JSON.stringify({status:'input_error',reason:e.message}));return 64;}
 const engine=o.engine??(command==='evaluate'?'smart':'dumb');
 let corpus,cases;
 if(command==='evaluate'){
  try{const loaded=loadCorpus(o.corpus);cases=loaded.cases;corpus=loaded.metadata;}catch(e){stderr(JSON.stringify({status:'input_error',reason:e.code==='ENOENT'?`No diagnostic corpus found. Download the default corpus from ${DEFAULT_CORPUS_URL}, then use --corpus /path/controls.json.`:e.code==='ELOOP'?'corpus must not be a symlink':e.code?'corpus file unavailable ('+e.code+')':e.message}));return 64;}
 }else{
  cases=o.files.length?o.files.map((file,i)=>({id:'file-'+(i+1),source:file})): [{id:o.stdin?'stdin':'text'}];
  for(const item of cases){item.expected=o.expect;item.labelProvenance=o.expect?'operator batch label':'unlabelled';
   if(o.preview)continue;
   try{item.body=o.files.length?readFile(item.source):decode(o.stdin?await readStdin():Buffer.from(o.text));}catch(e){item.error=safeError(e);}
  }
 }
 if(cases.length>LIMITS.batchCases){stderr(JSON.stringify({status:'input_error',reason:'case limit exceeded'}));return 64;}
 const model=engine!=='dumb';let p,ruleset;
 if(['smart','model'].includes(engine)&&o.ruleset){stderr(JSON.stringify({status:'input_error',reason:'--ruleset applies only to Dumb or Both'}));return 64;}
 try{if(engine==='dumb'||engine==='both')ruleset=loadRuleset(o.ruleset??c.rulesetFile);if(model&&c.scannerModel)p=resolveScanner(c.scannerModel,host);}catch(e){stderr(JSON.stringify({status:'configuration_error',reason:e.message}));return 3;}
 const report={schema:1,command,engine,preview:o.preview,startedAt:new Date().toISOString(),plan:{cases:cases.length,repetitions:o.repeat,maxRequests:model?cases.length*o.repeat:0,order:'corpus/file order; serial; no randomization',limits:LIMITS},corpus:corpus??null,scanner:p?{model:p.modelId,identity:p.identity,ready:p.identity===c.scannerIdentity}:null,rules:ruleset?.hash??null,rubric:RUBRIC,verdictSchema:1,implementation:Object.fromEntries(knownSources.map(f=>[f,hash(fs.readFileSync(new URL(f,import.meta.url)))])),disclosure:model?'Smart/model/Both may send supplied bodies to the selected registered model. No delivery, policy change or inbox insertion.':'Offline Dumb scan. No delivery, policy change or inbox insertion.',verbose:!!o.verbose,details:o.verbose?'Verbose failures include submitted content; exports are private.':o.details?'Detailed findings may include submitted text; exports are private.':'Bodies, raw responses and finding explanations omitted.',results:[]};
 if(o.preview){stdout(o.json?JSON.stringify(report):human(report));return 0;}
 if(model&&((!p||p.identity!==c.scannerIdentity))){stderr(JSON.stringify({status:'configuration_error',reason:'selected scanner missing or unvalidated; use check/select',plan:report.plan}));return 3;}
 if(o.output){try{fs.mkdirSync(o.output,{mode:0o700});}catch{stderr(JSON.stringify({status:'input_error',reason:'output must be a new directory under an existing parent'}));return 64;}}
 const resourceDir=capacityDirectory(path.dirname(c.inboxFile));
 const smart=model?body=>scanModel(host,p,body):undefined;
 const flow=new ReceiveFlow({dumb:body=>scanDumb(body,{resourceDir,ruleset}),smart});
 const began=performance.now();
 for(let repetition=1;repetition<=o.repeat;repetition++)for(const item of cases){
  const start=performance.now();let result;
  if(item.error)result={verdict:'incomplete',reason:item.error};
  else result=await flow.scan({body:item.body},{mode:engine==='model'?'smart':engine});
  const row={id:item.id,source:item.source,expected:item.expected,labelProvenance:item.labelProvenance??(o.corpus?'operator corpus label':'bundled control intent'),family:item.family,split:item.split,repetition,bodyDigest:item.body===undefined?null:hash(item.body),bodyBytes:item.body===undefined?null:Buffer.byteLength(item.body),verdict:result.verdict,error:item.error,reason:result.reason,stage:result.stage,modelSkipped:model&&result.stage!=='smart',requests:result.requests??0,usage:result.usage,returnedModel:result.returnedModel,elapsedMs:performance.now()-start,outcome:result.verdict==='pass'?'Would pass MCS':result.verdict==='flagged'?'Would hold':'Scan incomplete',findings:result.findings?.map(f=>o.details||o.verbose?f:{id:f.id,category:f.category})??[]};
  if(o.verbose&&((item.expected==='malicious'&&result.verdict==='pass')||(item.expected==='benign'&&result.verdict==='flagged')))row.body=item.body;
  report.results.push(row);
 }
 report.finishedAt=new Date().toISOString();report.elapsedMs=performance.now()-began;report.summary=summarize(report.results);
 if(o.output){fs.writeFileSync(path.join(o.output,'report.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});fs.writeFileSync(path.join(o.output,'report.txt'),human(report),{flag:'wx',mode:0o600});}
 stdout(o.json?JSON.stringify(report):human(report));
 if(command==='evaluate')return 0;
 return cases.some(x=>x.error)?64:report.results.some(x=>x.verdict==='incomplete')?3:report.results.some(x=>x.verdict==='flagged')?2:0;
}
