# Antenna Development Handoff

**Prepared:** 2026-08-08  
**For:** Annie, Antenna Development  
**Status:** Phases 1–3 complete locally; feature work frozen for live and
release-candidate validation; Phase 4 paused before PUB-001

## The one-sentence picture

Antenna v1.5.2 is the published plaintext-authentication baseline. New work on
`dev/signature-minimal` moves directly to Ed25519 sender signatures and uses
local Distribution List aliases for bounded one-to-many fan-out; HMAC-minimal is
preserved but will not be an intermediate public protocol. Public Groups use a
separate encrypted ClawReef relay architecture after those foundations are
stable.

The canonical four-phase progress map is
`references/FOUR-PHASE-DEVELOPMENT-STATUS-2026-08-11.md`. It distinguishes
local completion from public release and maps SIG-001/SIG-002/DL-001/DL-002 to
the original four product phases.

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
- Public v1.5.2 authentication is plaintext runtime-secret comparison with a
  constant-time comparison helper. The checked-out `dev/signature-minimal`
  branch instead contains reviewed `ed25519-v1` plus explicit warned
  `plaintext-legacy`; neither is publicly released from this branch.
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

### Distribution Lists and Public Groups

The May local `docs/broadcast-design.md` remains historical input. The tracked
August architecture replaces its private-group assumptions:

- a Distribution List is a local alias such as `@my-team`, not a protocol
  group;
- the alias expands into independent signed unicast sends to already-paired
  peers;
- `--show-recipients` optionally prepends a signed-body `[ANTENNA_META v=1]`
  block containing only the local alias and sorted/deduplicated peer IDs;
- Antenna provides no reply-all parser/CLI or list export/import workflow;
  humans and agents may use the visible peer IDs in ordinary sends;
- there is no list ID, revision, thread, synchronization, persistent broadcast
  state, retry, or delivery transaction; and
- Public Groups use the separate architecture in
  `references/PUBLIC-GROUP-RELAY-ARCHITECTURE-2026-08-11.md`.

For Public Groups:

- the sender signs one recipient-neutral message and age-encrypts it once to
  all current member public keys;
- the sender uploads that ciphertext plus the group ID to a dedicated ClawReef
  API;
- ClawReef stores each member's hook token, never shares tokens among members,
  and deterministically forwards the same ciphertext to current members;
- ClawReef uses ordinary TypeScript/Node server logic and no model call;
- recipient hosts decrypt and verify the original sender's Ed25519 signature;
- ClawReef sees routing metadata but cannot decrypt the content; and
- there is no plaintext Public Group mode, shared group key, message store,
  retry system, or content inspection.

The old group/cluster sections in `references/ANTENNA-RELAY-FSD.md` are
superseded by that design record. Local Distribution Lists are implemented only
on the unreleased development branch; Public Groups remain proposed and
unimplemented.

### Release authority

You may prepare local commits on `dev/signature-minimal`. Betty owns remote pushes,
tags, GitHub Releases, ClawHub publishing, and public statements.

## Documentation and artifact reality

The repository has two different documentation populations:

- **Tracked/shipped:** `README.md`, `SKILL.md`, `CHANGELOG.md`, `SECURITY.md`,
  and selected `references/` documents. Public version claims were reconciled
  to v1.5.2; `[Unreleased]` records development work without making it current.
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

1. Run controlled BettyXIX↔BettyXX validation of Ed25519 pairing/migration,
   local Distribution List fan-out, and visible-recipient context.
2. Complete the release-candidate code, security, packaging, and operator-doc
   review for Phases 1–3; decide what is actually ready to publish.
3. Measure whether live use demonstrates a concrete need for Public Groups.
4. Reopen PUB-001 only with explicit authorization. If reopened, keep it a
   specification and fixture-only feasibility spike before any production
   ClawReef work.

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
| Distribution List / encrypted Public Group split | Current 2026-08-11 conversation; durable decisions in the two architecture records above and `memory/2026-08-11.md`. |

Suggested ChatBank queries: `antenna HMAC v1.5`, `transport-first pairing`,
and `group broadcast Antenna`. Some FTS queries are sensitive to hyphenated
terms; quote exact phrases when necessary.
