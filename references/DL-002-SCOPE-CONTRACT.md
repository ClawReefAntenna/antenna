# DL-002 Scope Contract

**Status:** completed, owner-reviewed, and simplified after value/complexity review

## Failure mode

A recipient of a local Distribution List fan-out cannot tell which local list
name or send-time recipients the sender used.

## Null hypothesis

Keep DL-001 unchanged. This is safe, but recipients lose useful context and
must ask the sender who else received the message.

## Simplest correct solution

`--show-recipients` prepends one canonical `[ANTENNA_META v=1]` block to the
non-empty user body before the existing unicast sender signs it. The block
contains the local alias and sorted, deduplicated peer IDs. Every delivery
remains an ordinary independent unicast.

The metadata is descriptive input for humans and agents. Antenna does not add a
reply-all command or interpret the block as an instruction. A recipient may
copy the peer IDs or ask its agent to send new ordinary unicasts.

## Bounds

The block begins at byte zero, is at most 8192 bytes, and contains exactly one
`list` line and one `recipients` line, followed by the close marker, a blank
line, and the original body. Visible sends require a non-empty UTF-8 body and
reject either metadata delimiter in user content.

Local `antenna-lists.json` remains the DL-001 object mapping aliases directly to
peer-ID arrays. No richer schema is introduced.

## Deliberate non-goals

No reply-all CLI, metadata parser, list export/import, snapshot schema, list
mutation command, envelope/header change, implicit trust, group ID, revision,
threading, synchronization, retry, receipt, ClawReef, or Public Group behavior.

## Required evidence

- exact canonical prefix and original-body byte preservation;
- sorted/deduplicated recipients;
- empty-body and reserved-delimiter rejection before sending;
- signature verification and metadata-tamper rejection;
- unchanged default DL-001 behavior;
- focused tests, DL-001 regression, Tier A, isolated suite, and diff hygiene.
