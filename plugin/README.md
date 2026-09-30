# Antenna OpenClaw plugin — development candidate

Inbound signed v2 delivery with Off / Dumb / Smart / Both content scanning.
Default: Dumb. Both runs Dumb first and only calls Smart after a pass.
Authentication, replay checks and receiver-selected existing destinations apply
in every mode. Ordinary approval and MCS holds remain independent.

This is the packaged inbound vertical slice, not a released replacement for
the legacy Antenna skill. Manual legacy migration, new direct/list transport and contact exchange now have
a development implementation; see [MIGRATION.md](MIGRATION.md). Full release,
live cutover and native subscription qualification remain separate work. No atomic session-incarnation or exactly-once
delivery guarantee is made.

## Install in an isolated OpenClaw instance

Requires Node supported by OpenClaw 2026.9.5+, Bash, jq and flock.
Package with `npm pack ./plugin`; install the resulting archive with
`openclaw plugins install /absolute/path/to/archive.tgz` using the intended
isolated OpenClaw state/config environment. Do not point qualification at
production state. The OpenClaw peer dependency supplies the public gateway SDK.

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
Set the plugin enabled and allowlisted only in the intended isolated config,
then restart that gateway. Mode/selection edits also require a restart.
The local adapter uses the gateway's configured port and token authentication.
A non-string token reference must be resolved by OpenClaw before registration;
the standalone operator process requires a resolved local gateway token.

## Operator commands

All output is JSON, including escaped message bodies; never render decoded
message bodies as terminal commands, HTML or model instructions.

```text
antenna-plugin /path/openclaw.json status
antenna-plugin /path/openclaw.json mode off|dumb|smart|both [peer]
antenna-plugin /path/openclaw.json mode default peer
antenna-plugin /path/openclaw.json check profile.json
antenna-plugin /path/openclaw.json select profile.json
antenna-plugin /path/openclaw.json inbox list
antenna-plugin /path/openclaw.json inbox show ITEM_ID
antenna-plugin /path/openclaw.json inbox release ITEM_ID '["Awaiting approval","MCS flagged"]'
antenna-plugin /path/openclaw.json inbox discard ITEM_ID
antenna-plugin /path/openclaw.json inbox approve-ordinary
```

Status is offline. Check makes one bounded synthetic request, does not save or
activate anything, and makes no quality claim. Select checks and saves one
shared Smart/Both profile without changing mode or enabling the plugin.
No automatic retries, fallback, model downloads, scheduler or dashboard.

Profile fields: `baseUrl`, `model`, declared `locality`
(local/remote/unknown), `tokenParameter` (max_tokens/max_completion_tokens),
`jsonObject` boolean, `maxInputBytes` (1–65536), optional `strictSchema`
and `reasoningEffort`. Current adapter also caps serialized requests at
16 KiB and output at 1024 tokens; oversized input holds incomplete, never crops.
Optional `credentialRef` is exactly `{"env":"VARIABLE"}` or
`{"file":"/absolute/private/file"}`; file must be regular, private and bounded.
No credential value is copied into the profile. Credential rotation at the
same reference is supported.

Optional `configuredModel` resolves an explicit configured provider/model or
unambiguous alias from OpenClaw's explicit models configuration. Only
openai-completions providers are supported here; implicit catalogs and native
subscription credentials are not silently bridged. Supply the credential
reference explicitly. Resolution changes invalidate validation. Smart/Both
without a ready profile cannot be selected; later scanner failure holds
incomplete. Remote endpoints require HTTPS; loopback HTTP is supported.

## Explicit upgrade

Stop the isolated gateway before migration. Preview:
`antenna-plugin /path/openclaw.json migrate`; apply with `migrate --apply`.
Only recognized `schemaVersion:1, policyRevision:"combined-smart-v1"`
configuration maps global/peer smart to both. Version 2 is unchanged.
Unknown legacy layouts, including old array inboxes, require manual migration;
they are rejected rather than guessed at or discarded. Existing schema-2
inbox payloads and hold reasons are never rewritten by configuration migration.
Back up config/state before operator edits. No automatic rollback conversion.

## MCS evaluation and custom-body diagnostics (development candidate)

These commands share the production scanner and do **not** send peer messages,
create sessions, change policy, insert inbox records, or release held work.
The small private kernel-lock files described below are their only scanner state.

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

Smart/model/Both can upload selected bodies to the already validated endpoint.
Before requests, stderr displays its endpoint/model/locality and maximum request
count. `--preview` performs no scan or model request and never consumes stdin.
There is no additional confirmation prompt, provider fallback, retry, model
installation, selection activation, or automatic acceptance threshold. Tests of
multiple models are separate explicit selections/runs; reports carry fingerprints
for comparison. Evaluation itself never switches the selected model.

The bundled versioned corpus has 40 malicious, 40 benign and four ambiguous
controls. Its JSON contains intent rationales, development/held-out-family splits
and source/license provenance. Labels were authored without scanner results;
these are locally authored synthetic controls, **not an independently sourced
quality certification**. No rules/rubric were tuned against these held-out-family
cases. Expected labels never enter model requests. Ambiguous controls do not
enter binary denominators; incomplete scans remain in the relevant denominators.
Reports distinguish misses, false flags, incomplete holds and operational failures,
including benign hold burden. Repetitions show disagreement without inflating
unique-case counts. Usage is reported when returned; cost is unknown without a
qualified price source. Provider-returned model names do not pin immutable weights.

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
Bodies, raw responses and finding explanations are omitted by default. `--details`
includes bounded scanner findings; reasons may quote submitted sensitive text.
Human output escapes untrusted values; do not interpret report content as commands
or HTML. Reports include corpus hash, implementation-file hashes, scanner versions,
endpoint fingerprint, timings, request counts, order and per-case body digests.

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
