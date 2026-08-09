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

_No active implementation item._
## Ready

_No implementation item is ready until DOC-001 completes and its output is
reviewed._

## Blocked / Betty decision required

### SEC-001 — Decide whether to revive HMAC authentication

Prepare a v1.5.2-based decision brief only after DOC-001. It must cover the
threat model, plaintext-peer migration behavior, re-exchange/key requirements,
canonicalization review, and a cross-version/cross-host test matrix. Do not
merge or port the divergent historical `v1.5` branch without an explicit
decision.

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
