# Antenna diagnostics — v1.6.9

Try screening rules against sample messages or your own examples, without
sending messages or changing your active settings. Use the diagnostics kit
matching your Antenna release; it is a separate download from native messaging.
[Download v1.6.9](https://github.com/ClawReefAntenna/antenna-openclaw/releases/download/v1.6.9/antenna-diagnostics-1.6.9.tgz) and verify its
[SHA-256 checksum](https://github.com/ClawReefAntenna/antenna-openclaw/releases/download/v1.6.9/SHA256SUMS) before extracting it into its own directory.
Run from this extracted kit with `node diagnostics/cli.mjs HOST COMMAND ...`.

## MCS evaluation and custom-body diagnostics

With Dumb or Both, `evaluate` and `test` accept `--ruleset /absolute/candidate.json` for candidate
rule evaluation without changing the active file. These commands share the
production scanner and leave your messages, inbox and policy unchanged.

See the [corpus format and authoring guide](../plugin/CORPORA.md). `evaluate --corpus /path/tests.json`
selects a custom labelled corpus for that invocation; omitting it uses the separate
bundled file. `--preview` validates without scanning. Default human output contains
attacks caught, false positives, incomplete scans and model requests. `--verbose`
adds missed attack IDs/types/content, false-positive IDs/content/rules or model
findings, and incomplete IDs/reasons. Repetitions get separate summaries.
Requested JSON report files retain detailed diagnostics; custom corpora have dynamic denominators.

```text
node diagnostics/cli.mjs /path/openclaw.json evaluate --engine dumb --preview --json
node diagnostics/cli.mjs /path/openclaw.json evaluate --engine smart --repeat 2 --output /new/private-report
node diagnostics/cli.mjs /path/openclaw.json evaluate --engine both --json
node diagnostics/cli.mjs /path/openclaw.json test --text "meeting agenda" --json
node diagnostics/cli.mjs /path/openclaw.json test --file one.txt --file two.txt --engine smart --expect benign
node diagnostics/cli.mjs /path/openclaw.json test --stdin --engine dumb --output /new/private-report
node diagnostics/cli.mjs /path/openclaw.json test --file one.txt --engine dumb
```

Use the standalone `diagnostics/cli.mjs` from this kit with an explicit host config. `evaluate` defaults to Smart; `test` defaults to Dumb.
Smart is model-only, Both is Dumb-first with short-circuit, and `model` is a
model-only diagnostic alias. Off is not a diagnostic engine.

Smart/model sends selected message bodies to your configured model; Both does
so after a Dumb pass. Preview makes no model calls and never consumes stdin.
Evaluation leaves your selected model and live policy unchanged. To compare
models, select and run each explicitly; reports include model identities and
fingerprints.

The bundled corpus contains 40 malicious, 40 benign and four ambiguous examples.
Use your own examples alongside this sample when comparing screening choices.
Expected labels never enter model requests. Ambiguous cases do not enter binary
scores; incomplete scans remain in their labelled denominators. Repetitions show
variation without increasing the number of unique examples.

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
includes full missed-attack/false-positive bodies and findings in requested exports; console output is bounded. `--details`
includes bounded scanner findings; reasons may quote submitted sensitive text.
Human output escapes untrusted values; do not interpret report content as commands
or HTML. Structured JSON reports include corpus hash, implementation-file hashes, scanner versions,
model-selection fingerprint, timings, request counts, order and per-case body digests.

Exit codes: evaluation report generated = 0 (not quality acceptance); custom pass
= 0, would hold = 2, incomplete/configuration failure = 3, invalid invocation/input
= 64. Mixed custom batches retain every error and return 64 if any input failed.


## Report bounds

Console output is capped at 64 KiB; larger results produce a compact summary.
Use `--output NEW_DIRECTORY` for full JSON/plain-text reports (0700 directory,
0600 files). Detailed reports have a 32 MiB budget per representation; reduce
cases, repetitions or verbose/details if it is exceeded. No partial report is
presented as complete.

## Technical compatibility

This kit matches the v1.6.9 release manifest, schema 2 and `antenna-limits-2`.
Scans use private kernel-lock slots beneath the configured inbox directory;
they do not write message or policy state.

The asset manifest records SHA-256 hashes of every file. Reports additionally
fingerprint the scanner implementation, corpus and selected rules/model. Those
identify this kit, not an arbitrary installed plugin; compare the asset manifest
to the matching runtime before treating results as runtime qualification.
