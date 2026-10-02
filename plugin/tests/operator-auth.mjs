import assert from 'node:assert/strict';
import {operatorAuth as resolve} from '../operator-auth.mjs';
const operatorAuth=(host,forbidden=[])=>resolve(host,forbidden,{});
const host=auth=>({gateway:{auth}});
assert.deepEqual(operatorAuth(host({token:'operator'})),{token:'operator'});
assert.deepEqual(operatorAuth(host({password:'operator'})),{password:'operator'});
assert.deepEqual(operatorAuth(host({mode:'password',token:'unused',password:'operator'})),{password:'operator'});
assert.deepEqual(operatorAuth(host({mode:'token',token:'operator',password:'unused'})),{token:'operator'});
for(const auth of [{},{token:''},{mode:'password',password:' '},{mode:'password',token:'fallback'},{mode:'token',password:'fallback'},{mode:'none'},{mode:'trusted-proxy'},{token:{source:'env',id:'SECRET'}},{mode:'password',password:{source:'env',id:'SECRET'}}]) assert.throws(()=>operatorAuth(host(auth)));
for(const mode of ['token','password']) assert.throws(()=>operatorAuth(host({mode,[mode]:'peer'}),['peer']));
console.log('PASS operator auth: token/password selection, no fallback or unresolved references, peer/operator separation');

for (const mode of ['token','password']) {
 const key=mode==='password'?'OPENCLAW_GATEWAY_PASSWORD':'OPENCLAW_GATEWAY_TOKEN';
 const other=mode==='password'?'OPENCLAW_GATEWAY_TOKEN':'OPENCLAW_GATEWAY_PASSWORD';
 assert.deepEqual(resolve(host({mode}),[],{[key]:'environment'}),{[mode]:'environment'});
 assert.deepEqual(resolve(host({mode,[mode]:'configured'}),[],{[key]:'environment'}),{[mode]:'configured'});
 assert.throws(()=>resolve(host({mode}),['peer'],{[key]:'peer'}));
 assert.throws(()=>resolve(host({mode}),[],{[other]:'wrong-mode'}));
 assert.throws(()=>resolve(host({mode,[mode]:{source:'env',id:'SECRET'}}),[],{[key]:'environment'}));
 assert.throws(()=>resolve(host({mode,[mode]:''}),[],{[key]:'environment'}));
}
console.log('PASS explicitly selected environment auth: precedence, mode isolation, unresolved-ref refusal, bearer separation');
