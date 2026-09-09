#!/usr/bin/env python3
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

SOURCE=Path(__file__).resolve().parents[1]
CONTRACT=json.loads((SOURCE/'lib/clawreef-contract.json').read_text())
class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)/'skill'
        for directory in ['bin','scripts','lib']:
            (self.root/directory).mkdir(parents=True)
        for file in ['bin/antenna.sh','scripts/antenna-clawreef.py','lib/session-policy.py','lib/clawreef-contract.json']:
            shutil.copyfile(SOURCE/file,self.root/file)
        self.calls=[]; outer=self
        self.body=CONTRACT;self.http=200;self.raw=None
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                outer.calls.append((self.command,self.path,dict(self.headers)))
                self.send_response(outer.http)
                if outer.http==302:self.send_header('Location','/must-not-follow')
                self.end_headers();self.wfile.write(outer.raw if outer.raw is not None else json.dumps(outer.body).encode())
            def do_POST(self):
                outer.calls.append(('POST',self.path,{}));self.send_response(500);self.end_headers()
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.service=f'http://127.0.0.1:{self.server.server_port}'
        self.env=dict(os.environ)
        self.env['PATH']=str(self.root/'bin')+':'+self.env['PATH']
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.tmp.cleanup()
    def call(self,*args):
        result=subprocess.run(['bash',str(self.root/'bin/antenna.sh'),'clawreef',*args,'--json'],
            env=self.env,capture_output=True,text=True)
        obj=json.loads(result.stdout)
        self.assertEqual(set(obj),{'schema_version','ok','code','message','data','request_id','correlation_id','retryable','next_action'})
        self.assertNotIn('\x1b',result.stdout+result.stderr)
        self.assertNotIn('SECRET-CANARY',result.stdout+result.stderr)
        return result.returncode,obj
    def setup_local(self):
        self.key='agent:betty:dashboard:12345678-abcd-1234-abcd-123456789abc'
        self.config={'local_agent_id':'betty','relay_agent_id':'antenna','allowed_inbound_sessions':[self.key],
            'session_policy_version':1,'session_policies':{self.key:{'entry_id':'12345678-abcd-1234-abcd-123456789abc','alias':'work','alias_revision':1,'inbox':False}}}
        (self.root/'antenna-config.json').write_text(json.dumps(self.config))
        (self.root/'antenna-peers.json').write_text(json.dumps({'my-host':{'self':True,'signing_public_key_file':'public.pem','hooks_token':'SECRET-CANARY'}}))
        subprocess.run(['openssl','genpkey','-algorithm','ed25519','-out',str(self.root/'private.pem')],check=True,capture_output=True)
        subprocess.run(['openssl','pkey','-in',str(self.root/'private.pem'),'-pubout','-out',str(self.root/'public.pem')],check=True,capture_output=True)
        stub=self.root/'bin/openclaw'
        stub.write_text('#!/usr/bin/env python3\nimport sys,json\np=json.loads(sys.argv[sys.argv.index("--params")+1])\nkey='+repr(self.key)+'\nif p.get("key")==key or p.get("shortId")=="12345678": print(json.dumps({"ok":True,"key":key,"agentId":"betty"}))\nelse: print("session not found",file=sys.stderr);sys.exit(1)\n')
        stub.chmod(0o755)
    def snapshot(self):
        return {str(p.relative_to(self.root)):(hashlib.sha256(p.read_bytes()).hexdigest(),p.stat().st_mode) for p in self.root.rglob('*') if p.is_file()}
    def test_before_setup_and_no_permission_healing(self):
        before=self.snapshot()
        status,obj=self.call('discover','--service',self.service)
        self.assertEqual(status,0);self.assertFalse(obj['data']['enrollment_checked'])
        self.assertEqual(self.snapshot(),before)
        self.assertEqual(len(self.calls),1);self.assertEqual(self.calls[0][1],CONTRACT['discovery_path'])
        self.assertNotIn('Authorization',self.calls[0][2]);self.assertNotIn('Cookie',self.calls[0][2])
        self.assertEqual(self.call('onboard','--request','groups.join')[1]['code'],'setup_required')
    def test_unsupported_and_malformed_servers(self):
        for field,value in [('api_version',2),('api_version',True),('minimum_client_version','1.6.7'),('maximum_client_major',0),('api_base','https://evil.invalid')]:
            self.body=copy.deepcopy(CONTRACT);self.body[field]=value
            self.assertEqual(self.call('discover','--service',self.service)[0],4)
        for raw in [b'<html>SECRET-CANARY</html>',b'[]',b'['*2000+b']'*2000,b'x'*65537]:
            self.raw=raw;self.assertEqual(self.call('discover','--service',self.service)[0],4)
    def test_redirect_access_gate_and_old_server(self):
        for http,exit_code in [(302,5),(401,5),(403,5),(404,4),(503,5)]:
            self.http=http;before=len(self.calls)
            self.assertEqual(self.call('discover','--service',self.service)[0],exit_code)
            self.assertEqual(len(self.calls),before+1)
    def test_arguments_are_safe(self):
        for args in [('enroll','SECRET-CANARY'),('discover','--token','SECRET-CANARY'),('discover','--service','https://user:SECRET-CANARY@example.test'),('discover','--service','https://example.test/path'),('discover','--service','http://example.test')]:
            self.assertNotEqual(self.call(*args)[0],0)
        self.assertEqual(self.calls,[])
    def test_onboard_canonical_alias_uuid_no_outreach_or_writes(self):
        self.setup_local();before=self.snapshot()
        der=subprocess.check_output(['openssl','pkey','-pubin','-in',str(self.root/'public.pem'),'-outform','DER'])
        for reference in [self.key,'agent:betty:work','12345678']:
            status,obj=self.call('onboard','--session',reference,'--request','groups.join','--service',self.service,'--local-only')
            self.assertEqual(status,0,obj);self.assertEqual(obj['data']['context']['canonical_session_key'],self.key)
            self.assertEqual(obj['data']['signing_fingerprint'],'sha256:'+hashlib.sha256(der).hexdigest())
            self.assertFalse(obj['data']['enrollment_created'])
        self.assertEqual(self.snapshot(),before);self.assertEqual(self.calls,[])
    def test_explicit_selection_and_invalid_contexts(self):
        self.setup_local();self.config['allowed_inbound_sessions']+=['agent:betty:main','agent:antenna:main','agent:betty:cron:12345678']
        (self.root/'antenna-config.json').write_text(json.dumps(self.config))
        self.assertEqual(self.call('onboard','--request','groups.join')[1]['code'],'session_selection_required')
        for ref in ['Friendly greeting','agent:antenna:main','agent:betty:cron:12345678','agent:betty:missing']:
            self.assertEqual(self.call('onboard','--session',ref,'--request','groups.join')[0],6)
        self.assertEqual(self.call('onboard','--actor','betty','--request','groups.join')[0],4)
        self.assertEqual(self.call('onboard','--session',self.key)[0],2)
    def test_status_no_false_enrollment_or_network(self):
        self.setup_local();before=self.snapshot()
        status,obj=self.call('status','--service',self.service)
        self.assertEqual(status,3);self.assertFalse(obj['data']['remote_checked'])
        self.assertEqual(self.calls,[]);self.assertEqual(self.snapshot(),before)
    def test_no_invented_key_or_self_and_unsupported_capability(self):
        self.setup_local()
        self.assertEqual(self.call('onboard','--request','admin')[0],2)
        (self.root/'public.pem').write_text('SECRET-CANARY')
        self.assertEqual(self.call('onboard','--request','groups.join')[0],3)
        (self.root/'antenna-peers.json').write_text('{"one":{"self":true},"two":{"self":true}}')
        self.assertEqual(self.call('status')[0],3)

if __name__=='__main__':unittest.main()
