# Antenna Public Group Protocol v1 — PUB-001 Draft

**Status:** fixture specification; not implemented or released
**Protocol names:** `antenna-public-group-ed25519-v1`,
`antenna-public-group-submit-v1`, and `antenna-public-group-delivery-v1`

## 1. Security roles

- The account bearer token authorizes a ClawReef account to call the dedicated
  Public Group submission API. It does not prove message authorship.
- The sender host's Ed25519 key signs the outer submission so ClawReef can
  authenticate the host and exact ciphertext without decrypting it.
- The same host identity signs the inner message so recipients authenticate
  the original sender after decryption.
- Each recipient's age/X25519 key provides payload confidentiality. ClawReef
  stores public encryption keys but has no recipient private key.
- ClawReef's per-host OpenClaw hook tokens authorize only the downstream
  ClawReef-to-host delivery call. They never appear in member data, delivered
  wrappers, or submission results.

## 2. Host key binding and local pins

Every Public Group host record has an Ed25519 public identity key and an age
recipient. The host signs this length-prefixed binding:

```text
protocol:26:antenna-age-key-binding-v1\n
host_id:<bytes>:<UUID>\n
age_recipient:<bytes>:<age1...>\n
```

ClawReef verifies the binding before publishing a key-set snapshot. A sender
stores trust-on-first-use pins for both the member identity-key fingerprint and
age-recipient fingerprint. Any later change stops the send until the operator
explicitly approves new pins. Self-signing prevents silent age-key replacement
under a stable pinned identity; TOFU cannot protect a first observation from a
fully compromised directory. Key transparency is future hardening.

Fingerprints are lowercase SHA-256 hex over the DER Ed25519 public key or the
UTF-8 age-recipient string, respectively.

## 3. Recipient key-set snapshot

Before encrypting, the sender requests the current group snapshot with
`GET /registry/api/groups/{group_id}/keyset`. ClawReef
returns the group UUID, non-negative integer `group_revision`, and active
recipient records excluding the sender. Each recipient record contains:

- `host_id`;
- Ed25519 public key and fingerprint;
- age recipient and fingerprint; and
- age-key binding signature.

Every record must be complete, unique, syntactically valid, and binding-valid.
Missing or malformed keys fail the entire snapshot. The sender validates local
pins before encryption.

`keyset_digest` is lowercase SHA-256 over length-prefixed canonical recipient
records sorted by `host_id`. It covers host ID, identity fingerprint, age
recipient, and age fingerprint. The server recomputes the same current digest
at submission time. A revision or digest mismatch returns conflict and causes
the sender to discard the ciphertext and restart from a fresh snapshot.

## 4. Inner encrypted message

The recipient-neutral inner object contains exactly:

- `protocol`: `antenna-public-group-ed25519-v1`;
- `sender_host_id`: UUID;
- `timestamp`: canonical UTC `YYYY-MM-DDTHH:MM:SSZ`;
- `message_id`: lowercase UUID v4;
- `group_id`: UUID;
- `group_revision`: non-negative integer;
- `subject`: UTF-8 string up to 256 characters;
- `body_base64`: canonical standard-base64 body bytes; and
- `signature`: `ed25519-v1:<canonical base64 Ed25519 signature>`.

The inner signature covers all fields except `signature` using Antenna's
length-prefixed canonical construction. There is no target session in the
sender-controlled message; each recipient's registered local policy chooses
the delivery session. The sender encrypts the complete signed object once with
`age` to every recipient in the validated snapshot. There is no plaintext
fallback.

Initial limits: 256 recipients; 64 KiB decoded message body; 2 MiB ciphertext;
five-minute maximum age; one-minute future skew. PUB-002 may lower these after
measurement but must not silently raise them.

## 5. Submission request and authentication

The sender posts the JSON request to
`POST /registry/api/groups/{group_id}/messages`. The body contains exactly:

