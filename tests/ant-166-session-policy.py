#!/usr/bin/env python3
"""Isolated policy + signed relay/queue tests; gateway is a recording fixture."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('policy', ROOT / 'lib/session-policy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
A = 'agent:betty:dashboard:11111111-1111-4111-8111-111111111111'
B = 'agent:betty:dashboard:22222222-2222-4222-8222-222222222222'
C = 'agent:vivian:dashboard:33333333-3333-4333-8333-333333333333'


def config():
    return {'local_agent_id': 'betty', 'allowed_inbound_sessions': [A, B, C],
            'default_target_session': A, 'allowed_inbound_peers': ['alice'],
            'inbox_auto_approve_peers': ['alice'], 'inbox_enabled': False, 'log_enabled': False}


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='antenna-166-')
        self.base = Path(self.temp.name)
        self.skill = self.base / 'skill'
        shutil.copytree(ROOT, self.skill, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        self.cfg = self.skill / 'antenna-config.json'
        self.cfg.write_text(json.dumps(config()))
        self.cfg.chmod(0o640)
        (self.skill / 'antenna-peers.json').write_text(json.dumps({'alice': {}}))
        self.state = self.base / 'gateway.json'
        self.state.write_text(json.dumps({'keys': [A, B, C, 'agent:betty:main'], 'short': True}))
        self.capture = self.base / 'sent.jsonl'
        binary = self.base / 'bin'
        binary.mkdir()
        stub = binary / 'openclaw'
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
s = json.loads(Path(os.environ['ANT166_GATEWAY']).read_text())
params = json.loads(args[args.index('--params') + 1])
if args[:3] == ['gateway','call','sessions.resolve']:
    if s.get('offline'):
        print('gateway timeout', file=sys.stderr); sys.exit(1)
    if 'shortId' in params:
        if not s['short']:
            print('unexpected property shortId', file=sys.stderr); sys.exit(1)
        matches = [k for k in s['keys'] if k.split(':')[-1].replace('-', '').startswith(params['shortId'])]
    else:
        matches = [k for k in s['keys'] if k == params['key']]
    if len(matches) != 1:
        print('No session found' if not matches else 'ambiguous', file=sys.stderr); sys.exit(1)
    print(json.dumps({'ok': True, 'key': matches[0], 'agentId': matches[0].split(':')[1]}))
elif args[:3] == ['gateway','call','sessions.send']:
    with open(os.environ['ANT166_CAPTURE'], 'a') as f:
        f.write(json.dumps(params) + '\\n')
    if s.get('revoke_after_send'):
        c = Path(os.environ['ANT166_CONFIG']); value=json.loads(c.read_text())
        value['allowed_inbound_peers']=[]; c.write_text(json.dumps(value))
    print(json.dumps({'status':'started','runId':'fixture'}))
else:
    print('Unexpected gateway operation', file=sys.stderr); sys.exit(1)
''')
        stub.chmod(0o700)
        self.env = {**os.environ, 'PATH': str(binary) + ':' + os.environ['PATH'],
                    'ANT166_GATEWAY': str(self.state), 'ANT166_CAPTURE': str(self.capture),
                    'ANT166_CONFIG': str(self.cfg), 'TMPDIR': str(self.base)}
        self.patch = patch.dict(os.environ, self.env)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def run_cli(self, *args, ok=True):
        r = subprocess.run(['bash', str(self.skill / 'bin/antenna.sh'), *args], env=self.env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, ok, (args, r.stdout, r.stderr))
        return r

    def helper(self, *args, data=None, ok=True):
        r = subprocess.run(['python3', str(self.skill / 'lib/session-policy.py'), str(self.cfg), *args],
                           input=data, env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, ok, (args, r.stdout, r.stderr))
        return r

    def allow(self, key=A, alias='ideas', inbox='yes'):
        self.run_cli('sessions', 'add', key, '--alias', alias, '--inbox', inbox, '--json')

    def edit_state(self, **values):
        s = p.read(self.state); s.update(values); self.state.write_text(json.dumps(s))

    def test_address_forms_and_matrix(self):
        self.allow()
        for mode in ('off', 'on', 'allowlist'):
            for flag in (False, True):
                for trusted in (False, True):
                    self.run_cli('sessions', 'update', A, '--inbox', 'yes' if flag else 'no')
                    self.run_cli('config', 'set', 'inbox_mode', mode)
                    self.run_cli('config', 'set', 'inbox_auto_approve_peers', '["alice"]' if trusted else '[]')
                    for ref in (A, 'agent:betty:ideas', '11111111', A.split(':')[-1], A.split(':')[-1].replace('-', ''), ''):
                        with self.subTest(mode=mode, flag=flag, trusted=trusted, ref=ref):
                            r = p.admit(p.read(self.cfg), 'alice', ref)
                            self.assertEqual(r['sessionKey'], A)
                            self.assertEqual(r['queue'], mode == 'on' and not trusted or mode == 'allowlist' and flag)
        self.assertEqual(self.cfg.stat().st_mode & 0o777, 0o640)

    def test_owner_cli_atomic_and_collisions(self):
        self.allow()
        self.allow(C)  # same alias, different owning agent
        original = self.cfg.read_bytes()
        for alias in ('ideas', 'main', 'cron', 'Upper', 'two--parts', 'é', 'x' * 49):
            self.run_cli('sessions', 'add', B, '--alias', alias, '--json', ok=False)
            self.assertEqual(self.cfg.read_bytes(), original)
        self.edit_state(keys=[A, B, C, 'agent:betty:occupied'])
        self.run_cli('sessions', 'add', B, '--alias', 'occupied', ok=False)
        self.assertEqual(self.cfg.read_bytes(), original)
        self.run_cli('sessions', 'add', 'agent:betty:missing', '--inbox', 'yes', ok=False)
        self.run_cli('sessions', 'update', A, '--clear-alias')
        self.assertNotIn('alias', p.read(self.cfg)['session_policies'][A])
        self.run_cli('sessions', 'remove', A)
        self.run_cli('sessions', 'add', A)
        self.assertNotIn(A, p.read(self.cfg)['session_policies'])
        self.run_cli('sessions', 'add', 'main', 'antenna')
        self.run_cli('sessions', 'remove', 'main', ok=False)
        self.run_cli('sessions', 'remove', 'main', '--force')

    def test_late_collision_missing_ambiguous_old_gateway(self):
        self.allow()
        self.edit_state(keys=[A, B, C, 'agent:betty:ideas'])
        with self.assertRaises(p.PolicyError): p.admit(p.read(self.cfg), 'alice', 'agent:betty:ideas')
        self.edit_state(keys=[A, B, C], short=False)
        self.assertEqual(p.admit(p.read(self.cfg), 'alice', 'agent:betty:ideas')['sessionKey'], A)
        with self.assertRaises(p.PolicyError): p.admit(p.read(self.cfg), 'alice', '11111111')
        self.edit_state(short=True, keys=[A, B, C, A.replace('1111-4111', '1111-4112')])
        with self.assertRaises(p.PolicyError): p.admit(p.read(self.cfg), 'alice', '11111111')
        self.edit_state(keys=[B, C])
        with self.assertRaises(p.PolicyError): p.admit(p.read(self.cfg), 'alice', 'agent:betty:ideas')
        self.edit_state(keys=[A, B, C], offline=True)
        with self.assertRaises(p.PolicyError): p.admit(p.read(self.cfg), 'alice', 'agent:betty:ideas')
        self.assertFalse(self.capture.exists())

    def test_pending_binding_lifecycle(self):
        self.allow()
        result = p.admit(p.read(self.cfg), 'alice', 'agent:betty:ideas')
        item = {'from': 'alice', 'session_key': A, 'binding': result['binding']}
        self.run_cli('sessions', 'update', A, '--inbox', 'no')
        self.run_cli('config', 'set', 'inbox_mode', 'off')
        p.delivery(p.read(self.cfg), item, {'alice': {}})
        self.run_cli('sessions', 'update', A, '--alias', 'other')
        self.run_cli('sessions', 'update', A, '--alias', 'ideas')
        with self.assertRaises(p.PolicyError): p.delivery(p.read(self.cfg), item, {'alice': {}})
        self.run_cli('sessions', 'remove', A)
        self.allow()
        with self.assertRaises(p.PolicyError): p.delivery(p.read(self.cfg), item, {'alice': {}})
        p.delivery(p.read(self.cfg), {'from': 'alice', 'session_key': A}, {'alice': {}})  # legacy
        with self.assertRaises(p.PolicyError): p.delivery(p.read(self.cfg), item, {})

    def test_strict_invalid_and_generic_writes(self):
        self.allow()
        cfg = p.read(self.cfg)
        variants = []
        for key, val in [('inbox_mode', 'unknown'), ('inbox_enabled', 'false'), ('session_policy_version', 2),
                         ('allowed_inbound_sessions', [A, A]), ('inbox_auto_approve_peers', None)]:
            bad = json.loads(json.dumps(cfg)); bad[key] = val; variants.append(bad)
        bad = json.loads(json.dumps(cfg)); bad['session_policies'][A]['inbox'] = 'no'; variants.append(bad)
        bad = json.loads(json.dumps(cfg)); bad['allowed_inbound_sessions'].remove(A); variants.append(bad)
        for value in variants:
            with self.assertRaises((p.PolicyError, ValueError)): p.validate(value)
        with self.assertRaises(p.PolicyError): p.decode('{"inbox_enabled":true,"inbox_enabled":false}')
        before = self.cfg.read_bytes()
        self.run_cli('config', 'set', 'inbox_mode', 'unknown', ok=False)
        self.assertEqual(self.cfg.read_bytes(), before)
        self.run_cli('config', 'set', 'inbox_mode', 'allowlist')
        self.assertTrue(p.read(self.cfg)['inbox_enabled'])
        self.run_cli('config', 'set', 'inbox_enabled', 'true')
        self.assertEqual(p.read(self.cfg)['inbox_mode'], 'on')
        self.run_cli('config', 'set', 'inbox_enabled', 'false')
        self.assertEqual(p.read(self.cfg)['inbox_mode'], 'off')
        changed = p.read(self.cfg)['session_policies']; changed[A]['alias'] = 'new'
        self.run_cli('config', 'set', 'session_policies', json.dumps(changed), ok=False)

    def test_concurrent_writers_no_lost_update(self):
        def add(n):
            return self.run_cli('sessions', 'add', 'agent:betty:test' + str(n)).returncode
        with ThreadPoolExecutor(max_workers=5) as pool:
            self.assertEqual(list(pool.map(add, range(15))), [0] * 15)
        self.assertEqual(len(p.read(self.cfg)['allowed_inbound_sessions']), 18)
        self.allow()
        self.run_cli('sessions', 'update', A, '--inbox', 'no')
        self.assertEqual(p.read(self.cfg)['session_policies'][A]['alias'], 'ideas')

    def test_offline_rollback_projection_and_queue_validation(self):
        self.allow(); self.run_cli('config', 'set', 'inbox_mode', 'allowlist')
        self.relay(self.envelope('agent:betty:ideas'))
        self.relay(self.envelope(A))
        self.helper('validate-queue')
        before = self.cfg.read_bytes()
        queue = self.skill / 'antenna-inbox.json'; queue_before = queue.read_bytes()
        output = self.base / 'rollback'
        result = subprocess.run(['python3', str(self.skill / 'scripts/antenna-policy-export.py'),
                                 '--config', str(self.cfg), '--output', str(output), '--dispatch-stopped'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        projected = p.read(output / 'antenna-config.json')
        self.assertTrue(projected['inbox_enabled'])
        self.assertEqual(projected['inbox_auto_approve_peers'], [])
        self.assertNotIn('session_policies', projected)
        self.assertEqual(len(p.read(output / 'quarantined-alias-inbox.json')), 1)
        self.assertEqual(len(p.read(output / 'antenna-inbox.json')), 1)
        self.assertEqual(self.cfg.read_bytes(), before); self.assertEqual(queue.read_bytes(), queue_before)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(f.stat().st_mode & 0o777 == 0o600 for f in output.iterdir()))
        # Staged queue validates structure without requiring currently allowed peers/sessions.
        items = p.read(queue); items[0]['binding']['canonical_key'] = B
        queue.write_text(json.dumps(items)); self.helper('validate-queue', ok=False)

    def envelope(self, target, body='café 🦞', tamper=False):
        keys = self.skill / 'keys'; keys.mkdir(exist_ok=True); keys.chmod(0o700)
        private = keys / 'fixture.pem'; public = keys / 'fixture.pub'
        if not private.exists():
            subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(private)],check=True,capture_output=True)
            subprocess.run(['openssl','pkey','-in',str(private),'-pubout','-out',str(public)],check=True,capture_output=True)
        private.chmod(0o600); public.chmod(0o644)
        (self.skill / 'antenna-peers.json').write_text(json.dumps({'alice': {'auth_mode':'ed25519-v1','signing_public_key_file':'keys/fixture.pub','display_name':'Alice'}}))
        script = '''source "$1/lib/antenna-signature.sh"
printf '%s' "$3" > "$1/body-fixture"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mid=$(python3 -c 'import uuid; print(uuid.uuid4())')
signature_canonical_file "$1/canonical-fixture" antenna-ed25519-v1 alice "$ts" "$mid" "$2" '' '' '' "$1/body-fixture"
sig=$(signature_sign "$1/keys/fixture.pem" "$1/canonical-fixture")
printf '[ANTENNA_RELAY]\\nprotocol: antenna-ed25519-v1\\nfrom: alice\\ntimestamp: %s\\nmessage_id: %s\\nsignature: ed25519-v1:%s\\n' "$ts" "$mid" "$sig"
if [[ -n "$2" ]]; then printf 'target_session: %s\\n' "$2"; fi
printf '\\n%s\\n[/ANTENNA_RELAY]' "$3"
'''
        r = subprocess.run(['bash','-c',script,'_',str(self.skill),target,body],capture_output=True,text=True,check=True)
        return r.stdout.replace(body, body + 'tampered') if tamper else r.stdout

    def relay(self, envelope):
        r = subprocess.run(['bash',str(self.skill/'scripts/antenna-relay-deliver.sh')],input=envelope,
                           capture_output=True,text=True,env=self.env)
        self.assertEqual(r.returncode,0,r.stderr)
        return r.stdout

    def test_signed_end_to_end_queue_direct_and_revocation(self):
        self.allow()
        self.run_cli('config','set','inbox_mode','allowlist')
        self.assertIn('"action": "queue"',self.relay(self.envelope('agent:betty:ideas')))
        self.assertFalse(self.capture.exists())
        self.assertIn('Relayed', self.relay(self.envelope(B)))
        sends = [json.loads(x) for x in self.capture.read_text().splitlines()]
        self.assertEqual([x['key'] for x in sends],[B]); self.assertIn('café 🦞',sends[0]['message'])
        self.run_cli('config','set','inbox_mode','off')
        queue = self.skill/'antenna-inbox.json'
        self.assertEqual(p.read(queue)[0]['status'],'pending')
        self.run_cli('inbox','approve','all'); self.run_cli('inbox','drain')
        sends = [json.loads(x) for x in self.capture.read_text().splitlines()]
        self.assertEqual([x['key'] for x in sends],[B,A])
        self.run_cli('inbox','drain'); self.assertEqual(len(self.capture.read_text().splitlines()),2)
        self.assertIn('rejected',self.relay(self.envelope('agent:betty:ideas',tamper=True)))
        self.assertIn('rejected',self.relay(self.envelope('agent:betty:main')))
        self.run_cli('config','set','inbox_mode','allowlist')
        self.relay(self.envelope('agent:betty:ideas'))
        self.run_cli('inbox','approve','all')
        self.run_cli('sessions','update',A,'--alias','other')
        self.run_cli('inbox','drain',ok=False)
        self.assertIn('Alias binding changed',p.read(queue)[-1]['last_error'])
        self.assertEqual(len(self.capture.read_text().splitlines()),2)

    def test_recheck_between_drain_items(self):
        self.allow(); self.run_cli('config','set','inbox_mode','allowlist')
        self.relay(self.envelope(A)); self.relay(self.envelope('11111111'))
        self.run_cli('inbox','approve','all')
        self.edit_state(revoke_after_send=True)
        self.run_cli('inbox','drain',ok=False)
        self.assertEqual(len(self.capture.read_text().splitlines()),1)
        self.assertEqual([x['status'] for x in p.read(self.skill/'antenna-inbox.json')],['delivered','failed'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
