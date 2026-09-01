# Changelog

All notable changes to the Antenna skill are documented here.

This file is the forward-looking, `[Unreleased]` + recent-releases changelog shipped with the skill.
For the complete version history prior to `1.3.0`, see:

- GitHub releases: https://github.com/ClawReefAntenna/antenna/releases
- Full historical changelog (in-repo): [`references/CHANGELOG-HISTORY.md`](references/CHANGELOG-HISTORY.md)

## [Unreleased]

### Fixed

- **OpenClaw 2026.8.1 agent-roster compatibility.** Setup, side-by-side
  upgrade, Doctor, and relay-model synchronization now read both the legacy
  `agents.list` roster used through OpenClaw 2026.7.x and the canonical keyed
  `agents.entries` roster used by OpenClaw 2026.8.1+. Mutations preserve the
  host's native generation and never create both shapes.
- **Canonical ownership preservation.** Adding Antenna to a sole keyed-agent
  roster materializes explicit system/auth ownership for the prior agent when
  required, while existing ownership, defaults, bindings, unrelated agents,
  tool policy, custom fields, and unknown forward-compatible fields survive
  unchanged.
- **Atomic gateway updates.** Setup now constructs roster, hook, and
  cross-agent policy changes as one candidate, validates it through the
  installed OpenClaw, writes a private rollback backup, and performs one
  atomic swap. Upgrade and model synchronization use the same validated
  roster boundary and preserve the gateway file mode.
- **Fail-closed migration boundary.** Mixed or malformed rosters,
  generation-mismatched shapes, duplicate/invalid IDs, symlinked gateway
  configs, include-owned roster membership, and OpenClaw validation failures
  are refused before gateway mutation. An unmigrated `agents.list` on 8.1 is
  directed to `openclaw doctor --fix`; Antenna does not run broad config
  migration automatically.
- **OpenClaw 8.1 relay-workspace compatibility.** The relay tool contract is
  consolidated into `agent/AGENTS.md`; the package no longer ships retired
  `agent/TOOLS.md`. On 8.1+, side-by-side upgrade refuses before mutation when
  a legacy relay `HEARTBEAT.md` still needs OpenClaw's cron-scratch migration.
- **OpenClaw-owned upgrade seams.** The 8.1 upgrade path now diagnoses retired
  config keys, the retired lossless-claw `autoRotateSessionFiles` setting, and
  an unmigrated legacy exec-approvals file. It leaves plugin lifecycle,
  approvals import, config repair, and Tailscale route ownership to OpenClaw
  and links an explicit stopped-writer checklist, including a side-by-side
  CLI/gateway version-agreement check that prevents an older system CLI from
  shadowing the intended 8.1 user install.

### Validation

- Added isolated 2026.7/2026.8.1 fixtures for setup, rerun, upgrade, Doctor,
  model synchronization, ownership transitions, policy preservation,
  include-aware read-only diagnosis, atomic failure, backups, permissions,
  and refusal cases. The complete shipped shell regression directory passes
  with the new compatibility layer.
- Added bounded workspace/runbook fixtures covering 7.x heartbeat retention,
  8.1 heartbeat refusal, retired config/plugin settings, legacy approvals,
  consolidated agent policy, and Tailscale/plugin ownership guidance.

## [1.6.1] — 2026-08-20

### Fixed

- **ClawHub runtime-policy packaging.** Root-workspace ignore patterns are now
  anchored to the skill root so they do not accidentally omit the required
  `agent/AGENTS.md` and `agent/TOOLS.md` relay-agent policy files from the
  ClawHub package.

## [1.6.0] — 2026-08-20

### Added

- **State-preserving v1.5.2 upgrade command.** A new side-by-side
  `antenna upgrade --from <old-skill-dir>` path refuses destination overwrite,
  preserves runtime state without modifying the old installation, backs up and
  repoints the existing OpenClaw Antenna agent, and updates an existing CLI
  symlink. Legacy peers remain fail-closed until a fresh encrypted Ed25519
  re-pair; `setup --force` is explicitly not an upgrade mechanism.
