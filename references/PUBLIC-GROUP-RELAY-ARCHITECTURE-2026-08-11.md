# Antenna Public Group Relay Architecture

**Date:** 2026-08-11

**Status:** approved architecture; protocol details and implementation pending

**Dependencies:** validated Ed25519 signed unicast and local Distribution Lists

## Decision

Public Groups use ClawReef as a deterministic, credential-holding fan-out
service. This is intentionally different from direct Antenna unicast and local
Distribution Lists.

The sender submits one signed, multi-recipient-encrypted message plus a Public
Group ID to a dedicated ClawReef API. ClawReef verifies the authenticated
sender's current membership, resolves the current active members, and forwards
the same ciphertext to each member's OpenClaw Antenna ingress using the hook
credential that member registered with ClawReef.

The ClawReef relay is ordinary server code. It performs database lookups,
validation, bounded HTTP fan-out, and result collection without invoking an AI
agent or consuming model tokens. Recipient OpenClaw hosts may still incur their
existing Antenna relay-agent run until Antenna has a deterministic plugin
ingress.

There is no user-facing plaintext Public Group mode.

## Product boundary

- **Unicast:** direct peer-to-peer delivery between paired hosts.
- **Distribution Lists:** local `@alias` expansion into independent direct
  sends among already-paired peers.
- **Public Groups:** ClawReef-mediated delivery to centrally managed current
  membership without pairwise hook-token exchange.

ClawReef is in the delivery path only for Public Groups. Unicast and
Distribution Lists continue to work without it.

## Member registration and credentials

Each participating host registers with ClawReef:

- host/peer ID;
- Antenna endpoint;
- OpenClaw hook token;
- Ed25519 public identity key and fingerprint;
- age/X25519 public encryption key and fingerprint; and
- chosen Public Group delivery session/policy metadata.

ClawReef stores hook tokens encrypted at rest, never includes them in group
member data, never exposes them to other members, masks them in operator views,
and supports operator-driven replacement. Joining a Public Group explicitly
authorizes ClawReef to invoke that host's Antenna ingress for group delivery.

The current OpenClaw hook token is a shared hook-surface credential rather than
an Antenna-scoped token. That makes ClawReef a high-trust credential custodian.
ClawReef must target only the Antenna agent, use strict egress code paths, audit
credential use, and minimize who or what can read decrypted token values.

## Sender submission

The sender:

1. authenticates to the dedicated ClawReef Public Group API;
2. requests the current active member IDs and public encryption keys;
3. creates and Ed25519-signs the recipient-neutral Antenna message;
4. age-encrypts that signed message once to all intended member public keys;
5. submits the group ID, clear routing metadata, and one ciphertext to
   ClawReef.

Multi-recipient age encryption encrypts the message body once and wraps the
content key for each recipient. Payload overhead grows with membership, but the
sender uploads one ciphertext and ClawReef forwards that same ciphertext.

The exact submission authentication, membership/key-set freshness check,
request schema, and size limits must be fixed in a bounded protocol spec before
implementation. Missing or malformed required member keys fail closed; there
is no automatic plaintext fallback.

## Relay behavior

ClawReef deterministically:

1. authenticates the submitting host;
2. verifies that the host may send to the named group;
3. applies membership, role, rate-limit, and group policy checks;
4. resolves the current active delivery records;
5. forwards the same opaque ciphertext to each eligible member with bounded
   concurrency and timeouts; and
6. returns a safe per-member success/failure summary without exposing
   credentials.

Initial delivery is best-effort. There is no durable message store, automatic
retry queue, ordering guarantee, or atomic all-member transaction. ClawReef may
log metadata needed for security and operations, but not plaintext or reusable
ciphertext bodies.

## Recipient behavior

The recipient Antenna ingress:

1. accepts the request authenticated with the locally configured hook token;
2. decrypts the ciphertext using the host's private age/X25519 key;
3. byte-preservingly parses the inner Antenna envelope;
4. verifies the sender's Ed25519 signature, freshness, and replay ID;
5. applies local Public Group delivery policy; and
6. delivers or quarantines the message.

ClawReef's successful HTTP delivery is not proof of decryption or session
delivery. The first release does not add receipts.

## Confidentiality and trust

ClawReef stores members' public encryption keys but cannot decrypt messages;
only the corresponding private keys on member hosts can. ClawReef can still see
group ID, sender identity, membership, timing, ciphertext size, and delivery
results.

Because ClawReef distributes the public-key directory, a malicious or
compromised ClawReef could attempt key substitution. The first design must bind
each age public key to the host's Ed25519 identity, pin fingerprints locally,
and warn or stop on unexpected key changes. A public key-transparency mechanism
is future hardening, not a first-release requirement.

End-to-end encryption removes server-side content inspection. ClawReef may
moderate membership and behavior using identity, rate, reports, and metadata,
but it cannot search or automatically inspect message text.

## Non-goals for the first release

- Plaintext Public Group delivery.
- Shared group encryption keys or group rekey protocols.
- Pairwise hook-token distribution among group members.
- ClawReef-authored messages that replace sender signatures.
- Message persistence, store-and-forward, retries, receipts, or ordering.
- LLM involvement in ClawReef relay decisions.
- Content search or server-side content moderation.
- Replacing direct Antenna unicast or local Distribution Lists.

## Required pre-implementation specification

Before opening the implementation branch, fix only these bounded details:

1. sender API authentication and request schema;
2. public-key binding, pinning, and change behavior;
3. membership/key-set freshness and fail-closed behavior;
4. ciphertext wrapper and recipient ingress/decryption contract;
5. request/group-size limits, concurrency, timeout, and result semantics; and
6. metadata-only logging and hook-token storage controls.

Stop and reassess if this work introduces a shared group secret, content store,
distributed recovery protocol, automatic retry system, plaintext fallback, or
an AI agent in the ClawReef delivery path.

## Success criteria

A controlled multi-host matrix must prove that:

- one sender uploads one ciphertext for a multi-member group;
- ClawReef performs fan-out without a model call;
- every intended member can decrypt and verify the original sender;
- ClawReef and a non-member cannot decrypt;
- removed or unauthorized senders cannot submit;
- missing/changed encryption keys fail closed;
- no member receives another member's hook token; and
- partial delivery is reported without retries or transaction state.
