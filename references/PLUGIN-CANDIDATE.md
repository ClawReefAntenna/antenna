# Antenna 1.6.8 — installation and release handoff

**Final-version preparation; publication pending. No live upgrade is authorized by this file.**
The plugin is the signed ingress and direct-dispatch adapter. The companion CLI
retains sender, contact, list/group and recovery helpers. There is no relay model
in the new ingress path. Read this before the retained legacy guides.

## Two artifacts, one version

| Artifact | Contents / role |
| --- | --- |
| `clawreefantenna-antenna-plugin-1.6.8.tgz` | `npm pack ./plugin`: OpenClaw manifest, `.mjs` operators/runtime, replay shell helper, bundled corpus/default rules, ruleset/corpus guides, README and migration guide. Install this archive with OpenClaw. |
| `antenna-companion-1.6.8.tar.gz` | Companion source payload: `bin`, `scripts`, `lib`, `plugin`, references and root metadata/examples. Keep this directory layout intact. Not a second OpenClaw plugin archive. |

The plugin archive alone does **not** include the legacy companion CLI or its
Python helpers. The companion retains `plugin/` because `antenna mcs`, migrated
send/contact commands and migration helpers use those relative paths. Keep both
artifacts at the same version; use recorded hashes, not filenames alone.
Renamed Python modules use underscores (`session_policy.py`, `clawreef_http.py`,
`clawreef_registration.py`, `clawreef_reports.py`, `clawreef_groups.py`). Replace
program files coherently; do not overlay just a caller onto old libraries.

## Prerequisites and tested scope

- Observed evidence: Linux x64, Node 26.8.2 and 24.19.0, OpenClaw 2026.9.5.
- Plugin: Node compatible with the selected OpenClaw, Bash, jq and flock;
  standalone operators need the OpenClaw SDK peer dependency.
- Companion: Python 3, Bash, jq, OpenSSL, curl and ordinary GNU/Linux helpers.
  Age/age-keygen are needed for encrypted exchange/backup operations.
- Manifest constraint `openclaw >=2026.9.5` is an API floor, **not** proof that
  every later release or every OS has been qualified. Windows-native/macOS and
  other provider/platform combinations are not certified by the local evidence.

## Isolated installation and operation

1. Unpack the companion into a separate installation directory; never extract it over
   live state. Do not run the retained legacy `install.sh` / `antenna setup` to
   initialize plugin ingress: they configure the old relay/hooks path.
2. With disposable `OPENCLAW_STATE_DIR` and `OPENCLAW_CONFIG_PATH`, install the
   exact plugin archive:

   ```sh
   openclaw plugins install --force --accept-capabilities /absolute/path/to/clawreefantenna-antenna-plugin-1.6.8.tgz
   ```

   These flags accept the reviewed local archive and declared capabilities.
   Do not start that gateway until an explicit receiver policy is merged and its
   enablement reviewed. The native installer can create an enabled entry; the
   operator `init` command instead creates a new entry disabled.
3. Follow [plugin configuration and operators](../plugin/README.md). Receiver-owned
   addresses must name existing destinations. Ordinary approval and MCS holds
   remain independent; Off does not disable signatures, permission or replay checks.
4. For legacy state, follow [manual migration](../plugin/MIGRATION.md). Preserve old
   holds, keys, lists and registrations; retire peer access to the general hook
   credential before cutover. Unrelated hook users require explicit inventory.
5. Rollback means disable ingress while retaining state—not restore an old
   peer-known gateway credential or silently return to legacy delivery.

Examples from the companion root:

```sh
node plugin/cli.mjs /absolute/isolated/openclaw.json status
bin/antenna.sh mcs --config /absolute/isolated/openclaw.json evaluate --engine dumb --output /absolute/new-report
node plugin/migration-check.mjs doctor /absolute/isolated/openclaw.json /absolute/legacy-copy
```

Diagnostics do not deliver or change policy. Smart/Both diagnostics send bodies
to the explicitly selected registered host model through its isolated runtime.
`--preview` is optional and makes no model calls. Default reports omit bodies;
`--verbose` includes failure bodies and findings. `--corpus` selects one local
JSON corpus for that invocation; see [the corpus guide](../plugin/CORPORA.md).

## Transport and accepted limits

HTTPS is the default. In retained setup and peer add/update, `--allow-insecure`
permits HTTP without transport encryption and produces one configuration warning.
Tokens/messages can be exposed unless an encrypted tunnel protects the connection.
Private addressing alone does not establish encryption; loopback relies on local
host security. Signatures authenticate content but do not encrypt it.

Delivery is best-effort. A runtime submission is not a final response or an
exactly-once guarantee. Do not automatically resend an uncertain outcome. The
accepted local 73.5 ms p95 is not a universal latency promise. The scanner-quality review below records known misses and false positives;
scanner clearance is not proof that content is safe.

