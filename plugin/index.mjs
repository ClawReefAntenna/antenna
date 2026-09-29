import {validateConfig} from './policy.mjs';
import {callGatewayFromCli} from 'openclaw/plugin-sdk/gateway-runtime';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {timingSafeEqual} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {makeFlow} from './runtime.mjs';
import {policyFor} from './inbox.mjs';
import {Refusal,parse,authenticate} from './envelope.mjs';
const exec=promisify(execFile),helper=fileURLToPath(new URL('./antenna-replay.sh',import.meta.url));
export default {id:'antenna',name:'Antenna',register(api){
 const c=validateConfig(api.pluginConfig);
 if(!['off','dumb','smart','both'].includes(c.mcs)||!['off','on'].includes(c.inbox)||!Number.isInteger(c.maxBodyChars)||c.maxBodyChars<1||c.maxBodyChars>1000000)throw new Error('Invalid prototype modes or body cap');
 const flow=makeFlow(c,api.config); flow.inbox.recover();
 let active=0;const arrivals=[];
 api.registerHttpRoute({path:'/antenna/v1/receive',auth:'plugin',handler:async(req,res)=>{
  let acquired=false,submissionAttempted=false;
  const send=(code,result)=>{res.statusCode=code;res.setHeader('Content-Type','application/json');res.end(JSON.stringify(result));return true;};
  const fail=(code,status,reason)=>{throw new Refusal(code,status,reason);};
  try{
   const auth=Buffer.from(req.headers.authorization??''),want=Buffer.from(`Bearer ${c.bearer}`);
   if(auth.length!==want.length||!timingSafeEqual(auth,want))fail(401,'rejected','unauthenticated');
   if(req.method!=='POST')fail(400,'rejected','malformed');
   if(!/^text\/plain\s*;\s*charset=utf-8$/i.test(req.headers['content-type']??'')||req.headers['content-encoding'])fail(415,'rejected','media_type');
   if(active>=2)fail(503,'unavailable','capacity');active++;acquired=true;
   const cap=4*c.maxBodyChars+4096;
   if(req.headers['content-length']&&Number(req.headers['content-length'])>cap)fail(413,'rejected','too_large');
   req.setTimeout(5000,()=>req.destroy());
   const chunks=[];let n=0;
   for await(const chunk of req){n+=chunk.length;if(n>cap)fail(413,'rejected','too_large');chunks.push(chunk);}
   req.setTimeout(0); // Body-read timeout must not shorten the bounded Smart scan.
   const fields=parse(Buffer.concat(chunks),c.maxBodyChars);
   let target=authenticate(fields,c);
   // Bounded qualification slice: existing 10/peer, 30/global per minute defaults.
   const now=Date.now();while(arrivals.length&&arrivals[0].at<=now-60000)arrivals.shift();
   if(arrivals.length>=30||arrivals.filter(x=>x.peer===fields.from).length>=10)fail(429,'rejected','rate_limited');
   arrivals.push({at:now,peer:fields.from});
   // Reuse the existing lock/atomic-file replay reservation, never a receipt store.
   try{await exec('bash',['-c','source "$1"; replay_reserve "$2" 360 240 "$3" "$4"','antenna-replay',helper,c.replayFile,fields.from,fields.message_id],{timeout:5000,maxBuffer:1024});}
   catch(e){if(e.code===2)fail(409,'rejected','replay');fail(503,'unavailable','capacity');}
   const opts={url:`ws://127.0.0.1:${api.config.gateway.port??18789}`,token:api.config.gateway.auth.token,timeout:'5000',json:true};
   const extra={scopes:['operator.read','operator.write'],progress:false};
   const found=await callGatewayFromCli('sessions.resolve',opts,{key:target,allowMissing:true},extra);
   if(!found.ok||found.key!==target)fail(503,'unavailable','runtime_unavailable');
   if(authenticate(fields,c)!==target)fail(403,'rejected','not_permitted');
   const result=await flow.receive(fields,target,policyFor(c,c.peers[fields.from],fields.target_session));
   return send(result.status==='unknown'?504:202,result);
  }catch(e){
   if(e instanceof Refusal)return send(e.code,e.result);
   return send(submissionAttempted?504:503,{status:submissionAttempted?'unknown':'unavailable',reason:submissionAttempted?'confirmation_unavailable':'runtime_unavailable'});
  }finally{if(acquired)active--;}
 }});
}};
