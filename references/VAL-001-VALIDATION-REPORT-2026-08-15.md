# VAL-001 Three-Host Validation Report — 2026-08-15

## Verdict

**Pass.** Candidate commit
`2763a78e569d3de7b8ddd0624f371713d5f871c2` completed controlled live
validation across BettyXIX, BettyXX, and clean-install canary BettyXVIII.
SIG-001, SIG-002, DL-001, and DL-002 behaved as specified. REL-001 may begin
against this exact code candidate. No publication, Public Group work, tag,
push, release, or announcement is authorized by this result.

The three hosts deliberately retain the candidate pending REL-001. Their
pre-change rollback archives remain intact and verified.

## Candidate identity

- Git commit: `2763a78e569d3de7b8ddd0624f371713d5f871c2`
- Archive SHA-256:
  `96918b0f04ca72c46179d433af59755d5f1d8ab6937c013360c37e804b8a215b`
- The archive was produced with `git archive`, contained 90 tracked members,
  and excluded runtime state, secrets, keys, sessions, and databases.
- The same archive digest and these runtime file digests were verified on all
  three hosts:
  - `scripts/antenna-send.sh`:
    `aa0e73d78712ac72f442f9ba638a03f6fd2fbfe84a2618bcf16b5e3387cd533b`
  - `scripts/antenna-relay.sh`:
    `145969bcce0130f66fa4bfd20db528b4386ed0326ecca1e18b16e34a1e3682cf`
  - `scripts/antenna-relay-deliver.sh`:
    `d288a96791dc9e1e421ebb57c584bab809c87022869ff5f86bc3fb900d749898`
  - `bin/antenna.sh`:
    `d424909d24ab99c21d0a495e71d08f3bf00f2176b89b2a389aa9d0dfa63a0699`

## Host lanes and retained state

| Host | Lane | Candidate path | Relay model |
|---|---|---|---|
| BettyXIX | candidate/control | `~/clawd/skills/antenna-val001-2763a78` | `openai/gpt-5.5` |
| BettyXX | historical migration | `~/clawd/skills/antenna-val001-2763a78` | `minimax/MiniMax-M2.7` |
| BettyXVIII | clean install | `~/clawd/skills/antenna-val001-2763a78` | `openai/gpt-5.5` |

On every host, the gateway Antenna agent's `agentDir` and `workspace` point to
the candidate `agent/` directory. Every gateway is active. BettyXIX uses the
candidate through `/usr/local/bin/antenna`; BettyXX and BettyXVIII use
user-local `~/.local/bin/antenna` links because their setup context could not
write `/usr/local/bin`.

## Deterministic verification

The following passed from the staged candidate on all three hosts before live
activation:

- `tests/ed25519-v1.sh`
- `tests/dl-001-list-send.sh`
- `tests/dl-002-visible-recipients.sh`
- `tests/run-tier-a-fixture.sh` (20/20)

After `age` was made available on BettyXX and BettyXVIII,
`tests/sig002-migration.sh` also passed on all three hosts. Shell syntax and
candidate packaging scans passed before activation.

## Pairing and migration

All three bilateral links were established with fresh encrypted schema-v2
bundles and `auth_mode: ed25519-v1`:

1. BettyXIX ↔ BettyXVIII: clean first pairing.
2. BettyXIX ↔ BettyXX: explicit migration from the historical
   `plaintext-legacy` state by fresh encrypted re-pair.
3. BettyXX ↔ BettyXVIII: clean cross-peer pairing after the first two links
   passed.

Each remote peer now pins a public signing key and has no active
`peer_secret_file` reference. Old unreferenced secret files were deliberately
retained for evidence/rollback; no silent fallback or automatic downgrade was
used. All encrypted bundle artifacts are mode 600.

## Live positive paths

All six directed paths passed into the isolated
`agent:antenna:modeltest` session:

- BettyXIX → BettyXVIII and BettyXVIII → BettyXIX
- BettyXIX → BettyXX and BettyXX → BettyXIX
- BettyXX → BettyXVIII and BettyXVIII → BettyXX

For every path, the sender received webhook acceptance, the receiver logged
`peer_auth:verified`, the relay invoked `sessions.send`, and the exact unique
message marker was found in the intended target-session transcript.

## Live negative paths

Receiver-side logs proved fail-closed behavior for:

- exact signed-message replay → `replay detected`;
- signature produced by an unpinned key → `invalid Ed25519 signature`;
- correctly signed stale message → `timestamp too old`;
- correctly signed future message → `timestamp in future`;
- sender absent from the allowlist/peer set →
  `not in allowed_inbound_peers`;
- signed delivery to an unapproved target session → `session not allowed`.

HTTP 200 from `/hooks/agent` was treated only as asynchronous acceptance, not
as proof of delivery. Every verdict above came from receiver logs or the target
session transcript.

## Distribution Lists and visible recipients

Each host created one local-only `@val001-triangle` list containing the other
two peers and sent with `--show-recipients`. All three fan-outs reported 2/2
sender success, and all six target transcripts contained:

- the unique user-body marker;
- `[ANTENNA_META v=1]`;
- `list: val001-triangle`;
- the same canonical, sorted two-peer `recipients:` value.

No list state was shared, no reply-all behavior was implied, and no ClawReef
or Public Group path was used.

## Security and rollback checks

- Final code digests match across all hosts.
- Final gateways are active and use the intended candidate agent directory.
- Signing private keys are owner-only; pinned public-key directories remain
  owner controlled.
- Runtime logs and test logs contain no private-key PEM, hook-token value, or
  runtime-secret value.
- Private rollback artifacts and their independently verified checksums remain
  available in the operator's project records.
- Only `bettyxix`, `bettyxx`, and `bettyxviii` were contacted as Antenna peers.

## REL-001 findings

These do not invalidate the live cryptographic/delivery result, but must be
handled in release review:

1. **Stale status audit:** `antenna status` warns that an Ed25519 peer without
   `peer_secret_file` has “sender identity unverified.” Live logs prove the
   signing key is verified. Status must understand `auth_mode: ed25519-v1`.
2. **Relay-model validation:** a configured relay model can be accepted by
   setup even when unavailable on that host. BettyXVIII failed closed until
   the model was changed to a locally configured `openai/gpt-5.5`.
3. **CLI-link fallback:** setup reports inability to write `/usr/local/bin`
   but does not install a user-local fallback link. BettyXX and BettyXVIII
   required explicit `~/.local/bin/antenna` links.
4. **Asynchronous result semantics:** `/hooks/agent` HTTP 200 means queued,
   not delivered. Isolated target sessions without an outward delivery
   channel can persist the Antenna message successfully while the surrounding
   agent run later reports a channel/target error. Operator documentation and
   test assertions must preserve this distinction.
5. **Isolated Antenna-session artifact:** targeting the Antenna agent's own
   model-test session causes the persisted, already-unwrapped message to be
   seen again by the strict relay agent and logged as malformed. This is a
   test-session artifact; ordinary target sessions should use the receiving
   host's intended local agent.

## Disposition

VAL-001 is complete. Retain all three candidate installations and the
validation artifacts while REL-001 reviews code, packaging, versioning,
operator documentation, and the findings above. Publication and Phase 4 remain
blocked behind separate decisions.
