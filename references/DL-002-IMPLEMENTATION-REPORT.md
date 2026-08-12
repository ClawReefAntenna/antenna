# DL-002 Implementation Report

**Branch:** `dev/signature-minimal`

**Status:** visible-recipient prefix retained; reply-all and list snapshot
interfaces removed after owner complexity review

`antenna send @alias --show-recipients ...` prepends a canonical signed-body
block containing the local alias and sorted, deduplicated recipient peer IDs.
The exact user body follows the block. Default list sends remain unchanged.

The prefix encoder rejects empty bodies, invalid UTF-8, NUL, reserved metadata
delimiters, invalid peer IDs, noncanonical membership, and oversized metadata
before invoking any sender. Because the block is part of the signed body, any
change invalidates the Ed25519 signature.

The initially implemented `antenna reply-all` and `antenna lists export/import`
interfaces were deliberately removed. Agents can read the visible peer IDs and
send ordinary unicasts when instructed; permanent parsing, snapshot, collision,
locking, and list-mutation machinery did not earn its maintenance cost. The
removed experiment remains recoverable from Git commit `9a71c0b`.

There is no envelope change, automatic reply behavior, list interchange
format, retained delivery state, retry, group identity, ClawReef integration,
or Public Group logic.

## Verification

- visible-prefix focused tests: 15/15;
- DL-001 regression: 30/30;
- Tier A: 20/20;
- complete deterministic suite: 23 scripts, 0 failures;
- Bash syntax, Python compile, and `git diff --check`: clean.

The retained DL-002 slice is +36 net runtime lines against the DL-001 review
baseline `a86f933`. The simplification removes 203 net runtime lines from the
pre-prune branch state `974331b`.
