# SIG-001 Implementation Report

**Date:** 2026-08-11

**Branch:** `dev/signature-minimal`

**Status:** complete and independently cleared at `00ee65f`

## Delivered vertical slice

- Normative `antenna-ed25519-v1` envelope and canonical-byte contract with a
  fixed RFC 8032-derived vector.
- OpenSSL Ed25519 key generation, validation, fingerprint, signing, and
  verification primitives.
- Byte-preserving strict parser for unique LF-framed Antenna envelopes.
- Exact sender-side signing of protocol, sender, timestamp, UUID message ID,
  optional metadata, and UTF-8 body bytes.
- Receiver-side verification from a private capture of the claimed sender's
  locally pinned public key beneath an owner-controlled `keys/` trust root.
- Bounded, persistent, locked, atomic replay reservation after authentication
  and non-content policy gates but before queueing/delivery.
- Fail-closed inbound and outbound allowlist/config/key behavior.
- Replay-state cleanup on uninstall and runtime-state ignore rules.

## Deliberately absent

- Plaintext legacy mode or migration.
- Pairing/setup integration for signing-key exchange.
- Key replacement or automatic rotation.
- HMAC compatibility.
- Distribution Lists, groups, ClawReef, or message encryption.
- Live-host installation, gateway changes, remote push, tag, or publication.

SIG-001 fixtures configure signing-key references directly. Operator-facing
pairing and migration remain separate work after the security review.

## Verification evidence

- `tests/ed25519-v1.sh`: 67/67 passing, including the fixed vector, canonical
  base64, strict parser negatives, empty/multiline/Unicode/terminal-LF bodies,
  all canonical-field tampering, key-path trust and key-type failures,
  fail-closed allowlists, real stale/future signed envelopes, replay
  persistence/dynamic capacity/recovery/corruption, and concurrency.
- Hermetic Tier A: 20/20 passing.
- All 20 deterministic `tests/*.sh` scripts passed in an isolated seeded skill
  copy.
- Bash syntax, Python compile, and `git diff --check` clean. ShellCheck was not
  available on this host and remains a review-time check.

## Complexity review

The initial implementation was approximately 180 net new runtime lines against
`bb599c7`. Independent review required key-path capture, strict allowlists,
dynamic replay sizing, and bounded input/configuration. The repaired candidate
is approximately **290 net new runtime lines**. It crossed the 200-line review
threshold only to remediate concrete reviewed failure modes, remains below the
300-line stop threshold, and still introduces no negotiation state, journal,
recovery protocol, or second modern authentication mode.

## Gate result

The initial review and follow-up are recorded in
`references/SIG-001-SECURITY-REVIEW-2026-08-11.md`. The follow-up independently
reproduced the focused and Tier A evidence and cleared SIG-001 at `00ee65f` with
no blocking security finding. SIG-002, pairing/setup integration, and any
live-host validation remain separate work and were not authorized by this
clearance.
