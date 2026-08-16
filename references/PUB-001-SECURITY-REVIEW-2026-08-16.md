# PUB-001 Independent Security Review

**Date:** 2026-08-16
**Disposition:** CLEARED for bounded PUB-002 implementation; not cleared for
deployment or publication

## Reviewed boundary

- signature-only Public Group submission protocol;
- generated fixture and its negative tests;
- current Antenna Ed25519 canonicalization/replay behavior;
- recovered ClawReef host schema, host APIs, sanitizers, and outbound Antenna
  sender; and
- ciphertext, membership, hook-token, and endpoint trust boundaries.

No production route, migration, credential, live host, or public surface was
changed by this review.

## Threats reviewed

- unregistered, disabled, revoked, wrongly signed, removed, or muted senders;
- ciphertext, wrapper, inner-message, revision, key-set, and message-ID tamper;
- sender and recipient replay, stale/future messages, and rate exhaustion;
- directory key substitution, first-contact trust, membership injection, and
  key replacement/recovery;
- membership changes racing submission and fan-out;
- parser ambiguity, oversized bodies, expensive unauthenticated work, and host
  enumeration;
- hook-token disclosure, database-row substitution, and overbroad secret
  access; and
- registered-endpoint SSRF, redirects, DNS rebinding, and metadata-service
  access.

## Findings corrected in PUB-001

1. **High — redundant bearer authentication.** Resolved before this review:
   the registered Ed25519 host key authenticates submissions; CR-PROD-002 is not
   a Public Group dependency.
2. **High — recipient sender-key authority was underspecified.** Recipients now
   require an already pinned group identity roster. Delivery wrappers cannot
   introduce or replace sender keys.
3. **High — recipient-set race could contact a post-encryption member.** The
   protocol now captures authorization, revision/key-set validation, replay
   reservation, and exact recipient IDs in one local database transaction.
   Later additions apply only to later messages.
4. **High — host-key replacement relied too heavily on an account session.**
   Enrollment now requires proof of possession; normal replacement also
   requires the old key. Lost-key recovery revokes/suspends first and forces
   explicit new-fingerprint approval.
5. **Medium — exact replay TTL had no pruning margin.** Retention is now at
   least 420 seconds for a 300-second age plus 60-second future window.
6. **Medium — HTTP/parser and work-order requirements were incomplete.** The
   protocol now requires pre-buffer body limits, exact types, duplicate/unknown
   key rejection, canonical encodings, generic authentication failure, and
   signature/rate admission before avoidable ciphertext work.
7. **High — hook-token row swapping and raw-owner exposure were not explicit.**
   AES-GCM additional authenticated data now binds host, purpose, and version;
   raw hook-token/identity-secret owner APIs must be removed before launch.
8. **High — fan-out endpoint SSRF was not addressed.** The protocol now requires
   verified HTTPS endpoints, redirect denial, DNS/connection-address checks,
   and explicit allowlists for any supported private/tailnet ranges.
9. **Important trust limitation — malicious membership authority.** ClawReef
   cannot decrypt ciphertext sent to the legitimate key set, but a fully
   compromised membership service could inject a future recipient unless
   membership changes are independently approved or signed. v1 now states this
   limitation and must not claim protection from a malicious membership
   authority.

## Verification

- PUB-001 hardened fixture: 25/25;
- Antenna deterministic suite: 24/24 scripts;
- focused Ed25519 suite: pass;
- release-readiness: 9/9;
- ClawHub dry run: 62 files, no PUB-001 evidence/spike leakage;
- targeted sensitive-pattern scan: clean; and
- `git diff --check`: clean.

New fixture coverage includes recipient replay, wrapper/inner mismatch,
unpinned sender verification failure, and post-authorization member injection.

## Mandatory PUB-002 implementation gates

These are not optional polish and must pass before any live test or deployment:

1. Add host Ed25519 and age-key-binding storage with proof-of-possession,
   replacement, revocation, recovery, and group-revision semantics.
2. Implement exact schema parsing, body caps, signature verification,
   transactional replay reservation/recipient capture, and bounded rate limits.
3. Encrypt hook tokens with versioned AES-256-GCM plus host/purpose/version AAD;
   eliminate raw secret values from owner API responses and operator views.
4. Add verified-endpoint egress controls and SSRF tests, including redirect and
   DNS-rebinding cases.
5. Implement recipient decrypt/strict-parse/pinned-key verification,
   wrapper-inner comparison, freshness, replay, and local policy admission.
6. Test concurrency, timeout, partial-delivery, log redaction, storage failure,
   group changes, key changes, and 256-recipient resource use in the real stack.
7. Keep ciphertext non-durable, permit no plaintext fallback, and add no retry
   queue or LLM decision path.

## Decision

The corrected PUB-001 architecture is internally coherent and its fixture
supports the claimed feasibility. No unresolved design flaw requires another
architecture spike. PUB-001 is therefore security-cleared for a deliberately
bounded PUB-002 implementation, but this review is not permission to implement,
deploy, publish, or market PUB-002. Production clearance requires review of the
actual TypeScript, database migration, Antenna recipient code, and live-test
evidence against every gate above.