- **Safe Public Group route lifecycle.** Operators can install one authenticated
  ClawReef route download under a stable local alias, refresh metadata by
  immutable group ID, list installed aliases, and remove one alias without
  overwriting unrelated local routes. State is atomically written with mode
  `0600`; malformed records, duplicate group IDs, alias collisions, and
  unpinned/non-Ed25519 relay peers fail closed.
- **ClawReef-attested Listed Public Groups.** A member submits one ordinary
  Ed25519-signed Antenna envelope to ClawReef. ClawReef verifies freshness,
  replay/rate boundaries, sender identity, and active membership, then signs
  and fans an ordinary Antenna message out to the other active members.
  Route downloads are roster-free; delivery results are aggregate and partial
  fan-out exits non-zero.
- **Content-free relay audit.** ClawReef can read Public Group plaintext while
  fanning it out but does not retain the subject, body, group content, or raw
  envelope. Only sender/message/timestamp and content-free per-member delivery
  outcomes are kept for replay protection and audit.
- **Controlled acceptance.** The exact Antenna/ClawReef pair passed the complete
  three-host supported workflow, including simultaneous fan-out persistence,
  membership removal/re-add, route refresh/removal, zero content retention,
  cleanup, and ordinary-unicast regression.

- **Ed25519 sender identity (`antenna-ed25519-v1`).** Modern peers sign a
  byte-preserving canonical envelope with a dedicated Ed25519 identity key;
  receivers verify the sender against a locally pinned public key before
  delivery. Freshness, exact message-ID replay rejection, strict parsing, and
  fail-closed key/allowlist behavior are included.
- **Explicit legacy migration.** Each peer selects exactly one authentication
  mode: modern `ed25519-v1` or prominently warned `plaintext-legacy`. Existing
  peers migrate by a fresh encrypted re-pair; there is no silent fallback,
  negotiation, automatic downgrade, rotation protocol, or recovery journal.
- **Local Distribution Lists.** `antenna send @alias ...` expands a strictly
  validated local list into independent existing unicasts with deterministic
  per-recipient results and no retry or delivery transaction. Each canonical
  object entry requires `peer` and may include a full `session`; omitted
  sessions delegate routing to the recipient. Because this feature was
  unreleased, the earlier string-only draft schema was removed rather than
  retained as permanent compatibility surface.
- **Visible Distribution List recipients.** `--show-recipients` optionally adds
  a canonical signed-body block containing the local alias and sorted,
  deduplicated recipient peer IDs. Antenna adds no reply-all or list-management
  protocol; recipients may use the visible context in ordinary sends.

### Security

- Reusable plaintext authentication remains available only as the explicit
  `plaintext-legacy` compatibility mode. It is never accepted as fallback for
  an Ed25519 peer.
- Distribution-list metadata grants no endpoint, token, key, reachability, or
  trust. No group credential is embedded in messages.

### Fixed

- `antenna status` now audits the pinned public key selected by an
  `ed25519-v1` peer instead of incorrectly warning that its intentionally
  absent legacy secret leaves the sender unverified.
- Non-interactive setup now defaults to the host's configured primary model
  and rejects an explicitly selected relay model when OpenClaw reports that it
  is unavailable on that host.
- CLI installation skips unwritable PATH directories and reliably falls back
  to `~/.local/bin/antenna`.
- The bundle-verifier regression now creates its own isolated runtime fixture
  instead of depending on untracked developer configuration.

### Validation

- Passed a controlled three-host matrix covering clean install, legacy
  migration, all six signed-unicast directions, replay/tamper/freshness/
  allowlist negative controls, and three-origin Distribution List fan-out.
- Documented that hook HTTP success is asynchronous acceptance rather than a
  final delivery receipt.

### Product boundary

- Listed/open Public Groups are the supported first slice. Pseudonymous groups,
  payload end-to-end encryption, retries, store-and-forward, per-recipient
  receipts, and atomic all-member delivery remain out of scope.

## [1.5.2] — 2026-05-18

### Added
- **Transport-first pairing wizard.** Pairing now opens with a transport-selection menu
  (Email / ClawReef / Manual) before proceeding. Email path sends an encrypted
  bundle invite when the peer's pubkey is already known, and automatically requests
  the peer's pubkey otherwise. ClawReef and Manual remain as alternatives. Preview-
  before-send and optional CC-to-self on the email path. New `--subject`, `--message`,
  and `--cc-self` flags on `antenna-exchange.sh`.

