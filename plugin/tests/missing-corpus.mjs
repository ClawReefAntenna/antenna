import assert from 'node:assert/strict';
import fs from 'node:fs';
import {runDiagnostic,DEFAULT_CORPUS_URL} from '../evaluation.mjs';
const root=fs.mkdtempSync('/tmp/antenna-missing-corpus-');
try{
 let err='',calls=0;
 const status=await runDiagnostic('evaluate',['--engine','dumb','--corpus',root+'/absent.json'],{}, {},{stderr:value=>err=value,scanModel:()=>{calls++;}});
 assert.equal(status,64);assert.equal(calls,0);
 assert.match(err,/No diagnostic corpus found/);assert.ok(err.includes(DEFAULT_CORPUS_URL));assert.match(err,/--corpus/);
 console.log('PASS missing corpus gives ClawReef link and explicit file instruction without scanning');
}finally{fs.rmSync(root,{recursive:true,force:true});}
