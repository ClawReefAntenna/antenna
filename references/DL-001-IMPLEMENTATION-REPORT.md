# DL-001 Implementation Report

**Branch:** `dev/signature-minimal`

**Status:** implementation and deterministic verification complete

DL-001 adds a local `antenna-lists.json` address book and reserves `@alias` at
CLI dispatch. A list is validated in full before any network-capable sender is
invoked, sorted and deduplicated in memory, then expanded into independent
calls to the existing unicast sender. No envelope, authentication, pairing, or
relay behavior changed.

The bounded schema permits at most 100 aliases and 100 source members per list.
Aliases and members use the existing peer-ID-safe character set. Validation
rejects malformed or symlinked list files, empty/oversized lists, nested
aliases, self, unknown/disallowed peers, invalid URLs, missing tokens, unknown
authentication modes, and unavailable local mode credentials before fan-out.

Stdin is staged once and replayed byte-for-byte to every member. Supported send
flags pass through unchanged. Every validated member is attempted exactly once,
in sorted order. Stdout contains one aggregate JSON object with alias, totals,
and a result per peer; sender warnings remain on stderr. The command exits zero
only if every unicast succeeds. Partial delivery is reported, not rolled back.

## Verification

- focused hermetic DL-001 matrix: 30/30;
- hermetic Tier A: 20/20;
- full isolated deterministic suite: 22 scripts, 0 failures;
- Bash syntax and `git diff --check`: clean.

Runtime growth is +127 net lines against `9992e6a`, below the 150-line stop
gate. There is no retry, queue, persistent delivery state, transaction,
recipient metadata, reply-all, sharing, group identity, protocol change,
ClawReef integration, or Public Group behavior. Owner review is recorded in
`references/DL-001-OWNER-REVIEW-2026-08-11.md`.
