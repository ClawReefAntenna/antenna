# SIG-001 Implementation Report

**Date:** 2026-08-11

**Branch:** `dev/signature-minimal`

**Status:** implementation and deterministic verification complete; independent
security review still required

## Delivered vertical slice

- Normative `antenna-ed25519-v1` envelope and canonical-byte contract with a
  fixed RFC 8032-derived vector.
- OpenSSL Ed25519 key generation, validation, fingerprint, signing, and
  verification primitives.
- Byte-preserving strict parser for unique LF-framed Antenna envelopes.
- Exact sender-side signing of protocol, sender, timestamp, UUID message ID,
  optional metadata, and UTF-8 body bytes.
- Receiver-side verification with the claimed sender's locally pinned public
  key.
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

- `tests/ed25519-v1.sh`: 35/35 passing, including the fixed vector, parser,
  Unicode and terminal-LF bodies, all canonical-field tampering, missing/wrong
  keys, freshness configuration, replay persistence/capacity/corruption, and
  concurrency.
- Hermetic Tier A: 20/20 passing.
- All 20 deterministic `tests/*.sh` scripts passed in an isolated seeded skill
  copy.
- Bash syntax, Python compile, and `git diff --check` clean. ShellCheck was not
  available on this host and remains a review-time check.

## Complexity review

The three new runtime libraries total 197 lines. Tracked runtime changes remove
17 more lines than they add, for approximately **180 net new runtime lines**
against `bb599c7`. No negotiation state, journal, recovery protocol, or second
modern auth mode was introduced. The slice remains below the 200-line scope-
creep review threshold and well below the 300-line stop threshold.

## Remaining gate

A fresh reviewer must examine the protocol and diff from `bb599c7`, focusing on
canonical-byte agreement, OpenSSL invocation, parser ambiguity, key-path trust,
replay ordering/state failure, and denial-of-service behavior. Do not begin
SIG-002 or live-host validation until that review clears.
