# Antenna Four-Phase Development Status

**Date:** 2026-08-11

**Public baseline:** v1.5.2 / `6f48bec`

**Development branch:** `dev/signature-minimal`

**Release status:** none of the four-phase work below has been merged, pushed,
tagged, published, or installed on live hosts.

## Status at a glance

| Phase | Product outcome | Engineering slices | Status |
|---|---|---|---|
| 1 — Signed identity | Ed25519 sender identity, canonical signed envelopes, freshness and replay rejection | SIG-001 | Complete and independently reviewed |
| 2 — Migration | Explicit `ed25519-v1` or warned `plaintext-legacy`; migration by fresh encrypted re-pair | SIG-002 | Complete and owner-reviewed |
| 3 — Distribution Lists | Local `@alias` fan-out with optional signed visible-recipient context | DL-001, DL-002 | Complete and owner-reviewed |
| 4 — Public Groups | Encrypted ClawReef-mediated current-membership delivery without pairwise hook-token disclosure | PUB-001, PUB-002 | Architecture recorded; phase paused before PUB-001 |

The project is at a validation boundary, not an automatic Phase 3 → Phase 4
handoff. Phases 1–3 must prove themselves live and pass release-candidate review
before PUB-001 may be reconsidered.

## Phase 1 — Signed identity

Modern Antenna messages are signed by the sender's Ed25519 private identity key
and verified against a locally pinned public key. The signed canonical bytes
cover sender, timestamp, message ID, optional routing/user metadata, and exact
body bytes. Freshness and persistent bounded replay rejection apply before
delivery.

Controlling evidence:

- `references/ED25519-PROTOCOL-V1.md`
- `references/SIG-001-IMPLEMENTATION-REPORT.md`
- `references/SIG-001-SECURITY-REVIEW-2026-08-11.md`

## Phase 2 — Migration

Each peer uses exactly one explicit authentication mode: `ed25519-v1` or
`plaintext-legacy`. There is no silent fallback, dual acceptance, negotiation,
automatic downgrade, rotation state machine, journal, or recovery protocol.
Existing peers migrate only through a fresh operator-approved encrypted re-pair.

Controlling evidence:

- `references/SIG-002-SCOPE-CONTRACT.md`
- `references/SIG-002-IMPLEMENTATION-REPORT.md`
- `references/SIG-002-SECURITY-REVIEW-2026-08-11.md`

## Phase 3 — Distribution Lists

Distribution Lists are local address-book aliases, not protocol groups.
`@alias` expands to independent existing unicasts. Optional visible-recipient
metadata is part of the signed body. Antenna adds no reply-all or list-sharing
workflow; agents and humans may use the visible peer IDs in ordinary sends.
There is no shared membership authority, revision, thread,
synchronization, retry, or delivery transaction.

Controlling evidence:

- `references/DL-001-SCOPE-CONTRACT.md`
- `references/DL-001-IMPLEMENTATION-REPORT.md`
- `references/DL-001-OWNER-REVIEW-2026-08-11.md`
- `references/DL-002-SCOPE-CONTRACT.md`
- `references/DL-002-IMPLEMENTATION-REPORT.md`
- `references/DL-002-OWNER-REVIEW-2026-08-11.md`

## Phase 4 — Public Groups

Public Groups deliberately use a different delivery model. ClawReef is the
current-membership authority, hook-token custodian, and deterministic fan-out
service. A sender signs one recipient-neutral Antenna message, age-encrypts it
once to all current member public keys, and uploads one opaque ciphertext.
ClawReef forwards the same ciphertext without a model call and cannot decrypt
it. Direct unicast and Distribution Lists remain peer-to-peer.

Phase 4 is split into two gates, both currently blocked:

1. **PUB-001 — bounded protocol and fixture-only feasibility proof.** Fix the
   sender authentication, request/wrapper schemas, key binding and pinning,
   membership/key-set freshness, recipient decrypt contract, limits, result
   semantics, metadata logging, and token-storage controls. Prove one-ciphertext
   multi-recipient fan-out with fixtures only—no real tokens or live delivery.
2. **PUB-002 — production implementation.** Only after PUB-001 review, build
   the ClawReef endpoint and credential custody together with Antenna
   multi-recipient encryption/decryption, then run a controlled multi-host
   matrix.

PUB-001 is not authority to add a production endpoint, database migration,
live credential, group UI, retry queue, content store, receipt system, shared
group key, plaintext fallback, or LLM relay logic.

PUB-001 may begin only after controlled live validation of Phases 1–3,
release-candidate review, evidence of concrete Public Group need, and explicit
authorization. Roadmap position alone is not sufficient.

Controlling architecture:

- `references/PUBLIC-GROUP-RELAY-ARCHITECTURE-2026-08-11.md`
- `references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`

## Release boundary

Completion here means locally implemented and reviewed on the development
branch. It does not mean publicly released. Betty retains authority over merge,
remote push, tags, GitHub Releases, ClawHub publication, live-host rollout, and
public claims.
