# Optional tools for v1.6.9

Your everyday kit is ready for messaging. Add diagnostics when you want to try
screening rules or test a collection of messages.

## Diagnostics

Download `antenna-diagnostics-1.6.9.tgz` from the
[v1.6.9 release](https://github.com/ClawReefAntenna/antenna-openclaw/releases/tag/v1.6.9),
verify its SHA-256 against `SHA256SUMS`, and extract it into its own directory,
separate from the native plugin and companion. Use the kit matching your runtime version.

From the extracted diagnostics directory:

```sh
node diagnostics/cli.mjs /absolute/openclaw.json evaluate --engine dumb --preview
node diagnostics/cli.mjs /absolute/openclaw.json evaluate --engine dumb --output /absolute/new-report
node diagnostics/cli.mjs /absolute/openclaw.json test --text 'meeting agenda' --json
```

Replace the host path with your resolved OpenClaw JSON configuration. For saved
reports, choose a new directory under an existing parent. Dumb runs offline;
Smart/Both use your selected model and may send it the supplied messages.

The kit includes scanner libraries and a sample corpus. Read its
`diagnostics/README.md` for custom inputs and reports. To try a custom ruleset,
add `--ruleset /absolute/my-rules.json`. Testing does not change your active selection.
A corpus-only download supplies test data, not the tools needed to run it.

## Migration

Moving from the older relay? Migration uses a separate app to preserve your
identity, permissions and saved state. That app is not yet published; it is not
included in the messaging or diagnostics downloads.

Already using v1.6.8 native transport? Follow the normal update instructions—no
relay migration is needed. Keep your existing identity, permissions and held messages.
