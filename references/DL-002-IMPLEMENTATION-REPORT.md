# DL-002 Implementation Report

**Branch:** `dev/signature-minimal`

**Status:** implementation, deterministic verification, and owner review
complete

DL-002 extends local Distribution Lists without changing an Antenna envelope or
protocol. Rich list entries add a bounded display name while legacy arrays stay
valid. `--show-recipients` prepends the canonical `[ANTENNA_META v=1]` block to
the exact user body bytes before the existing sender signs and delivers it.
Default list sends are byte-for-byte behaviorally unchanged.

`antenna reply-all <original-sender> --source <body-file> ...` strictly parses
one leading metadata block, unions its canonical peer IDs with the supplied
original sender, excludes self, and starts a new local fan-out. Unknown,
unconfigured, or outbound-disallowed peers are warned and skipped; embedded
IDs never import trust or credentials. Malformed, duplicated, embedded,
oversized, or noncanonical metadata fails before any sender invocation.

`antenna lists export/import` uses a strict version-1 snapshot containing only
display name, preferred alias, and peer IDs. Import normalizes membership,
warns for unknown/disallowed peers and invalid or missing URL, token, or
authentication-mode readiness, uses an atomic locally locked list-file update,
and requires an explicit unused `--alias` or `--replace` for collisions. It
does not modify peer or credential state.

Visible metadata is never allowed to become the whole message: zero-byte user
bodies are rejected. The exact metadata delimiters `[ANTENNA_META v=1]` and
`[/ANTENNA_META]` are reserved in visible-send user bodies and rejected before
any sender invocation, ensuring every produced visible message remains strict-
parser compatible.

## Verification

- focused DL-002 matrix: 39/39;
- DL-001 regression matrix: 30/30;
- hermetic Tier A: 20/20;
- full isolated deterministic suite: 23 scripts, 0 failures;
- Bash syntax, Python compile, and `git diff --check`: clean;
- ShellCheck unavailable on this host.

Runtime growth is +235 net lines against `a86f933`, below the 250-line review
gate and 350-line stop ceiling. There is no retry, queue, receipt, retained
delivery state, recovery journal, protocol/header change, credential import,
group identity/revision/threading, ClawReef integration, or Public Group logic.

## Interface limitation

The metadata body intentionally contains no sender field. A script invoking
reply-all must therefore supply the already-authenticated original sender from
the received envelope context. The command does not claim to authenticate a
sender from a detached body file alone.

Owner review found and repaired three pre-acceptance gaps: empty visible-message
bodies, reserved metadata delimiters in the original body, and incomplete
snapshot readiness warnings. A final cleanup repair installed the temporary-file
trap before metadata construction so early validation failures do not leave
protected body files behind. All verification above was rerun after the repairs.