## Publication hold

Final-version files are prepared privately. No release tag, remote push,
ClawHub/npm publication, live migration, announcement or seven-day countdown is
started by these artifacts. The selected BETTYXVIII public DNS/CA/proxy ingress
check passed; its temporary endpoint was removed. This is not qualification of
every production binding or a public Registry group fan-out test.

The separate v1.6.7 recovery build is preserved. Both builds must be ready before
an announcement, with v1.6.8 publication planned seven days afterward. The notice
remains undated until a schedule is approved. See [release notes](../RELEASE-NOTES.md).
Production host inventory and authorization remain separate. Reuse evidence by
component and artifact; do not repeat broad tests without a relevant change.

## dev.5 scanner changes

See [scanner setup](../plugin/README.md#registered-model-smart-scanning) and
[ruleset authoring](../plugin/RULESETS.md). Smart now selects a registered host
model and uses runtime authentication through isolated zero-tool completion.
No separate endpoint/authentication profile. Old scannerProfile selections do not
authorize Smart; explicitly check/select a registered model. OpenClaw plugin LLM
permissions are required; no new credentials are created. CLI Smart checks need
the running local gateway. External ruleset edits require restart.

Local fixture qualification is not proof that every model/runtime/subscription
works. The host's output-token hint is advisory for some runtimes; Antenna enforces
input/accepted-response bounds and deadlines, not a universal provider generation
cap. Existing holds, receiver permissions and release approval remain unchanged.

## Scanner-quality review and supported scope

The bundled development-reviewed synthetic corpus contains 40 malicious, 40
benign and four ambiguous controls. One real GPT-5.6 Terra / native Codex / OAuth
run on OpenClaw 2026.9.5 produced:

| Mode | Attacks caught | False positives | Incomplete | Model calls |
| --- | ---: | ---: | ---: | ---: |
| Dumb | 30/40 | 9/40 | 0 | 0 |
| Smart | 40/40 | 1/40 | 0 | 84 |
| Both | 40/40 | 9/40 | 0 | 45 |

Dumb is an English-oriented pattern baseline: five multilingual attacks, two
obfuscations, two concealment paraphrases and one remote-execution paraphrase were
missed. Its nine false flags concern quotations/security discussion, a code-safety
warning, public-versus-private wording and protective negation. Smart's sole false
flag was an explicitly quoted password-disclosure training exercise. Both retains
Dumb flags without model review; fewer calls does not mean fewer false positives.

Engineering review recommends retaining these measured scanner bytes for v1.6.8,
not exempting all quotations or tuning to this already-reviewed corpus. No label,
rule, rubric or default is changed. Smart has the better observed quality in this
comparison, but operators choose their mode/model. This is not independent or
held-out certification, universal model support, or a guarantee against injection.
Ambiguous examples varied between runs and remain outside binary denominators.
A bare encoded attack control tests recognition, not proof of malicious intent in
every surrounding context. Larger/independent datasets and repeatability remain
unmeasured; no automatic quality threshold is imposed.

The scanner model has zero tools and fresh context containing only rubric and
message body. This is model/tool isolation, not a separate OS sandbox for the
trusted host process. Invalid/failed scans hold as incomplete; valid verdicts feed
existing code-owned delivery/approval policy. Ordinary approval is independent.

## Recovery and coordinated-release inventory

- Preserve the separate frozen v1.6.7 recovery candidate and its checksums. Its
  age-encrypted backup/restore and readiness commands address legacy state, not
  schema-2 plugin holds. Do not advertise it as a downgrade converter.
- Before a real migration, inventory legacy config/peers, signing identity and
  pins, destination permissions, lists, group registrations/grants, unresolved
  legacy holds, hook integrations and relay-owned provisioning. Back up those
  records and host config privately; never place live state in release archives.
- Preserve new inbox/replay files and custom rules/corpora outside install folders.
  Disabling/uninstalling the plugin does not authorize deletion of that state.
- Rollback stops ingress and retains evidence. Never automatically restore a
  peer-known general-hook credential, release old holds or resend unknown delivery.
- Source/lifecycle qualification used recognized synthetic legacy layouts, not
  every historical deployment. Unknown/custom layouts require explicit operator
  reconciliation. Registry v2 support and contact refresh must be coordinated.
- OpenClaw 2026.9.5 on Linux is observed. The minimum manifest constraint is an
  API floor, not a blanket guarantee for future releases, Windows/macOS or other
  native models. GPT-5.6 Terra native Codex/OAuth is the real scanner path measured;
  the synthetic provider tests establish failure handling, not other-model quality.
- Both v1.6.7 and v1.6.8 must be ready before any seven-day adoption announcement.
  No clock starts with candidate packaging. GitHub, ClawHub, deployment and
  announcements retain their separate explicit approval gates.
