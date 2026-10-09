# Antenna diagnostics — local candidate oc168-sec001.1

Standalone, not installed with native messaging. Compatibility: matching candidate
manifest, schema 2, antenna-limits-2. Release version/URL not selected.
Run from this extracted kit with `node diagnostics/cli.mjs HOST COMMAND ...`.

## MCS evaluation and custom-body diagnostics

With Dumb or Both, `evaluate` and `test` accept `--ruleset /absolute/candidate.json` for candidate
rule evaluation without changing the active file. These commands share the production scanner and do **not** send peer messages,
create sessions, change policy, insert inbox records, or release held work.
The small private kernel-lock files described below are their only scanner state.

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
presented as complete. Realistic test bodies and protective rules are unchanged.

The asset manifest records SHA-256 hashes of every file. Reports additionally
fingerprint the scanner implementation, corpus and selected rules/model. Those
identify this kit, not an arbitrary installed plugin; compare the asset manifest
to the matching runtime before treating results as runtime qualification.
