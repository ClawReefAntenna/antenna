# DL-001 Scope Contract

**Status:** Active implementation contract

## Failure mode

An operator who routinely sends the same message to several already-paired
peers must repeat the unicast command manually, increasing omission and
copy/paste risk.

## Null hypothesis

Do nothing: manual repeated unicasts remain correct and safe, but inconvenient.

## Simplest correct solution

Reserve `@alias` as a local address-book shorthand. Read a bounded local JSON
list, validate every member before sending, sort and deduplicate the peer IDs,
then invoke the existing unicast sender independently for every member. Stage
stdin once and replay those exact bytes to each invocation. Report one stable
result per recipient and return success only when every invocation succeeds.
Stdout is one JSON object containing `alias`, `total`, `succeeded`, `failed`,
and peer-sorted `results` with each sender exit code and parsed result/error
when available. Individual sender warnings remain on stderr. `--dry-run` runs
the existing sender's dry run independently for each member and is aggregated
under the same contract.

## Local schema and bounds

`antenna-lists.json` is one JSON object mapping aliases to arrays of peer IDs.
Aliases and peer IDs use `[a-z0-9][a-z0-9._-]{0,63}`. The file may contain at
most 100 aliases and each list at most 100 source entries. Empty lists, nested
`@aliases`, self, unknown peers, and peers absent from the explicit outbound
allowlist are rejected before any send. Runtime sorting/deduplication is local;
the file is not rewritten.

## Persistent state and recovery owner

The list file is an operator-maintained address book. Fan-out creates no state.
Each unicast is independent; a nonzero exit after partial delivery is a report,
not a transaction requiring rollback or recovery.

## Deliberate non-goals

No retries, persistence, queue, atomicity claim, delivery transaction,
recipient metadata, `--show-recipients`, reply-all, list export/import, group
ID/revision/threading, protocol or envelope change, ClawReef, or Public Groups.

## Kill criteria and complexity ceiling

Stop if the wrapper requires protocol changes, shared state, retries/recovery,
or more than 150 net runtime lines against `9992e6a`. Review for a smaller
alternative at 100 net runtime lines.

## Required evidence

- strict schema, bounds, and validation-before-send;
- sorted/deduplicated expansion and self/nested/unknown/disallowed rejection;
- attempt-all behavior with deterministic per-recipient and overall status;
- exact stdin-byte replay and preservation of supported send flags;
- no retry or persistent delivery state;
- focused hermetic tests and the complete isolated deterministic suite.
