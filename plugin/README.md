# Antenna for OpenClaw plugin — 1.6.8

Inbound signed v2 delivery with Off / Dumb / Smart / Both content scanning.
Default: Dumb. Both runs Dumb first and only calls Smart after a pass.
Authentication, replay checks and receiver-selected existing destinations apply
in every mode. Ordinary approval and MCS holds remain independent.

This package provides signed ingress and direct local dispatch without a messaging
relay model. Manual migration, direct/list transport and contact exchange are
covered in [MIGRATION.md](MIGRATION.md). Compatible peers may run OpenClaw or Hermes, using their own
runtime-specific setup. Direct messaging does not establish Registry feature parity. Qualification is
scoped to the tested components and runtime, not every model or deployment.
No atomic session-incarnation or exactly-once delivery guarantee is made.

## Install in your selected OpenClaw instance

Requires Node supported by OpenClaw, Bash, jq and flock. Local qualification uses
Linux x64 / Node 26.8.2 and 24.19.0 / OpenClaw 2026.9.5. The manifest floor `>=2026.9.5`
is not certification of all later releases or platforms.
Package with `npm pack ./plugin`; install the resulting archive with
`openclaw plugins install /absolute/path/to/archive.tgz` using the intended
OpenClaw state/config environment. For a migration rehearsal, use an isolated copy. The OpenClaw peer dependency supplies the public gateway SDK.

Prepare a JSON policy with:
- `schemaVersion: 2`, `receiver`, a private random `bearer` (at least 32 characters);
- `peers`: map of authenticated peer names to Ed25519 PEM `publicKey`,
  allowed `destinations` array and optional `mcs` override;
- `destinations`: receiver-approved name to existing `agent:...` session key;
- absolute, distinct `inboxFile` and `replayFile`;
- optional `mcs` (default dumb), `inbox` (default on), `maxBodyChars` (65536).

For a new absent entry, `antenna-plugin /path/openclaw.json init policy.json`
writes it **disabled**. If the native installer has already added an entry,
merge the policy into its config explicitly; init refuses to overwrite it.
Set the plugin enabled and allowlisted only in the intended config,
then restart that gateway. Mode/selection edits also require a restart.
The local adapter uses the gateway's configured port and token or password authentication,
matching the host's selected mode without changing its login configuration. The selected
credential must be resolved to a nonempty string and differ from the Antenna peer bearer.
When the mode is explicit and that credential is absent from config, the matching
`OPENCLAW_GATEWAY_TOKEN` or `OPENCLAW_GATEWAY_PASSWORD` environment variable is
accepted. Config values take precedence; the other mode is never used as fallback.
Non-string secret references must be resolved by OpenClaw before registration; standalone
operator commands likewise require a resolved local credential. Unsupported auth modes
and missing credentials fail without falling back to another mode.

## Operator commands

All output is JSON, including escaped message bodies; never render decoded
message bodies as terminal commands, HTML or model instructions.

```text
antenna-plugin /path/openclaw.json status
antenna-plugin /path/openclaw.json mode off|dumb|smart|both [peer]
antenna-plugin /path/openclaw.json mode default peer
antenna-plugin /path/openclaw.json check registered-model-or-alias
antenna-plugin /path/openclaw.json select registered-model-or-alias
antenna-plugin /path/openclaw.json inbox list
antenna-plugin /path/openclaw.json inbox show ITEM_ID
antenna-plugin /path/openclaw.json inbox release ITEM_ID '["Awaiting approval","MCS flagged"]'
antenna-plugin /path/openclaw.json inbox discard ITEM_ID
antenna-plugin /path/openclaw.json inbox approve-ordinary
```

Status is offline. `check` makes one synthetic request without saving a selection;
`select` checks and saves one registered model/alias shared by Smart and Both.
Neither changes mode or enables the plugin. Restart after selection/mode changes.
Detection evaluation is optional and does not impose a passing-score gate.

## Registered-model Smart scanning

Configure models and credentials in OpenClaw, including models used only for
scanning. Antenna stores only `scannerModel` and a configuration-binding identity;
it has no custom endpoint, credential-reference or parallel profile interface.
The loaded plugin uses `api.runtime.llm.complete` with
`execution.mode: isolated-agent-runtime`: one fresh user message, fixed scanner
rubric, no tools, unrelated history, session creation or destination delivery.
Unsupported runtime paths fail incomplete; no direct-provider fallback.

OpenClaw requires host plugin LLM permission for an explicit model selection:

```json
{
  "plugins": {
    "entries": {
      "antenna": {
        "llm": {
          "allowModelOverride": true,
          "allowedModels": ["your-provider/your-model"],
          "allowedCompletionModels": ["your-provider/your-model"]
        }
      }
    }
  }
}
```

