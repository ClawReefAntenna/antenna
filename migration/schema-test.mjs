import assert from 'node:assert/strict';
import {migrate} from './schema.mjs';
const v={schemaVersion:1,policyRevision:'combined-smart-v1',receiver:'test',bearer:'x'.repeat(32),mcs:'smart',peers:{peer:{publicKey:'fixture',destinations:['work'],mcs:'smart'}},destinations:{work:'agent:test:work'},inboxFile:'/tmp/test-inbox',replayFile:'/tmp/test-replay'};
const out=migrate(v);assert.equal(out.schemaVersion,2);assert.equal(out.mcs,'both');assert.equal(out.peers.peer.mcs,'both');assert.equal(v.schemaVersion,1);assert.equal(v.mcs,'smart');assert.deepEqual(migrate(out),out);assert.throws(()=>migrate({...v,schemaVersion:99}));console.log('PASS schema conversion copies input, preserves destination and rejects unknown schema');
