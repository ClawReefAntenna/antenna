// Exercise actual CLI mutations with a fixture-only public gateway SDK. No model,
// live gateway, credentials or host configuration is used.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-cli-write-'));
try{
 const plugin=path.join(root,'plugin');fs.cpSync(new URL('..',import.meta.url),plugin,{recursive:true,filter:f=>!f.includes('/tests')&&!f.includes('/node_modules')});
 const sdk=path.join(plugin,'node_modules/openclaw');fs.mkdirSync(sdk,{recursive:true});
 fs.writeFileSync(path.join(sdk,'package.json'),JSON.stringify({type:'module',exports:{'./plugin-sdk/gateway-runtime':'./fixture.mjs'}}));
 fs.writeFileSync(path.join(sdk,'fixture.mjs'),"export async function callGatewayFromCli(){return {verdict:process.env.ANTENNA_FIXTURE_FAIL?'incomplete':'pass'};}\n");
 const hostFile=path.join(root,'host.json'),policyFile=path.join(root,'policy.json'),ruleFile=path.join(root,'rules.json');
 const host={gateway:{port:18789,auth:{token:'operator-fixture'}},agents:{defaults:{models:{'fixture/model':{alias:'scan'}}}},models:{providers:{fixture:{api:'openai-completions',baseUrl:'http://127.0.0.1:1',apiKey:'synthetic',models:[{id:'model'}]}}},unrelated:{retain:true}};
 fs.writeFileSync(hostFile,JSON.stringify(host),{mode:0o600});
 fs.writeFileSync(policyFile,JSON.stringify({schemaVersion:2,receiver:'test',bearer:'x'.repeat(32),peers:{},destinations:{},mcs:'off',inbox:'on',inboxFile:path.join(root,'inbox'),replayFile:path.join(root,'replay')}));
 fs.writeFileSync(ruleFile,JSON.stringify({formatVersion:1,rules:[{id:'ONE',pattern:'fixture',flags:'iu',explanation:'fixture only'}]}));
 const run=(args,fail=false)=>spawnSync(process.execPath,[path.join(plugin,'cli.mjs'),hostFile,...args],{encoding:'utf8',timeout:20000,maxBuffer:1024*1024,env:{...process.env,...(fail?{ANTENNA_FIXTURE_FAIL:'1'}:{})}});
 for(const args of [['init',policyFile],['mode','dumb'],['select','scan'],['mode','both'],['rules','select',ruleFile]]){
  const before=fs.readFileSync(hostFile,'utf8'),r=run(args);assert.equal(r.status,0,r.stderr);const result=JSON.parse(r.stdout);
  assert.equal(result.saved,true);assert.equal(fs.readFileSync(path.join(result.backup,'before.json'),'utf8'),before);
  const saved=JSON.parse(fs.readFileSync(hostFile));assert.equal(saved.plugins.entries.antenna.enabled,false);assert.deepEqual(saved.unrelated,host.unrelated);assert.deepEqual(saved.models,host.models);assert.deepEqual(saved.gateway,host.gateway);
 }
 const before=fs.readFileSync(hostFile,'utf8');assert.equal(run(['select','scan'],true).status,1);assert.equal(fs.readFileSync(hostFile,'utf8'),before);
 assert.equal(run(['mode','both']).status,0);assert.equal(JSON.parse(run(['mode','both']).stdout).saved,false);
 assert(!fs.existsSync(path.join(root,'inbox')));assert(!fs.existsSync(path.join(root,'replay')));
 console.log('PASS init/mode/select/rules: private preimages, unrelated fields, activation unchanged, rejected scanner leaves bytes unchanged, no-op and no inbox creation (fixture SDK)');
}finally{fs.rmSync(root,{recursive:true,force:true});}
