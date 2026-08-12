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
- Public Group messaging is proposed and not implemented. Local Distribution
  Lists are implemented only on the unreleased development branch. The
  controlling tracked architecture records are
  `references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`. It separates
  local Distribution Lists from future Public Groups: `@alias` is only a local
  fan-out shorthand and optional visible recipients live in a signed body
  preamble. `references/PUBLIC-GROUP-RELAY-ARCHITECTURE-2026-08-11.md` defines
  Public Groups separately: one signed multi-recipient age ciphertext is
  submitted to a deterministic ClawReef relay, which holds member hook tokens
  and fans out without a ClawReef model call. No plaintext Public Group mode is
  planned.

## Historical branches and notes

- The separate `v1.5` branch contains experimental HMAC-SHA256 canonicalization
  and `secret_mode` work (`67a3cf2`, `dab77d8`). It is not an ancestor of this
  baseline and must not be described as shipped.
- `docs/` is local/ignored working material. It contains useful history but
  includes stale baselines, unpruned REF statuses, and obsolete architecture
  assumptions.

## Current development position

The signed-unicast and explicit legacy-migration slices are complete at
`00ee65f` and `9992e6a`. DL-001 now adds bounded local `@alias` fan-out over the
existing unicast sender, with strict validation-before-send and no delivery
state or protocol change. DL-002 now adds canonical signed-body visible
metadata, locally filtered reply-all, and credential-free manual snapshots.
Public Group/ClawReef work has not begun. DL-002 owner review is complete and no
task is Active pending authorization for the next bounded slice. See
`references/DL-002-IMPLEMENTATION-REPORT.md`.

Public Group work additionally requires the bounded PUB-001 API/wire
specification and feasibility spike before an implementation branch is opened.
The canonical phase map is
`references/FOUR-PHASE-DEVELOPMENT-STATUS-2026-08-11.md`: Phases 1–3 are
complete and reviewed locally; Phase 4 is ready to begin at PUB-001.

The completed HMAC-minimal branch is retained as
`archive/hmac-minimal-study`; it is evidence and a source of selectively
reusable parser/replay tests, not the release architecture.

## Release boundary

Local commits may be prepared on `dev/signature-minimal`. Betty owns pushes, tags,
GitHub Releases, ClawHub publication, and any public announcement.
