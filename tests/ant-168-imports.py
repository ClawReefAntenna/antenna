"""Focused import provenance/cache and registration/report storage checks."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from types import SimpleNamespace as NS
from unittest.mock import patch
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'lib'))
import session_policy
import clawreef_registration
import clawreef_reports
with tempfile.TemporaryDirectory() as temp:
 d=Path(temp);d.chmod(0o700)
 # CWD/PYTHONPATH decoys must never shadow installed modules, including via CLI link.
 for name in ('session_policy','clawreef_registration','clawreef_reports','clawreef_groups','clawreef_http'):
  (d/(name+'.py')).write_text("raise RuntimeError('SHADOW MODULE')\n")
 link=d/'antenna';link.symlink_to(ROOT/'bin/antenna.sh')
 env={**os.environ,'PYTHONPATH':str(d)}
 r=subprocess.run([str(link),'clawreef','--help'],cwd=d,env=env,capture_output=True,text=True);assert r.returncode==0,r.stderr
 # Legacy rollback projection is source-only, not part of native installables.
 if (ROOT/'scripts/antenna-policy-export.py').exists():
     r=subprocess.run([sys.executable,str(ROOT/'scripts/antenna-policy-export.py'),'--help'],cwd=d,env=env,capture_output=True,text=True);assert r.returncode==0,r.stderr
 # Force the CLI's deferred import from a foreign CWD/environment too.
 script="import runpy; p=runpy.run_path("+repr(str(ROOT/'scripts/antenna-clawreef.py'))+"); m=p['policy_module'](); assert m.__file__=="+repr(str(ROOT/'lib/session_policy.py'))
 r=subprocess.run([sys.executable,'-c',script],cwd=d,env=env,capture_output=True,text=True);assert r.returncode==0,r.stderr
 assert not list(d.rglob('*.pyc'))
 print('PASS installed module provenance from foreign CWD/PYTHONPATH and CLI symlink; no bytecode')
 cfg=d/'config.json';cfg.write_text('{"revision":1}');assert session_policy.read(cfg)['revision']==1
 cfg.write_text('{"revision":2}');assert session_policy.read(cfg)['revision']==2
 print('PASS cached module rereads mutable state')
 class Failure(Exception):pass
 def fail(ok,*args,**kwargs):
  if not ok:raise Failure(args)
 cli=NS(ROOT=d,fingerprint=lambda _: 'fixture',fail=fail,Failure=Failure)
 client=clawreef_registration.Registration(cli,'https://fixture.invalid',(None,{}, {},'fixture',[]))
 assert Path(client.http.__file__)==ROOT/'lib/clawreef_http.py'
 client.directory.mkdir(mode=0o700);client.write({'schema_version':1,'service_origin':client.service,'peer_name':'fixture','key_id':client.key_id,'host_id':'11111111-1111-4111-8111-111111111111','state':'active'})
 assert client.read()['state']=='active'
 print('PASS conventional registration/HTTP imports retain private state round trip')
 calls=[]
 client.transport_ready=lambda:None
 client.request=lambda *args,**kw: calls.append(args) or {'ok':True}
 options=NS(group_command='submit',session=None,name=None,slug=None,description=None,theme=None,query=None,alias=None,after=None,reason_stdin=True,request_id=None,group_id='22222222-2222-4222-8222-222222222222')
 with patch.object(sys,'stdin',NS(buffer=io.BytesIO(b'Private fixture reason'))):first=clawreef_reports.run(client,options)
 with patch.object(sys,'stdin',NS(buffer=io.BytesIO(b'Private fixture reason'))):second=clawreef_reports.run(client,options)
 assert first[0]==second[0]=='REPORT_SUBMITTED'
 assert calls[0][2]['id']==calls[1][2]['id']
 record=next(client.directory.glob('report-*.json'));assert 'Private fixture reason' not in record.read_text();assert record.stat().st_mode&0o777==0o600
 print('PASS report/group import preserves private storage and stable retry identity')
