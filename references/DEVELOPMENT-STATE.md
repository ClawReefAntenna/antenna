# Antenna Development State

**Maintainer baseline:** 2026-08-08  
**Checked-out baseline:** `v1.5.2`, commit `6f48bec` (`local-v1.4` / public `origin/main`)  
**Development branch:** `dev/signature-minimal`

## Current truth

- v1.5.2 added the transport-first pairing wizard (Email / ClawReef / Manual).
- The current relay-agent contract is `write` the raw envelope to a temp file,
  then `exec` `antenna-relay-deliver.sh` with the file path. The wrapper owns
  validation, delivery, and cleanup.
- The current release line retains plaintext runtime-secret authentication with
  constant-time comparison. It does not include `lib/antenna-hmac.sh`.
- Group/broadcast messaging is proposed, not implemented. The controlling
  tracked architecture is now
  `references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`. It separates
  local Distribution Lists from future Public Groups: `@alias` is only a local
  fan-out shorthand, optional visible recipients live in a signed body preamble,
  and Public Group architecture remains deferred.

## Historical branches and notes

- The separate `v1.5` branch contains experimental HMAC-SHA256 canonicalization
  and `secret_mode` work (`67a3cf2`, `dab77d8`). It is not an ancestor of this
  baseline and must not be described as shipped.
- `docs/` is local/ignored working material. It contains useful history but
  includes stale baselines, unpruned REF statuses, and obsolete architecture
  assumptions.

## First maintenance objective

Implement the bounded SIG-001 signed-unicast vertical slice. Stop for complexity
and security review before legacy migration, Distribution Lists, or Public
Group/ClawReef work.

The completed HMAC-minimal branch is retained as
`archive/hmac-minimal-study`; it is evidence and a source of selectively
reusable parser/replay tests, not the release architecture.

## Release boundary

Local commits may be prepared on `dev/signature-minimal`. Betty owns pushes, tags,
GitHub Releases, ClawHub publication, and any public announcement.
