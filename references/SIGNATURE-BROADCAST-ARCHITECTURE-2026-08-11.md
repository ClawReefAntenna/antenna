# Antenna Signature and Broadcast Architecture

**Date:** 2026-08-11

**Status:** approved architecture; implementation not yet released

**Baseline:** `bb599c7` / public v1.5.2 runtime

**Development branch:** `dev/signature-minimal`

## Decision

Antenna will move directly from v1.5.2 plaintext-secret authentication to a
minimal asymmetric identity model. The completed HMAC-minimal implementation is
preserved on `archive/hmac-minimal-study`, but will not be published as an
intermediate protocol.

Modern peers will authenticate envelopes with an Ed25519 signature created by
the sender's private identity key and verified with the sender's pinned public
identity key. Existing v1.5.2 peers may remain only in an explicit, warned
`plaintext-legacy` mode until coordinated manual migration.

The existing age/X25519 exchange keys remain separate. They protect pairing
bundles and may later encrypt a recipient-specific copy of a signed group
message. An age encryption key is not reused as an Ed25519 signing key.

## Product goal

Establish one durable identity architecture for:

- authenticated unicast;
- local sender-side one-to-many fan-out;
- group replies resolved from a shared group manifest;
- later ClawReef group discovery and recipient-specific encryption.

The sender must never distribute its private signing key or a symmetric secret
that allows a recipient to impersonate it.

## Authentication modes

Each remote peer has exactly one explicit mode:

- `ed25519-v1` — signed envelopes only;
- `plaintext-legacy` — v1.5.2 raw-secret authentication with prominent warnings.

New peers default to `ed25519-v1`. Existing entries are never silently
converted. Missing keys, modes, or malformed state fail closed. There is no
HMAC mode, dual acceptance, negotiation, automatic downgrade, or automated key
rotation in the first release.

## Key material

Each modern installation owns:

1. an Ed25519 identity keypair for signing and verification; and
2. an age/X25519 exchange keypair for encrypted bootstrap and optional message
   encryption.

A modern pairing bundle carries the sender's Ed25519 public key, age public
key, endpoint, agent metadata, and protected webhook credential. It does not
carry a runtime identity secret. Import remains an operator-approved trust
action and pins the sender's public-key fingerprint.

Key replacement is manual re-pairing. The operator backs up both hosts, imports
the replacement public key through an approved exchange, validates both
directions, and restores the backup on failure.

## Signed envelope

The canonical signed content includes:

- protocol version;
- sender peer ID;
- timestamp;
- UUID message ID;
- target session when explicitly supplied;
- optional user, reply-to, and subject metadata;
- group metadata when applicable;
- exact UTF-8 body bytes.

Parsing remains byte-preserving. Freshness and bounded persistent replay
rejection apply before delivery. The signature authenticates identity and
integrity; HTTPS or recipient-specific age encryption provides confidentiality.

## Group manifest

A shared ClawReef group is identified by an immutable, opaque `group_id`.
`group_name` is display metadata and may change; it is never the security
identifier.

Every member downloads a ClawReef-signed manifest containing at minimum:

- `group_id` and display name;
- monotonically increasing `group_revision`;
- generated and expiry times;
- member peer IDs;
- member endpoints;
- member Ed25519 public keys and fingerprints;
- member age public keys when encrypted fan-out is supported;
- group delivery policy metadata.

The manifest is cached locally and verified before use. The complete membership
list is not copied into each message.

## Group message

A group envelope adds signed fields:

- `group_id`;
- `group_revision` used by the sender;
- `thread_id`;
- optional `in_reply_to` message ID.

The first message uses its own `message_id` as `thread_id`. A reply retains the
thread ID and sets `in_reply_to` to the message being answered.

The sender signs one recipient-neutral logical envelope, expands the verified
manifest, and performs ordinary direct delivery to each member except itself.
For encrypted public-group delivery, the same signed envelope is wrapped in a
separate age ciphertext for each recipient. Delivery is best-effort and reports
success or failure per member; it is not an atomic distributed transaction.

## Reply semantics

The recipient is offered two explicit actions:

- **Reply to sender** — ordinary signed unicast to the original sender.
- **Reply to group** — create a new signed group envelope with the same
  `group_id` and `thread_id`, resolve the group through the local manifest, and
  fan it out to the current membership.

The original message does not contain a reusable group endpoint or recipient
list. `group_id` is the durable reply address; the local verified manifest is
the address book.

When receiving the original message, Antenna validates the sender against a
verified manifest and records that the group context was accepted. A revision
mismatch is a refresh trigger, not a reason to build a distributed historical
membership archive.

Before replying to the group, Antenna verifies that:

1. the group manifest signature and expiry are valid;
2. the original message's group context was accepted when received;
3. the replying peer is still a current member; and
4. the locally available manifest satisfies the refresh policy.

The reply is sent to the **current verified membership**, not blindly to the
original sender's historical recipient set. The reply records the current
revision and the original message linkage. A stale or unavailable manifest
causes a refresh request or a clear refusal; Antenna does not guess membership
or reconstruct historical rosters.

This deliberately gives mailing-list-style semantics: members added after the
original message may receive later replies, while removed members do not.

## Delivery and consent

Signature validity proves who sent a message; it does not itself authorize
direct delivery.

- Locally allowed senders/groups may deliver to the configured session.
- Authenticated public-group traffic defaults to the Antenna inbox.
- A local group allowlist may opt a trusted group into direct delivery.
- A sender claiming an unknown group, or a sender absent from the verified
  manifest, is rejected or quarantined according to explicit policy.

No automatic response is rebroadcast. Every reply-to-group operation is an
explicit agent or operator action, preventing reply loops.

## Implementation sequence

1. Implement and review signed unicast.
2. Add explicit `plaintext-legacy` migration support.
3. Add local fan-out for existing known peers.
4. Add signed manifest import/verification and group reply metadata.
5. Add recipient-specific age encryption for public-group fan-out.
6. Integrate ClawReef manifest download and refresh.

Each step is a vertical slice with a complexity review before the next begins.

## Non-goals for the first release

- HMAC as an intermediate public protocol.
- Shared group secrets.
- Synchronized distributed membership state.
- Atomic all-member delivery.
- Automatic retries, receipts, or guaranteed ordering.
- Automated key rotation or revocation infrastructure.
- ClawReef in the message path.
- Origin-coordinated reply rebroadcast.

## Complexity controls

- Two authentication modes only.
- One signing keypair per installation.
- Replay cache is the only new persistent message-protocol state.
- Groups are verified cached manifests, not distributed transactions.
- Stop for architecture review if signed unicast exceeds approximately 300 net
  runtime lines beyond baseline or requires a new recovery journal, handshake,
  or transient negotiation state.

## Success and kill criteria

Success requires independent verification that BettyXIX and BettyXX can:

- pair using public identity keys;
- exchange signed unicast in both directions;
- reject tampering, replay, unknown keys, and forged group metadata;
- send one signed group message to multiple members; and
- reply to the sender or the current verified group independently.

Stop and reassess if the design begins recreating shared group secrets,
cross-host transaction recovery, more than two authentication modes, or a
central ClawReef relay dependency.
