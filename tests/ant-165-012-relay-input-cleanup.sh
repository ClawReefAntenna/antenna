#!/usr/bin/env bash
# Real wrapper/reader/verifier; synthetic keys and recording gateway RPC only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import datetime, json, os, shutil, stat, subprocess, sys, tempfile, uuid
from pathlib import Path
root = Path(sys.argv[1])
checks = 0

def check(ok, label):
    global checks
    assert ok, label
    checks += 1
    print('PASS', label)

with tempfile.TemporaryDirectory(prefix='antenna-cleanup-') as temp:
    base = Path(temp)
    skill = base / 'skill'
    for directory in ('scripts', 'lib'):
        shutil.copytree(root / directory, skill / directory)
    scratch = base / 'tmp'
    scratch.mkdir()
    staging = scratch / 'antenna-relay'
    staging.mkdir(mode=0o700)
    keys = skill / 'keys'
    keys.mkdir(mode=0o700)
    private = base / 'private.pem'
    subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(private)], check=True)
    private.chmod(0o600)
    subprocess.run(['openssl', 'pkey', '-in', str(private), '-pubout', '-out', str(keys/'sender.pem')], check=True)
    (keys/'sender.pem').chmod(0o644)
    (skill/'antenna-config.json').write_text(json.dumps({'log_enabled':False,
        'allowed_inbound_peers':['sender'], 'allowed_inbound_sessions':['agent:receiver:main'],
        'default_target_session':'agent:receiver:main', 'inbox_enabled':False}))
    (skill/'antenna-peers.json').write_text(json.dumps({'sender':{'auth_mode':'ed25519-v1',
        'signing_public_key_file':'keys/sender.pem', 'url':'https://sender.example'}}))
    bindir = base / 'bin'
    bindir.mkdir()
    capture = base / 'rpc.jsonl'
    stub = bindir / 'openclaw'
    stub.write_text('''#!/usr/bin/env python3
import json, os, sys
args=sys.argv[1:]
if args[:3] == ['gateway','call','sessions.resolve']:
    params=json.loads(args[args.index('--params')+1])
    print(json.dumps({'ok':True,'key':params['key']})); sys.exit(0)
assert args[:3] == ['gateway','call','sessions.send']
with open(os.environ['CLEANUP_RPC_CAPTURE'],'a') as f:
    f.write(args[args.index('--params')+1]+'\\n')
print('{"status":"started","runId":"cleanup-fixture"}')
''')
    stub.chmod(0o700)
    env = {**os.environ, 'TMPDIR':str(scratch), 'PATH':str(bindir)+':'+os.environ['PATH'],
        'CLEANUP_RPC_CAPTURE':str(capture)}
    def run(path=None, script='antenna-relay-deliver.sh', text=None):
        args=['bash',str(skill/'scripts'/script)] + ([] if path is None else [str(path)])
        return subprocess.run(args, input=text, capture_output=True, text=True, env=env, timeout=30)
    def snapshot(p):
        return p.read_bytes(), stat.S_IMODE(p.stat().st_mode)
    outside = base/'saved envelope.txt'
    outside.write_text('not an envelope\n')
    outside.chmod(0o640)
    original = snapshot(outside)
    for script in ('antenna-relay-deliver.sh','antenna-relay-file.sh'):
        result=run(outside, script)
        check(json.loads(result.stdout)['action']=='reject', script+' rejects ordinary input')
        check(snapshot(outside)==original, script+' preserves outside bytes and mode')
    staging.chmod(0o755)
    for label, path in (
        ('normal staged rejection', staging/'msg-reject.txt'),
        ('hard link', staging/'msg-hard.txt'),
        ('symlink', staging/'msg-link.txt'),
    ):
        if label=='hard link': os.link(outside,path)
        elif label=='symlink': path.symlink_to(outside)
        else: path.write_text('not an envelope')
        check(json.loads(run(path).stdout)['action']=='reject', label+' rejected')
        check(snapshot(outside)==original, label+' leaves outside target unchanged')
        check(path.is_symlink() if label=='symlink' else not path.exists(), label+' cleanup disposition')
    check(stat.S_IMODE(staging.stat().st_mode)==0o700, 'normal staging directory remains private')
    path = staging/'..'/'..'/outside.name
    run(path)
    check(snapshot(outside)==original, 'dot-dot path does not confer cleanup ownership')
    nested = staging/'nested'
    nested.mkdir()
    nested_file=nested/'saved.txt'
    nested_file.write_text('not an envelope')
    run(nested_file)
    check(nested_file.exists(), 'nested files are not direct staging entries')
    reader_file=staging/'reader.txt'
    reader_file.write_text('not an envelope')
    reader_file.chmod(0o640)
    reader_before=snapshot(reader_file)
    run(reader_file, 'antenna-relay-file.sh')
    check(snapshot(reader_file)==reader_before, 'inner reader is read-only even inside staging')
    before=set(staging.iterdir())
    check(json.loads(run(text='not an envelope').stdout)['action']=='reject', 'stdin malformed input rejected')
    check(set(staging.iterdir())==before, 'stdin temporary entry cleaned after rejection')

    def signed():
        timestamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        message_id=str(uuid.uuid4())
        body=base/'body'
        body.write_text('cleanup signed control')
        signature=subprocess.run(['bash','-c',
            'source "$1"; signature_canonical_file "$2" antenna-ed25519-v1 sender "$3" "$4" "" "" "" "" "$5"; signature_sign "$6" "$2"',
            '_',str(skill/'lib/antenna-signature.sh'),str(base/'canonical'),timestamp,message_id,str(body),str(private)],
            capture_output=True,text=True,check=True).stdout.strip()
        return f'[ANTENNA_RELAY]\nprotocol: antenna-ed25519-v1\nfrom: sender\ntimestamp: {timestamp}\nmessage_id: {message_id}\nsignature: ed25519-v1:{signature}\n\n{body.read_text()}\n[/ANTENNA_RELAY]'
    for label,path in (('outside',outside),('staged',staging/'msg-valid.txt'),('stdin',None)):
        envelope=signed()
        if path is not None:
            path.write_text(envelope)
            saved=snapshot(path)
        before=set(staging.iterdir())
        result=run(path,text=envelope if path is None else None)
        check(result.returncode==0 and result.stdout.strip()=='Relayed', label+' signed control delivered: '+result.stdout+result.stderr)
        if label=='outside': check(snapshot(path)==saved, 'accepted outside file preserved')
        elif label=='staged': check(not path.exists(), 'accepted staged entry removed')
        else: check(set(staging.iterdir())==before, 'accepted stdin temporary entry removed')
    calls=[json.loads(line) for line in capture.read_text().splitlines()]
    check(len(calls)==3 and all(c['key']=='agent:receiver:main' and c['message'].endswith('cleanup signed control') for c in calls),
          'only valid controls reach the unchanged destination RPC')
    # A staging-directory symlink must not turn an unrelated directory into cleanup-owned storage.
    shutil.rmtree(staging)
    staging.symlink_to(base, target_is_directory=True)
    saved=snapshot(outside)
    run(staging/outside.name)
    check(snapshot(outside)==saved, 'symlinked staging directory preserves outside input')
    result=run(text='not an envelope')
    check(result.returncode!=0 and 'symlink' in result.stdout, 'stdin refuses symlinked staging directory')
print(f'SUMMARY {checks} passed, 0 failed')
PY
