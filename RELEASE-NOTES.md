# 🦞 Antenna for OpenClaw v1.6.9 — A Lighter Kit

Your everyday messaging kit now carries just what it needs. Diagnostics and legacy
migration tools are separate from the native plugin and companion.

## What changed

- Separate, explicit package contents for native messaging, companion/ClawHub,
  diagnostics, and the independently staged migration app.
- Protected configuration writes and recovery preimages; stopped-host legacy
  retirement and interrupted migration handling in the separate migration kit.
- Stricter Smart response validation, safe list-metadata output files, validated
  loopback gateway ports, and cleanup after damaged replay-cache refusal.
- Recovery accepts the explicitly qualified v1.6.8/v1.6.9 schema-2 packages and
  archives; newly created archives identify v1.6.9 as their producer.
- Clearer guidance on signed messaging, model screening and Registry report privacy.

## Install or update

Install `antenna-native-1.6.9.tgz` with the matching
`antenna-companion-1.6.9.tgz`. The optional diagnostics asset is
`antenna-diagnostics-1.6.9.tgz`. Verify the selected release's SHA-256 manifest.
Start with the [User Guide](references/USER-GUIDE.md#install-and-configure).

v1.6.8 native installations keep schema 2 and `antenna-plugin-v2`: no peer remigration
is needed. Preserve identity, permissions, holds and replay data when updating.
OpenClaw **2026.9.5 or newer** remains the API requirement; Linux is the qualified
platform. This does not claim every later host version has been tested.

Legacy relay installations still need coordinated manual migration. The migration
app remains a separate, locally qualified candidate, not a runtime download or an
automatic update. See [optional kits](plugin/OPTIONAL-KITS.md#migration).

## Recovery and security

Back up and stop the intended gateway before replacement. Keep the previous matched
packages and protected state snapshot. If an update fails, leave Antenna disabled;
restore compatible state with the [recovery guide](references/BACKUP-AND-READINESS.md),
review Doctor and policy, then explicitly re-enable. Never reactivate the retired relay.
Restoring an older snapshot can restore revoked grants or lose newer replay entries.

Screening is not a security guarantee. Standing grants, trusted peers and preserved
HTTP peer configuration retain their existing behavior. See the [Security Policy](SECURITY.md).
