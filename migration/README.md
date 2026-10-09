# Antenna migration app — local candidate oc168-sec001.1

Separate local repository candidate; no remote name or public release selected.
This is preparation, not a qualified migration release. OC168-SEC-002–004 still
cover retirement/cleanup, conversion semantics and configuration-write safeguards.

Compatibility: Ed25519 relay-era v1.6.7 state to schema-2/plugin-v2 candidate;
experimental schema-1 combined-smart-v1 policy can be exported as schema 2.
Unknown schemas/plaintext peer modes are rejected, not guessed. Existing HTTP
URLs are preserved without an additional acknowledgment. No legacy installer,
relay starter, model administrator or relay-policy restoration is included.

Commands (from this repository):

```sh
node plugin/legacy-migration.mjs --help
node plugin/migration-check.mjs sources /private/staged/report.json
node plugin/migration-check.mjs doctor /private/openclaw.json /private/companion
node migration/cli.mjs /private/openclaw.json /private/new-policy.json
```

The staging tool's actual arguments are documented in [manual migration](../plugin/MIGRATION.md).
The schema exporter writes only a new private policy file; it does not apply it
or modify host/inbox state. Review and apply via the selected host's supported
configuration workflow after qualification. Preserve original state/backups.
Run the included fixture tests; passing them does not close the pending tickets.
The artifact manifest records source revision, compatibility and every file hash.