Merge this into existing host configuration, not the Antenna `config` object;
do not overwrite other settings. This grants model-use authority, not new
credentials. Use your registered canonical model ID in the permission lists.
Start/restart the gateway with the plugin enabled in Off or Dumb mode, check/select
the model, then enable Smart/Both and restart. Do not send real messages during an
unqualified cutover. Check/select and Smart diagnostics require the running local
gateway and operator-admin access to `antenna.scan`; the peer bearer cannot call it.
The RPC only scans literal bodies: no endpoint overrides, sessions or inbox writes.

The host resolves authentication and rotation; subscription support depends on the
selected runtime's isolated-completion capability and is not universally promised.
The SDK's `maxTokens` is advisory for some runtimes. Antenna requests 1,024 tokens,
limits input and accepted response bytes, and enforces a deadline; it cannot promise
a provider-side generation cap on a backend that ignores the hint. Oversized,
malformed or unsupported responses hold incomplete. No cost estimate, budget feature,
pre-run request display, automatic retry, model download or fallback.

Old `scannerProfile` selections do not authorize Smart in v1.6.8. Run
`select` with a registered model; success removes that obsolete field. Existing
held messages remain held. No automatic credential/profile migration is attempted.

## Editable Dumb rulesets

See [ruleset format and agent-friendly editing guide](RULESETS.md). The bundled
`rules/default.json` is selected by default. Optional `rulesetFile` selects one
absolute local file, loaded at startup. Custom copies belong outside the plugin
install directory. `rules validate FILE` checks structure and regex compilation;
`rules select FILE` saves the selection and requires restart. Missing or invalid
selected files fail visibly, never silently disable scanning.

## Explicit upgrade

Stop the selected gateway before migration. Preview:
`antenna-plugin /path/openclaw.json migrate`; apply with `migrate --apply`.
Only recognized `schemaVersion:1, policyRevision:"combined-smart-v1"`
configuration maps global/peer smart to both. Version 2 is unchanged.
Unknown legacy layouts, including old array inboxes, require manual migration;
they are rejected rather than guessed at or discarded. Existing schema-2
inbox payloads and hold reasons are never rewritten by configuration migration.
Back up config/state before operator edits. No automatic rollback conversion.

## MCS evaluation and custom-body diagnostics

With Dumb or Both, `evaluate` and `test` accept `--ruleset /absolute/candidate.json` for candidate
rule evaluation without changing the active file. These commands share the production scanner and do **not** send peer messages,
create sessions, change policy, insert inbox records, or release held work.
The small private kernel-lock files described below are their only scanner state.

See the [corpus format and authoring guide](CORPORA.md). `evaluate --corpus /path/tests.json`
selects a custom labelled corpus for that invocation; omitting it uses the separate
bundled file. `--preview` validates without scanning. Default human output contains
attacks caught, false positives, incomplete scans and model requests. `--verbose`
adds missed attack IDs/types/content, false-positive IDs/content/rules or model
findings, and incomplete IDs/reasons. Repetitions get separate summaries.
Structured JSON retains detailed diagnostics; custom corpora have dynamic denominators.

```text
antenna-plugin /path/openclaw.json mcs evaluate --engine dumb --preview --json
antenna-plugin /path/openclaw.json mcs evaluate --engine smart --repeat 2 --output /new/private-report
antenna-plugin /path/openclaw.json mcs evaluate --engine both --json
antenna-plugin /path/openclaw.json mcs test --text "meeting agenda" --json
antenna-plugin /path/openclaw.json mcs test --file one.txt --file two.txt --engine smart --expect benign
antenna-plugin /path/openclaw.json mcs test --stdin --engine dumb --output /new/private-report
antenna mcs --config /path/openclaw.json test --file one.txt --engine dumb
```

Use `antenna-plugin` from the archive, or the companion `antenna` dispatcher with
an explicit host config. `evaluate` defaults to Smart; `test` defaults to Dumb.
Smart is model-only, Both is Dumb-first with short-circuit, and `model` is a
model-only diagnostic alias. These names follow the four-mode policy; the older
proposal's combined “smart” spelling is not used. Off is not a diagnostic engine.

Smart/model/Both can upload selected bodies to the selected registered model.
`--preview` performs no scan or model request and never consumes stdin.
There is no additional confirmation prompt, provider fallback, retry, model
installation, selection activation, or automatic acceptance threshold. Tests of
multiple models are separate explicit selections/runs; reports carry model identities and fingerprints
for comparison. Evaluation itself never switches the selected model.

