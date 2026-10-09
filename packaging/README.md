# Local package separation

Run `python3 packaging/build.py --output /new/empty-output-path` from this source.
The destination must not exist. No host configuration, installation or remote
publication is changed. Five literal allowlists define native, companion,
ClawHub, diagnostics and migration contents. Unknown source files are not added.
Native npm metadata must match the native allowlist (npm also adds the license).

Use **only the generated `clawhub/` staging directory** for a future ClawHub
collector/upload, never this source checkout. Companion and ClawHub bytes match.
Each asset has a separate JSON manifest of source paths, file hashes, modes and
owner ticket. The deterministic archives have fixed timestamps and ownership.
Build after committing source to bind manifests to a reviewable source revision.

The migration tree seeds a separate local repository. Remote name/publication
and qualification are later steps, not side effects of packaging. The diagnostics
asset is standalone from this repository; no separate diagnostics repo is needed.
Complete source/development history remains in Git and a separately generated
source archive, never an installable. Keep local correction builds distinct from published assets until their exact
replacement packet is reviewed. Migration build details belong here and in the
source-only migration guides, not in the operator acquisition page.

## Source builds and engineering evidence

From a source checkout, `npm pack ./plugin` builds only the native npm archive.
Use the allowlist builder above for coordinated native, companion, diagnostics
and full-source packages. The migration artifact is built locally for its separate
app; it is not a published runtime download.

The separate migration candidate includes fixture-tested stopped-host retirement,
protected staging and interrupted-apply recovery (OC168-SEC-002–004). Its live
cutover and publication remain separate work.

The diagnostic corpus is locally authored synthetic material with source/license
metadata. All cases have been reviewed during development; its split labels are
not held-out evidence or independent quality certification. Reported model names
do not pin immutable provider weights.

The earlier local receive benchmark missed the proposed 50 ms p95 target, including
after worker reuse. Broad performance acceptance remains open; loaded gateway,
provider, public-network and long-running soak results must be assessed separately.
