# Antenna Development Handoff

**Prepared:** 2026-08-08  
**For:** Annie, Antenna Development  
**Status:** context and decision record; verify against code before acting

## The one-sentence picture

Antenna v1.5.2 is a published, script-first inter-host relay with a
transport-first pairing wizard; its documentation and ignored development notes
now need reconciliation before security work, HMAC revival, or group broadcast
work resumes.

## Verified release timeline

| Date | Version / commit | What happened |
|---|---|---|
| 2026-04-25 | v1.4.0, `38e82c1` | Relay simplification. The production agent contract moved toward a wrapper-owned delivery path. |
| 2026-04-27 | v1.5.0, `4953e30` | In-script inbox drain and status semantics. |
| 2026-04-28/30 | v1.5.1, `3ec2c88` | Relay contract/documentation reconciliation; public GitHub releases were created for v1.4.0, v1.5.0, and v1.5.1. |
| 2026-05-18 | v1.5.2, `6f48bec` | Transport-first pairing wizard; pushed to `origin/main`, tag and GitHub Release created. |

The public v1.5.2 line is the baseline for all new work. Do not infer that a
branch called `v1.5` is part of it: it is a divergent historical line.

## Current architecture facts

- Inbound agent contract: `write` raw envelope to a unique temp file, then
  `exec` `scripts/antenna-relay-deliver.sh <path>`.
- The wrapper owns validation, local gateway delivery, and cleanup. The relay
  agent does not call `sessions_send` directly.
- Current checked-out authentication is plaintext runtime-secret comparison with
  a constant-time comparison helper. Inspect code rather than trusting older
 marketing/security prose.
- `age` is used for encrypted bootstrap exchange. That protects onboarding
 artifacts; it is distinct from per-message HMAC or message encryption.

## The HMAC fork: important, not shipped

Historical branch `v1.5` contains:

- `67a3cf2` — self-describing relay auth mode and explicit HMAC/plaintext
  sending options.
- `dab77d8` — `lib/antenna-hmac.sh`, canonicalization/signing/verification,
  and HMAC defaults for new peers.

That design aimed to replace the raw `auth:` secret with an HMAC-SHA256 digest
over a canonical envelope. It introduced `secret_mode` and a compatibility
bridge: plaintext-mode receivers could recognize HMAC-shaped values, whereas
strict HMAC mode rejected plaintext.

It was never merged into the v1.5.2 lineage. Treat it as a decision gate:

1. re-evaluate the design and migration/symmetric-peer requirements;
2. port only intentional pieces to a fresh branch from v1.5.2;
3. write cross-version and cross-host tests before calling it a release;
4. update every security/version claim only after code and tests agree.

Do not “merge the old HMAC branch” wholesale.

## Design decisions already made

### Groups / broadcast

The current design record is local `docs/broadcast-design.md` (2026-05-18):

- broadcasts are discrete, fire-and-forget events;
- the sending side expands a group to individual normal Antenna sends;
- `CC` carries `group: <name>`, not every member;
- replies resolve current group membership directly; no origin-coordinated
  rebroadcast and no thread/broadcast/group-version machinery in this phase;
- groups are local JSON files, sourced either locally or from ClawReef.

The old group/cluster sections in `references/ANTENNA-RELAY-FSD.md` are
superseded by that design record. Group work remains proposed, not implemented.

### Release authority

You may prepare local commits on `dev/antenna-next`. Betty owns remote pushes,
tags, GitHub Releases, ClawHub publishing, and public statements.

## Documentation and artifact reality

The repository has two different documentation populations:

- **Tracked/shipped:** `README.md`, `SKILL.md`, `CHANGELOG.md`, `SECURITY.md`,
  and selected `references/` documents. Several still say v1.5.1, so audit
  rather than repeat their version claims.
- **Ignored/local `docs/`:** planning, refactor notes, audit maps, security
  reviews, and design records. Useful, but not a source of current behavior.

Specific concerns to resolve during the first read-only report:

- `docs/ANTENNA-DOCUMENTATION-MAP.md` and `docs/ANTENNA-FILE-MANIFEST.md` are
  based on v1.5.1 / `3ec2c88`, not v1.5.2.
- `docs/REFACTOR-NOTES.md` is a valuable ledger but its counts and some status
  claims are stale. In particular, HMAC-related “fixed” claims must be
  separated from the public v1.5.2 baseline.
- `references/ANTENNA-RELAY-FSD.md` is historical. Keep it, but identify
  sections superseded by the current relay contract and broadcast design.
- Old `test-results/`, `*.age.txt` bootstrap bundles, agent state/SQLite files,
  backups, and `Zone.Identifier` files are runtime/history artifacts—not
  release documentation. Propose retention or quarantine; do not delete them
  without approval.

## Recommended work order

1. Deliver an evidence-backed, read-only baseline/rationalization report.
2. Make a docs-only rationalization commit: version/contract truth, document
   map and file-manifest update, active-vs-historical ledger split.
3. Choose one security/operability tranche from the verified backlog.
4. Hold an explicit HMAC decision review before implementing it.
5. Start broadcast work only after the transport/security baseline is stable.

## Retrieval anchors

Use these to recover original discussion when needed; do not rely on snippets
alone for precise claims.

| Topic | Strongest evidence |
|---|---|
| v1.5.2 commit, tag, push, and GitHub Release | SMAR ChatBank session `947629be-cf12-4ca6-928d-31e0a800ba58`, messages 60543–60556; Git `6f48bec` / tag `v1.5.2`. |
| v1.4.0–v1.5.1 public release sequence | SMAR session `253e8d9c-a80c-45e9-8c0e-012e3e791fea`, messages 59848 onward; Git `38e82c1`, `4953e30`, `3ec2c88`. |
| HMAC specification and migration debugging | SMAR session `68cbabe1-36d2-41a6-a314-0a67ab16f6fe`, messages 58794, 58936, 58941, 58956, 58981, 58990, 58995; historical commits `67a3cf2`, `dab77d8`. |
| Relay tests / whether Tier C was still meaningful | SMAR session `55074bda-b7e1-434b-a574-32b2b407bb92`, messages 59700–59725. |
| May 18 group/broadcast decisions | SMAR session `947629be-cf12-4ca6-928d-31e0a800ba58`, messages 60557 onward; local `docs/broadcast-design.md`. |
| Earlier group discussion | SMAR session `eea5bae1-24cc-4d2a-b44c-5cfdf7b992e4`, messages 53169–53181. |

Suggested ChatBank queries: `antenna HMAC v1.5`, `transport-first pairing`,
and `group broadcast Antenna`. Some FTS queries are sensitive to hyphenated
terms; quote exact phrases when necessary.