### Fixed
- **`antenna pair` returns to transport menu when email tooling is absent.** Previously,
  selecting the Email transport on a host without `gog` or `himalaya` installed would
  abort the wizard under `set -e`, preventing the operator from falling back to Manual
  or ClawReef in the same run. Now returns gracefully to the transport-selection menu.


## [1.5.1] — 2026-04-28

### Fixed
- **Fresh-install relay-agent contract drift.** Previous shipped docs mixed two
  different relay contracts: `agent/AGENTS.md` told the relay agent to exec the
  wrapper with raw message content on stdin and not call `write`, while
  `agent/TOOLS.md` and the `scripts/antenna-relay-deliver.sh` header documented
  the allowlist-safe file-path invocation shape. On hosts with accumulated
  context the agent often improvised the correct write→exec behavior anyway; on
  fresh installs it could follow the stale AGENTS contract literally and fail
  relay handling with `MALFORMED (no envelope markers)`. The shipped relay-agent
  contract is now the canonical two-step recipe: `write` the raw envelope to
  `/tmp/antenna-relay/msg-<unique-id>.txt`, then `exec bash
  ../scripts/antenna-relay-deliver.sh <that-path>`.
- **Relay-agent docs reconciled across shipped surfaces.** `agent/AGENTS.md`,
  `agent/TOOLS.md`, `SKILL.md`, `README.md`, and `references/USER-GUIDE.md` now
  all describe the same current relay path: the agent performs exactly two tool
  calls (`write`, then `exec`), `antenna-relay-deliver.sh` handles validation +
  delivery + cleanup, and the agent never calls `sessions_send` directly.

## [1.5.0] — 2026-04-27

In-script inbox drain delivery. **No protocol change, no sender-side
change** — fully backward-compatible with v1.4.x and v1.3.x peers.

Highlights:
- **`antenna inbox drain` now delivers in-script.** Instead of emitting
  JSON delivery instructions for a calling agent to act on, drain iterates
  every approved item and calls `openclaw gateway call sessions.send`
  directly — the same gateway RPC the relay path uses. The calling agent's
  role drops to a single `exec` of `antenna inbox drain`; no MCP
  `sessions_send` tool calls, no JSON parsing on the agent side. Cron jobs
  can drain the queue without an agent in the loop.
- **Status semantics tightened.** Drain no longer pre-marks items as
  `delivered`. An item transitions to `delivered` only after a successful
  gateway RPC, or to `failed` (with `last_error` recorded) on RPC failure.
  Denied items are still removed up front. Failed items remain visible in
  the queue for operator triage; `clear` sweeps them when ready.
- **Drain reports per-ref outcome.** Each delivery is logged to
  `antenna.log` with `INBOX | action:deliver | ref:N | session:… | runId:…`
  (or `action:deliver_failed | ref:N | session:… | error:…`). Drain prints
  a one-line summary on stderr and exits non-zero if any delivery failed,
  so cron / agent callers can detect partial drain.

## [1.4.0] — 2026-04-25

Relay agent simplification. **No protocol change, no sender-side change**
— fully backward-compatible with v1.3.x peers (BETTYXX, devon1545,
clawreef can keep sending unchanged).

Highlights:
- Relay agent now performs **1 tool call per inbound** (was 3): a single
  `exec` of `scripts/antenna-relay-deliver.sh`, which writes the temp
  file, runs the verifier, and calls `openclaw gateway call sessions.send`
  directly. The agent no longer calls `write` or `sessions_send` itself.
- Smaller relay-agent prompt surface — less room for prompt injection,
  fewer allowlist exec shapes to maintain, simpler debugging.
- 7-test plan executed on bettyxix before commit (happy / stale-ts /
  bad-auth / unknown-peer / bad-target-session / concurrent / log-shape).

