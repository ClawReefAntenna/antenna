# Local package separation

Run `python3 packaging/build.py --output /new/empty-output-path` from this source.
The destination must not exist. No host configuration, installation or remote
publication is changed. Three literal allowlists define native, companion and ClawHub contents. Unknown source files are not added.
Native npm metadata must match the native allowlist (npm also adds the license).

Use **only the generated `clawhub/` staging directory** for a future ClawHub
collector/upload, never this source checkout. Companion and ClawHub bytes match.
Each asset has a separate JSON manifest of source paths, file hashes, modes and
owner ticket. The deterministic archives have fixed timestamps and ownership.
Build after committing source to bind manifests to a reviewable source revision.

## Optional apps

App-specific code, tests and release packaging live in their authoritative repositories:

- [Migration](https://github.com/ClawReefAntenna/antenna-migration)
- [Diagnostics](https://github.com/ClawReefAntenna/antenna-diagnostics)

Each app builds independently and bundles pinned shared helpers from this
repository. Its `SOURCE.json` records the source revision and file hashes.
Runtime helpers remain authoritative here; app-specific changes stay in the app.

From this checkout, `npm pack ./plugin` builds the native npm archive. The
allowlist builder produces native, companion and ClawHub packages plus a full
source archive. Optional apps are not included in that source archive.

## Engineering evidence

The earlier local receive benchmark missed the proposed 50 ms p95 target, including
after worker reuse. Broad performance acceptance remains open; loaded gateway,
provider, public-network and long-running soak results must be assessed separately.

## Configuration-write implementation

The explicit-file CLI uses source comparisons and a cooperative lock; these do
not provide a cross-tool compare-and-swap API. Other configuration writers must
be stopped while editing. The adapter also supports isolated/offline rehearsals
without selecting or invoking the active host. Operator setup and private
recovery-copy details remain in the [plugin reference](../plugin/README.md).
