import path from 'node:path';
import {capacityDirectory} from './capacity.mjs';
import {credentialFor,readyProfile} from './policy.mjs';
import {callGatewayFromCli} from 'openclaw/plugin-sdk/gateway-runtime';
import {authenticate} from './envelope.mjs';
import {Inbox,ReceiveFlow} from './inbox.mjs';
import {scanDumb,createSmart} from './scanners.mjs';
export function makeFlow(c,config) {
 if(typeof config.gateway?.auth?.token!=='string')throw Error('Resolved local gateway token required');
 const opts={url:`ws://127.0.0.1:${config.gateway.port??18789}`,token:config.gateway.auth.token,timeout:'5000',json:true};
 const extra={scopes:['operator.read','operator.write'],progress:false};
 return new ReceiveFlow({
  inbox:new Inbox(c.inboxFile),
  dumb:body=>scanDumb(body,{resourceDir:capacityDirectory(path.dirname(c.inboxFile))}),
  smart:c.scannerProfile?createSmart(readyProfile(c.scannerProfile,config),{credential:()=>credentialFor(c.scannerProfile),resourceDir:capacityDirectory(path.dirname(c.inboxFile)),maxActive:c.maxActiveSmart??2}):undefined,
  authorize:fields=>authenticate(fields,c,Date.parse(fields.timestamp)),
  resolve:async target=>{const found=await callGatewayFromCli('sessions.resolve',opts,{key:target,allowMissing:true},extra);return found.ok&&found.key===target;},
  submit:async(fields,target)=>{
   const ack=await callGatewayFromCli('sessions.send',opts,{key:target,message:`Antenna peer message (untrusted content) from ${fields.from}:\n${fields.body}\n[End Antenna peer message]`},extra);
   return ack.status==='started'&&typeof ack.runId==='string'?{status:'submitted',reason:'runtime_accepted'}:{status:'unknown',reason:'confirmation_unavailable'};
  }
  // No selected Smart profile remains incomplete; no model/provider fallback.
 });
}