### Added
- **`scripts/antenna-relay-deliver.sh`** — single-call wrapper. Inputs:
  raw envelope on stdin (preferred) or `$1` file path (back-compat).
  Outputs one of: `Relayed`, `Queued: ref #<ref> from <from>`,
  `Rejected: <reason>`, `Error: <description>` on a single stdout line.
  All inbound delivery flows through this script; the relay agent simply
  echoes its stdout. Logs every call to `antenna.log` with `DELIVER` tag
  for traceability alongside the existing `INBOUND` / `OUTBOUND` lines.

### Changed
- **`agent/AGENTS.md`** — reduced to a single-recipe agent: receive raw
  inbound text, exec `bash ../scripts/antenna-relay-deliver.sh` with the
  message piped on stdin, reply with the wrapper's stdout exactly. No
  more file writing, no more `sessions_send`, no more JSON parsing in
  the agent layer.

### Fixed
- **Silent-failure path on gateway error.** When `sessions.send` returns
  nonzero (e.g. `session not found`), the wrapper used to die under
  `set -e` before printing its `Error:` line, leaving the relay agent
  with empty stdout. Now the gateway call is wrapped in `|| true`, the
  raw CLI error text is captured as a fallback when the response isn't
  JSON, and the wrapper exits 0 with a structured `Error: sessions.send
  failed — <reason>` line so the relay agent can forward it cleanly.
  Caught by the v1.4 test plan's bad-target-session case.

### Notes for testers / operators
- `allowed_inbound_sessions` in `antenna-config.json` is the first line
  of defense, *before* the gateway is consulted. Test sessions must be
  allow-listed (or omit `target_session` to use
  `default_target_session`) before they will accept inbound traffic.
- Per-peer rate limit (default 10 messages/min) is unchanged from
  v1.3.x; concurrent v1.4 wrapper runs respect it.

### Rollback
```
cd ~/clawd/skills/antenna
git checkout -- agent/AGENTS.md SKILL.md README.md CHANGELOG.md
rm -f scripts/antenna-relay-deliver.sh
openclaw gateway restart
```
Sender side stays compatible regardless, so no peer coordination needed.

### Why this is `1.4.0` and not `2.0.0`
`2.0.0` is reserved for the no-LLM-on-inbound architecture (the
"Antenna Plugin" SKU). v1.4.0 still uses the relay agent — it just
narrows the agent's job to a single exec. See
`docs/planning/antenna-v1.4-relay-simplification.md`.

## [1.3.4] — 2026-04-22

Diagnostics and hygiene roll-up. No breaking changes; upgrade with `clawhub update antenna`.

Highlights:
- `antenna bundle verify <file>` — inspect a bootstrap bundle before importing (REF-2000).
- `antenna doctor` gains three new audits: self-peer URL shape (REF-2001), peer-state drift section 1b (REF-2002), and on-disk secrets hygiene section 6b (REF-2003).
- `antenna peers remove` now prunes peer-scoped allowlist entries (REF-1312); peer endpoint URLs validated at every ingress path (REF-1313).

### Added
- **REF-2000 — `antenna bundle verify <file>`.** New read-only CLI command for sanity-checking a received `.age.txt` bootstrap bundle before running `antenna peers exchange import`. Decrypts in place, validates shape / endpoint URL / freshness, and prints a safe summary — the hooks token and identity secret never appear in human or `--json` output, only `has_hooks_token` / `has_identity_secret` presence booleans. Never writes to `antenna-peers.json` or `antenna-config.json`. Supports `--json`, `--force-expired`, and `--no-decrypt`. A new shared `lib/bundles.sh` backs both this command and `antenna peers exchange import`, so both paths agree on what "valid" means; import error messages are now more specific as a side effect (e.g. `schema_version must be 1 (got: 2)`).
  Docs impact: bundle_verification

### Fixed
- **REF-1312 — `antenna peers remove` now prunes peer-scoped allowlist entries.** When a peer is removed, its entries in `allowed_inbound_peers`, `allowed_outbound_peers`, and any peer-scoped inbound session allowlists are also pruned so stale allowlist debris (the `nexus` / `bruce` class of leftover) doesn't accumulate. Peer secret material is intentionally left in place; secret deletion remains an explicit operator action.
  Docs impact: peer_remove_allowlist_pruning