The bundled versioned corpus has 40 malicious, 40 benign and four ambiguous
controls. Its JSON contains intent rationales, development/held-out-family splits
and source/license provenance. Labels were authored without scanner results;
these are locally authored synthetic controls, **not an independently sourced
quality certification**. All cases have now been inspected during development review; none are claimed
as held-out evidence for this release. Bodies and labels are unchanged. Expected labels never enter model requests. Ambiguous controls do not
enter binary denominators; incomplete scans remain in the relevant denominators.
Reports distinguish misses, false flags, incomplete holds and operational failures,
including benign hold burden. Repetitions show disagreement without inflating
unique-case counts. No pricing lookup or cost estimation is performed. Provider-returned model names do not pin immutable weights.

Inputs are literal UTF-8 text, explicit regular files, or explicit stdin; forms
cannot be mixed except repeated files. BOMs and terminal newlines are preserved.
Empty, invalid UTF-8, binary/control, oversized, symlink, device, directory and FIFO
inputs are rejected rather than cropped. Failed files remain visible in batch
reports. Stdin has a 30-second read deadline. Use files/stdin to avoid placing
private text in process arguments or shell history. No URL fetching or globbing
is performed by the scanner. Shell expansion is the caller's responsibility.

`--expect benign|malicious` supplies an operator **batch-wide** label, never an
inferred correct answer. Unlabelled custom tests have no correctness score.
`--output` must name a new directory under an existing parent: permissions 0700,
reports 0600, no overwrites. Both JSON and escaped plain-text reports are saved.
Bodies, raw responses and finding explanations are omitted by default. `--verbose`
includes full missed-attack/false-positive bodies and findings in output/exports. `--details`
includes bounded scanner findings; reasons may quote submitted sensitive text.
Human output escapes untrusted values; do not interpret report content as commands
or HTML. Structured JSON reports include corpus hash, implementation-file hashes, scanner versions,
model-selection fingerprint, timings, request counts, order and per-case body digests.

Exit codes: evaluation report generated = 0 (not quality acceptance); custom pass
= 0, would hold = 2, incomplete/configuration failure = 3, invalid invocation/input
= 64. Mixed custom batches retain every error and return 64 if any input failed.

## Shared resource limits and retention

`limits.mjs` is the versioned hard-ceiling contract. Scan input is 64 KiB; derived
inspection text is bounded to min(4× bytes, 256 KiB) and two decoding levels.
Dumb has a 250 ms wall-time deadline, bounded 64/16 MiB old/young worker heaps,
and at most two process-local workers; idle workers expire after one second.
Timeout or worker failure terminates that worker and yields incomplete.

Gateway and CLI share two kernel-owned `flock` slots per engine beneath the
configured inbox directory (`antenna-scan-slots/`). They use the existing Bash/flock
dependencies; no daemon, owner database, polling queue or automatic stale-lock
stealing. Parent EOF/exit releases leases, with bounded lease lifetime. Default
Smart concurrency is two; `maxActiveSmart: 1` can lower a runtime/command's local
limit. The cross-process hard ceiling remains two; separate inbox installations
are separate capacity domains. Busy scans become incomplete, with no delayed
surprise request. Production durable inbox capacity still governs acceptance.

Smart's 30-second total includes scheduling; connect cap is five seconds, response
64 KiB, serialized request 16 KiB, requested output 1,024 tokens, at most 16 findings
and 512 characters per reason. Oversize context/requests hold incomplete, never crop.
Slow/cold providers time out rather than receiving an automatic retry. HTTP ingress
also has a five-second total body-read deadline and the existing two-request cap.

Pending scans are bounded by the durable inbox, capped at 100 items / 16 MiB,
including terminal items. Capacity is not renewed by silently deleting old records:
**no automatic retention purge, held-payload eviction or pressure-driven release**.
At capacity, further durable admission fails closed. Archive/retire state only by
an explicit stopped-writer operator procedure; no automatic cleanup command is
introduced. Read-only status includes state counts and hard limits. Per-message
scan metadata and diagnostic reports provide timing/outcome/usage counters without
ordinary raw-body logging. Evaluation/custom batches are serial, at most 500 cases
and five repetitions.

Local failure and load evidence does not establish broad support-host performance.
The initial local receive benchmark missed the proposed 50 ms p95 target, including
after worker reuse; resource/performance acceptance remains open. Loaded gateway,
provider, public-network, and long-running soak scopes must be reported separately.

## Companion packaging

This npm archive includes the plugin and its own operators, not the companion
`antenna` shell CLI or Python helpers. Keep companion `bin/`, `scripts/`, `lib/`
and `plugin/` together at the same release version. The repository's
`references/PLUGIN-CANDIDATE.md` describes the two-artifact handoff; it is not
included in this plugin-only archive. Legacy setup is not plugin initialization.

## Recovery and retained hooks

Use the version-matched companion recovery command and its `references/BACKUP-AND-READINESS.md` guide. Recovery is not a plugin-only CLI feature. General-hook rotation is recommended, not mandatory; operator credentials must remain separate. See [migration](MIGRATION.md).
