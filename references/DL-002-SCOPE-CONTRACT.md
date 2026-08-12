# DL-002 Scope Contract

**Status:** completed and owner-reviewed

## Failure mode

Local Distribution List recipients cannot see the send-time list context, cannot
construct a safe reply-all without copying peer IDs manually, and cannot share
an address-book snapshot without inventing an unsafe ad hoc format.

## Null hypothesis

Keep DL-001 unchanged. Operators can send independent unicasts, reply only to
the sender, and recreate local lists manually. This is safe but inconvenient.

## Simplest correct solution

Keep every delivery as an existing unicast. `--show-recipients` stages the
user's exact body once and prepends one canonical signed-body metadata block.
`antenna reply-all <sender> --source <body-file> ...` parses that block, unions
the authenticated envelope sender supplied by the operator with its recipient
IDs, excludes self, warns and skips peers that are not already locally usable,
then performs ordinary independent unicasts. `antenna lists export/import`
copies only descriptive list data.

## Schemas, commands, and bounds

Local `antenna-lists.json` accepts the DL-001 array value and the richer value
`{"display_name":"...","peers":[...]}`. Aliases and peer IDs use
`[a-z0-9][a-z0-9._-]{0,63}`; there are at most 100 aliases and 100 source
members per list. Display names are 1-100 UTF-8 characters with no control
characters. Legacy array entries use their alias as their locally configured
display name.

The canonical metadata block is at the very start of the signed body, is at
most 8192 bytes, and contains exactly one `list` line and one sorted,
deduplicated comma-separated `recipients` line, followed by the close marker,
one blank line, then the original body. Duplicate, noncanonical, embedded, or
oversized blocks fail before sending. Visible sends require at least one byte of
user body and reserve the exact literals `[ANTENNA_META v=1]` and
`[/ANTENNA_META]` throughout that body; either literal is rejected before
metadata construction so a produced message remains strictly reply-all parseable.

The credential-free snapshot is strict JSON with exactly `schema_version: 1`,
`display_name`, `preferred_alias`, and `peers`. Import sorts/deduplicates peers,
warns for locally unavailable peers, and rejects an alias collision unless
`--alias <new>` or `--replace` is explicit.

## Persistent state and recovery owner

Only explicit list import changes the local address book, using a same-directory
atomic replacement under a local lock. Fan-out and reply-all create no retained
message state. Partial delivery remains an operator-visible result, not a
transaction.

## Deliberate non-goals

No envelope/header/protocol changes, implicit trust, credentials in snapshots,
group ID/revision/threading, synchronization, retries, queues, receipts,
delivery transactions, recovery journals, ClawReef, or Public Groups.

## Kill criteria and complexity ceiling

Stop if implementation requires shared cross-host state, protocol changes,
negotiation, or recovery. Review for a smaller solution at 250 net runtime
lines beyond `a86f933`; stop above 350.

## Required evidence

- canonical metadata and exact original-body byte preservation;
- malformed, duplicate, oversized, and noncanonical metadata rejection;
- reply-all union/self-exclusion and local-trust filtering with warnings;
- signature tamper regression through the existing signed-body path;
- strict collision handling and credential-free snapshot proof;
- focused hermetic tests, Tier A, complete isolated deterministic suite,
  syntax/static checks, and a runtime-line delta.