- **REF-1313 — peer endpoint URLs are validated at every ingress path.** `antenna peers add`, `antenna setup`, `antenna peers exchange export`, and `antenna peers exchange import` now reject non-HTTPS / malformed URLs (e.g. bare strings like `main`, `localhost` without a scheme) rather than silently accepting them and corrupting peer state downstream.
  Docs impact: peer_url_validation
- **REF-2001 — `antenna doctor` now validates the self-peer URL shape.** A malformed self-peer `url` (for example a legacy `"main"` value) is now a doctor failure rather than silently passing. Malformed non-self peer URLs are reported as warnings rather than failures so existing paired peers don't break operations. A self-marked peer missing `url` entirely is also surfaced as a distinct failure.
  Docs impact: doctor_url_validation
- **REF-2002 — `antenna doctor` now audits peer-state drift.** New section `1b. Peer-State Drift` audits the three peer-scoped allowlists in `antenna-config.json` (`allowed_inbound_peers`, `allowed_outbound_peers`, peer-scoped inbound sessions) against `antenna-peers.json`. Orphan peer IDs (allowlist entries for peers that no longer exist) surface as warnings, never failures. Catches the `nexus` / `bruce`-era debris class automatically and complements the REF-1312 pruning at peer removal time.
  Docs impact: doctor_peer_state_drift
- **REF-2003 — `antenna doctor` now audits on-disk secrets hygiene.** New section `6b. Secrets Directory Hygiene` audits the live `secrets/` directory: orphan peer-scoped secret / token files whose peer IDs are no longer in `antenna-peers.json` (the file-side counterpart to REF-1312 / 1b), backup-pattern leftovers (`.bak*`, `.backup*`, `~`, `.old`), loose `secrets/` directory permissions (target `700`), loose per-file permissions on secret-shaped files (target `600`), and unknown-shape files inside `secrets/`. All findings surface as warnings, never failures, so a peer removal that leaves stale secret files on disk does not break the health check while still getting visible attention.
  Docs impact: doctor_secrets_hygiene

### Docs
- Sync `SKILL.md` and `references/USER-GUIDE.md` with the REF-1312 / REF-1313 / REF-2002 entries above so the health-and-status and troubleshooting sections match shipped behavior before publish.
  Docs impact: continuity_sync

## [1.3.3] — 2026-04-21

### Docs
- **Revert 1.3.2 README-header tweak.** Post-publish investigation confirmed ClawHub's skill-page "README" tab always renders `SKILL.md`, not `README.md`; the 1.3.2 H1-to-blockquote change had no effect on the rendered page and was made on a false premise. Restored the original `# 🦞 Antenna — Cross-Host Messaging for OpenClaw` heading and bold tagline. No runtime changes.
  Docs impact: readme_header_revert

## [1.3.2] — 2026-04-21

### Docs
- **Attempted README rendering fix for ClawHub (did not take effect).** Removed the `# H1` heading from the top of `README.md` and moved the project tagline into a blockquote, on the theory that ClawHub's skill-page "README" tab was falling back to `SKILL.md` when `README.md` opened with a competing H1. Later verification showed ClawHub's "README" tab renders `SKILL.md` regardless of `README.md`'s heading style, so this change was ineffective and is reverted in 1.3.3.
  Docs impact: readme_rendering

## [1.3.1] — 2026-04-21

### Changed
- **Changelog slimmed down.** Pre-`1.3.0` entries moved to `references/CHANGELOG-HISTORY.md`. The current file covers `[Unreleased]` plus the most recent releases; full history lives on GitHub and in the history file.
  Docs impact: changelog_layout
- **Registry bundle trimmed.** Added `.clawhubignore` so internal review/QA documents and historical drafts stay in the git repo but are no longer shipped to the ClawHub registry. Specifically excluded: `references/ANTV4-PHASE-1-REVIEW.md`, `references/ANTV4-VALIDATION-CHECKLIST.md`, `references/ANTV4-VALIDATION-CHECKLIST-SHORT.md`, `references/copy-draft-v1.2.0.md`, `references/issues.md`, `references/setup-completion-v1.1.8.md`, `references/GAPS.md`.
  Docs impact: registry_bundle_contents

