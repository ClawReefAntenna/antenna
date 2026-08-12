# SIG-002 Scope Contract

**Status:** Active implementation contract

**Compatibility tier:** documented manual migration

## Failure mode

An upgraded host cannot currently communicate with a v1.5.2 peer while the
operators coordinate an Ed25519 re-pair. Accepting both signed and plaintext
envelopes for one peer would create downgrade ambiguity; silently treating a
missing mode as plaintext would preserve the insecure default indefinitely.

## Null hypothesis

Do nothing: every peer must move to Ed25519 in one coordinated maintenance
window. That is safe but unnecessarily prevents an explicit, temporary legacy
configuration for peers that cannot yet upgrade.

## Simplest correct solution

Each peer entry selects exactly one `auth_mode`: `ed25519-v1` or
`plaintext-legacy`. Send and relay dispatch only by that local setting and fail
closed for missing or unknown modes. `plaintext-legacy` uses the v1.5.2 wire
format and emits an operator warning. The existing age-encrypted bootstrap
exchange carries the sender's selected mode and, for Ed25519, its public key.
Operators migrate by upgrading both hosts and performing a fresh encrypted
re-pair; there is no on-wire negotiation or dual acceptance.

## Persistent state and recovery owner

Only existing peer-registry fields and key/secret files are used. No protocol
state, lock, journal, retry queue, or recovery record is added. A failed or
partial import is recovered by the operator rerunning the encrypted re-pair.

## Deliberate non-goals

No automatic migration, live downgrade/upgrade negotiation, rotation,
cross-host recovery, groups, encryption of messages, live-host changes,
release, push, tag, or public claim. Ed25519 remains the sole modern mode.

## Kill criteria and complexity ceiling

Stop and reassess if implementation requires more than a manual coordinated
re-pair, accepts two authentication schemes for one peer, introduces protocol
state/recovery, or exceeds 200 net new runtime lines against `a6a5757`. Review
for a smaller alternative at 120 net new runtime lines.

## Required evidence

- exact-mode send and receive behavior;
- no downgrade or dual acceptance;
- missing/unknown mode and missing key/secret fail closed;
- warned legacy send and v1.5.2-compatible envelope;
- encrypted bundle import pins Ed25519 public key or legacy secret according to
  the declared mode;
- deterministic focused regressions and the complete isolated suite.
