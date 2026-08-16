# PUB-001 Public Group Feasibility Report

**Date:** 2026-08-16
**Verdict:** VALIDATED
**Status:** owner accepted and security-reviewed; PUB-002 implementation remains
separately gated

## Question

Can one authenticated Antenna sender create one recipient-neutral,
multi-recipient age ciphertext that ClawReef fans out without decryption, while
current recipients authenticate the original sender and all authority/key
conflicts fail closed?

## Artifacts

- Scope: `PUB-001-SCOPE-CONTRACT.md`
- Protocol: `PUBLIC-GROUP-PROTOCOL-V1.md`
- Proof: `../spikes/001-public-group-relay/proof.py`
- Proof instructions/verdict: `../spikes/001-public-group-relay/README.md`

All fixtures use generated identities and credentials under a temporary
directory. The proof opens no network socket, contacts no host, reads no live
credential, changes no database, and retains no ciphertext.

## Chosen protocol shape

1. An outer Ed25519 signature, verified against the sender host's registered
   active public key, authenticates the submission without a separate API key.
2. That signature binds the sender host, group/revision, exact
   key-set digest, message ID, timestamp, and ciphertext size/hash. ClawReef
   verifies this without decrypting.
3. An independently signed inner Public Group message is encrypted once with
   age to every current recipient.
4. Each recipient decrypts, checks wrapper-to-inner identity/group/message
   equality, verifies the original sender, then applies freshness, replay, and
   local delivery policy.
5. ClawReef reserves metadata-only submission replay state and attempts each
   current member exactly once. It keeps no plaintext/ciphertext message store
   and performs no retry or atomic rollback.

The host public key is enrolled or changed through the owner's authenticated
ClawReef account-management session. Submission identity then comes from the
signature, while current Registry records independently authorize membership,
posting role, mute state, and rate limits. Downstream OpenClaw hook tokens
remain separate and never enter group member data, delivered wrappers, or API
responses.

## Evidence

Command:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 spikes/001-public-group-relay/proof.py
```

Final result: **25/25 passed**. The hardened proof was rerun successfully after
each security refinement. It demonstrated:

- one ciphertext copied byte-identically to two normal recipients;
- both recipients decrypted the exact inner object and verified the sender;
- a non-member and a ClawReef non-recipient identity could not decrypt;
- duplicate submission, unregistered host, disabled host, removed or muted
  sender, sender-rate excess, stale timestamp, stale revision/key set, missing
  recipient key, changed
  pinned key, altered ciphertext, hash tamper, and wrong Ed25519 signer all
  failed closed;
- recipient replay, wrapper/inner mismatch, and an unpinned sender key failed
  closed;
- a member added after the committed authorization snapshot was not contacted;
- one simulated member failure produced one success and one failure after one
  attempt each, with no retry or transaction state;
- delivered wrappers and responses exposed no hook token;
- no ciphertext artifact survived the fixture run; and
- actual age encryption to the proposed 256-recipient ceiling produced a
  25,671-byte ciphertext in approximately 0.09 seconds on BETTYXIX; the first and last
  recipients both decrypted the original object.

The existing Antenna release-readiness test also passed 9/9, and the ClawHub
dry run confirmed all PUB-001 protocol/evidence and `spikes/` paths are
excluded from its 62-file package. Python
compilation, `git diff --check`, and targeted private-key/credential/path scans
were clean.

Validation tools:

- age 1.2.1;
- OpenSSL 3.5.5;
- Python 3.14.4; and
- jq 1.8.1 for the existing release-readiness check.

## Important trust boundary

Member age keys are self-bound to their Ed25519 identity, and senders pin both
fingerprints locally. That prevents silent age-key replacement after a host's
identity has been observed. It does not solve malicious-directory substitution
on first contact; v1 uses explicit TOFU and must say so. Key transparency is a
future hardening option, not a hidden PUB-002 dependency.

## Remaining PUB-002 review points

- Implement and review host-key enrollment/replacement/revocation, generic
  signature-authentication failures, pre-verification abuse limits, and
  verified-host/group rate and replay middleware. CR-PROD-002 is not a Public
  Group dependency.
- Design encrypted-at-rest hook-token custody and narrowly auditable egress.
- Define the operator approval UX for first-use pins and legitimate key
  changes; never auto-accept a changed key.
- Rewrite the fixture parser/relay as normal production TypeScript and Antenna
  code; do not transplant spike code.
- Validate production rate limits, timeout/concurrency values, memory use, and
  256-member behavior on the real deployment stack.
- Independently review strict schema parsing, signature canonicalization,
  replay reservation, wrapper/inner comparison, and metadata-only logging.

## Verdict

The core design is feasible without plaintext access, pairwise hook-token
disclosure, shared group secrets, retries, a content store, or an LLM in the
relay path. No PUB-001 kill criterion was triggered.

Corey accepted this protocol boundary on 2026-08-16. The independent security
review in `PUB-001-SECURITY-REVIEW-2026-08-16.md` clears the architecture for a
bounded PUB-002 implementation while preserving explicit pre-deployment
security blockers and separate implementation authority.
