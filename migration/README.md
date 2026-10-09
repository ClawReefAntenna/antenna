# Antenna migration app — local candidate oc168-sec002-004.1

Separate local repository; no remote name or public release selected. This kit
is locally fixture-qualified, not a live-host migration or public release.
Compatibility: Ed25519 relay-era v1.6.7 session-policy-v1 state to schema-2/plugin-v2;
experimental schema-1 combined-smart-v1 policy can be exported as schema 2.
Unknown schemas and plaintext signing peers are rejected, not guessed.

## Rehearse on an isolated copy

Use the receiver-owned selection JSON in [manual migration](../plugin/MIGRATION.md).
A dry-run prints only the report. Supplying a new staging directory writes private
preimages, disabled native policy, peer/config candidates and a hash-bound plan.

```sh
node migration/cutover.mjs stage LEGACY_ROOT HOST_JSON SELECTION_JSON
node migration/cutover.mjs stage LEGACY_ROOT HOST_JSON SELECTION_JSON NEW_STAGE APPROVALS_JSON
```

The optional approvals file defaults to `exec-approvals.json` beside HOST_JSON
when present. Supply its actual path if the host uses another state directory.
All inputs must be bounded (8 MiB per file), owned regular files without symlinks
or hard links. Host JSON must already be resolved; use OpenClaw's configuration
commands for JSON5/includes. The token must also be private and at most 16 KiB.
No credential is printed. Stage directories are 0700, files 0600; they contain
credentials and are recovery material, not distributable kit contents.

## Cut over while stopped

Stop the selected gateway and **all** Antenna writers first. This interrupts host
service; schedule it deliberately. Review the staged changes, then:

```sh
node migration/cutover.mjs apply NEW_STAGE --writers-stopped
```

The flag records the operator's stopped-writer prerequisite, not another approval
prompt. A Linux `/proc` check also refuses detected gateway/relay/native writers.
It cannot observe other PID namespaces, remote hosts or a future process start;
keep the host quiescent throughout. Other systems use the manual workflow.
The app never stops/starts services, invokes old setup, enables the plugin,
rotates credentials, sends messages or automatically rolls back.

Owned relay roster entries must have the configured relay ID and exactly the old
root's `agent` workspace. Remove their agent-specific hook allow entry and known
Bash/echo/jq/cat approvals only; custom approvals and other agents remain.
Ambiguous agent ownership or direct relay hook mappings require manual review,
not a wider automatic deletion. Broad hooks, hook tokens, session visibility,
model registrations, signing identities, lists and group grants stay unchanged.
Legacy pending, approved-but-unsent and failed inbox items remain untouched.
Existing HTTP URLs are retained without acknowledgment; HTTPS is never downgraded.

No temporary-file sweep occurs. To remove confirmed obsolete relay input, add
`obsoleteTemps` entries to the selection with exact `path`, `sha256` and
`obsolete: true`. Only private, owned, single-link historical temporary filenames
under `/tmp` are eligible. Staging retains a private recovery copy. Cleanup occurs
only after stopped-host retirement; inbox, replay, keys and recovery paths do not
qualify. If a file is still unresolved, leave it out.

## Interrupted cutover and recovery

Every target must match its original or planned hash before any write. Changes
to other inputs, newly appeared native state, or changed staged bytes stop the
operation. Each replacement is validated JSON, fsynced, privately backed up and
atomically renamed with a final source comparison. Cooperating writers use locks;
these checks are not an atomic CAS against unrelated programs. Keep writers stopped.

After interruption, remain unavailable. Preserve NEW_STAGE and its RECOVERY.txt;
rerun the same apply only if its checks pass. It skips exact completed targets.
Do not restore the old relay or broad shell approvals from preimages. To abandon
cutover, leave Antenna disabled and recover unrelated settings manually from the
private copies. New holds and replay data must not be replaced by old snapshots.
This is operator recovery, not seamless downgrade or automatic rollback.

The native plugin/companion assets still need installation separately. Then verify
existing destinations, operator credential separation and scanner selection,
explicitly enable/restart, and live-probe admission before advertising migration.
The guide describes optional general-hook token rotation; it is not mandatory.
Publication and each live-host cutover remain separately authorized actions.

## Schema-only export and checks

```sh
node migration/cli.mjs HOST_JSON NEW_POLICY_JSON
node plugin/migration-check.mjs doctor HOST_JSON COMPANION_ROOT
node migration/schema-test.mjs
node migration/cutover-test.mjs
node plugin/tests/config-write.mjs
node plugin/tests/migration-doctor.mjs
```

Schema export never applies host settings or changes inbox data. Explicit per-peer
and per-destination approval bits remain independent of MCS. Combined legacy
Smart becomes Both. The artifact manifest binds version, source and file hashes.
