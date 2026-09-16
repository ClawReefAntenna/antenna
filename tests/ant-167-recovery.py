#!/usr/bin/env python3
"""Synthetic state only. Real age/openssl with PTY prompts; no live gateway sends."""
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import pty
import runpy
import select
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
sys.dont_write_bytecode=True
ROOT=Path(os.environ.get('ANT167_TEST_ROOT',Path(__file__).resolve().parents[1]))
sys.path.insert(0,str(ROOT/'lib'))
import antenna_state as s
B=runpy.run_path(str(ROOT/'scripts/antenna-backup.py'))
R=runpy.run_path(str(ROOT/'scripts/antenna-readiness.py'))


def snapshot(root):
    return {str(p.relative_to(root)):(p.read_bytes(),p.stat().st_mode) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}


def prompt_run(args,answers,timeout=35):
    pid,fd=pty.fork()
    if pid==0:
        os.execvp(args[0],args)
    output=b'';seen=0;start=time.monotonic();status=None
    try:
        while time.monotonic()-start<timeout:
            if select.select([fd],[],[],.1)[0]:
                try: chunk=os.read(fd,65536)
                except OSError: break
                if not chunk: break
                output+=chunk
                # age uses CR updates and /dev/tty; each prompt ends with ': '.
                count=output.count(b'Enter passphrase')+output.count(b'Confirm passphrase')+output.count(b'[y/N] ')
                while seen<count:
                    if seen>=len(answers): raise AssertionError('Unexpected prompt: '+output.decode(errors='replace'))
                    os.write(fd,answers[seen]+b'\n');seen+=1
            done,value=os.waitpid(pid,os.WNOHANG)
            if done: status=value;break
        if status is None:
            done,value=os.waitpid(pid,os.WNOHANG)
            if not done:
                os.kill(pid,signal.SIGKILL);_,value=os.waitpid(pid,0)
            status=value
        return os.waitstatus_to_exitcode(status),output
    finally: os.close(fd)


