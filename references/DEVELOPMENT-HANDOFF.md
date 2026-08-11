# Antenna Development Handoff

**Prepared:** 2026-08-08  
**For:** Annie, Antenna Development  
**Status:** signature architecture approved; SIG-001 is the sole active item

## The one-sentence picture

Antenna v1.5.2 is the published plaintext-authentication baseline. New work on
`dev/signature-minimal` moves directly to Ed25519 sender signatures and uses
verified group manifests for one-to-many fan-out and group replies; HMAC-minimal
is preserved but will not be an intermediate public protocol.

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

## HMAC studies: preserved, not selected

Historical branch `v1.5` contains:

- `67a3cf2` — self-describing relay auth mode and explicit HMAC/plaintext
  sending options.
- `dab77d8` — `lib/antenna-hmac.sh`, canonicalization/signing/verification,
  and HMAC defaults for new peers.

That design aimed to replace the raw `auth:` secret with an HMAC-SHA256 digest
over a canonical envelope. It introduced `secret_mode` and a compatibility
bridge: plaintext-mode receivers could recognize HMAC-shaped values, whereas
strict HMAC mode rejected plaintext.

It was never merged into the v1.5.2 lineage. A later minimal implementation was
completed and validated on `dev/hmac-minimal`, then preserved at
`archive/hmac-minimal-study`. Corey and Betty decided not to publish HMAC as an
intermediate protocol because Ed25519 sender identity is the intended unicast
and broadcast foundation. Reuse only generally applicable parser, canonical
byte, replay, and test concepts; do not merge either HMAC line wholesale.

## Design decisions already made

### Identity authentication

The controlling record is
`references/SIGNATURE-BROADCAST-ARCHITECTURE-2026-08-11.md`:

- dedicated Ed25519 identity keys sign messages;
- age/X25519 keys remain separate for encrypted exchange/encryption;
- modern peers exchange public keys, not runtime identity secrets;
- exactly two modes are permitted: `ed25519-v1` and warned
  `plaintext-legacy`;
- migration is coordinated and manual; there is no HMAC compatibility layer,
  negotiation, automated rotation, or rollback protocol.

### Groups / broadcast

The May local `docs/broadcast-design.md` remains historical input. The tracked
August architecture refines it:

- broadcasts remain discrete sender-side fan-out, not a central relay;
- a stable signed `group_id` and manifest revision replace recipient-list CC;
- every member caches a ClawReef-signed manifest containing current endpoints
  and public keys;
- recipients explicitly choose reply-to-sender or reply-to-group;
- reply-to-group preserves thread linkage but resolves the current verified
  membership, excluding removed members and allowing later members to receive
  subsequent replies;
- ClawReef distributes manifests but is not in the message path.

The old group/cluster sections in `references/ANTENNA-RELAY-FSD.md` are
superseded by that design record. Group work remains proposed, not implemented.

### Release authority

You may prepare local commits on `dev/signature-minimal`. Betty owns remote pushes,
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

1. Complete SIG-001 signed unicast as a bounded vertical slice.
2. Stop for complexity and independent security review.
3. Add explicit plaintext-legacy migration only after SIG-001 clears.
4. Add local sender-side broadcast fan-out.
5. Add signed group-manifest and reply-to-group semantics.
6. Add recipient-specific age encryption and ClawReef manifest refresh only
   after the simpler group path is stable.

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