### Docs
- README "Version" section updated to reflect the current published release and to point at the in-repo full-history changelog.
  Docs impact: version_number

## [1.3.0] — 2026-04-20

### Security
- **REF-603 — plaintext bootstrap bundle JSON could leak in `/tmp` on failure.** `scripts/antenna-exchange.sh` now streams outbound bootstrap JSON directly from `jq` into `age` instead of writing a plaintext temp file first, and the import path installs cleanup traps immediately after decrypt so decrypted plaintext JSON is removed on normal return, validation failure, or signal interruption.
  Docs impact: bootstrap_bundle_handling
- **REF-400 — envelope-marker collisions could smuggle fake headers.** `scripts/antenna-relay.sh` now rejects any message whose body or sanitized header values contain `[ANTENNA_RELAY]` or `[/ANTENNA_RELAY]`, logging `status:MALFORMED (marker in body|headers)`. Sender (`antenna-send.sh`) also guards against injecting markers outbound.
- **REF-402 — no timestamp freshness check on inbound messages.** Relay now validates `timestamp:` against a freshness window (default: max 300s old, 60s future skew), configurable via `.security.max_message_age_seconds` / `.security.max_future_skew_seconds`. Rejected lines carry `nonce:` for correlation, consistent with REF-1501.
- **REF-403 (partial) — plaintext auth envelope persisted on receiver disk.** Relay temp files (`antenna-relay-exec.sh`, `antenna-relay-file.sh`) are now created under `umask 077`, `chmod 0600`'d, and `shred`'d-before-unlink on cleanup (best-effort, falls back to truncate+rm). The `/tmp/antenna-relay` parent dir is tightened to `0700` when owned. Full REF-403 (removing `auth:` from the wire) remains tracked alongside REF-402 HMAC work.
- **REF-404 — self-id fell back to `$(hostname)` if config was missing.** `antenna-send.sh` now fails fast with a clear error instead of silently using the machine hostname as a peer identity, preventing accidental cross-host identity collisions.
- **REF-501 — auth comparison was not constant-time.** Relay-side peer-secret comparison now uses a constant-time path to eliminate timing side-channels on secret verification.
- **REF-601 — expired bundle import succeeded silently.** `antenna-exchange.sh` import path now validates bundle expiry and refuses expired material with a clear error, covered by `tests/ref-601-expired-bundle-refusal.sh`.
- **REF-616 — exchange-bundle emails sent with bogus `antenna@localhost` From address.** `scripts/antenna-exchange.sh` now resolves sender email from the Himalaya TOML config at `${HIMALAYA_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/himalaya/config.toml}`. Both `send_bundle_email` and `send_pubkey_email` hard-fail if the account's email cannot be resolved. Interactive flows use selection-only confirmation through `confirm_from_account`. `--account <name>` remains supported as strict selection of a configured account.
  Docs impact: exchange_email_from_resolution

### Fixed
- **REF-300 / REF-303 — `antenna peers add` silently overwrote existing entries and null-ed out un-supplied fields.** `cmd_peers add` now refuses to touch an existing peer unless `--force` is given, and `--force` applies merge semantics: only fields explicitly supplied on the command line are overwritten, everything else (including unknown top-level fields like `.self` set by peer-exchange) is preserved.
  Docs impact: peers_add_overwrite_policy, peer_registry_merge_semantics
- **REF-604 — `ensure_peer_entry_updated()` lost unknown peer-entry fields:** jq merge switched from `+` to `*` so nested peer fields (including `.self`) are preserved additively during peer updates.
  Docs impact: peer_registry_merge_semantics
- **REF-605 — legacy identity-secret export could leak over non-TTY stdout:** `legacy_export_runtime_secret()` now refuses to print the runtime identity secret when stdout is not a TTY and points operators at Layer A encrypted bootstrap instead.
  Docs impact: identity_secret_handling
- **REF-901 — setup could silently overwrite gateway `hooks.token`:** `scripts/antenna-setup.sh` now preserves an existing gateway `hooks.token` and only writes from Antenna's token file when the gateway value is absent or already matches.
  Docs impact: gateway_hooks_token_setup
