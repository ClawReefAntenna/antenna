#!/usr/bin/env python3
"""Focused readiness contract tests using disposable legacy state only."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import patch
sys.dont_write_bytecode=True
base=runpy.run_path(str(Path(__file__).with_name('ant-167-recovery.py')))
R=base['R'];s=base['s'];snapshot=base['snapshot']


class Readiness(unittest.TestCase):
    setUp=base['Recovery'].setUp
    tearDown=base['Recovery'].tearDown
    write=base['Recovery'].write

    def gateway(self):
        gateway=self.base/'gateway.json'
        gateway.write_bytes(s.encode({'agents':{'entries':{'antenna':{'workspace':str(self.root/'agent')}}},
            'hooks':{'enabled':True,'allowedAgentIds':['antenna'],'allowRequestSessionKey':True,'allowedSessionKeyPrefixes':['hook:','agent:test:'],'token':'SYNTHETIC-TOKEN-ONLY'},
            'tools':{'sessions':{'visibility':'all'},'agentToAgent':{'enabled':True}}}))
        gateway.chmod(0o600)
        return gateway

    def installed(self,version):
        package=self.base/'openclaw';package.mkdir(exist_ok=True)
        (package/'package.json').write_text(json.dumps({'name':'openclaw','version':version}))
        binary=package/'openclaw';binary.write_text('#!/bin/sh\nexit 99\n');binary.chmod(0o700)
        return binary

    def report(self,version='2026.9.5'):
        binary=self.installed(version);gateway=self.gateway();before=snapshot(self.base)
        which=R['shutil'].which;run=subprocess.run
        def local_only(args,*a,**kw):
            self.assertIn(args[0],('bash','openssl','age-keygen'))
            if args[0]=='bash': self.assertIn('relay_policy_audit',args[2])
            return run(args,*a,**kw)
        with patch.object(R['shutil'],'which',side_effect=lambda name:str(binary) if name=='openclaw' else which(name)),patch.object(subprocess,'run',side_effect=local_only):
            result=R['report'](self.root,gateway)
        self.assertEqual(before,snapshot(self.base))
        raw=json.dumps(result)
        for secret in ('SYNTHETIC-TOKEN-ONLY','EXACT UTF8','PRIVATE KEY'):self.assertNotIn(secret,raw)
        out=io.StringIO()
        with contextlib.redirect_stdout(out):R['human'](result)
        self.assertNotIn('SYNTHETIC-TOKEN-ONLY',out.getvalue())
        return {c['id']:c for c in result['checks']},result,out.getvalue()

    def test_installed_version_matrix(self):
        for version,status in [('2026.9.4','fail'),('2026.9.5','pass'),('2026.9.5-2','pass'),('2026.10.1','pass'),('2026.9.5+build.1','pass'),('2026.9.5-beta.1','unknown'),('bad','unknown'),(None,'unknown'),(42,'unknown')]:
            with self.subTest(version=version):
                checks,_,_=self.report(version)
                self.assertEqual(checks['plugin_openclaw_minimum']['status'],status)
                self.assertEqual(checks['running_gateway']['status'],'unknown')
                self.assertEqual(checks['remote_peers']['status'],'unknown')

    def test_inbox_statuses_and_empty(self):
        for statuses in [[],['delivered','denied'],['pending'],['approved'],['failed'],['pending','approved','failed','delivered']]:
            with self.subTest(statuses=statuses):
                self.write('antenna-inbox.json',s.encode([{'ref':i+1,'status':status,'body':'EXACT UTF8'} for i,status in enumerate(statuses)]))
                checks,_,human=self.report()
                unresolved=sum(x in ('pending','approved','failed') for x in statuses)
                self.assertEqual(checks['inbox']['unresolved'],unresolved)
                self.assertEqual(checks['inbox']['status'],'warn' if unresolved else 'pass')
                if unresolved:self.assertIn('not deliverable v1.6.8',human)

    def test_custom_inbox_and_invalid_state(self):
        self.config['inbox_queue_path']='queues/custom.json'
        self.write('antenna-config.json',s.encode(self.config))
        (self.root/'antenna-inbox.json').unlink()
        self.write('queues/custom.json',s.encode([{'ref':1,'status':'failed'}]))
        checks,_,_=self.report();self.assertEqual(checks['inbox']['unresolved'],1)
        self.write('queues/custom.json',b'{broken')
        checks,_,_=self.report();self.assertEqual(checks['identity_state']['status'],'fail')
        self.assertNotIn('inbox',checks)

    def test_rotation_warning_not_blocker(self):
        checks,result,_=self.report()
        self.assertEqual(checks['hooks_token_rotation']['status'],'warn')
        self.assertEqual(checks['hooks_token_rotation']['reason'],R['HOOKS_WARNING'])
        self.assertFalse(result['summary'].get('fail'),result)
        self.assertIn('v1.6.7 installations only',checks['backup']['next_action'])
        self.assertEqual(checks['migration']['status'],'unknown')

    def test_notice_states(self):
        original=json.loads((self.root/'references/upgrade-notice.json').read_text())
        for changes,status in [({},'warn'),({'announcement_at':'2026-10-01T00:00:00Z'},'unknown'),({'publication_at':'2026-10-08T00:00:00Z'},'unknown'),({'status':'published'},'unknown'),({'schema_version':2},'unknown'),({'next_version':'9.0'},'unknown')]:
            with self.subTest(changes=changes):
                self.write('references/upgrade-notice.json',s.encode({**original,**changes}))
                checks,_,_=self.report();self.assertEqual(checks['notice']['status'],status)
        self.write('references/upgrade-notice.json',b'{broken')
        checks,_,_=self.report();self.assertEqual(checks['notice']['status'],'unknown')
        (self.root/'references/upgrade-notice.json').unlink()
        checks,_,_=self.report();self.assertEqual(checks['notice']['status'],'unknown')

    def test_cli_exit_codes_and_readonly(self):
        gateway=self.gateway()
        for version,rc in [('2026.9.5',0),('2026.9.4',1),('unknown',0)]:
            binary=self.installed(version)
            env={**os.environ,'PATH':str(binary.parent)+':'+os.environ['PATH']}
            before=snapshot(self.base)
            p=subprocess.run(['bash',str(self.root/'bin/antenna.sh'),'readiness','--json','--gateway',str(gateway)],env=env,capture_output=True,text=True)
            self.assertEqual(p.returncode,rc,p.stderr+p.stdout)
            self.assertTrue(json.loads(p.stdout)['complete'])
            self.assertEqual(snapshot(self.base),before)
            self.assertNotIn('SYNTHETIC-TOKEN-ONLY',p.stdout+p.stderr)


if __name__=='__main__':unittest.main(verbosity=2)
