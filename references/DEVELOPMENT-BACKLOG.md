# Antenna Development Backlog

**Purpose:** the durable, verified work queue for the Antenna maintainer.
This is not a release plan: Betty retains push, tag, GitHub Release, ClawHub,
and public-communication authority.

## Operating rules

- Keep one task in **Active**.
- Items in **Ready** may begin only after the active item is completed and its
  stated verification is satisfied.
- Items in **Blocked / Betty decision required** are not implementation
  authority. Record evidence or a proposal, then wait for a decision.
- Update this ledger in the commit that completes a tracked work item.

## Active

### SIG-001 — Minimal Ed25519 signed unicast

**Owner:** Annie
**Goal:** implement the first vertical slice defined by
`references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`: dedicated Ed25519
identity keys, canonical signed envelopes, pinned-key verification, freshness,
and replay rejection on the v1.5.2 baseline.

**Non-goals:** group fan-out, ClawReef manifest integration, message encryption,
automatic key rotation, HMAC compatibility, or release/publication.

**Complexity gate:** stop for Betty review before adding legacy migration or
group behavior, and immediately if the slice requires negotiation state,
cross-host recovery, a journal, or more than approximately 300 net runtime
lines beyond baseline.

**Verification:** deterministic signature vectors; byte/parser, tamper,
freshness, replay, missing-key, and wrong-key tests; Tier A; independent review;
no public claims.

## Ready

### SIG-002 — Explicit plaintext-legacy migration

May begin only after SIG-001 complexity and security review. Add one explicit,
warned legacy mode and a manual coordinated re-pairing procedure. No dual
acceptance or automatic migration.

### GRP-001 — Local signed broadcast fan-out

May begin only after signed unicast is stable. Expand a locally verified group
manifest into direct sends, preserve one signed logical envelope, and report
partial delivery without retries or atomicity.

### GRP-002 — Group reply and manifest semantics

Add signed `group_id`, revision, thread, and reply linkage; resolve reply-to-group
through current verified membership as specified in the architecture record.

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

### ARCH-SIG-001 — Choose asymmetric identity and broadcast architecture

**Decision:** move directly from v1.5.2 plaintext authentication to
`ed25519-v1`, preserve HMAC-minimal as an unpublished study, and use
ClawReef-signed manifests for sender-side fan-out and group replies.
**Record:** `references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`.
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
