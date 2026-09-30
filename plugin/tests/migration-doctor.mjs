import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'antenna-doctor-test-'));
const write=(name,data)=>fs.writeFileSync(path.join(root,name),JSON.stringify(data),{mode:0o600});
fs.writeFileSync(path.join(root,'token'),'p'.repeat(32),{mode:0o600});
write('antenna-config.json',{transport_profile:'antenna-plugin-v2',relay_agent_id:'custom-relay'});
write('antenna-peers.json',{beta:{self:true,token_file:'token'}});
const host={gateway:{auth:{token:'o'.repeat(32)}},hooks:{enabled:true,token:'h'.repeat(32)},plugins:{allow:['antenna'],entries:{antenna:{enabled:true,config:{schemaVersion:2,receiver:'beta',bearer:'p'.repeat(32),peers:{},destinations:{work:'agent:probe:work'},mcs:'off',inbox:'on',maxBodyChars:4096,inboxFile:path.join(root,'inbox.json'),replayFile:path.join(root,'replay.json')}}}}};
const doctor=new URL('../migration-check.mjs',import.meta.url).pathname;
function check(name,agents,blocked){host.agents=agents;write('host.json',host);const r=spawnSync(process.execPath,[doctor,'doctor',path.join(root,'host.json'),root],{encoding:'utf8'});assert.equal(r.status,blocked?1:0,r.stderr);const v=JSON.parse(r.stdout);assert.equal(v.problems.some(x=>x.includes('legacy relay agent')),blocked);console.log('PASS '+name);}
check('legacy list relay detected',{list:[{id:'custom-relay'}]},true);
check('keyed entries relay detected',{entries:{'custom-relay':{}}},true);
check('mixed representation relay detected',{list:[{id:'other'}],entries:{'custom-relay':{}}},true);
check('unrelated keyed agent preserved',{entries:{other:{}}},false);
check('removed relay passes',{entries:{}},false);