class Recovery(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='ant167-test-');self.base=Path(self.temp.name)
        self.root=self.base/'skill'
        shutil.copytree(ROOT,self.root,ignore=shutil.ignore_patterns('.git','__pycache__'))
        for d in self.root.rglob('*'):
            if d.is_dir(): d.chmod(0o700)
            elif d.is_file(): d.chmod(0o600)
        self.root.chmod(0o700)
        (self.root/'secrets').mkdir(mode=0o700)
        self.config=json.loads((ROOT/'antenna-config.example.json').read_text())
        self.config.update(local_agent_id='test',relay_agent_id='antenna',install_path=str(self.root),
            default_target_session='agent:test:main',allowed_inbound_sessions=['agent:test:main'],
            allowed_inbound_peers=['self'],allowed_outbound_peers=['self'])
        self.write('antenna-config.json',s.encode(self.config))
        def run(args): subprocess.run(args,check=True,capture_output=True)
        private=self.root/'secrets/antenna-signing-private.pem';public=self.root/'secrets/antenna-signing-public.pem'
        run(['openssl','genpkey','-algorithm','ED25519','-out',str(private)])
        run(['openssl','pkey','-in',str(private),'-pubout','-out',str(public)])
        key=self.root/'secrets/antenna-exchange.agekey'
        run(['age-keygen','-o',str(key)])
        pub=subprocess.check_output(['age-keygen','-y',str(key)]).strip()
        self.write('secrets/antenna-exchange.agepub',pub+b'\n')
        self.write('secrets/hooks_token_self',b'SYNTHETIC-TOKEN-ONLY')
        self.peer={'url':'https://fixture.invalid','self':True,'auth_mode':'ed25519-v1',
            'token_file':'secrets/hooks_token_self','signing_private_key_file':'secrets/antenna-signing-private.pem',
            'signing_public_key_file':'secrets/antenna-signing-public.pem','exchange_public_key':pub.decode()}
        self.write('antenna-peers.json',s.encode({'self':self.peer}))
        self.write('antenna-inbox.json',s.encode([{'ref':1,'status':'approved','body':'EXACT UTF8 π 🦞','from':'self','session_key':'agent:test:main'}]))
        self.write('antenna-ratelimit.json',b'{"self":[123]}')
        self.write('state/antenna-replay.json',b'{"entries":[]}')
        for f in (self.root/'secrets').iterdir(): f.chmod(0o600)

    def tearDown(self): self.temp.cleanup()
    def write(self,name,raw):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True,mode=0o700);p.write_bytes(raw);p.chmod(0o600)
    def archive(self):
        refs,files,_=s.capture(self.root)
        path=self.base/'snapshot.tar';B['write_archive'](path,self.root,files,refs)
        return B['load_archive'](path)
    def test_replace_missing_corrupt_and_remove(self):
        m,files,fps=self.archive()
        self.write('antenna-config.json',b'{broken')
        (self.root/'secrets/hooks_token_self').unlink()
        self.write('secrets/hooks_token_new',b'new')
        self.write('unrelated.txt',b'keep')
        self.write('antenna-inbox.json',b'[]')
        plan,desired,prior,_,_=B['restore_plan'](m,files,self.root)
        self.assertIn('secrets/hooks_token_new',plan['remove'])
        package=(self.root/'bin/antenna.sh').read_bytes()
        B['replace_state'](self.root,desired,prior)
        self.assertEqual((self.root/'antenna-inbox.json').read_bytes(),files['antenna-inbox.json'])
        self.assertFalse((self.root/'secrets/hooks_token_new').exists())
        self.assertEqual((self.root/'bin/antenna.sh').read_bytes(),package)
        self.assertEqual((self.root/'unrelated.txt').read_bytes(),b'keep')
        self.assertFalse(list(self.root.glob('.antenna-restore-*')))
    def test_rollback_on_write_failure(self):
        m,files,_=self.archive();self.write('antenna-inbox.json',b'[]')
        plan,desired,prior,_,_=B['restore_plan'](m,files,self.root)
        original=snapshot(self.root);atomic=B['atomic'];calls=[]
        def fail_once(path,raw):
            if path==self.root/'antenna-peers.json' and not calls:
                calls.append(True);raise OSError('disk full fixture')
            atomic(path,raw)
        with patch.dict(B['replace_state'].__globals__,atomic=fail_once):
            with self.assertRaises(s.StateError) as e:B['replace_state'](self.root,desired,prior)
        self.assertEqual(e.exception.code,'RESTORE_FAILED')
        self.assertEqual(snapshot(self.root),original)
    def test_retained_rollback_on_persistent_failure(self):
        m,files,_=self.archive();_,desired,prior,_,_=B['restore_plan'](m,files,self.root)
        atomic=B['atomic']
        def fail(path,raw):
            if path.parent==self.root: raise OSError('persistent fixture')
            atomic(path,raw)
        with patch.dict(B['replace_state'].__globals__,atomic=fail):
            with self.assertRaises(s.StateError) as e:B['replace_state'](self.root,desired,prior)
        self.assertEqual(e.exception.code,'ROLLBACK_REQUIRED')
        self.assertEqual(len(list(self.root.glob('.antenna-restore-*/rollback.json'))),1)
    def test_external_mapping_no_external_writes(self):
        external=self.base/'external-token';external.write_bytes(b'EXTERNAL-SYNTHETIC');external.chmod(0o600)
        self.peer['token_file']=str(external);self.write('antenna-peers.json',s.encode({'self':self.peer}))
        m,files,_=self.archive();plan,desired,prior,_,_=B['restore_plan'](m,files,self.root)
        self.assertTrue(plan['remappings']);B['replace_state'](self.root,desired,prior)
        self.assertEqual(external.read_bytes(),b'EXTERNAL-SYNTHETIC')
        peers=s.decode((self.root/'antenna-peers.json').read_bytes());self.assertTrue(peers['self']['token_file'].startswith('secrets/restored-'))
    def test_archive_rejects_traversal_links_duplicates_extras_digest(self):
        m,files,_=self.archive()
        for kind in ('traversal','link','duplicate','extra','digest','format','size'):
            path=self.base/(kind+'.tar')
            manifest=json.loads(json.dumps(m));payload=dict(files)
            if kind=='digest': payload['antenna-inbox.json']=b'[]'
            if kind=='format': manifest['format_version']=900
            if kind=='size': manifest['files'][0]['size']+=1
            with tarfile.open(path,'w') as tar:
                entries=[('manifest.json',s.encode(manifest))]+[('payload/'+n,r) for n,r in payload.items()]
                if kind=='duplicate': entries.append(entries[0])
                if kind=='extra': entries.append(('extra',b'x'))
                if kind=='traversal': entries.append(('../escape',b'x'))
                for name,raw in entries:
                    info=tarfile.TarInfo(name);info.size=len(raw);tar.addfile(info,io.BytesIO(raw))
                if kind=='link':
                    info=tarfile.TarInfo('link');info.type=tarfile.SYMTYPE;info.linkname='/tmp/no';tar.addfile(info)
            with self.subTest(kind=kind),self.assertRaises(s.StateError): B['load_archive'](path)
    def test_symlink_hardlink_and_unknown_refused(self):
        source=self.root/'secrets/hooks_token_self';raw=source.read_bytes();source.unlink();source.symlink_to('/etc/passwd')
        with self.assertRaises(s.StateError):s.capture(self.root)
        source.unlink();source.write_bytes(raw);source.chmod(0o600)
        os.link(source,self.base/'hardlink')
        with self.assertRaises(s.StateError):s.capture(self.root)
        (self.base/'hardlink').unlink();self.write('state/unknown.json',b'{}')
        with self.assertRaises(s.StateError):s.capture(self.root)
    def test_no_terminal_even_yes_and_json(self):
        before=snapshot(self.root)
        p=subprocess.run(['bash',str(self.root/'bin/antenna.sh'),'backup','restore','missing.age','--apply','--yes','--json'],start_new_session=True,capture_output=True,text=True)
        self.assertEqual(p.returncode,1);self.assertIn('TERMINAL_REQUIRED',p.stderr);self.assertEqual(snapshot(self.root),before)
    def test_lock_contention(self):
        with open(self.root/'antenna-inbox.json.lock','w') as f:
            fcntl.flock(f,fcntl.LOCK_EX)
            with self.assertRaises(s.StateError) as e:
                with s.locks(self.root,[self.root/'antenna-inbox.json']):pass
            self.assertEqual(e.exception.code,'BUSY')
    def test_size_and_key_mismatch(self):
        with patch.object(s,'MAX_TOTAL',10),self.assertRaises(s.StateError):s.capture(self.root)
        self.write('secrets/antenna-exchange.agepub',b'wrong')
        with self.assertRaises(s.StateError):s.capture(self.root)
    def test_real_age_encrypt_decrypt_and_wrong_password(self):
        self.archive();encrypted=self.base/'real.age';plain=self.base/'decoded.tar'
        args=['age','-p','-o',str(encrypted),str(self.base/'snapshot.tar')]
        rc,out=prompt_run(args,[b'test-only-passphrase',b'test-only-passphrase'])
        self.assertEqual(rc,0,out);self.assertNotIn(b'test-only-passphrase',out)
        rc,out=prompt_run(['age','-d','-o',str(plain),str(encrypted)],[b'test-only-passphrase'])
        self.assertEqual(rc,0,out);B['load_archive'](plain)
        rc,out=prompt_run(['age','-d','-o',str(self.base/'bad.tar'),str(encrypted)],[b'wrong-passphrase'])
        self.assertNotEqual(rc,0)
    def test_end_to_end_cli_and_cancel(self):
        # Only gateway inactivity is supplied by the isolated fixture. Production
        # CLI has no bypass; real cryptography, prompts, locks and replacement run.
        driver=self.base/'driver.py'
        driver.write_text("import runpy,sys\nfrom pathlib import Path\nsys.dont_write_bytecode=True\nroot=Path(sys.argv.pop(1))\nsys.path.insert(0,str(root/'lib'))\nimport antenna_state\nantenna_state.quiescent=lambda:None\nrunpy.run_path(str(root/'scripts/antenna-backup.py'),run_name='__main__')\n")
        archive=self.base/'backup.age'
        call=lambda args,answers:prompt_run(['python3','-B',str(driver),str(self.root),*args],answers)
        secret=b'fixture-passphrase-only'
        rc,out=call(['create','--output',str(archive),'--json'],[secret,secret,secret])
        self.assertEqual(rc,0,out);self.assertIn(b'BACKUP_VERIFIED',out)
        original=(self.root/'antenna-inbox.json').read_bytes()
        self.write('antenna-inbox.json',b'[]');(self.root/'antenna-config.json').unlink()
        rc,out=call(['restore',str(archive),'--to',str(self.root),'--json'],[secret])
        self.assertEqual(rc,0,out);self.assertIn(b'RESTORE_PREVIEW',out)
        self.assertFalse((self.root/'antenna-config.json').exists())
        before=snapshot(self.root)
        rc,out=call(['restore',str(archive),'--to',str(self.root),'--apply','--json'],[secret,b'n'])
        self.assertNotEqual(rc,0);self.assertIn(b'CANCELLED',out);self.assertEqual(snapshot(self.root),before)
        rc,out=call(['restore',str(archive),'--to',str(self.root),'--apply','--yes','--json'],[secret])
        self.assertEqual(rc,0,out);self.assertIn(b'RESTORED',out)
        self.assertEqual((self.root/'antenna-inbox.json').read_bytes(),original)
        self.assertNotIn(secret,out);self.assertNotIn(b'SYNTHETIC-TOKEN-ONLY',out)
        rc,out=call(['create','--output',str(archive)],[])
        self.assertNotEqual(rc,0);self.assertIn(b'OUTPUT_EXISTS',out)

    def test_gateway_process_detection(self):
        # A harmless local sleeper advertises the gateway process name.
        proc=subprocess.Popen(['bash','-c','exec -a openclaw-gateway sleep 20'])
        try:
            time.sleep(.1)
            with self.assertRaises(s.StateError) as e:s.quiescent()
            self.assertIn(e.exception.code,('GATEWAY_RUNNING','GATEWAY_UNKNOWN'))
        finally:proc.terminate();proc.wait()

    def test_archive_cannot_replace_program_file(self):
        self.config['inbox_queue_path']='scripts/antenna-backup.py'
        self.write('antenna-config.json',s.encode(self.config))
        with self.assertRaises(s.StateError):s.capture(self.root)

    def test_abrupt_interruption_retains_complete_displaced_state(self):
        driver=self.base/'crash.py'
        driver.write_text("import os,runpy,sys\nfrom pathlib import Path\nm=runpy.run_path(sys.argv[1]);root=Path(sys.argv[2]);s=m['state']\nrefs,files,_=s.capture(root);prior=dict(files);desired=dict(files);desired['antenna-inbox.json']=b'[]'\nreal=m['atomic']\ndef crash(path,raw):\n real(path,raw)\n if path==root/'antenna-inbox.json':os._exit(91)\nm['replace_state'].__globals__['atomic']=crash\nm['replace_state'](root,desired,prior)\n")
        before=snapshot(self.root)
        p=subprocess.run(['python3','-B',str(driver),str(self.root/'scripts/antenna-backup.py'),str(self.root)],capture_output=True)
        self.assertEqual(p.returncode,91,p.stderr)
        retained=list(self.root.glob('.antenna-restore-*/rollback.json'));self.assertEqual(len(retained),1)
        for entry in json.loads(retained[0].read_text())['files']:
            if entry['backup'] is not None:
                self.assertEqual((retained[0].parent/entry['backup']).read_bytes(),before[entry['path']][0])

    def test_external_public_pin_restores_into_runtime_trusted_keys(self):
        external=self.base/'external-public.pem';external.write_bytes((self.root/'secrets/antenna-signing-public.pem').read_bytes());external.chmod(0o600)
        peer={'url':'https://remote.invalid','auth_mode':'ed25519-v1','token_file':'secrets/hooks_token_self','signing_public_key_file':str(external)}
        self.write('antenna-peers.json',s.encode({'self':self.peer,'remote':peer}))
        m,files,_=self.archive();_,desired,prior,_,_=B['restore_plan'](m,files,self.root)
        B['replace_state'](self.root,desired,prior)
        restored=s.decode((self.root/'antenna-peers.json').read_bytes())['remote']['signing_public_key_file']
        self.assertTrue(restored.startswith('keys/'))
        p=subprocess.run(['bash','-c','source "$1/lib/antenna-signature.sh"; signature_public_key_ok "$1/$2" "$1/keys"','_',str(self.root),restored],capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr)

    def test_custom_queue_and_registration_roundtrip(self):
        self.config['inbox_queue_path']='queues/custom.json'
        self.write('antenna-config.json',s.encode(self.config))
        body=(self.root/'antenna-inbox.json').read_bytes()
        (self.root/'antenna-inbox.json').unlink();self.write('queues/custom.json',body)
        refs,files,_=s.capture(self.root)
        fps=s.validate_snapshot(self.root,files)[3]
        service='https://registry.invalid'
        self.write('.clawreef/'+s.digest(service.encode())+'.json',s.encode({'schema_version':1,'service_origin':service,'peer_name':'self','key_id':fps['self'],'host_id':'11111111-1111-4111-8111-111111111111','state':'active'}))
        m,files,_=self.archive();self.write('queues/custom.json',b'[]')
        _,desired,prior,_,_=B['restore_plan'](m,files,self.root)
        B['replace_state'](self.root,desired,prior)
        self.assertEqual((self.root/'queues/custom.json').read_bytes(),body)
        self.assertIn('.clawreef/'+s.digest(service.encode())+'.json',desired)

    def test_plaintext_legacy_inventory(self):
        self.peer['auth_mode']='plaintext-legacy'
        self.peer['peer_secret_file']='secrets/antenna-peer-self.secret'
        self.write('secrets/antenna-peer-self.secret',b'0'*64)
        self.write('antenna-peers.json',s.encode({'self':self.peer}))
        self.archive()

    def test_restore_target_changed_after_preview(self):
        m,files,_=self.archive();first=B['restore_plan'](m,files,self.root)
        self.write('antenna-inbox.json',b'[]')
        self.assertNotEqual(B['restore_plan'](m,files,self.root),first)

    def test_fresh_setup_and_v166_upgrade_snapshot(self):
        baseline=Path(os.environ.get('ANT167_BASELINE_ROOT',ROOT))
        clean=self.base/'fresh';shutil.copytree(baseline,clean,ignore=shutil.ignore_patterns('.git','__pycache__'))
        home=self.base/'home';binary=home/'bin';binary.mkdir(parents=True)
        (home/'.openclaw').mkdir()
        gateway=home/'.openclaw/openclaw.json';gateway.write_bytes(s.encode({'agents':{'list':[{'id':'test','workspace':str(home/'workspace')}]},'hooks':{'token':'SYNTHETIC-TOKEN-ONLY'}}))
        stub=binary/'openclaw';stub.write_text('#!/bin/bash\nif [[ "$1" == --version ]]; then echo "OpenClaw 2026.7.1"; elif [[ "$1 $2" == "config validate" ]]; then jq empty "$OPENCLAW_CONFIG_PATH"; else exit 0; fi\n');stub.chmod(0o700)
        token=home/'token';token.write_bytes(b'SYNTHETIC-TOKEN-ONLY');token.chmod(0o600)
        env={**os.environ,'HOME':str(home),'PATH':str(binary)+':'+os.environ['PATH'],'OPENCLAW_CONFIG_PATH':str(gateway)}
        p=subprocess.run(['bash',str(clean/'scripts/antenna-setup.sh'),'--host-id','fixture','--url','https://fixture.invalid','--token-file',str(token),'--agent-id','test','--model','openai/gpt-5.4','--inbox','false','--yes'],env=env,capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr+p.stdout)
        s.capture(clean) # Setup creates an unpaired self, not an invented auth mode.
        newer=self.base/'upgraded';shutil.copytree(ROOT,newer,ignore=shutil.ignore_patterns('.git','__pycache__'))
        # Synthetic source uses the unchanged v1.6.6 setup/state schema.
        oldbytes=snapshot(clean)
        p=subprocess.run(['bash',str(newer/'scripts/antenna-upgrade.sh'),'--from',str(clean),'--gateway',str(gateway),'--yes'],env=env,capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr+p.stdout)
        s.capture(newer)
        self.assertEqual(snapshot(clean),oldbytes)

    def test_missing_config_readiness_cli_is_read_only(self):
        (self.root/'antenna-config.json').unlink();before=snapshot(self.root)
        p=subprocess.run(['bash',str(self.root/'bin/antenna.sh'),'readiness','--json','--gateway',str(self.base/'absent')],capture_output=True,text=True)
        self.assertEqual(p.returncode,1,p.stderr)
        report=json.loads(p.stdout);self.assertTrue(report['complete'])
        self.assertEqual(snapshot(self.root),before)
        self.assertTrue(any(c['id']=='config_policy' and c['status']=='fail' for c in report['checks']))

    def test_readiness_readonly(self):
        gateway=self.base/'gateway.json';gateway.write_bytes(s.encode({'agents':{'entries':{'antenna':{'workspace':str(self.root/'agent')}}},
            'hooks':{'enabled':True,'allowedAgentIds':['antenna'],'allowRequestSessionKey':True,'allowedSessionKeyPrefixes':['hook:','agent:test:'],'token':'SYNTHETIC-TOKEN-ONLY'},
            'tools':{'sessions':{'visibility':'all'},'agentToAgent':{'enabled':True}}}));gateway.chmod(0o600)
        before=snapshot(self.root)
        result=R['report'](self.root,gateway)
        self.assertFalse(result['summary'].get('fail'),result)
        self.assertEqual(snapshot(self.root),before)
        raw=json.dumps(result);self.assertNotIn('SYNTHETIC-TOKEN-ONLY',raw);self.assertNotIn('EXACT UTF8',raw)
        out=io.StringIO()
        with contextlib.redirect_stdout(out):R['human'](result)
        self.assertIn('Remote-peer readiness: unknown',out.getvalue());self.assertNotIn('safe to upgrade',out.getvalue())
        self.assertNotIn('dependency_python3',out.getvalue())

if __name__=='__main__':unittest.main(verbosity=2)
