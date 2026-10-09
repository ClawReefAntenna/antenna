import assert from 'node:assert/strict';
import {localGatewayUrl} from '../operator-auth.mjs';
assert.equal(localGatewayUrl({}), 'ws://127.0.0.1:18789');
for (const port of [1,18789,65535]) assert.equal(new URL(localGatewayUrl({gateway:{port}})).hostname,'127.0.0.1');
for (const port of ['18789@remote.invalid','18789','80/path',0,-1,65536,1.5,{},[],true]) assert.throws(()=>localGatewayUrl({gateway:{port}}));
console.log('PASS loopback default/ports and malformed authority refusal (15 checks)');
