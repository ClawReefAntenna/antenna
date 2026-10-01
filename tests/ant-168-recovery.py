#!/usr/bin/env python3
"""Disposable state, real age prompts and no live dispatch."""
import json, os, runpy, sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode=True
base=runpy.run_path(str(Path(__file__).with_name('ant-167-recovery.py')))
B=base['B'];s=B['state'];snapshot=base['snapshot'];prompt_run=base['prompt_run']
class Recovery(unittest.TestCase):
    tearDown=base['Recovery'].tearDown
    write=base['Recovery'].write
    def setUp(self):
        base['Recovery'].setUp(self)
        self.config['transport_profile']='antenna-plugin-v2';self.write('antenna-config.json',s.encode(self.config))
        self.host=self.base/'host.json';s.HOST=self.host
        self.c={'schemaVersion':2,'receiver':'self','bearer':'p'*32,'peers':{},'destinations':{'work':'agent:test:main'},'mcs':'off','inbox':'on','inboxFile':str(self.base/'external-inbox.json'),'replayFile':str(self.base/'external-replay.json'),'rulesetFile':str(self.base/'rules.json')}
        self.h={'gateway':{'auth':{'token':'o'*32}},'hooks':{'enabled':True,'token':'p'*32},'unrelated':{'preserve':True},'plugins':{'entries':{'other':{'enabled':True},'antenna':{'enabled':True,'config':self.c}}}}
        self.host.write_bytes(s.encode(self.h));self.host.chmod(0o600)
        # Let the runtime construct authentic hashes; no scanner or dispatch.
        import subprocess
        subprocess.run(['node','--input-type=module','-e',"import {Inbox} from '"+(self.root/'plugin/inbox.mjs').as_uri()+"';const i=new Inbox(process.argv[1]);const r=i.create({from:'self',message_id:'11111111-1111-4111-8111-111111111111',body:'EXACT π 🦞\\n\\n'},'agent:test:main',{approval:true});i.change(r.id,x=>{x.state='held';x.reasons.push('MCS flagged');});",self.c['inboxFile']],check=True)
        Path(self.c['replayFile']).write_bytes(b'{"entries":[{"id":"11111111-1111-4111-8111-111111111111","peer":"self","seen":123}]}')
        Path(self.c['rulesetFile']).write_bytes((self.root/'plugin/rules/default.json').read_bytes())
    def archive(self):
        refs,files,_=s.capture(self.root);p=self.base/'snapshot.tar';B['write_archive'](p,self.root,files,refs);return B['load_archive'](p)
    def test_roundtrip_and_host_isolation(self):
        m,files,_=self.archive();self.assertNotIn('o'*32,b''.join(files.values()).decode())
        self.write('antenna-inbox.json',b'[]')
        original=Path(self.c['inboxFile']).read_bytes()
        plan,desired,prior,_,_,targets=B['restore_plan'](m,files,self.root)
        B['replace_state'](self.root,desired,prior,targets)
        h=json.loads(self.host.read_text());self.assertFalse(h['plugins']['entries']['antenna']['enabled']);self.assertEqual(h['gateway'],self.h['gateway']);self.assertEqual(h['unrelated'],self.h['unrelated']);self.assertEqual(h['plugins']['entries']['other'],self.h['plugins']['entries']['other'])
        self.assertEqual((self.root/'state/plugin-inbox.json').read_bytes(),original)
        self.assertEqual(Path(self.c['inboxFile']).read_bytes(),original)
        self.assertEqual((self.root/'state/plugin-replay.json').read_bytes(),files['state/plugin-replay.json'])
        self.assertEqual((self.root/'state/plugin-ruleset.json').read_bytes(),files['state/plugin-ruleset.json'])
        s.capture(self.root)
    def test_failures_before_writes(self):
        m,files,_=self.archive();before=snapshot(self.base)
        for mutate in ('legacy','bad-inbox','bad-replay','missing-key','traversal','operator'):
            with self.subTest(mutate=mutate):
                data=dict(files)
                if mutate=='legacy':
                    c=s.decode(data['antenna-config.json']);c.pop('transport_profile');data['antenna-config.json']=s.encode(c)
                if mutate=='bad-inbox':data['state/plugin-inbox.json']=b'{"schema":1,"items":[]}'
                if mutate=='bad-replay':data['state/plugin-replay.json']=b'{"entries":[{}]}'
                if mutate=='missing-key':data.pop('secrets/antenna-signing-private.pem')
                if mutate=='traversal':data['../bad']=b'bad'
                if mutate=='operator':
                    c=s.decode(data[s.PLUGIN]);c['bearer']='o'*32;data[s.PLUGIN]=s.encode(c)
                with self.assertRaises((s.StateError,KeyError)):B['restore_plan'](m,data,self.root)
                self.assertEqual(snapshot(self.base),before)
    def test_rollback_and_state_change(self):
        m,files,_=self.archive();self.write('antenna-inbox.json',b'[]')
        first=B['restore_plan'](m,files,self.root);before=snapshot(self.base);real=B['atomic'];hit=[]
        def fail(p,raw):
            if p==self.root/'antenna-inbox.json' and not hit:hit.append(True);raise OSError('fixture')
            real(p,raw)
        with patch.dict(B['replace_state'].__globals__,{'atomic':fail}):
            with self.assertRaises(s.StateError):B['replace_state'](self.root,first[1],first[2],first[5])
        self.assertEqual(snapshot(self.base),before)
        self.h['unrelated']['new']=1;self.host.write_bytes(s.encode(self.h));self.assertNotEqual(first,B['restore_plan'](m,files,self.root))
    def test_archive_legacy_and_links_rejected(self):
        import tarfile,io
        self.archive();p=self.base/'legacy.tar'
        with tarfile.open(p,'w') as t:
            raw=s.encode({'format_version':1,'state_schema':1,'producer_version':'1.6.7'});info=tarfile.TarInfo('manifest.json');info.size=len(raw);t.addfile(info,io.BytesIO(raw))
        with self.assertRaises(s.StateError):B['load_archive'](p)
        Path(self.c['inboxFile']).unlink();Path(self.c['inboxFile']).symlink_to(self.host)
        with self.assertRaises(s.StateError):s.capture(self.root)
    def test_busy_inbox_and_legacy_target(self):
        lock=Path(self.c['inboxFile']+'.lock');lock.mkdir()
        with self.assertRaises(s.StateError):
            with s.locks(self.root,[]):pass
        lock.rmdir();self.config.pop('transport_profile');self.write('antenna-config.json',s.encode(self.config))
        with self.assertRaises(s.StateError):s.capture(self.root)
    def test_interrupted_replacement_preserves_recovery_material(self):
        import subprocess
        self.archive();before=snapshot(self.base)
        driver=self.base/'crash.py'
        driver.write_text("import os,runpy,sys\nfrom pathlib import Path\nm=runpy.run_path(sys.argv[1]);s=m['state'];s.HOST=Path(sys.argv[3]);root=Path(sys.argv[2])\nmanifest,files,_=m['load_archive'](Path(sys.argv[4]));p=m['restore_plan'](manifest,files,root)\nreal=m['atomic']\ndef crash(path,raw):\n real(path,raw)\n if path==s.HOST:os._exit(91)\nm['replace_state'].__globals__['atomic']=crash\nm['replace_state'](root,p[1],p[2],p[5])\n")
        r=subprocess.run(['python3','-B',str(driver),str(self.root/'scripts/antenna-backup.py'),str(self.root),str(self.host),str(self.base/'snapshot.tar')],capture_output=True)
        self.assertEqual(r.returncode,91,r.stderr)
        retained=list(self.root.glob('.antenna-restore-*/rollback.json'));self.assertEqual(len(retained),1)
        for entry in json.loads(retained[0].read_text())['files']:
            if entry['backup'] is not None:
                n=str(Path(entry['path']).relative_to(self.base));self.assertEqual((retained[0].parent/entry['backup']).read_bytes(),before[n][0])
        self.assertFalse(json.loads(self.host.read_text())['plugins']['entries']['antenna']['enabled'])
    def test_archive_duplicate_and_program_payload_refused(self):
        import io,tarfile
        _,files,_=self.archive()
        for name in ('../escape','scripts/antenna-backup.py'):
            modified=dict(files);modified[name]=b'bad';p=self.base/'bad.tar'
            B['write_archive'](p,self.root,modified,{})
            with self.assertRaises(s.StateError):B['load_archive'](p)
        p=self.base/'duplicate.tar'
        with tarfile.open(p,'w') as t:
            for _ in range(2):
                item=tarfile.TarInfo('manifest.json');item.size=2;t.addfile(item,io.BytesIO(b'{}'))
        with self.assertRaises(s.StateError):B['load_archive'](p)
    def test_real_encryption_cli_cancel_restore(self):
        driver=self.base/'driver.py';driver.write_text("import runpy,sys\nfrom pathlib import Path\nsys.dont_write_bytecode=True\nroot=Path(sys.argv.pop(1))\nsys.path.insert(0,str(root/'lib'))\nimport antenna_plugin_state\nantenna_plugin_state.quiescent=lambda:None\nrunpy.run_path(str(root/'scripts/antenna-backup.py'),run_name='__main__')\n")
        call=lambda args,answers:prompt_run(['python3','-B',str(driver),str(self.root),*args,'--host',str(self.host)],answers)
        archive=self.base/'backup.age';secret=b'fixture-passphrase-only'
        rc,out=call(['create','--output',str(archive),'--json'],[secret,secret,secret]);self.assertEqual(rc,0,out);self.assertIn(b'BACKUP_VERIFIED',out)
        before=snapshot(self.base)
        rc,out=call(['restore',str(archive),'--to',str(self.root),'--apply'],[secret,b'n']);self.assertNotEqual(rc,0);self.assertIn(b'CANCELLED',out);self.assertEqual(snapshot(self.base),before)
        rc,out=call(['verify',str(archive)],[b'wrong']);self.assertNotEqual(rc,0)
        rc,out=call(['restore',str(archive),'--to',str(self.root),'--apply','--yes','--json'],[secret]);self.assertEqual(rc,0,out);self.assertIn(b'RESTORED',out);self.assertNotIn(secret,out);self.assertNotIn(b'EXACT',out);self.assertNotIn(b'SYNTHETIC-TOKEN',out)
if __name__=='__main__':unittest.main(verbosity=2)
