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

## Completed

### VAL-001 — Controlled three-host validation of Phases 1–3

Validate the reviewed-but-unreleased Antenna work across BettyXIX, BettyXX,
and clean-install control host BettyXVIII without changing the public release,
publishing artifacts, or opening Public Group work.

**Included:** inventory all three hosts; select and record the exact candidate;
exercise fresh Ed25519 pairing, explicit `plaintext-legacy` migration by fresh
encrypted re-pair, signed unicast in both directions, replay/freshness and
wrong-key rejection, local Distribution List fan-out, and visible-recipient
context. BettyXVIII is the clean-install/canary lane; BettyXX exercises
historical-state migration; BettyXIX is the candidate/control lane.

**Acceptance:** all three hosts and their rollback points are recorded; positive
paths succeed in both directions where applicable; negative security paths
fail closed; no peer outside the test set is contacted; logs contain no
private keys, runtime secrets, or unredacted bootstrap bundles; the public
v1.5.2 installation remains recoverable; and a bounded validation report is
reviewed before REL-001 begins.

**Status:** Complete — passed 2026-08-15. All three hosts deliberately retain
the exact candidate pending REL-001.

**Evidence:** immutable candidate and rollback manifests, deterministic suites,
fresh Ed25519 pairing, explicit legacy migration, six signed unicast paths,
six live negative controls, and all three two-recipient Distribution List
fan-outs passed. See
`references/VAL-001-VALIDATION-REPORT-2026-08-15.md`.

Current phase map:
`references/FOUR-PHASE-DEVELOPMENT-STATUS-2026-08-11.md` (Phases 1–3 complete
locally; Phase 4 is paused before PUB-001).

## Active

### PUB-001 — Public Group relay protocol and feasibility spike

Corey authorized this bounded specification-and-fixture phase on 2026-08-16.
It may define the API/wire contract and run generated local fixtures only. It
must not expose a production route, migrate a database, use a real credential,
contact a live Antenna host, add UI, retain ciphertext, or claim availability.

**Status:** corrected signature-only design complete; VALIDATED with 21/21
fixture checks and ready for owner plus independent security review. PUB-002
remains blocked. No Public Group submission API key is required.

**Evidence:** `references/PUB-001-SCOPE-CONTRACT.md`,
`references/PUBLIC-GROUP-PROTOCOL-V1.md`, and
`references/PUB-001-FEASIBILITY-REPORT-2026-08-16.md`.

## Completed

### REL-001 — Phases 1–3 release-candidate review

After VAL-001 passes, review the exact validated candidate for code, security,
packaging, migration/operator documentation, versioning, and release hygiene.

**Acceptance:** validation evidence is linked; all deterministic and focused
tests pass from a clean candidate; packaged contents contain no internal or
sensitive artifacts; public documentation distinguishes v1.5.2 from the new
candidate; remaining risks and rollback instructions are explicit; and a
separate decision is recorded for push, tag, GitHub Release, ClawHub, rollout,
and announcement.

**Status:** Complete — passed 2026-08-15. Candidate `7d8c5d4` passed the
release review; DL-003 subsequently produced validated candidate `d214a7a`.
Public publication is deliberately deferred until Public Groups are enabled.

## Blocked / Betty decision required

### PUB-002 — Encrypted ClawReef Public Group relay

Blocked behind PUB-001 authorization, completion, owner review, and independent
security review. No production implementation authority exists.

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

### DL-003 — Per-recipient Distribution List session routing

**Decision:** replace the unreleased string-only member draft with one strict
object-entry schema: required `peer`, optional full `session`. Omission delegates
routing to the recipient; an explicit session is passed only to that member.
Command-level `--session` is rejected for lists so local policy cannot be
silently overridden.
**Boundary:** local address-book fan-out only. No synchronized membership,
self-delivery, reply-all, group identity, shared trust, retries, or ClawReef
Public Group behavior.
**Authorization:** Corey approved the clean schema break on 2026-08-15 before
any public Distribution List release.

### DL-002 — Visible recipient context

**Decision:** retain only the canonical signed-body prefix containing the local
alias and sorted/deduplicated peer IDs. Remove reply-all and list export/import;
agents or humans can use the visible IDs in ordinary sends without permanent
workflow machinery.
**Verification:** visible-prefix 15/15, DL-001 regression 30/30, Tier A 20/20,
and complete deterministic suite 23 scripts with 0 failures; syntax/Python/diff
checks clean.
**Complexity:** +36 net runtime lines against `a86f933`; the simplification
removed 203 net runtime lines from `974331b`. No reply parser, snapshot schema,
list mutation/locking, protocol, shared state, retry, or recovery behavior.
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

**Decision:** Private Groups are local Distribution List aliases. `@alias`
expands to ordinary unicasts. `--show-recipients` may add a lean signed-body
metadata block with the alias and peer IDs for context. Antenna provides no
automatic reply-all or list-sharing workflow. Public Groups require a separate
architecture decision rather than an extension of Distribution Lists; that
decision is recorded below.
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
