#!/usr/bin/env python3
"""Receiver-owned session policy. No transport, session creation, or fuzzy lookup.

All configuration writers use CONFIG.lock. Readers load one atomic snapshot;
no lock is held across a gateway call. RPC admission cannot revoke an in-flight
send. Only public gateway selectors are used, never the transcript store.
"""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import unicodedata


class PolicyError(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise PolicyError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'Duplicate JSON field')
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def read(path):
    return decode(Path(path).read_text())


def owner(key):
    need(isinstance(key, str) and len(key.encode()) <= 128 and
         not any(unicodedata.category(c).startswith('C') for c in key) and
         re.fullmatch(r'agent:([A-Za-z0-9_.-]+):[^\s\x00-\x1f\x7f]+', key),
         'Expected a canonical agent session key (maximum 128 bytes)')
    return key.split(':', 2)[1]


RESERVED = {'main', 'global', 'unknown', 'cron', 'hook', 'subagent', 'acp', 'dashboard'}


def alias_address(key, alias):
    need(isinstance(alias, str) and len(alias) <= 48 and
         re.fullmatch(r'[a-z][a-z0-9]*(?:-[a-z0-9]+)*', alias) and alias not in RESERVED,
         'Alias must be a non-reserved lowercase slug of 1–48 characters')
    address = 'agent:' + owner(key) + ':' + alias
    owner(address)
    return address


def string_list(config, field):
    value = config.get(field, [])
    need(isinstance(value, list) and all(isinstance(x, str) for x in value) and
         len(set(value)) == len(value), 'Invalid ' + field)
    return value


def validate(config):
    need(isinstance(config, dict), 'Configuration must be an object')
    allowed = string_list(config, 'allowed_inbound_sessions')
    # Retain inert pre-existing string entries; new writes/resolution require
    # canonical keys. They must not block unrelated peer revocation.
    for field in ('allowed_inbound_peers', 'allowed_outbound_peers', 'inbox_auto_approve_peers'):
        string_list(config, field)
    legacy = config.get('inbox_enabled', False)
    need(type(legacy) is bool, 'inbox_enabled must be boolean')
    mode = config.get('inbox_mode', 'on' if legacy else 'off')
    need(isinstance(mode, str) and mode in ('off', 'on', 'allowlist'), 'Invalid inbox_mode')
    if 'inbox_mode' in config:
        need('inbox_enabled' in config and legacy == (mode != 'off'), 'Conflicting inbox mode/mirror')
    policies = config.get('session_policies', {})
    if 'session_policies' in config or 'session_policy_version' in config:
        need(type(config.get('session_policy_version')) is int and config['session_policy_version'] == 1,
             'Unsupported session_policy_version')
    need(isinstance(policies, dict), 'Invalid session_policies')
    aliases, identities = {}, set()
    for key, entry in policies.items():
        need(key in allowed and isinstance(entry, dict), 'Orphan or invalid session metadata')
        need(set(entry) <= {'entry_id', 'alias', 'alias_revision', 'inbox'}, 'Unknown session metadata field')
        identity = entry.get('entry_id')
        need(isinstance(identity, str) and str(uuid.UUID(identity)) == identity, 'Invalid entry_id')
        need(identity not in identities, 'Duplicate entry_id')
        identities.add(identity)
        need(type(entry.get('alias_revision')) is int and entry['alias_revision'] >= 0, 'Invalid alias_revision')
        need(type(entry.get('inbox', False)) is bool, 'Session inbox must be boolean')
        if 'alias' in entry:
            address = alias_address(key, entry['alias'])
            need(entry['alias_revision'] > 0, 'Alias must have a revision')
            need(address not in aliases and (address not in allowed or address == key), 'Alias collision')
            aliases[address] = key
    return mode, policies, aliases