- `protocol`: `antenna-public-group-submit-v1`;
- `group_id`, `group_revision`, and `keyset_digest`;
- `sender_host_id`, `message_id`, and `created_at`;
- `ciphertext_format`: `age-v1`;
- `ciphertext_size` and `ciphertext_sha256`;
- `ciphertext_base64`; and
- `submission_signature`.

The caller supplies `Authorization: Bearer <account-token>`. The token must be
active, unexpired, scoped `public-groups:send`, and owned by the account that
owns `sender_host_id`. ClawReef then requires an active sender membership with
permission to post.

The outer Ed25519 signature covers every request field except
`ciphertext_base64` and `submission_signature`; the exact ciphertext is bound
through its size and SHA-256. ClawReef checks canonical base64, decoded size,
hash, freshness, lowercase UUID v4 message ID, current membership, revision,
key-set digest, and the sender host's registered Ed25519 key before fan-out.
It also reserves `(sender_host_id, message_id)` in bounded metadata-only replay
state before fan-out. A duplicate submission fails closed; replay state never
contains ciphertext or plaintext.

Replay records contain only sender host ID, message ID, and reservation time.
They remain for 360 seconds (the five-minute age plus one-minute future-skew
window), use a unique `(sender_host_id, message_id)` constraint, and fail closed
if reservation storage is unavailable or over its rate-derived bound.

Initial admission limits are 10 submissions per sender per minute, 60 per group
per minute, and 300 globally per minute. Exceeding any limit returns HTTP 429.
Malformed requests return 400, bad/missing bearer authentication 401, ownership
or membership denial 403, stale revision/key set or replay 409, oversized input
413, and unavailable replay/admission storage 503. A fully processed fan-out
returns 200 even when individual members fail; the body carries the partial
result and therefore does not imply universal delivery.

## 6. Deterministic fan-out

ClawReef resolves the current active recipients again after admission and
makes at most one attempt per recipient with concurrency 32, a five-second
per-recipient timeout, and a 45-second whole-request deadline. Every downstream
JSON wrapper contains exactly `protocol` (`antenna-public-group-delivery-v1`),
group ID, revision, sender host ID, message ID, ciphertext format, size, hash,
and canonical `ciphertext_base64`. Every member receives byte-identical decoded
ciphertext. The recipient-specific hook token is an HTTP Authorization bearer,
not wrapper content.

The response contains a sorted list of opaque member IDs and one of
`accepted`, `failed`, or `timed_out`, plus aggregate counts. It contains no
endpoint, hook token, public key, ciphertext, or internal error detail.
Partial delivery is not rolled back and is not retried. HTTP acceptance means
only that the host ingress accepted the wrapper; it is not a read receipt.

ClawReef may log request ID, group ID, sender ID, message ID, member ID, status,
timing, ciphertext size, and ciphertext hash. It must not log tokens, plaintext,
private keys, full ciphertext, or unredacted downstream responses.

Hook tokens are encrypted at the application layer before database storage
using versioned AES-256-GCM records with a fresh 96-bit nonce and authentication
tag per record. The 256-bit master key lives outside the database in the
deployment secret store, is never returned through an API, and is available
only to the narrow outbound-delivery code path. Operator views expose only a
presence flag and replacement/revocation action. Decryption, use, rotation, and
failure are metadata-audited without token values.

## 7. Recipient admission

The recipient verifies wrapper size/hash, decrypts with its local age private
key, strictly parses the inner object, reconstructs the canonical bytes,
verifies the sender's pinned Ed25519 key, checks that wrapper and inner group,
revision, sender, and message ID match, then applies freshness, message-ID
replay state, and local group/session policy before delivery or quarantine. Any
failure rejects without plaintext delivery.

## 8. Compatibility and recovery

There is no compatibility mode because Public Groups have not shipped. Unknown
protocols fail closed. Recovery from membership/key conflict, rejected
credentials, or partial delivery is operator correction followed by a new
message with a new UUID; there is no automatic retry or transaction journal.
