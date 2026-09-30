# Backup, restore and readiness — v1.6.7 private candidate

> Retained v1.6.7 legacy recovery guidance. For the 1.6.8-dev.4 plugin candidate,
> start with [the candidate handoff](PLUGIN-CANDIDATE.md) and manual migration.
> Legacy restore/readiness cannot qualify or restore migrated plugin state; preserve
> plugin inbox/replay separately and never restore a peer-known general-hook token.


These commands are implemented in the local candidate, not yet published.
They do not change the messaging transport or implement v1.6.8 staging/MCS.

## Back up and verify

Pause Antenna activity: stop gateway dispatch, state-changing Antenna commands
and inbox drain before capture. The utility never stops or starts services.
If stopping the shared OpenClaw gateway is necessary, other agents using it are
also interrupted. There is no timed waiting period.

```bash
antenna backup create --output /private/backups/antenna.age
antenna backup inspect /private/backups/antenna.age --json
antenna backup verify /private/backups/antenna.age
```

Use a directory controlled by your account. Creation never overwrites an
existing archive. Enter and confirm your chosen passphrase at age's protected
terminal prompt. Creation opens the encrypted archive again for verification
before publishing the completed file, so enter the passphrase again when asked.

**If you lose the passphrase, you cannot recover this backup.** No password is
stored and no automatic unlock is provided. Enter it directly at the terminal,
not in chat: an agent cannot complete this step unattended. Without a usable
terminal the command fails with instructions. `--yes` and `--json` do not bypass
unlock. Cancellation/failure produces no verified-backup claim. Inspect and
verify both currently perform full bounded verification and display only
sanitized metadata, never credentials or message bodies.

## Restore into the existing installation

```bash
antenna backup restore /private/backups/antenna.age
antenna backup restore /private/backups/antenna.age --apply
```

The first command verifies and previews; the second verifies, shows the target
and additions/replacements/removals, and asks for confirmation. The default
target is the installation running the command. `--to /path/to/antenna` selects
another compatible v1.6.7 directory on the same host. No uninstall, empty
installation or manual directory deletion is required. Missing or damaged
current configuration is a supported recovery case. `--apply --yes` accepts
the displayed replacement plan without its confirmation prompt, not without
the passphrase or validation checks.

> This will replace Antenna’s configuration and saved state with this backup. Changes made since the backup—including newer inbox records—will be lost. Installed program files and OpenClaw conversation history will not be changed. Continue?

Keep gateway dispatch and Antenna writers stopped during replacement. Restore
**replaces, not merges**, the explicitly inventoried state. It verifies before
changing files and retains a private temporary copy of displaced state while
replacing it. A failed replacement rolls back; if interrupted or rollback
cannot finish, the reported `.antenna-restore-*` directory contains numbered
copies, a mapping and recovery instructions. Keep activity stopped and retain
that directory until the state is consistent. Successful restore removes its
temporary rollback copy. This is not a permanent backup history service.

Covered state: configuration, peers, referenced credentials and signing/exchange
keys, local lists/Public Group routes, inbox, replay/rate state and recognized
local ClawReef registration records. Old covered entries absent from the backup
are removed. Arbitrary files and shared directories are not deleted.

Program files, gateway settings, CLI links, OpenClaw databases/conversation
history, agent identity/memory, provider auth, logs and caches remain untouched.
Explicit external inbox/credential files are captured individually, not by
copying directories. For restore they are remapped to private local paths
shown in the preview; original external files are not overwritten or removed.
Unknown operational state or unsupported schemas cause a visible refusal,
not a partial “complete” backup. Initial limits: 10,000 payload files, 128 MiB
per file, 512 MiB total payload; no truncation to fit.

### After restore

Review settings and inbox before resuming services or existing drain automation.
Restore does not start services, send messages, approve items or drain queues.
It preserves archived inbox statuses; a restored approved item may already
have been delivered since the snapshot and could be delivered again on normal
drain. An old replay cache also forgets later accepted messages. No exactly-once
recovery guarantee, countdown, recovery-only hold or activation gate is added.

Old settings can restore revoked permissions or obsolete credentials. Gateway
configuration and remote ClawReef grants have not been restored. Use existing
Doctor diagnostics to check compatibility; the backup utility does not repair
remote state or rotate keys. Cross-host cloning and arbitrary version migration
are not supported by this first version.

## Local readiness

```bash
antenna readiness
antenna readiness --json
antenna readiness --gateway /path/to/openclaw.json
```

Default output identifies the target/version, shows problems and warnings with
next actions, keeps unknowns visible and summarizes passed checks. JSON carries
full check results and evidence without secret values. Readiness uses local
files and validators: no network probes, gateway RPC, repairs, chmod, queue
initialization, backup lookup/decryption or service changes. Installed CLI
version is not the running gateway version. Include-owned gateway settings are
reported unknown, not expanded. A missing optional backup is not a blocker.

**Remote-peer readiness: unknown (not checked).** A clean local result means
“No local problems found,” not “safe to upgrade.” Exit codes: 0 completed with
no local failures (warnings/unknowns remain visible); 1 local failures; 2 invalid
invocation or incomplete report. Missing age tools warn because backup is optional.

## Coordinated release notice — private, undated draft

Antenna v1.6.7 adds encrypted state backup, in-place restore and local readiness
while retaining the current messaging transport. v1.6.8 is planned to introduce
deterministic staging and a compatibility change requiring coordinated peer and
ClawReef upgrades. Review the qualified migration guide and coordinate with peer
operators; a backup is optional preparation, not an upgrade prerequisite.

Both builds must be complete, tested and migration/rollback-qualified before
the announcement. v1.6.8 publication is planned seven days after that announcement;
there is no early public breaking test build. **No announcement has been made
and no date has been set.** Before publication, replace this private draft with
approved dated copy and verified migration/rollback links across release notes,
CHANGELOG, ClawReef guidance and packaged notice metadata. The local metadata is
not a live notice feed or evidence of remote publication. This candidate does
not claim remediation of pre-model exposure or scanner clearance. Publication
and live deployment require their separate authorization.
