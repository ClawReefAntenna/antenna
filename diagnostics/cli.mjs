#!/usr/bin/env node
import fs from 'node:fs';
import {validateConfig} from '../plugin/policy.mjs';
import {runDiagnostic} from '../plugin/evaluation.mjs';
try {
 const [configPath,command,...args]=process.argv.slice(2);
 if(!configPath||!command)throw Error('Usage: node diagnostics/cli.mjs HOST evaluate|test [options]');
 const host=JSON.parse(fs.readFileSync(configPath,'utf8'));
 const c=validateConfig(host.plugins?.entries?.antenna?.config);
 process.exitCode=await runDiagnostic(command,args,c,host,{configPath});
}catch(e){console.error(JSON.stringify({status:'error',reason:e.message}));process.exitCode=1;}
