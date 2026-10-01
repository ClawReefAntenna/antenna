#!/usr/bin/env python3
"""Local-only read-only preparation checks; never invokes OpenClaw or Doctor repairs."""
import argparse
from collections import Counter
from datetime import date
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'lib'))
import antenna_state as state


PLUGIN_MINIMUM='2026.9.5'
HOOKS_WARNING='v1.6.8 no longer uses your gateway hooks token. Previously paired Antenna peers may still hold copies. We recommend rotating it to revoke non-essential general-hook access. If you rotate it, update any other integrations using that token. If you retain it, those copies may remain valid for enabled gateway hooks, outside Antenna’s checks.'


def plugin_version_status(version):
    # OpenClaw uses calendar versions; -N is a packaging revision, while
    # named prereleases do not establish support for the stable minimum.
    match=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-(\d+))?(?:\+[0-9A-Za-z.-]+)?',version or '') if isinstance(version,(str,type(None))) else None
    if not match: return 'unknown'
    return 'pass' if tuple(map(int,match.group(1,2,3))) >= (2026,9,5) else 'fail'


def report(root,gateway):
    checks=[]
    def add(code,status,reason,source,action='',**data):
        checks.append(dict(id=code,status=status,reason=reason,evidence=str(source),next_action=action,**data))
    metadata=state.read_file(root/'SKILL.md').decode()
    match=re.search(r'^  version: (\S+)',metadata,re.M)
    version=match.group(1) if match else 'unknown'
    add('installation','pass','Resolved local installation.',root,invoked_cli=os.environ.get('ANTENNA_INVOKED_CLI',str(root/'bin/antenna.sh')),resolved_cli=str(root/'bin/antenna.sh'),version=version)
    for dep in ('python3','bash','jq','openssl','age','age-keygen','flock','node','openclaw'):
        found=shutil.which(dep)
        add('dependency_'+dep,'pass' if found else 'warn' if dep in ('age','age-keygen') else 'fail',
            'Executable available.' if found else 'Executable missing.',found or 'PATH',
            '' if found else 'Install the missing dependency before using its commands.')
    oc=shutil.which('openclaw');ocversion=None
    if oc:
        for parent in list(Path(oc).resolve().parents)[:3]:
            try:
                package=state.decode(state.read_file(parent/'package.json'))
                if package.get('name')=='openclaw': ocversion=package.get('version');break
            except (state.StateError,OSError): continue
    add('openclaw_cli_version','pass' if ocversion else 'unknown','Installed CLI package version; not running gateway version.',oc or 'PATH',version=ocversion)
    minimum_status=plugin_version_status(ocversion)
    add('plugin_openclaw_minimum',minimum_status,
        'Installed OpenClaw meets the v1.6.8 minimum.' if minimum_status=='pass' else 'Installed OpenClaw is below the v1.6.8 minimum.' if minimum_status=='fail' else 'Installed OpenClaw compatibility with the v1.6.8 minimum is unknown.',
        oc or 'PATH','v1.6.8 requires OpenClaw '+PLUGIN_MINIMUM+' or later; verify the running gateway separately.',minimum=PLUGIN_MINIMUM)
    add('legacy_health_scope','pass','Configuration, identity, relay and gateway checks describe the current legacy installation, not completed plugin cutover.','local-only report')
    add('migration','unknown','Plugin installation and migration/cutover are not performed or verified by readiness.',root/'references/BACKUP-AND-READINESS.md','Follow the qualified v1.6.8 migration guide: install plugin and companion, preserve pairings, complete explicit cutover, and coordinate with peers and any Public Groups Registry operator.')
    add('hooks_token_rotation','warn',HOOKS_WARNING,'v1.6.8 migration guidance','Rotation is recommended, not required; no credentials are changed by readiness.')
    add('running_gateway','unknown','Running gateway version not checked.','local-only report','Verify separately during upgrade qualification.')
    add('remote_peers','unknown','Remote-peer readiness: unknown (not checked).','local-only report','Coordinate peer and ClawReef upgrades using the qualified migration guide.')
    config=None;peers=None
    try:
        config=state.decode(state.read_file(root/'antenna-config.json'));state.config_valid(config)
        add('config_policy','pass','Local settings and session policy valid.',root/'antenna-config.json')
    except (state.StateError,OSError):
        config=None;add('config_policy','fail','Configuration missing or invalid; no repair performed.',root/'antenna-config.json','Inspect settings or restore a verified backup.')
    try:
        peers=state.decode(state.read_file(root/'antenna-peers.json'))
        state.need(isinstance(peers,dict) and all(isinstance(p,dict) for p in peers.values()))
        modes=Counter(p.get('auth_mode','unpaired' if p.get('self') else 'missing') for p in peers.values())
        state.need(set(modes)<={'ed25519-v1','plaintext-legacy','unpaired'})
        add('peer_modes','warn' if modes.get('plaintext-legacy') or modes.get('unpaired') else 'pass','Local peer authentication modes.',root/'antenna-peers.json',
            'Review legacy or incomplete pairing when planning upgrades.' if modes.get('plaintext-legacy') or modes.get('unpaired') else '',counts=dict(modes))
    except (state.StateError,OSError,TypeError):
        peers=None;add('peer_modes','fail','Peer registry missing or invalid.',root/'antenna-peers.json','Inspect pairing configuration or restore a verified backup.')
    if config is not None and peers is not None:
        try:
            refs,files,_=state.capture(root)
            _,_,queue,fps=state.validate_snapshot(root,files)
            add('identity_state','pass','State inventory and key relationships valid.',root,identity_fingerprints=fps)
            items=state.decode(files[queue]) if queue in files else []
            counts=dict(Counter(i['status'] for i in items))
            unresolved=sum(counts.get(k,0) for k in ('pending','approved','failed'))
            add('inbox','warn' if unresolved else 'pass',
                'Unresolved legacy inbox items: pending, approved-but-unsent or failed/uncertain.' if unresolved else 'No unresolved legacy inbox items.',
                refs[queue],
                'Review and resolve what you can before migration. Remaining legacy items are preserved as read-only recovery material, not deliverable v1.6.8 messages. Any new signed resend is explicit; review failed/uncertain delivery before resending.' if unresolved else '',
                counts=counts,unresolved=unresolved)
        except (state.StateError,OSError,KeyError,TypeError):
            add('identity_state','fail','State inventory, key references or inbox invalid; no secret values displayed.',root,'Run Doctor or inspect the local state before upgrading.')
    # Reuse the exact non-mutating relay-policy validator used by Doctor.
    try:
        p=subprocess.run(['bash','-c','source "$1/lib/relay-policy.sh"; relay_policy_default_ok agent/AGENTS.md && relay_policy_audit "$1/agent/AGENTS.md" agent/AGENTS.md','_',str(root)],capture_output=True,text=True,timeout=10)
        status=p.stdout.split('|',1)[0].strip()
        status=status if status in ('pass','warn','fail') else 'fail'
        add('relay_policy',status,'Packaged relay policy matches.' if status=='pass' else 'Relay policy differs or cannot be validated.',root/'agent/AGENTS.md','' if status=='pass' else 'Review with antenna doctor; do not overwrite intentional changes blindly.')
    except (OSError,subprocess.TimeoutExpired):
        add('relay_policy','unknown','Relay policy validator unavailable.',root/'lib/relay-policy.sh','Check local dependencies.')
    try:
        g=state.decode(state.read_file(gateway))
        state.need(isinstance(g,dict))
        # Includes are not expanded and external secret providers are not invoked.
        if '$include' in json.dumps(g):
            add('gateway_config','unknown','Include-owned config not resolved by this local report.',gateway,'Inspect the resolved configuration separately.')
        else:
            agents=g.get('agents',{});entries=agents.get('entries');old=agents.get('list')
            state.need(not (entries is not None and old is not None))
            roster=entries if isinstance(entries,dict) else {a['id']:a for a in old} if isinstance(old,list) else {}
            relay=(config or {}).get('relay_agent_id','antenna');local=(config or {}).get('local_agent_id')
            hooks=g.get('hooks',{});tools=g.get('tools',{})
            state.need(isinstance(roster.get(relay),dict) and hooks.get('enabled') is True and relay in hooks.get('allowedAgentIds',[]) and hooks.get('allowRequestSessionKey') is True)
            prefixes=hooks.get('allowedSessionKeyPrefixes',[])
            state.need('hook:' in prefixes and (local is None or any(('agent:'+local+':').startswith(x) for x in prefixes)))
            state.need(Path(roster[relay].get('workspace','')).resolve()==root/'agent')
            state.need(tools.get('sessions',{}).get('visibility')=='all' and tools.get('agentToAgent',{}).get('enabled') is True)
            add('gateway_config','pass','Local relay roster, workspace, hooks and session configuration agree.',gateway)
            if peers is not None:
                selfpeer=next(p for p in peers.values() if p.get('self'))
                token=hooks.get('token')
                if isinstance(token,str):
                    actual=state.read_file(state.source_path(root,selfpeer['token_file']),private=True).decode().strip()
                    state.need(token==actual)
                    add('gateway_token','pass','Local self-token relationship agrees.',gateway)
                else: add('gateway_token','unknown','External token reference not resolved.',gateway,'Verify through the configured secret provider separately.')
    except (state.StateError,OSError,KeyError,TypeError,ValueError,StopIteration):
        add('gateway_config','fail','Local gateway configuration is missing, unsupported or inconsistent.',gateway,'Inspect with Doctor; this report makes no repairs.')
    add('backup','not_applicable','Backup is optional; no archive was located or decrypted.','not inspected','Create and verify a backup if desired. v1.6.7 archives restore state to compatible v1.6.7 installations only; not to v1.6.8 or as a downgrade from it.')
    notice=root/'references/upgrade-notice.json'
    try:
        n=state.decode(state.read_file(notice))
        state.need(isinstance(n,dict) and n.get('schema_version')==1 and n.get('from_version')=='1.6.7' and n.get('next_version')=='1.6.8')
        state.need(n.get('announcement_at') is None and n.get('publication_at') is None)
        if n.get('status')=='undated-draft':
            state.need(n.get('announcement_date') is None and n.get('publication_date') is None)
            add('notice','warn','Private undated notice draft; no publication date or remote availability established.',notice,'Use the final qualified migration guide at release time.',notice_status='undated-draft')
        else:
            state.need(n.get('status')=='scheduled' and n.get('timezone')=='America/Toronto' and n.get('notice_days')==7)
            dates=[n.get(k) for k in ('announcement_date','publication_date')]
            state.need(all(isinstance(d,str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}',d) for d in dates))
            first,last=map(date.fromisoformat,dates)
            state.need((last-first).days==7)
            add('notice','warn',f'Planned v1.6.7 release/announcement: {dates[0]}; planned v1.6.8 release: {dates[1]} (America/Toronto). This is a schedule, not confirmation of publication or remote availability.',notice,'Coordinate migration with peers and verify published release guidance separately.',notice_status='scheduled',announcement_date=dates[0],publication_date=dates[1],timezone=n['timezone'])
    except (state.StateError,OSError,AttributeError,ValueError,TypeError):
        add('notice','unknown','Packaged notice unavailable, inconsistent or unsupported; no countdown or remote availability established.',notice)
    counts=dict(Counter(c['status'] for c in checks))
    return {'schema_version':1,'complete':True,'target':str(root),'version':version,'checks':checks,'summary':counts,
            'local_result':'Local problems found' if counts.get('fail') else 'No local problems found'}


def human(result):
    # JSON escaping keeps user-controlled paths and labels inert on terminals.
    safe=lambda x:json.dumps(str(x),ensure_ascii=True)
    print('Antenna '+safe(result['version'])+' — '+safe(result['target']))
    print(result['local_result'])
    for c in result['checks']:
        if c['status'] not in ('warn','fail','unknown'): continue
        print(c['status'].upper()+' '+c['id']+': '+safe(c['reason']))
        if c['next_action']: print('  Next: '+safe(c['next_action']))
    print('Checks: '+', '.join(str(result['summary'].get(k,0))+' '+k for k in ('pass','warn','fail','unknown','not_applicable')))


def main():
    parser=argparse.ArgumentParser(prog='antenna readiness',description='Local-only read-only upgrade preparation; remote-peer readiness is unknown.')
    parser.add_argument('--json',action='store_true');parser.add_argument('--gateway')
    a=parser.parse_args()
    gateway=Path(a.gateway or os.environ.get('OPENCLAW_CONFIG_PATH') or str(Path(os.environ.get('OPENCLAW_STATE_DIR',str(Path.home()/'.openclaw')))/'openclaw.json'))
    try:
        result=report(ROOT,gateway)
        if a.json: print(json.dumps(result,ensure_ascii=True))
        else: human(result)
        return 1 if result['summary'].get('fail') else 0
    except (state.StateError,OSError,ValueError,KeyError,TypeError):
        print(json.dumps({'schema_version':1,'complete':False,'code':'REPORT_FAILED','message':'Cannot complete local report; no repairs performed.'}),file=sys.stderr)
        return 2

if __name__=='__main__': sys.exit(main())
