#!/usr/bin/env bash
# Execute real config/inbox code with private state and a recording RPC stub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
checks = 0
def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print('PASS', label)

with tempfile.TemporaryDirectory(prefix='antenna-review-r5-r6-') as temp:
    base = Path(temp)
    skill = base / 'skill'
    for relative in ('scripts/antenna-inbox.sh', 'lib/config.sh', 'lib/session-policy.py'):
        target = skill / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative, target)
    cfg = skill / 'antenna-config.json'
    peers = skill / 'antenna-peers.json'
    queue = skill / 'antenna-inbox.json'
    log = skill / 'antenna.log'
    capture = base / 'rpc.jsonl'
    binpath = base / 'bin'
    binpath.mkdir()
    stub = binpath / 'openclaw'
    stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[:3] == ['gateway', 'call', 'sessions.resolve']:
    params = json.loads(args[args.index('--params') + 1])
    print(json.dumps({'ok': True, 'key': params['key']})); sys.exit(0)
assert args[:3] == ['gateway', 'call', 'sessions.send'], args
with open(os.environ['REVIEW_RPC_CAPTURE'], 'a') as f:
    f.write(json.dumps(json.loads(args[args.index('--params') + 1])) + '\\n')
if os.environ.get('REVIEW_REVOKE_AFTER_SEND'):
    p = Path(os.environ['REVIEW_CONFIG'])
    c = json.loads(p.read_text())
    c['allowed_inbound_peers'] = []
    p.write_text(json.dumps(c))
print(json.dumps({'status': 'started', 'runId': 'fixture'}))
''')
    stub.chmod(0o700)
    env = {**os.environ, 'PATH': str(binpath) + ':' + os.environ['PATH'],
           'REVIEW_RPC_CAPTURE': str(capture), 'REVIEW_CONFIG': str(cfg)}
    env.pop('REVIEW_REVOKE_AFTER_SEND', None)

    def config_value(helper):
        return subprocess.run(['bash', '-c',
            'CONFIG_FILE="$1"; source "$2"; "$3"', '_', str(cfg),
            str(skill / 'lib/config.sh'), helper], capture_output=True, text=True, check=True)

    # Explicit false must survive even when the helper default is true.
    for key in ('log_enabled', 'log_verbose', 'inbox_enabled', 'mcs_enabled'):
        for value in (True, False):
            cfg.write_text(json.dumps({key: value}))
            check(config_value('config_' + key).stdout == str(value).lower(),
                  f'{key} preserves {value}')
    for contents in ('{}', '{"log_enabled":null}', '{broken'):
        cfg.write_text(contents)
        result = config_value('config_log_enabled')
        check(result.stdout == 'true', f'logging default retained for {contents}')
        if contents == '{broken':
            check('config read failed' in result.stderr, 'invalid JSON warns')
    cfg.unlink()
    check(config_value('config_log_enabled').stdout == 'true', 'missing file retains default')

    def inbox(*args, item=None, extra=None):
        return subprocess.run(['bash', str(skill / 'scripts/antenna-inbox.sh'), *args],
            input=json.dumps(item) if item is not None else None,
            text=True, capture_output=True, env={**env, **(extra or {})})

    def seed(count=1):
        for p in (queue, log, capture):
            p.unlink(missing_ok=True)
        cfg.write_text(json.dumps({'log_enabled': False,
            'allowed_inbound_peers': ['sender'],
            'allowed_inbound_sessions': ['agent:receiver:main']}))
        peers.write_text(json.dumps({'sender': {'url': 'https://sender.example'}}))
        for i in range(count):
            result = inbox('queue-add', item={'from': 'sender',
                'target_session': 'agent:receiver:main', 'session_key': 'agent:receiver:main',
                'full_message': f'fixture message {i}'})
            assert result.returncode == 0, result.stderr
        result = inbox('approve', 'all')
        assert result.returncode == 0, result.stderr

    def policy(**changes):
        c = json.loads(cfg.read_text())
        c.update(changes)
        cfg.write_text(json.dumps(c))

    for name, revoke in (
        ('peer allowlist removal', lambda: policy(allowed_inbound_peers=[])),
        ('session removal', lambda: policy(allowed_inbound_sessions=[])),
        ('peer registry removal', lambda: peers.write_text('{}')),
        ('missing peers file', lambda: peers.unlink()),
        ('invalid peers JSON', lambda: peers.write_text('{broken')),
        ('invalid config JSON', lambda: cfg.write_text('{broken')),
        ('missing config file', lambda: cfg.unlink()),
        ('missing allowlists', lambda: cfg.write_text('{"log_enabled":false}')),
        ('wrong allowlist type', lambda: policy(allowed_inbound_peers='sender')),
        ('invalid allowlist member', lambda: policy(allowed_inbound_peers=['sender', 1])),
        ('non-exact destination', lambda: policy(allowed_inbound_sessions=['agent:receiver:main-other'])),
    ):
        seed()
        revoke()
        result = inbox('drain')
        stored = json.loads(queue.read_text())[0]
        check(result.returncode != 0 and not capture.exists(), name + ' prevents RPC')
        check(stored['status'] == 'failed' and stored.get('last_error') and
              stored['full_message'] == 'fixture message 0', name + ' retains failed item')

    seed()
    result = inbox('drain')
    calls = [json.loads(line) for line in capture.read_text().splitlines()]
    check(result.returncode == 0 and calls == [
        {'key': 'agent:receiver:main', 'message': 'fixture message 0'}],
        'permitted item is delivered unchanged')
    check(json.loads(queue.read_text())[0]['status'] == 'delivered', 'successful delivery recorded')
    check(not log.exists(), 'queue/approval/drain write no log when disabled')
    seed()
    policy(log_enabled=True)
    check(inbox('drain').returncode == 0 and log.stat().st_size > 0, 'enabled logging still works')

    seed(2)
    result = inbox('drain', extra={'REVIEW_REVOKE_AFTER_SEND': '1'})
    check(result.returncode != 0 and len(capture.read_text().splitlines()) == 1,
          'permission is reread between deliveries, not once per drain')
    check([i['status'] for i in json.loads(queue.read_text())] == ['delivered', 'failed'],
          'partial drain retains individual outcomes')
    policy(allowed_inbound_peers=['sender'])
    check(inbox('drain').returncode == 0 and len(capture.read_text().splitlines()) == 1,
          'failed item does not automatically retry when permission returns')

print(f'SUMMARY {checks} passed, 0 failed')
PY
