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
 const values=new Set(['--engine','--repeat','--text','--file','--expect','--suite','--output','--ruleset']);
 const seen=new Set();
 while(args.length){const key=args.shift();
  if(!values.has(key)&&!['--json','--preview','--stdin','--details'].includes(key))throw Error('unknown option');
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
export function human(report){
 const lines=[`Antenna MCS ${report.command}${report.preview?' preview':''}`,`Engine: ${report.engine}; cases: ${report.plan.cases}; repetitions: ${report.plan.repetitions}; maximum model requests: ${report.plan.maxRequests}`,`Model: ${JSON.stringify(report.scanner??'offline')}`,report.disclosure];
 if(report.summary){lines.push(JSON.stringify(report.summary));for(const r of report.results)lines.push(`${JSON.stringify(r.id)} #${r.repetition}: ${r.outcome}${r.error?' ('+r.error+')':''} ${JSON.stringify({source:r.source,bodyDigest:r.bodyDigest,elapsedMs:r.elapsedMs,findings:r.findings})}`);}
 return lines.join('\n')+'\n';
}
export async function runDiagnostic(command,args,c,host,{configPath,stdout=console.log,stderr=console.error,scanModel=gatewayScan}={}){
 let o;try{o=options([...args]);if(!['evaluate','test'].includes(command))throw Error('evaluate or test required');
  if(command==='evaluate'&&(o.text!==undefined||o.files.length||o.stdin||o.expect))throw Error('evaluation takes bundled cases, not custom inputs');
  if(command==='test'&&(Number(o.text!==undefined)+Number(o.files.length>0)+Number(!!o.stdin)!==1||o.suite))throw Error('choose exactly one of text, files, stdin');
  if(o.suite&&o.suite!=='bundled')throw Error('only bundled suite supported');
  if(o.files.length>LIMITS.batchCases)throw Error('too many files');
 }catch(e){stderr(JSON.stringify({status:'input_error',reason:e.message}));return 64;}
 const engine=o.engine??(command==='evaluate'?'smart':'dumb');
 let corpus,cases;
 if(command==='evaluate'){
  const bytes=fs.readFileSync(new URL('./corpus/controls.json',import.meta.url));corpus=JSON.parse(bytes);
  cases=corpus.cases;corpus={version:corpus.version,sha256:hash(bytes),provenance:corpus.provenance};
 }else{
  cases=o.files.length?o.files.map((file,i)=>({id:'file-'+(i+1),source:file})): [{id:o.stdin?'stdin':'text'}];
  for(const item of cases){item.expected=o.expect;item.labelProvenance=o.expect?'operator batch label':'unlabelled';
   if(o.preview)continue;
   try{item.body=o.files.length?readFile(item.source):decode(o.stdin?await readStdin():Buffer.from(o.text));}catch(e){item.error=safeError(e);}
  }
 }
 if(cases.length>LIMITS.batchCases){stderr(JSON.stringify({status:'input_error',reason:'case limit exceeded'}));return 64;}
 const model=engine!=='dumb';let p,ruleset;
 try{ruleset=loadRuleset(o.ruleset??c.rulesetFile);if(model&&c.scannerModel)p=resolveScanner(c.scannerModel,host);}catch(e){stderr(JSON.stringify({status:'configuration_error',reason:e.message}));return 3;}
 const report={schema:1,command,engine,preview:o.preview,startedAt:new Date().toISOString(),plan:{cases:cases.length,repetitions:o.repeat,maxRequests:model?cases.length*o.repeat:0,order:'corpus/file order; serial; no randomization',limits:LIMITS},corpus:corpus??null,scanner:p?{model:p.modelId,identity:p.identity,ready:p.identity===c.scannerIdentity}:null,rules:ruleset.hash,rubric:RUBRIC,verdictSchema:1,implementation:Object.fromEntries(knownSources.map(f=>[f,hash(fs.readFileSync(new URL(f,import.meta.url)))])),disclosure:model?'Smart/model/Both may send supplied bodies to the selected registered model. No delivery, policy change or inbox insertion.':'Offline Dumb scan. No delivery, policy change or inbox insertion.',details:o.details?'Detailed findings may include submitted text; exports are private.':'Bodies, raw responses and finding explanations omitted.',results:[]};
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
  const row={id:item.id,source:item.source,expected:item.expected,labelProvenance:item.labelProvenance??'bundled control intent',family:item.family,split:item.split,repetition,bodyDigest:item.body===undefined?null:hash(item.body),bodyBytes:item.body===undefined?null:Buffer.byteLength(item.body),verdict:result.verdict,error:item.error,reason:result.reason,stage:result.stage,modelSkipped:model&&result.stage!=='smart',requests:result.requests??0,usage:result.usage,returnedModel:result.returnedModel,elapsedMs:performance.now()-start,outcome:result.verdict==='pass'?'Would pass MCS':result.verdict==='flagged'?'Would hold':'Scan incomplete',findings:result.findings?.map(f=>o.details?f:{id:f.id,category:f.category})??[]};
  report.results.push(row);
 }
 report.finishedAt=new Date().toISOString();report.elapsedMs=performance.now()-began;report.summary=summarize(report.results);
 if(o.output){fs.writeFileSync(path.join(o.output,'report.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});fs.writeFileSync(path.join(o.output,'report.txt'),human(report),{flag:'wx',mode:0o600});}
 stdout(o.json?JSON.stringify(report):human(report));
 if(command==='evaluate')return 0;
 return cases.some(x=>x.error)?64:report.results.some(x=>x.verdict==='incomplete')?3:report.results.some(x=>x.verdict==='flagged')?2:0;
}
