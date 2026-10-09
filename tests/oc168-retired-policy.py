"""Verify installed shared policy is read-only, without contacting a gateway."""
import ast,json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
helper=ROOT/'lib/session_policy.py'
with tempfile.TemporaryDirectory(prefix='antenna-retired-policy-') as temp:
    root=Path(temp);config=root/'config.json';config.write_text('{"unchanged":true}')
    jq=root/'jq';jq.write_text('#!/bin/sh\nprintf called > '+str(root/'called')+'\n');jq.chmod(0o700)
    for action in ['mutate','initialize','sessions','stage-queue']:
        r=subprocess.run(['python3',str(helper),str(config),action,'. + {"unexpected":true}'],input='{}',text=True,capture_output=True,env={**os.environ,'PATH':str(root)+':'+os.environ['PATH']},timeout=5)
        assert r.returncode==1 and 'retired' in r.stderr,(action,r.stdout,r.stderr)
        assert config.read_text()=='{"unchanged":true}' and not (root/'called').exists()
    functions={n.name for n in ast.parse(helper.read_text()).body if isinstance(n,ast.FunctionDef)}
    assert not functions.intersection({'mutate','write','sessions','stage_queue','transition','project_modes'})
    assert {'validate','read','resolve','validate_queue'}.issubset(functions)
print('PASS four retired policy actions refuse; no jq execution or state change; shared readers remain')
