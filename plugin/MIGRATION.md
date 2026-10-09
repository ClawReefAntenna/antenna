> Local fixture-qualified candidate: see [stopped-host app and recovery](../migration/README.md). Live cutover and release qualification remain separate.

# Explicit legacy migration — v1.6.8

Compatibility tier: **documented manual migration**, not seamless live compatibility.
Do this against an isolated copy first. The original preparation commands below do not apply changes. The separate
[cutover command](../migration/README.md) can retire an attributable relay on a
stopped host; it never rotates credentials, restarts a gateway, drains an inbox
or enables the plugin.

## Scope and complexity

User need: carry an existing installation into the signed plugin transport without
losing identities, permissions or deliberate holds. Smallest solution: offline
preparation, existing config files, explicit operator cutover, one-shot sends.
Budget: approximately 400 added runtime lines in Antenna, reusing the signed wire
and inbox; a small Registry binding plus copies of those wire/transport helpers.
No new database, recovery journal, daemon, automatic retry, receipt service or
old/new OpenClaw ingress stack. New files are operator-selected staging output
and ordinary contact/key files, not a second live inbox. Failure means refusal
or operator recovery. Stop/reassess before adding automatic rollback or a second
legacy dispatcher. Publication and each live cutover require separate authorization.

## 1. Prepare, do not activate

Install/package the plugin as described in README, leaving it disabled. Retain the
companion scripts/lib/bin and plugin directory together for existing CLI callers.
Create a receiver-owned selection JSON:

```json
{
  "mcs": "dumb",
  "destinations": {"agent:betty:main": "agent:betty:main"},
  "inboxFile": "/absolute/new-state/inbox.json",
  "replayFile": "/absolute/new-state/replay.json",
  "outbound": {
    "remote-peer": {
      "profile": "antenna-plugin-v2",
      "default_target": "receiver-approved-destination"
    }
  }
}
```

The destination values must preserve the exact old allowlist. Keep existing
canonical addresses and any still-used aliases as keys where appropriate;
otherwise coordinate changed addresses explicitly. No UUID/session discovery
or destination creation is attempted. Choose MCS explicitly; Smart/Both require
subsequent scanner validation. Previously combined Smart means Both, not Smart.

```text
node plugin/legacy-migration.mjs LEGACY_ROOT HOST_JSON SELECTION_JSON
node plugin/legacy-migration.mjs LEGACY_ROOT HOST_JSON SELECTION_JSON NEW_STAGING_DIR
node plugin/migration-check.mjs sources NEW_STAGING_DIR/report.json
```

Preparation reads the recognized version-1 session policy, Ed25519 pins and old
inbox array. It stages `host.json`, `config.json`, `peers.json`, and a hash/report
file with private permissions. Originals remain byte-identical. Staged host config
retains unrelated settings and **keeps the plugin disabled**. It is not a ready-to-
enable cutover config: destinations and operator authentication still require verification. Hook settings are retained; rotation is recommended, not required.

Global inbox On/Off, per-session allowlist approval and peer auto-approval are
mapped independently of MCS. Lists and group registrations are left in place;
Join/Post/Create grants are not re-enrolled or altered. Existing HTTP URLs retain
explicit plaintext opt-in in staged peers and appear in the preview. Signatures
do not encrypt content. Unknown layouts/plaintext-legacy signing peers stop;
re-pair or document their manual conversion rather than inventing identities.

### Existing held messages

An old queue item is not a receiver-addressed v2 signed envelope. Rewriting it
and inventing a signature would change its evidence. The old file stays untouched
and must remain non-deliverable after cutover. Preparation counts pending,
approved-but-unsent and failed/uncertain items as unresolved. Resolve explicitly
before cutover, or retain the old queue as a read-only recovery artifact and request
a newly signed resend after operator review. Never automatically resend uncertain
work. This version does **not** provide in-place legacy hold release under v2.
Existing native policy can use the separate schema exporter; it does not touch
schema-2 plugin holds, their exact payloads or their reasons. No migration silently approves an item.

## 2. Manual cutover checklist

1. Preview the staged diff and verify source hashes immediately before changes.
   Take rollback material with existing backup/config tools; encryption is optional.
2. Stop Antenna ingress and its writers/drains. If that requires stopping the host
   gateway, schedule that interruption explicitly. Do not run old/new writers together.
3. Install the version-matched plugin and companion CLI assets. Merge the staged config,
   preserving native installer load paths/allowlist and all unrelated plugin settings.
   Keep it disabled while resolving the remaining steps. Copy staged config/peers
   into their intended legacy paths only after reviewing their diffs.
4. Review the existing hooks credential. Rotation is recommended, not required.
   If rotating, update other integrations using it; do not distribute the replacement
   to Antenna peers. Retaining it must not block migration. Keep resolved operator
   authentication separate from both the retained peer token and plugin bearer.
5. Remove only confirmed Antenna-owned relay agent/mapping/cron/drain provisioning.
   Review customized or shared entries instead of deleting by name. Preserve other
   hooks, agents, sessions, lists, signing keys, pins, group registrations and grants.
