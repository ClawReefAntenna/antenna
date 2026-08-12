# Antenna Signature and Broadcast Architecture

**Date:** 2026-08-11

**Status:** Phases 1–3 implemented and reviewed locally; Phase 4 architecture
approved; none released

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
- local sender-side Distribution List fan-out;
- optional, visible Distribution List metadata and reply-all; and
- later Public Groups under a separate architecture decision.

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
- exact UTF-8 body bytes.

Parsing remains byte-preserving. Freshness and bounded persistent replay
rejection apply before delivery. The signature authenticates identity and
integrity; HTTPS or recipient-specific age encryption provides confidentiality.

## Distribution Lists

A Distribution List is a local alias for a personal recipient list. It is not a
protocol-level group or shared conversation object.

The CLI reserves an `@` prefix for list aliases:

```text
antenna send @my-team "Server maintenance tonight"
```

Antenna expands `@my-team` locally into ordinary, independent signed unicast
messages to the configured peers. Members must already be paired and reachable.
The sender receives per-recipient success or failure; Antenna keeps no broadcast
state, performs no retries, and makes no atomic-delivery claim.

The local member list is sorted and deduplicated before use. Membership changes
affect only future sends. A stale or mistaken list is the list owner's
responsibility.

### Visible list metadata

By default, list fan-out need not reveal the other recipients. When the sender
uses `--show-recipients`, Antenna prepends a small, versioned, machine-readable
block to the signed body:

```text
[ANTENNA_META v=1]
list: AGS Operations
recipients: bettyxix,bettyxx,nexus
[/ANTENNA_META]

Server maintenance tonight.
```

The block contains only:

- `list` — a human-readable sender-supplied display name; and
- `recipients` — sorted, deduplicated peer IDs from the send-time expansion.

It carries no endpoints, hook tokens, public keys, group identifier, revision,
thread identifier, or delivery claim. Because it is part of the signed body,
alteration invalidates the message signature. Older Antenna versions merely
display it as ordinary text.

The list name is descriptive, not authoritative. The signature proves only
that the sender used that name and recipient list; it does not establish a
shared security identity or prove that every listed peer received the message.

### Reply and sharing semantics

A visible list message may offer:

- **Reply** — ordinary signed unicast to the original sender; and
- **Reply all** — a new fan-out to the union of the original sender and the
  embedded recipients, excluding the replying peer.

Reply-all sends only to peers already configured and reachable by the replier.
Missing peers produce a warning; embedded peer IDs never grant credentials,
reachability, or trust.

Distribution Lists may be manually exported and imported so several operators
can use the same local shorthand. A shared list contains its display name,
preferred local alias, and peer IDs only. It contains no hook tokens or other
credentials, has no synchronization or revision protocol, and remains a local
snapshot after import. An alias collision requires an explicit rename or
replacement choice.

## Public Groups: separate architecture

Public Groups are not Distribution Lists with wider membership. Their approved
architecture is recorded separately in
`references/PUBLIC-GROUP-RELAY-ARCHITECTURE-2026-08-11.md`: ClawReef holds member
delivery credentials and deterministically fans one multi-recipient-encrypted
ciphertext out to current members. Public Group implementation remains gated
until signed unicast and Distribution Lists are stable and the bounded wire/API
specification is complete.

## Implementation sequence

1. **Complete:** implement and review signed unicast.
2. **Complete:** add explicit `plaintext-legacy` migration support.
3. **Complete:** add local `@alias` Distribution List fan-out for existing
   paired peers.
4. **Complete:** add optional `--show-recipients`, reply-all, and manual list
   export/import.
5. **Next gate (PUB-001):** complete the bounded Public Group relay protocol
   specification and fixture-only feasibility proof.
6. **Blocked pending PUB-001 review (PUB-002):** implement the ClawReef relay
   and multi-recipient encryption together; never
   expose a plaintext Public Group mode.

Each step is a vertical slice with a complexity review before the next begins.
See `references/FOUR-PHASE-DEVELOPMENT-STATUS-2026-08-11.md` for the product-
phase mapping and current release boundary.

## Non-goals for the first release

- HMAC as an intermediate public protocol.
- Shared group secrets.
- Synchronized distributed membership state.
- Protocol-level private groups, group IDs, revisions, or threading.
- Atomic all-member delivery.
- Automatic retries, receipts, or guaranteed ordering.
- Automated key rotation or revocation infrastructure.
- ClawReef in the message path.
- Origin-coordinated reply rebroadcast.

## Complexity controls

- Two authentication modes only.
- One signing keypair per installation.
- Replay cache is the only new persistent message-protocol state.
- Distribution Lists are local address-book aliases, not shared protocol state.
- Stop for architecture review if signed unicast exceeds approximately 300 net
  runtime lines beyond baseline or requires a new recovery journal, handshake,
  or transient negotiation state.

## Success and kill criteria

Success requires independent verification that BettyXIX and BettyXX can:

- pair using public identity keys;
- exchange signed unicast in both directions;
- reject tampering, replay, and unknown keys;
- expand one local Distribution List into independent signed sends; and
- parse visible list metadata and reply-all only to configured peers.

Stop and reassess if Distribution Lists begin acquiring shared membership
authority, synchronization, revisions, credentials, cross-host transaction
recovery, or Public Group behavior without a separate architecture decision.