- **REF-903 — setup reruns silently stripped operator `tools.exec` policy from the antenna agent:** the existing-agent repair path in `scripts/antenna-setup.sh` no longer does `del(.exec)`, so expert `tools.exec` overrides survive reruns. Setup still forces `sandbox.mode = "off"` and seeds the default deny list only when `tools.deny` is absent.
  Docs impact: setup_agent_update_behavior
- **REF-1206c — pair wizard no longer falsely implies bootstrap email delivery succeeded.** `scripts/antenna-pair.sh` now checks the real exit status from `antenna peers exchange initiate ... --send-email`, treats non-zero send attempts as failures, tells the operator the bundle was not sent, and falls back to explicit manual-delivery acknowledgement instead of fake-success wording.
  Docs impact: pair_wizard_email_delivery_behavior
- **REF-1501 — poll-loop couldn't fast-fail on auth/peer/rate-limit REJECTED:** `scripts/antenna-relay.sh` now tags all post-body REJECTED log lines with `nonce:$NONCE`. Combined with REF-1502, `antenna test <model>` now exits on the first nonce-scoped REJECTED instead of waiting for `--timeout`.
  Docs impact: model_test_behavior
- **REF-1502 — `TEST_NONCE` generated but not used for log correlation:** `scripts/antenna-model-test.sh` now polls for nonce-scoped PASS and nonce-scoped REJECTED instead of session-only matching, so concurrent runs can't cross-poison each other's results.
  Docs impact: model_test_behavior
- **REF-1504 — model-test swap bypassed gateway sync:** `scripts/antenna-model-test.sh` now swaps and restores `relay_agent_model` through `antenna config set ... --no-restart` (which also updates the antenna agent's `.model` in `openclaw.json`). Gateway is bounced exactly once after the initial swap and once in the cleanup trap, instead of per-run.
  Docs impact: model_test_behavior

### Added
- **`--no-restart` flag on `antenna config set` and `antenna model set`** for rapid-batch callers that want to write gateway config now and restart the gateway once at the end. Internal helper `_sync_relay_model_to_gateway` split into `_write_relay_model_to_gateway_config` (no restart) and `_restart_gateway`.
  Docs impact: model_test_behavior

### Changed
- **Test-suite provider request compatibility and fixture freshness refresh.** `scripts/antenna-test-suite.sh` now sends OpenAI-family requests with `max_completion_tokens`, Anthropic requests with `max_tokens`, and uses a fresh current UTC timestamp in Tier A.15 so the REF-500 regression once again exercises session-target rejection instead of tripping freshness validation first. Fresh validation evidence now includes clean full-suite runs for `openai/gpt-5.4-nano`, `openai/gpt-5.4-mini-2026-03-17`, `anthropic/claude-sonnet-4-5`, and `google/gemini-2.5-pro`.
  Docs impact: test_suite_behavior, relay_model_recommendation
- **Recommended relay model updated to `openai/gpt-5.4-nano`.** Operator-facing docs and config examples now present `openai/gpt-5.4-nano` as the recommended relay model on speed/fit grounds.
  Docs impact: relay_model_recommendation, version_number

### Docs
- README version/status refreshed for the `v1.3.0` release, SKILL metadata includes canonical repository/homepage URLs for provenance, and operator-facing docs/config examples now present `openai/gpt-5.4-nano` as the recommended relay model.
  Docs impact: version_number, relay_model_recommendation

## [1.2.22] — 2026-04-20

### Note
- Historical/prepared release waypoint retained for continuity. Its substantive fixes were rolled into the `1.3.0` release narrative above.

## [1.2.21] — 2026-04-18

### Fixed
- **Session resolution: sender no longer injects its own default session into outbound envelopes.** When `--session` is omitted, `target_session` is omitted from the envelope entirely; the recipient resolves from their own `default_target_session` config. Sender no longer needs to know the recipient's internal session layout. (Issue #17)
  Docs impact: session_resolution, version_number

---

For all releases prior to `1.2.21`, see [`references/CHANGELOG-HISTORY.md`](references/CHANGELOG-HISTORY.md) or the [GitHub releases page](https://github.com/ClawReefAntenna/antenna/releases).
