import {validateConfig} from '../plugin/policy.mjs';
export function migrate(input){
 if(input.schemaVersion===2)return validateConfig(input);
 if(input.schemaVersion!==1||input.policyRevision!=='combined-smart-v1')throw Error('unknown legacy schema; manual migration required');
 const c=structuredClone(input);
 if(c.mcs==='smart')c.mcs='both';
 for(const p of Object.values(c.peers??{}))if(p.mcs==='smart')p.mcs='both';
 c.schemaVersion=2;c.policyRevision='four-modes-v2';
 return validateConfig(c);
}
