# Antenna v1.6.8 — release notes

**Prepared final-version artifacts; not yet published.** No release date is assigned.

## What changes

Antenna moves inbound messaging from the legacy hooks/relay arrangement to an
OpenClaw plugin. Signed v2 envelopes address a receiver-approved existing
conversation. Code enforces authentication, permissions, replay protection and
holds before direct local submission; no messaging relay model is involved.
The protocol/transport/adapter separation supports future runtime implementations;
this release qualifies the OpenClaw adapter, not universal interoperability.

Off, Dumb, Smart and Both modes keep content screening separate from ordinary
approval. Dumb is the default; Both short-circuits on a Dumb finding. Smart uses
an explicitly selected registered host model in fresh, zero-tool context.
Operators can evaluate local corpora, test individual bodies, use custom Dumb
rulesets and request concise or verbose reports. Diagnostics do not deliver messages.

## Install and migrate

There are two version-matched artifacts:

- `clawreefantenna-antenna-plugin-1.6.8.tgz`: native OpenClaw plugin archive.
- `antenna-companion-1.6.8.tar.gz`: CLI, support files and relative plugin layout.

Start with [installation guidance](references/PLUGIN-CANDIDATE.md) and
[manual migration](plugin/MIGRATION.md). Do not use the retained legacy installer
to configure plugin ingress. Rehearse against an isolated copy first.

This is a breaking, coordinated transport change, not seamless old/new delivery.
Inventory peers, existing target permissions, signing pins, holds and group grants;
coordinate the Registry v2 binding where groups are used. Retire peer access to
general hooks before enabling plugin ingress. No silent fallback to old hooks.
Legacy held messages remain recovery evidence, not automatically rewritten v2 sends.
Rollback disables ingress and preserves state; it does not restore peer-known
hook authority or automatically resend uncertain messages.

## Tested scope and limitations

Linux with OpenClaw 2026.9.5 was observed on Node 26.8.2 and 24.19.0. The package
API floor is not certification of every later host version or OS. Bash, jq and
flock are required; companion tools also need Python 3, OpenSSL, curl and ordinary
GNU/Linux helpers. Age tools are needed for encrypted backup/exchange operations.

One real GPT-5.6 Terra/native Codex/OAuth evaluation used 40 malicious, 40 benign
and four ambiguous development controls:

| Mode | Attacks caught | Benign false flags | Model requests |
| --- | ---: | ---: | ---: |
| Dumb | 30/40 | 9/40 | 0 |
| Smart | 40/40 | 1/40 | 84 |
| Both | 40/40 | 9/40 | 45 |

No incomplete outcomes in that run. The corpus is synthetic and development-reviewed,
not independent certification. Dumb misses paraphrases, obfuscations and multilingual
attacks; quotations and negation cause false flags. Both cannot clear Dumb flags.
Model isolation is not OS sandboxing, and output-token hints are not universal
provider caps. Invalid or failed scans remain incomplete holds. Scanner clearance
is not proof of safety. Operators explicitly select mode/model; default stays Dumb.

Delivery remains best-effort, not exactly-once. The approved address may be reset
concurrently after preflight. Held/submitted responses do not establish completed
agent processing; uncertain outcomes must not be blindly retried. The selected
public HTTPS test qualifies one Funnel binding, not every production deployment.

## Coordinated recovery release

v1.6.7 provides legacy encrypted backup/in-place restore and local readiness;
it is not a converter for plugin-state downgrade. Backup is optional preparation,
not proof that peers are ready or a required activation gate.

Both builds must be ready before the announcement. v1.6.8 publication is planned
seven days after that announcement, with no early public breaking build. No date,
announcement or countdown is created by this private package. Final dated notice
and public links require publication preparation and authorization; deployment is
separate. Passage of seven days does not authorize publication or remote upgrades.
