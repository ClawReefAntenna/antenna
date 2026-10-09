# Optional tools for this candidate

Everyday messaging, screening, inbox review, contacts, health and recovery work
without either kit. Neither kit is fetched or executed automatically.

## Diagnostics

Use the **version-matched standalone diagnostics asset** alongside the companion,
not inside the native plugin directory. This local candidate is `oc168-sec001.1`,
compatible with the accompanying schema-2 runtime and `antenna-limits-2` contract.
It has not been published: there is no download URL for this candidate yet.
When released, obtain the matching diagnostics asset from the release's asset list
and verify its SHA-256 against that release's manifest before extracting it.
Do not substitute the older v1.6.8 corpus-only download for the full kit.

From the extracted diagnostics directory:

```sh
node diagnostics/cli.mjs /absolute/openclaw.json evaluate --engine dumb --preview
node diagnostics/cli.mjs /absolute/openclaw.json evaluate --engine dumb --output /new/private-report
node diagnostics/cli.mjs /absolute/openclaw.json test --text 'meeting agenda' --json
```

The kit carries its own fingerprinted scanner libraries and realistic corpus.
Its `diagnostics/README.md` describes report bounds and model-backed execution.
It does not install a gateway plugin or activate a model. To evaluate a custom
runtime ruleset, explicitly select that same file with `--ruleset`.

## Migration

Migration is a separate, versioned app/repository candidate, not an optional
runtime plugin feature. Its remote repository name and release version have not
been selected or published. Obtain the qualified matching migration release
when available; do not use the diagnostics kit to migrate an installation.

Local maintainers can build the `migration` artifact from `packaging/build.py`;
it has a license, compatibility record, narrow staging/schema tools and fixtures.
Conversion/retirement and configuration-write qualification remain open under
OC168-SEC-002–004. Keep existing identities and unresolved holds; do not reactivate
the retired relay. No extra acknowledgment is required to preserve existing HTTP
peer URLs. No general-hook rotation requirement is introduced by this separation.