def gateway(params, missing=False):
    # allowMissing isn't present in every supported schema. Do not depend on it.
    try:
        proc = subprocess.run(['openclaw', 'gateway', 'call', 'sessions.resolve', '--params',
                               json.dumps(params), '--json', '--timeout', '10000'],
                              capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        raise PolicyError('Session resolver unavailable') from None
    try:
        response = decode(proc.stdout)
    except (ValueError, TypeError):
        response = {}
    if not proc.returncode and response.get('ok') is True and isinstance(response.get('key'), str):
        return response
    diagnostic = (proc.stderr + proc.stdout).lower()
    # Absence only, not an authorization, timeout, or malformed-response failure.
    if missing and ('no session found' in diagnostic or 'session not found' in diagnostic):
        return None
    if 'shortId' in params:
        if 'shortid' in diagnostic and any(x in diagnostic for x in ('unexpected', 'additional', 'unknown', 'unrecognized')):
            raise PolicyError('UUID resolution unsupported by this gateway; use a full canonical key')
        if any(x in diagnostic for x in ('ambiguous', 'multiple', 'more than one')):
            raise PolicyError('UUID reference is ambiguous; use a longer prefix or full canonical key')
        if 'no session found' in diagnostic or 'session not found' in diagnostic:
            raise PolicyError('UUID reference has no matching session')
        raise PolicyError('UUID resolver unavailable; no fallback performed')
    raise PolicyError('Session missing or resolver unavailable; no fallback performed')


def exact(key):
    agent = owner(key)
    result = gateway({'key': key})
    need(result['key'] == key and result.get('agentId', agent) == agent,
         'Gateway identity differs from selected canonical session')


def check_collision(address, key):
    if address != key:
        result = gateway({'key': address}, missing=True)
        need(result is None, 'Alias conflicts with an existing gateway address')


def resolve(config, reference):
    mode, policies, aliases = validate(config)
    supplied = reference
    if not reference:
        reference = config.get('default_target_session') or 'agent:' + config.get('local_agent_id', 'agent') + ':main'
    kind = 'canonical'
    if reference in aliases:
        key, kind = aliases[reference], 'alias'
        check_collision(reference, key)
    elif reference.startswith('agent:'):
        key = reference
        owner(key)
    else:
        selector = reference
        if re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', selector):
            selector = selector.replace('-', '')
        need(re.fullmatch(r'[0-9a-fA-F]{8,32}', selector), 'Use an agent-qualified alias, canonical key, or key UUID')
        result = gateway({'shortId': selector.lower()})
        key, kind = result['key'], 'uuid'
        owner(key)
        need(result.get('agentId', owner(key)) == owner(key), 'Resolver agent mismatch')
    need(key in config.get('allowed_inbound_sessions', []), 'Session target not in allowed_inbound_sessions')
    exact(key)
    entry = policies.get(key, {})
    binding = {'original_reference': supplied, 'resolved_reference': reference,
               'reference_kind': kind, 'canonical_key': key}
    if kind == 'alias':
        binding.update(entry_id=entry['entry_id'], alias_revision=entry['alias_revision'])
    return mode, entry, binding


def admit(config, sender, reference):
    validate(config)
    need(sender in config.get('allowed_inbound_peers', []), 'Sender is not allowed')
    mode, entry, binding = resolve(config, reference)
    queued = (mode == 'allowlist' and entry.get('inbox', False)) or (
        mode == 'on' and sender not in config.get('inbox_auto_approve_peers', []))
    return {'sessionKey': binding['canonical_key'], 'queue': queued, 'inbox_mode': mode, 'binding': binding}


def delivery(config, item, peers):
    _, policies, aliases = validate(config)
    sender = item.get('from')
    key = item.get('session_key', item.get('sessionKey'))
    need(sender in config.get('allowed_inbound_peers', []) and isinstance(peers, dict) and
         isinstance(peers.get(sender), dict), 'Sender removed or disallowed')
    need(key in config.get('allowed_inbound_sessions', []), 'Destination removed or disallowed')
    binding = item.get('binding')
    if binding is not None:
        need(isinstance(binding, dict) and binding.get('canonical_key') == key and
             binding.get('reference_kind') in ('canonical', 'alias', 'uuid'), 'Invalid queued binding')
        if binding['reference_kind'] == 'alias':
            entry = policies.get(key, {})
            address = binding.get('resolved_reference')
            need(aliases.get(address) == key and entry.get('entry_id') == binding.get('entry_id') and
                 entry.get('alias_revision') == binding.get('alias_revision'), 'Alias binding changed; review required')
            check_collision(address, key)
    exact(key)
    return {'ok': True, 'sessionKey': key}


@contextlib.contextmanager
def locked(path):
    with open(str(path) + '.lock', 'a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def write(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.antenna-config.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            os.fchmod(handle.fileno(), (path.stat().st_mode & 0o777) if path.exists() else 0o600)
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def project_modes(before, after):
    # Generic legacy toggle remains supported and updates the authoritative mode.
    if before.get('inbox_mode') != after.get('inbox_mode') and 'inbox_mode' in after:
        after['inbox_enabled'] = after['inbox_mode'] != 'off'
    elif before.get('inbox_enabled') != after.get('inbox_enabled') and 'inbox_mode' in after:
        need(type(after.get('inbox_enabled')) is bool, 'inbox_enabled must be boolean')
        after['inbox_mode'] = 'on' if after['inbox_enabled'] else 'off'


def transition(before, after, managed=False):
    validate(after)
    old = before.get('session_policies', {})
    new = after.get('session_policies', {})
    for key, entry in new.items():
        prior = old.get(key)
        need(prior is not None or managed, 'Create session metadata with antenna sessions add/update')
        if prior is None or prior != entry:
            # Generic config writes must obey the same gateway/binding rules.
            exact(key)
            if 'alias' in entry:
                check_collision(alias_address(key, entry['alias']), key)
        if prior:
            need(entry['entry_id'] == prior['entry_id'], 'Cannot replace an existing entry identity')
            expected = prior['alias_revision'] + (prior.get('alias') != entry.get('alias'))
            need(entry['alias_revision'] == expected, 'Invalid alias revision transition')


def mutate(path, jq_args):
    with locked(path):
        before = read(path)
        validate(before)
        proc = subprocess.run(['jq', *jq_args], input=json.dumps(before), capture_output=True, text=True)
        need(proc.returncode == 0, 'Configuration mutation failed')
        after = decode(proc.stdout)
        project_modes(before, after)
        transition(before, after)
        write(path, after)


def sessions(path, args):
    parser = argparse.ArgumentParser(prog='antenna sessions')
    parser.add_argument('action', choices=['list', 'ls', 'add', 'update', 'remove', 'rm'], nargs='?', default='list')
    parser.add_argument('keys', nargs='*')
    parser.add_argument('--alias')
    parser.add_argument('--clear-alias', action='store_true')
    parser.add_argument('--inbox', choices=['yes', 'no'])
    parser.add_argument('--force', '-f', action='store_true')
    parser.add_argument('--json', action='store_true')
    opts = parser.parse_args(args)
    metadata = opts.alias is not None or opts.clear_alias or opts.inbox is not None
    need(not (opts.alias is not None and opts.clear_alias), 'Choose --alias or --clear-alias')
    with locked(path):
        config = read(path)
        mode, policies, _ = validate(config)
        before = decode(json.dumps(config))
        allowed = config.setdefault('allowed_inbound_sessions', [])
        agent = config.get('local_agent_id', 'agent')
        listing = opts.action in ('list', 'ls')
        need(not listing or (not opts.keys and not metadata and not opts.force), 'List takes only --json')
        if not listing:
            need(bool(opts.keys), 'Supply a session key')
            need(not metadata or len(opts.keys) == 1, 'Metadata requires exactly one canonical key')
            need(opts.action in ('add', 'update') or not metadata, 'Metadata applies to add/update only')
            for raw in opts.keys:
                key = raw if ':' in raw else 'agent:' + agent + ':' + raw
                owner(key)
                if metadata or opts.action == 'update':
                    need(raw == key, 'Metadata operations require an exact canonical key')
                    exact(key)
                if opts.action in ('remove', 'rm'):
                    need(opts.force or key not in ('agent:' + agent + ':main', 'agent:' + agent + ':antenna'),
                         'Core session: use --force to remove')
                    if key in allowed:
                        allowed.remove(key)
                    policies.pop(key, None)
                else:
                    need(opts.action != 'update' or key in allowed, 'Session is not allowlisted')
                    if key not in allowed:
                        allowed.append(key)
                    if metadata:
                        entry = policies.setdefault(key, {'entry_id': str(uuid.uuid4()), 'alias_revision': 0, 'inbox': False})
                        previous = entry.get('alias')
                        if opts.alias is not None:
                            entry['alias'] = opts.alias
                        elif opts.clear_alias:
                            entry.pop('alias', None)
                        if previous != entry.get('alias'):
                            entry['alias_revision'] += 1
                        if opts.inbox is not None:
                            entry['inbox'] = opts.inbox == 'yes'
            if policies or 'session_policies' in config:
                config.update(session_policy_version=1, session_policies=policies)
            transition(before, config, managed=True)
            write(path, config)
        rows = [{'key': key, 'alias': alias_address(key, policies[key]['alias']) if policies.get(key, {}).get('alias') else None,
                 'inbox': policies.get(key, {}).get('inbox', False)} for key in allowed]
    if opts.json:
        print(json.dumps({'ok': True, 'inbox_mode': mode, 'sessions': rows}))
    else:
        print('Allowed inbound sessions (inbox mode: ' + mode + '):')
        for row in rows:
            print('  ' + row['key'] + '  alias=' + (row['alias'] or '—') + '  inbox=' + ('yes' if row['inbox'] else 'no'))


def validate_queue(queue):
    need(isinstance(queue, list), 'Inbox must be an array')
    refs = set()
    for item in queue:
        need(isinstance(item, dict), 'Invalid inbox item')
        need(type(item.get('ref')) is int and item['ref'] not in refs, 'Invalid/duplicate inbox ref')
        refs.add(item['ref'])
        binding = item.get('binding')
        if binding is not None:
            need(isinstance(binding, dict) and binding.get('canonical_key') == item.get('session_key') and
                 binding.get('canonical_key') == item.get('target_session'), 'Invalid inbox canonical binding')
            owner(binding['canonical_key'])
            need(binding.get('reference_kind') in ('alias', 'canonical', 'uuid') and
                 isinstance(binding.get('original_reference'), str) and
                 isinstance(binding.get('resolved_reference'), str), 'Invalid inbox reference')
            if binding['reference_kind'] == 'alias':
                address = binding['resolved_reference']
                need(address == alias_address(binding['canonical_key'], address.split(':')[-1]), 'Invalid alias binding')
                need(isinstance(binding.get('entry_id'), str) and str(uuid.UUID(binding['entry_id'])) == binding['entry_id'] and
                     type(binding.get('alias_revision')) is int and binding['alias_revision'] > 0, 'Invalid alias generation')
    return queue


def queue_path(config, path):
    q = Path(config.get('inbox_queue_path', 'antenna-inbox.json'))
    return q if q.is_absolute() else Path(path).parent / q


def stage_queue(source_config, stage, destination):
    # Upgrade owns the stopped-dispatch boundary. Preserve a custom relative
    # queue at its same relative path, never overwrite candidate program files.
    config = read(source_config)
    relative = Path(config.get('inbox_queue_path', 'antenna-inbox.json'))
    source = queue_path(config, source_config)
    if source.exists():
        need(not source.is_symlink() and source.resolve() == source.absolute(), 'Symlinked inbox path refused')
        validate_queue(read(source))
    if relative.is_absolute():
        # External queue remains external and unchanged; no older snapshot copy.
        return
    need('..' not in relative.parts and all(not part.startswith('.') for part in relative.parts),
         'Custom inbox path must stay inside the installation')
    if relative == Path('antenna-inbox.json') or not source.exists():
        return
    need(relative.parts[0] not in ('agent-runtime', 'agent', 'keys', 'secrets'), 'Inbox path conflicts with protected state')
    target = Path(stage) / relative
    need(not (Path(destination) / relative.parts[0]).exists(), 'Custom inbox path collides with candidate files')
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def main():
    path, action, *args = sys.argv[1:]
    if action == 'sessions':
        sessions(path, args)
        return
    if action == 'stage-queue':
        stage_queue(path, *args)
        return
    if action == 'initialize':
        value = decode(sys.stdin.read())
        validate(value)
        with locked(path):
            write(path, value)
        return
    if action == 'mutate':
        mutate(path, args)
        return
    config = read(path)
    if action == 'validate':
        mode, _, _ = validate(config)
        print(mode)
    elif action == 'validate-queue':
        q = queue_path(config, path)
        if q.exists():
            validate_queue(read(q))
    elif action == 'admit':
        print(json.dumps(admit(config, *args)))
    elif action == 'delivery':
        print(json.dumps(delivery(config, decode(sys.stdin.read()), read(Path(path).parent / 'antenna-peers.json'))))
    else:
        raise PolicyError('Unknown policy operation')


if __name__ == '__main__':
    try:
        main()
    except (PolicyError, ValueError, OSError, KeyError, TypeError) as error:
        print('antenna: ' + str(error), file=sys.stderr)
        if '--json' in sys.argv and 'sessions' in sys.argv:
            print(json.dumps({'ok': False, 'error': str(error)}))
        sys.exit(1)
