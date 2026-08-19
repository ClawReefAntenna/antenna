# Antenna Ed25519 Protocol v1

**Status:** normative SIG-001 implementation contract

**Baseline:** `bb599c7` / public v1.5.2 runtime

**Release status:** local development only

## 1. Scope gate

### Failure mode

The v1.5.2 envelope transmits a reusable symmetric identity secret to every
recipient. A recipient that possesses that secret can impersonate the sender,
and disclosure from any envelope permits replay or forgery until rotation.

### Null hypothesis

Doing nothing leaves v1.5.2 usable for small trusted pairs, but it cannot safely
support sender-authenticated fan-out or Public Groups. That is acceptable for
the released line, not for the next identity architecture.

### Simplest correct solution

Each installation owns one Ed25519 identity keypair. The sender signs canonical
message bytes with its private key; the receiver verifies with the sender's
locally pinned public key. Fresh timestamps and a bounded persistent message-ID
cache reject stale and repeated envelopes.

SIG-001 deliberately excludes legacy migration, group behavior, encryption,
key rotation, negotiation, downgrade, receipts, retries, and release work.

### Kill criteria

Stop for architecture review if this slice requires cross-host state recovery,
a protocol journal, more than one modern authentication mode, or more than
approximately 300 net new runtime lines beyond the v1.5.2 baseline. Review for
a simpler design at 200 runtime lines.

## 2. Key material and peer state

The local identity uses OpenSSL Ed25519 PEM files:

- private key: mode `0600`, referenced by the self peer's
  `signing_private_key_file`;
- public key: mode `0644`, referenced by the self peer's
  `signing_public_key_file`.

Each remote `ed25519-v1` peer has a `signing_public_key_file` beneath the local
`keys/` trust root containing the public key pinned during an operator-approved
exchange. The key and every path component through `keys/` must be owned by the
runtime user, must not be group/other writable, and must not be a symlink. The
relay copies a trust-checked key into a private mode-`0600` temporary file and
verifies from that captured copy, avoiding a second open of the registry path.
Senders never receive or store another peer's signing private key. An
unreadable, malformed, missing, unsafe, symlinked, or non-Ed25519 key fails
closed.

SIG-001 fixtures configure these fields directly. Pairing UX and coordinated
replacement are subsequent vertical slices and must not be inferred here.

## 3. Wire envelope

```text
[ANTENNA_RELAY]
protocol: antenna-ed25519-v1
from: <peer-id>
timestamp: <UTC RFC3339 second>
message_id: <lowercase UUID v4>
[target_session: <session>]
[user: <name>]
[reply_to: <URL>]
[subject: <subject>]
signature: ed25519-v1:<base64 signature>

<exact UTF-8 body bytes>
[/ANTENNA_RELAY]
```

Required fields are `protocol`, `from`, `timestamp`, `message_id`, and
`signature`. Headers are unique, LF-delimited, and strictly bounded. Unknown or
duplicate headers, CR bytes, controls in header values, NUL body bytes, invalid
UTF-8, ambiguous markers, or malformed required fields are rejected before
delivery.

Transport framing outside the one unique Antenna marker pair is excluded from
parsing and authentication. The LF immediately before the closing marker frames
that marker and is not part of the body; any preceding terminal LF is part of
the body and is authenticated.

## 4. Canonical signed bytes

Fields are emitted in this fixed order:

`protocol`, `from`, `timestamp`, `message_id`, `target_session`, `user`,
`reply_to`, `subject`, `body`.

For each field emit:

```text
<ASCII field name>:<ASCII decimal UTF-8 byte length>:<exact value bytes><LF>
```

Absent optional values have byte length zero. The body uses the same framing
and may contain LF bytes. The signature header is excluded. Lengths are minimal
unsigned decimal without leading zeroes except the single digit `0`.

The sender signs these bytes directly with Ed25519. The signature is exactly 64
bytes, canonically standard-base64 encoded without line wrapping, and carried as
`ed25519-v1:<88 base64 characters>`. Verification reconstructs the canonical
bytes from the strict parser's validated header values and byte-preserved body.
Decoding and re-encoding must reproduce the wire value exactly; non-zero pad-bit
aliases are rejected.

## 5. Deterministic vector

The vector uses RFC 8032 test-1 key material:

- seed: `9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60`
- public key: `d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a`

Values:

- `protocol`: `antenna-ed25519-v1`
- `from`: `alpha`
- `timestamp`: `2026-08-11T18:00:00Z`
- `message_id`: `123e4567-e89b-42d3-a456-426614174000`
- `target_session`: absent
- `user`: `Corey`
- `reply_to`: absent
- `subject`: `Vector ✓`
- body bytes: `Hello,` + LF + `reef.` + LF

Expected canonical byte length: `216`.

Expected canonical SHA-256:
`02ec42dc56373e72b828ef050f0565c007a2e286e3d41d98f5aa24c530a07917`.

Expected signature:

```text
n1d1ue19mD1vIEL9oOZXDypsLwDSv31Q83NPLPmBset32BKm657dP4NqylHgYCRWvZcbgDqSlcz0kbisfwbpDQ==
```

## 6. Validation order

The relay performs:

1. bounded raw-envelope intake and strict byte-preserving envelope parsing;
2. required-field and protocol validation;
3. sender registry and inbound-allowlist validation;
4. bounded timestamp freshness validation;
5. pinned Ed25519 public-key and signature verification;
6. rate, length, and target-session policy;
7. persistent `(from, message_id)` replay reservation;
8. inbox policy and delivery.

Replay state is reserved only after a valid signature and admission by the
non-content rate/length/session gates, but before inbox queueing or delivery.
Cache corruption, lock/storage failure, or capacity exhaustion fails closed.
Inbound and outbound peer allowlists must be explicit arrays containing only
strings. Missing, empty, or malformed allowlists deny all. Absent freshness
limits use 300 seconds maximum age and 60 seconds future skew. Explicit values
must be JSON non-negative integers no greater than one hour and five minutes
respectively; malformed or out-of-range configuration fails closed.

The configured maximum message length must be a positive integer no greater
than 1,000,000 characters. Before parsing, the relay rejects raw envelopes over
`4 × max_message_length + 4096` bytes, allowing worst-case UTF-8 plus bounded
framing without loading an unbounded request into the parser.

## 7. Replay state

The cache stores only peer ID, lowercase UUID v4, and reservation epoch. It is
kept in a mode-`0700` directory, protected by `flock`, atomically replaced with
mode `0600`, and pruned by the configured freshness TTL. Capacity is derived
from the TTL and the validated global admitted-message rate, with two additional
minutes of headroom: `ceil(TTL / 60) + 2`, multiplied by
`global_per_minute`. Rate configuration is bounded to 1–100 per peer and 1–300
globally, with the global value at least the peer value. Duplicate reservations
within TTL are rejected; capacity, corruption, or storage failures fail closed.

## 8. Required SIG-001 evidence

- deterministic vector and generated-key round trip;
- Unicode, multiline, empty, and terminal-LF bodies;
- tampering of every signed field and body;
- missing, malformed, wrong, symlinked, and non-Ed25519 keys;
- strict parser rejection of duplicate/unknown headers, CRs, controls, NUL,
  malformed signatures, UUIDs, and timestamps;
- stale/future message rejection;
- replay duplicate, persistence, pruning, capacity, corruption, and concurrent
  reservation behavior;
- successful Tier A regression suite;
- runtime line-count review and independent security review before SIG-002.