6. Confirm targets already exist and scanner readiness if selected. Explicitly enable
   and allowlist the plugin, then restart. The static check is local-only:
   `node plugin/migration-check.mjs doctor HOST_JSON LEGACY_ROOT`.
7. Probe the public plugin route and verify signed admission and denial of operator
   access with peer credentials. If hooks were rotated or disabled, verify denial on
   `/hooks/agent`, `/hooks/wake` and alternate/encoded hook paths. If retained,
   general hooks may still accept the old credential outside Antenna checks; do not
   claim whole-gateway bypass closure. Plugin failure must not fall back to hooks.
8. Only now advertise the receiver's v2 transport. Switch each sender's peer profile
   explicitly. Unmigrated targets are unsupported; a timeout never selects old hooks.

Migrated companion setup/upgrade/pair/exchange/uninstall/inbox scripts refuse their
old operations; they cannot knowingly recreate the relay or drain old holds. Use
native plugin lifecycle commands, the new contact tool, and plugin inbox commands.
Old backups and copies of old scripts are not patched: keep them offline.

**Existing hooks credential:**

> v1.6.8 no longer uses your gateway hooks token. Previously paired Antenna peers may still hold copies. We recommend rotating it to revoke non-essential general-hook access. If you rotate it, update any other integrations using that token. If you retain it, those copies may remain valid for enabled gateway hooks, outside Antenna’s checks.

## 3. Contact exchange, direct sends and replies

No re-pair is needed merely to retain an existing safe key/bearer. To exchange a
new or updated contact:

```text
node plugin/pairing.mjs export LEGACY_ROOT HOST_JSON PRIVATE_CONTACT_FILE
node plugin/pairing.mjs import LEGACY_ROOT PRIVATE_CONTACT_FILE EXPECTED_PEER DEFAULT_TARGET
```

The output is **credential-bearing, private, and not encrypted**. Transfer it only
through an authenticated encrypted channel (existing age exchange may be used as
an external wrapper). Export warns about retained general-hook access and refuses shared operator authority; import requires
an explicit identity/destination, a fresh v3 contact, and continuity of an existing
signing pin. It never grants inbound/outbound permission. Review plugin inbound pin
configuration separately. Old bundle consumers reject version 3 rather than treating
its bearer as general-hook authority. Orphaned files after an interrupted import are
inert; inspect/remove them manually, never guess which contact was selected.

`antenna send`, `antenna msg`, list sends and Public Group posting retain their
existing front ends. The migrated root setting selects the new sender. Peer entries
need `transport_profile: "antenna-plugin-v2"` and `default_target`, plus existing
URL, token-file and signing identity fields. Explicit `--session` wins. New named
list destinations may be supplied through a peer default; old list schemas continue
to accept their existing canonical session keys.

Replies are explicit new sends to a configured peer and approved destination.
`--reply-to` / `--reply-session` are signed metadata, never authority to send to an
arbitrary URL. No automatic final-response or ACK echo is introduced. Body UTF-8,
including initial BOM and terminal newlines, is retained. Held/submitted are not
proof of agent processing. Lost or invalid confirmation is unknown; no retry.

## 4. Registry coordination

The coordinated ClawReef v2 binding adds a v2 binding beneath its configured API base:
`/registry/api/antenna/v1/receive` for the source tree's normal base path. Configure
the Antenna Registry peer URL as that API base, not a general OpenClaw hook URL.
Set a dedicated `CLAWREEF_ANTENNA_TOKEN` for that application route and explicitly
list migrated receiver identities in `CLAWREEF_ANTENNA_V2_PEERS` (comma-separated).
Existing host token storage holds each selected receiver's Antenna-only bearer;
no new grants/database schema or automatic discovery is introduced.

Public Group admission reuses signature, membership, replay, rate and independent
Post permission checks. The Registry signs one receiver-addressed envelope per
recipient and preserves its attested author/group body. Host-default delivery uses
the explicitly registered host default; selected sessions remain explicit. A v2
submission reports unmigrated recipients as unsupported, never tries their raw hook.
Old submissions retain old behavior for old targets. Per-recipient held/submitted/
unknown/unsupported dispositions are retained; the caller receives aggregate counts.
Public HTTPS deployment, proxy routing and live rollout remain separate qualification.

## 5. Rollback and uninstall

Disable the plugin and stop admission first. Retain config, keys, replay state and
both new holds and read-only legacy recovery material. Native plugin uninstall must
not be followed by an old installer automatically. Rollback of program files is not
permission to restore a peer-known general-hook credential or drain new holds through
an old client. If old code cannot read retained state safely, remain unavailable until
explicit operator recovery. No seamless downgrade or live migration is promised.

## 6. Plugin-native recovery

v1.6.8 provides its own encrypted backup and confirmed in-place restore. It rejects
legacy archives; use v1.6.7 for legacy recovery before migration. The companion
[recovery guide](https://github.com/ClawReefAntenna/antenna-openclaw/blob/v1.6.8/references/BACKUP-AND-READINESS.md) covers commands and scope.
A plugin restore leaves the plugin disabled, preserves exact holds and replay data,
and never activates, approves or resends. Existing legacy holds remain recovery
material, not converted v2 messages.
