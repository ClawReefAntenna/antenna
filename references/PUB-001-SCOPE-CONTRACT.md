# PUB-001 Scope Contract

**Authorized:** 2026-08-16
**Status:** Corrected fixture VALIDATED — owner and independent security review pending
**Compatibility:** none; Public Groups have never been released

## User-visible outcome

Establish whether ClawReef can safely relay one opaque, recipient-neutral
Public Group ciphertext to the current group members while recipients retain
end-to-end confidentiality and verify the original Antenna sender.

## Smallest safe solution

- The sender host's registered Ed25519 public key authenticates the submission;
  no separate Public Group API key is issued or required.
- One outer Ed25519 signature binds the sender host, request metadata, and exact
  ciphertext hash before ClawReef authorizes or fans anything out.
- One independently signed inner Public Group message is age-encrypted once to
  every current recipient.
- ClawReef rechecks current membership and the exact key-set digest, then makes
  one bounded best-effort delivery attempt per recipient.
- Recipient hosts decrypt and verify the original inner sender signature.

## New persistent state

None in PUB-001. All identities, credentials, membership records, ciphertext,
delivery results, and trust pins are generated beneath one temporary directory
and removed when the proof exits.

PUB-002 would require host identity and age-key-binding records, group
membership/revision data, bounded metadata-only
submission replay state, encrypted hook-token custody, and local recipient
trust pins. That production state is not authorized here.

## Complexity budget

PUB-001 may add one normative protocol document and one self-contained local
proof under `spikes/`. It must use the existing `age` and OpenSSL primitives,
Python's standard library, and no application framework, database, network
listener, package installation, retry engine, or recovery journal.

## Failure handling

Reject unregistered, disabled, wrongly signed, removed, muted, or rate-limited
senders, plus malformed signatures, memberships, revisions, key sets, key
bindings, pins, ciphertext hashes, and limits. Partial downstream
delivery returns a bounded per-member result without retry, rollback, or
transaction state. Operator correction and a new send are the only recovery.

## Deliberate non-goals

- Production routes, database migrations, live tokens, or live-host delivery.
- Plaintext Public Groups or ClawReef content inspection.
- Durable ciphertext, retry queues, receipts, ordering, or atomic fan-out.
- Shared group secrets, automatic key rotation, or transparency logs.
- Group UI, join workflow, moderation workflow, or public documentation.
- Compatibility with an earlier Public Group schema.

## Verification evidence required

- One ciphertext is byte-identically presented to multiple recipients.
- Every intended recipient decrypts and verifies the original sender.
- ClawReef and a non-member cannot decrypt.
- Unregistered and disabled hosts, removed or muted members, rate excess,
  stale membership/key-set, missing keys, changed keys, altered ciphertext,
  and wrong signatures fail closed.
- A simulated member failure is reported after one attempt without retry.
- No response or delivered wrapper exposes any member hook token.
- The temporary run retains no ciphertext after exit.

## Kill criteria

Stop and reassess if the proof needs a shared group secret, server plaintext,
message persistence, background retries, cross-host atomicity, a recovery
journal, more than one submission plus one fan-out protocol step, or production
code changes merely to demonstrate feasibility.
