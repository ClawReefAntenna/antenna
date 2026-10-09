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
source archive, never an installable. Keep these candidate bytes distinct from
the already-published v1.6.8 assets.
