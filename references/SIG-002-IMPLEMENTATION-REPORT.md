# SIG-002 Implementation Report

**Branch:** `dev/signature-minimal`

**Status:** implementation and deterministic verification complete

SIG-002 adds exactly two explicit peer modes: modern `ed25519-v1` and warned
`plaintext-legacy`. Sender and relay dispatch by the configured peer mode and
reject missing, unknown, mixed, or opposite-mode envelopes. Legacy secret files
must be owner-only regular files with mode `0600` and contain exactly 64
lowercase hexadecimal characters.

Bootstrap schema v2 declares `from_auth_mode` and carries exactly one matching
credential: an Ed25519 public PEM or a legacy identity secret. Schema v1 remains
importable only as `plaintext-legacy`. Ed25519 PEM is validated before token,
key, or registry mutation and is pinned beneath an owner-controlled `keys/`
directory. Stale unused credential files may remain after re-pair; they are not
referenced and deliberate deletion is outside this slice.

## Manual migration

1. Upgrade both hosts to a build supporting schema v2 and `ed25519-v1`.
2. Exchange current age public keys out of band.
3. Each host creates and imports a fresh encrypted bundle using the default
   `--auth-mode ed25519-v1`.
4. Confirm both peer entries say `auth_mode: ed25519-v1`, then test one message
   each direction.

There is no online negotiation, dual acceptance, rotation, rollback protocol,
journal, retry, or cross-host recovery. If one side is not ready, operators may
explicitly re-pair with `--auth-mode plaintext-legacy`; every legacy send warns.

## Verification

Focused evidence covers exact-mode send/relay behavior, downgrade rejection,
unsafe/missing credentials, mutually exclusive v2 bundles, schema-v1 legacy
mapping, public-key pinning, shared verifier/import Ed25519 validation, and no
mutation on malformed PEM. The focused authentication suite passed 72/72, the
migration suite passed 9/9, hermetic Tier A passed 20/20, REF-1501 passed 16/16,
and the deterministic scripts passed in an isolated seeded copy. SIG-002 adds
+95 net runtime lines against `a6a5757`, below its 200-line stop gate. Owner
review is recorded in `references/SIG-002-SECURITY-REVIEW-2026-08-11.md`.
