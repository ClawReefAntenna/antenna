#!/usr/bin/env python3
"""Prepare a private legacy rollback projection. Does not activate or send.
Run only while dispatch is stopped; export is NOT a live downgrade command.
"""
import argparse
import sys
import json
import os
from pathlib import Path
import shutil
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import session_policy as p


def export(config_path, output):
    output = Path(output)
    p.need(not output.exists(), 'Output already exists; choose a new private directory')
    config_path = Path(config_path)
    with p.locked(config_path):
        config = p.read(config_path)
        mode, policies, _ = p.validate(config)
        queue_path = p.queue_path(config, config_path)
        with p.locked(queue_path):
            queue = p.validate_queue(p.read(queue_path)) if queue_path.exists() else []
    projected = dict(config)
    for key in ('session_policy_version', 'session_policies', 'inbox_mode'):
        projected.pop(key, None)
    projected['inbox_enabled'] = mode != 'off'
    if mode == 'allowlist':
        projected['inbox_auto_approve_peers'] = []
    # Never leave an absolute/custom queue pointing at the unprojected live queue.
    projected['inbox_queue_path'] = 'antenna-inbox.json'
    quarantine = [x for x in queue if x.get('binding', {}).get('reference_kind') == 'alias']
    safe = [x for x in queue if x not in quarantine]
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.antenna-rollback.', dir=output.parent))
    try:
        values = {'antenna-config.json': projected, 'antenna-inbox.json': safe,
                  'quarantined-alias-inbox.json': quarantine,
                  'session-policy-archive.json': {'session_policy_version': config.get('session_policy_version'),
                                                'session_policies': policies, 'inbox_mode': mode},
                  'projection.json': {'activated': False, 'original_mode': mode, 'quarantined_items': len(quarantine),
                                     'legacy_inbox_enabled': projected['inbox_enabled'],
                                     'broader_review': mode == 'allowlist',
                                     'instructions': 'Keep dispatch stopped; use the supported upgrade/rollback procedure to activate config and projected queue together. Preserve keys, peers, newer permissions and quarantine. Reconcile install_path for the chosen install. Alias senders must use canonical keys.'}}
        for name, value in values.items():
            file = temporary / name
            with open(file, 'x') as handle:
                os.fchmod(handle.fileno(), 0o600)
                json.dump(value, handle, indent=2); handle.write('\n')
        os.rename(temporary, output)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return values['projection.json']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--dispatch-stopped', action='store_true', required=True,
                        help='Assert that dispatch is stopped for this offline snapshot')
    args = parser.parse_args()
    try:
        print(json.dumps(export(args.config, args.output)))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\n')
