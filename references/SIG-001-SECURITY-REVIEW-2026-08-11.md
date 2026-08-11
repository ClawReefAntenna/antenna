# SIG-001 Independent Security Review

**Date:** 2026-08-11

**Reviewer session:** `/root/sig001_security_review`

**Reviewed range:** `bb599c7..0a00a77`

**Mode:** fresh read-only review; no repository or live-host writes

**Initial verdict:** do not clear SIG-001

## Blockers

1. **High — pinned public-key path trust.** The leaf-only validator accepted a
   public key reached through a symlinked parent directory and did not reject a
   group/other-writable key. Validation and verification reopened the path.
2. **Medium — empty/missing allowlists were wildcards.** Both send and relay
   treated an absent or empty peer allowlist as permission for every configured
   peer, contradicting the fail-closed claim.
3. **Medium — freshness/replay capacity mismatch.** Seven-day retention with a
   fixed 10,000-entry global cache allowed normal admitted traffic to fill the
   cache long before expiry and reject every peer.
4. **Evidence — incomplete negative matrix.** Required empty/multiline body,
   receiver-path key hygiene, malformed grammar/signature/UUID/timestamp,
   stale/future signed envelope, and related cases were not all represented in
   the focused suite.

## Hardening findings

- Bound raw envelope bytes before the Python parser reads the complete input.
- Require canonical base64 signature encoding, not merely equivalent decoded
  bytes.
- Align registry/allowlist and freshness validation order with the protocol.
- Create the replay replacement file with mode 0600 before population/rename.
- Reject ambiguous registries containing multiple `self:true` entries.

## Positive controls confirmed

- Sender and receiver canonical bytes agree, including optional values and a
  terminal body LF.
- OpenSSL Ed25519 `pkeyutl -sign/-verify -rawin` usage and 64-byte signature
  handling are correct.
- Timestamp syntax and integer arithmetic are safe on the target GNU/Linux
  environment.
- Replay duplicate locking and atomic admission work under ordinary operation.
- Target sessions are exact-match gated before inbox/delivery.
- Only exact `ed25519-v1` policy/protocol is accepted; no HMAC/plaintext
  downgrade path remains.
- No shell-command injection path was found.

SIG-001 remains Active until repairs receive focused regressions, the complete
deterministic suite passes, and a fresh follow-up review clears the resulting
candidate.

## Repair candidate

The post-review repair tranche:

- constrains remote signing keys to an owner-controlled `keys/` trust root,
  rejects writable/symlinked path components, and verifies from a private
  captured copy;
- makes missing, empty, or non-string inbound/outbound allowlists deny all;
- reduces bounded freshness maxima to one hour/five minutes, validates admitted
  rates, and derives replay capacity from TTL × global admitted rate plus two
  minutes of headroom;
- caps raw envelope bytes before parsing, requires canonical base64, orders
  registry/allowlist before freshness, creates replay replacements mode `0600`,
  and rejects multiple self identities; and
- expands the focused matrix to 67/67, including all evidence gaps and
  sustained multi-peer replay capacity/recovery. Hermetic Tier A passes 20/20,
  and all 20 deterministic scripts pass in an isolated seeded skill copy.

A separate unauthenticated relay-level rate bucket was deliberately not added:
the deterministic relay receives no trustworthy network-origin identity, so a
single pre-authentication quota would give an attacker a cheaper way to block
valid peers. The raw-byte cap bounds parser memory, authenticated per-peer and
global limits bound admitted traffic, and transport-level request limiting
remains an ingress/Gateway responsibility. The follow-up reviewer must assess
that disposition rather than treating it as silently resolved.

## Follow-up verdict

**CLEAR SIG-001 at `00ee65f`.** The independent reviewer found no remaining
blocking security issue. The reviewer independently reproduced the 67/67
focused suite and Tier A 20/20, confirmed all four original blockers repaired,
and accepted transport/Gateway limiting—not an unauthenticated relay bucket—as
the correct boundary for pre-signature request throttling.

Non-blocking future hardening notes are: document the owner-controlled install-
directory assumption above `keys/`; enforce HTTP body limits at Gateway ingress;
require `max_message_length` to be a JSON number rather than accepting an
equivalent numeric string; apply string-array schema validation to inbound
session allowlists; and optionally add a time-scheduled replay-capacity boundary
test. None changes the SIG-001 gate verdict.
