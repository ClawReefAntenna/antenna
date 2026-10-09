# Editable Dumb rulesets

Antenna ships `rules/default.json`. Keep custom copies outside the plugin install
folder: upgrades replace the bundled default, not your own files. One file is
active at a time. JSON requires no additional parser dependency.

```json
{
  "formatVersion": 1,
  "rules": [
    {
      "id": "LOCAL-001",
      "pattern": "\\bignore\\s+previous\\s+instructions\\b",
      "flags": "iu",
      "explanation": "Instruction takeover phrase"
    }
  ]
}
```

Required fields are exactly those shown. IDs are unique, 1–64 letters, digits,
underscores or hyphens. Patterns use JavaScript RegExp syntax without `/.../`
delimiters. Flags may contain `i`, `m`, `s`, `u`, each once; matching iteration is
owned by the scanner. A match flags the message through existing hold/release
handling. No rule has executable code, scoring or a custom action.

Limits: 256 KiB file, 1–128 rules, 2,048 characters per pattern and 512 per
explanation. Files must be regular files, not symlinks/devices/FIFOs. Invalid or
missing selections fail visibly; there is no fallback to a different ruleset.
A worker deadline terminates expensive regexes with an incomplete scan.

## Edit, validate, evaluate, select

```text
antenna-plugin /path/openclaw.json rules validate /absolute/my-rules.json
node /absolute/diagnostics/diagnostics/cli.mjs /absolute/openclaw.json evaluate --engine dumb --preview
node /absolute/diagnostics/diagnostics/cli.mjs /absolute/openclaw.json evaluate --engine dumb --preview
antenna-plugin /path/openclaw.json rules select /absolute/my-rules.json
```

Restart the gateway after selecting or editing the active file. The gateway uses
an immutable startup snapshot; each diagnostic invocation loads its own snapshot.
Remove a rule to disable it. Keep at least one rule; use MCS Off to disable scanning.
Omit `rulesetFile` from plugin configuration to return to the bundled default.
Validation checks usability, not detection effectiveness. Evaluation reuses the
separate editable `corpus/controls.json` baseline: 40 malicious, 40 benign and
four ambiguous examples. Use `--corpus /path/tests.json` to select your own
labelled examples; see the [corpus authoring guide](OPTIONAL-KITS.md#diagnostics). Add `--verbose`
for missed attacks and false positives with full content and rule explanations.
Evaluation does not activate the tested ruleset or release holds.

## Instructions to give your agent

“Edit a copy of this JSON ruleset. Preserve formatVersion and unique IDs. Add,
change or remove patterns, flags and short explanations. Validate it and run
Antenna's existing evaluation/custom tests. Show which attacks were missed and
which benign messages were flagged. Do not activate it unless requested.”

For downloaded rules: translate to JavaScript regex and JSON escaping, preserve
required license notices, and report unsupported constructs. Do not flatten
conjunctions, thresholds or exclusions into independent rules if doing so changes
their meaning. There is no automatic importer. No per-rule provenance or embedded
examples are required; put examples in the separate corpus or custom input files.

## Scanner behavior and default scope

The engine performs NFKC/lowercase normalization, removes selected zero-width
characters, and scans bounded Base64/escape projections. These are scanner code,
not user-supplied rule instructions. Direct clause-local negation can suppress a
match; quoting or code fences do not automatically suppress it. Decoding is never
execution. Original message bytes remain unchanged.

The initial external default is nine locally authored MIT rules extending the
previous five. It covers selected takeover, disclosure, bypass, remote execution
and concealment phrases. It is English-oriented, not a multilingual guarantee.
Security discussion can still cause false alarms; paraphrases can evade patterns.
The baseline corpus is a diagnostic sample, not a protection guarantee.

Design/pattern coverage was reviewed against ATR, OpenRouter's published patterns,
fevziegeyurtsevenler/prompt-injection-detection-rules, and OWASP guidance. No
third-party regex text is bundled in this candidate; those sources are not runtime
dependencies or compatibility claims. Any future copied rules must carry the
notices their upstream licenses require.
