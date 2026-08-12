# Antenna Development Backlog

**Purpose:** the durable, verified work queue for the Antenna maintainer.
This is not a release plan: Betty retains push, tag, GitHub Release, ClawHub,
and public-communication authority.

## Operating rules

- Keep at most one task in **Active**; record `None` while awaiting authorization
  for the next bounded slice.
- Items in **Ready** may begin only after the active item is completed and its
  stated verification is satisfied.
- Items in **Blocked / Betty decision required** are not implementation
  authority. Record evidence or a proposal, then wait for a decision.
- Update this ledger in the commit that completes a tracked work item.

## Active

None. Awaiting authorization for the next bounded vertical slice.

## Ready

### PUB-001 — Public Group relay protocol and feasibility spike

May begin only after signed unicast and Distribution Lists are stable. Fix the
bounded API/wire contract in
`references/PUBLIC-GROUP-RELAY-ARCHITECTURE-2026-08-11.md` and demonstrate with
fixtures that one multi-recipient age ciphertext can be deterministically
fanned out without a ClawReef model call. No real tokens or live delivery.

### PUB-002 — Encrypted ClawReef Public Group relay

May begin only after PUB-001 review. Implement the deterministic ClawReef API
and bounded fan-out together with Antenna multi-recipient encryption/decryption.
No plaintext mode, shared group key, message persistence, retries, receipts, or
LLM relay logic.

## Blocked / Betty decision required

### ART-001 — Retention policy for ignored local artifacts

Bootstrap bundles, runtime state, test results, backups, and similar ignored
material may contain secrets or useful historical evidence. Inventory and
propose retention/quarantine only; no deletion without approval.

## Future research (not implementation authority)

### POS-001 — Positioning note: Antenna and A2A/Hermes

After the baseline is clean, propose a short note distinguishing Antenna's
trusted asynchronous session-addressed messaging from A2A/Hermes task
delegation. Antenna is A2A-aware, not A2A-dependent; do not begin an A2A
adapter without a concrete request.

## Completed

### DL-002 — Visible recipients, reply-all, and list sharing

**Decision:** visible metadata is a canonical signed-body prefix; reply-all is
a new locally filtered fan-out; list sharing is a credential-free snapshot.
**Verification:** focused DL-002 39/39, DL-001 regression 30/30, Tier A 20/20,
full isolated deterministic suite 23 scripts with 0 failures, syntax/Python/diff
checks clean; ShellCheck unavailable.
**Complexity:** +235 net runtime lines against `a86f933`, below the 250-line
review gate; no protocol/shared-state/retry/recovery behavior.
**Boundary:** no implicit trust, credential import, group identity/revision/
threading, ClawReef/Public Groups, live-host change, push, tag, or release.
**Records:** `references/DL-002-SCOPE-CONTRACT.md` and
`references/DL-002-IMPLEMENTATION-REPORT.md`, plus
`references/DL-002-OWNER-REVIEW-2026-08-11.md`.

### DL-001 — Local Distribution List fan-out

**Decision:** reserve local `@alias` names and expand a strictly validated,
sorted/deduplicated member list into independent existing unicast sends.
**Verification:** focused matrix 30/30, Tier A 20/20, full isolated deterministic
suite 22 scripts with 0 failures, syntax and diff checks clean.
**Complexity:** +127 net runtime lines against `9992e6a`, below the 150-line
stop gate; no protocol/state/retry/recovery behavior.
**Boundary:** no recipient metadata, reply-all, export/import, group identity,
ClawReef/Public Groups, live-host change, push, tag, release, or public claim.
**Records:** `references/DL-001-SCOPE-CONTRACT.md`,
`references/DL-001-IMPLEMENTATION-REPORT.md`, and
`references/DL-001-OWNER-REVIEW-2026-08-11.md`.

### SIG-002 — Explicit plaintext-legacy migration

**Decision:** each peer selects exactly one `auth_mode`: modern `ed25519-v1` or
warned `plaintext-legacy`; migration is a manual fresh encrypted re-pair.
**Verification:** focused auth 72/72, migration/bundle 9/9, Tier A 20/20,
REF-1501 16/16, the deterministic scripts in an isolated seeded copy, and
owner security review with no remaining blocker.
**Complexity:** +95 net runtime lines against `a6a5757`, below the 200-line
stop gate; no negotiation, dual acceptance, journal, retry, or recovery state.
**Boundary:** no live-host change, push, tag, release, or public claim.
**Records:** `references/SIG-002-SCOPE-CONTRACT.md`,
`references/SIG-002-IMPLEMENTATION-REPORT.md`, and
`references/SIG-002-SECURITY-REVIEW-2026-08-11.md`.

### SIG-001 — Minimal Ed25519 signed unicast

**Decision:** implement `antenna-ed25519-v1` with dedicated identity keys,
canonical signed envelopes, owner-controlled pinned-key verification,
freshness, explicit fail-closed allowlists, and persistent replay rejection.
**Implementation:** `0a00a77`; security repairs: `00ee65f`.
**Verification:** focused matrix 67/67, hermetic Tier A 20/20, all 20
deterministic scripts in an isolated seeded skill copy, syntax/diff checks, and
independent follow-up security clearance with no blocker.
**Complexity:** +289 net runtime lines against `bb599c7`, below the 300-line
stop gate; no migration state machine, journal, recovery protocol, or second
modern mode.
**Boundary:** no setup/pairing integration, legacy migration, live-host change,
push, tag, release, or public claim.
**Records:** `references/ED25519-PROTOCOL-V1.md`,
`references/SIG-001-IMPLEMENTATION-REPORT.md`, and
`references/SIG-001-SECURITY-REVIEW-2026-08-11.md`.

### ARCH-SIG-001 — Choose asymmetric identity and broadcast architecture

**Decision:** move directly from v1.5.2 plaintext authentication to
`ed25519-v1` and preserve HMAC-minimal as an unpublished study.
**Record:** `references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`.
**Authorization:** Corey approved the direction on 2026-08-11.

### ARCH-DL-001 — Separate Distribution Lists from Public Groups

**Decision:** Private Groups are local, optionally shareable Distribution List
aliases. `@alias` expands to ordinary unicasts. `--show-recipients` may add a
lean signed-body metadata block with list name and peer IDs for recognition and
reply-all. Public Groups require a separate architecture decision rather than
an extension of Distribution Lists; that decision is recorded below.
**Record:** `references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`.
**Authorization:** Corey approved the direction on 2026-08-11.

### ARCH-PUB-001 — Choose encrypted ClawReef relay for Public Groups

**Decision:** senders upload one signed, multi-recipient age ciphertext plus a
group ID; ClawReef deterministically fans the same ciphertext out using member
hook tokens held only by ClawReef. Public Groups have no plaintext mode.
**Record:** `references/PUBLIC-GROUP-RELAY-ARCHITECTURE-2026-08-11.md`.
**Authorization:** Corey approved the direction on 2026-08-11.

### DOC-001 — Rationalize the v1.5.2 documentation baseline

**Owner:** Annie
**Scope:** docs-only reconciliation of release/version, pairing, relay-contract,
test-suite, and historical group/broadcast claims.
**Constraints honored:** no runtime code, HMAC work, ignored-artifact cleanup,
`.gitignore` changes, remote push, tag, or public release.
**Completed:** `25bee12` (`docs: rationalize v1.5.2 release documentation`).
**Verification:** targeted consistency search against the v1.5.2 test runner,
local Markdown-link check for the five changed documents, `git diff --check`,
and staged diff review.
