# 🦞 Antenna for OpenClaw v1.6.9 — A Lighter Kit

Your everyday messaging kit now carries just what it needs. Diagnostics and legacy
migration tools are separate from the native plugin and companion.

**Documentation correction — October 9, 2026:** Updated the guides and examples
for standalone diagnostics and the separate migration app. Runtime code is unchanged.

## What changed

- A smaller everyday install, with diagnostics available as an optional download.
- Configuration changes now keep private recovery copies.
- Tighter checks for Smart responses, metadata files and gateway connections.
- Restore schema-2 backups from v1.6.8 or v1.6.9. New backups are marked v1.6.9.
- Clearer guidance on signed messaging, model screening and Registry report privacy.

## Install or update

Install `antenna-native-1.6.9.tgz` with the matching
`antenna-companion-1.6.9.tgz`. The optional diagnostics asset is
`antenna-diagnostics-1.6.9.tgz`. Verify the selected release's SHA-256 manifest.
Start with the [User Guide](references/USER-GUIDE.md#install-and-configure).

Updating from native v1.6.8? Your existing connections and permissions carry
forward; no relay migration is needed. Requires OpenClaw **2026.9.5 or newer**.
Tested platform: Linux.

Legacy relay installations still need coordinated manual migration. The migration
app has not yet been published and is not included in these downloads.
See [optional kits](plugin/OPTIONAL-KITS.md#migration).

## Recovery and security

Before replacing packages, stop the gateway and preserve your Antenna state.
A backup is recommended; keep the previous matched packages if you may need to
roll back. Follow the [recovery guide](references/BACKUP-AND-READINESS.md) for
restore steps and version compatibility.

Your existing permissions and screening choices stay yours. See the
[Security Policy](SECURITY.md) for privacy and screening details.
