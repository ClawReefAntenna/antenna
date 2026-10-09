#!/usr/bin/env node
// Narrow schema conversion only; legacy staging/checking use plugin scripts.
import fs from 'node:fs';
import {migrate} from './schema.mjs';
import {Inbox} from '../plugin/inbox.mjs';
try{
 const [file,output]=process.argv.slice(2);
 if(!file)throw Error('Usage: node migration/cli.mjs HOST [NEW_POLICY_FILE]; never applies to host');
 const host=JSON.parse(fs.readFileSync(file,'utf8')),before=host.plugins?.entries?.antenna?.config;
 const next=migrate(before);new Inbox(next.inboxFile,{readOnly:true}).read();
 if(output)fs.writeFileSync(output,JSON.stringify(next,null,2)+'\n',{flag:'wx',mode:0o600});
 console.log(JSON.stringify({from:before.schemaVersion,to:next.schemaVersion,policyWritten:!!output,hostChanged:false,inbox:'preserved'}));
}catch(e){console.error(JSON.stringify({status:'blocked',reason:e instanceof SyntaxError?'invalid JSON input':e.message}));process.exitCode=1;}
