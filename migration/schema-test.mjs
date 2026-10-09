import assert from 'node:assert/strict';
import {migrate} from './schema.mjs';
const v={schemaVersion:1,policyRevision:'combined-smart-v1',receiver:'test',bearer:'x'.repeat(32),mcs:'smart',peers:{peer:{publicKey:'fixture',destinations:['work'],mcs:'smart'}},destinations:{work:'agent:test:work'},inboxFile:'/tmp/test-inbox',replayFile:'/tmp/test-replay'};
const out=migrate(v);assert.equal(out.schemaVersion,2);assert.equal(out.mcs,'both');assert.equal(out.peers.peer.mcs,'both');assert.equal(v.schemaVersion,1);assert.equal(v.mcs,'smart');assert.deepEqual(migrate(out),out);assert.throws(()=>migrate({...v,schemaVersion:99}));console.log('PASS schema conversion copies input, preserves destination and rejects unknown schema');
const {policyFor}=await import('../plugin/inbox.mjs');
let cases=0;
for(const schemaVersion of [1,2])for(const inbox of ['on','off'])for(const global of [undefined,false,true])for(const peer of [undefined,false,true]){
 const c=structuredClone(v);c.schemaVersion=schemaVersion;c.inbox=inbox;
 if(global!==undefined)c.approvalByDestination={work:global};
 if(peer!==undefined)c.peers.peer.approvalByDestination={work:peer};
 const expected=policyFor(c,c.peers.peer,'work').approval,converted=migrate(c);
 assert.equal(policyFor(converted,converted.peers.peer,'work').approval,expected);
 assert.deepEqual(converted.destinations,c.destinations);cases++;
}
console.log(`PASS ${cases} native global/per-peer approval combinations across schema 1 and 2`);
