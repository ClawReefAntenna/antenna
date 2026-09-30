# Antenna 1.6.8-dev.4 — local candidate handoff

**Unreleased development candidate. Not a production-upgrade instruction.**
The plugin is the signed ingress and direct-dispatch adapter. The companion CLI
retains sender, contact, list/group and recovery helpers. There is no relay model
in the new ingress path. Read this before the retained legacy guides.

## Two artifacts, one candidate

| Artifact | Contents / role |
| --- | --- |
| `clawreefantenna-antenna-plugin-1.6.8-dev.4.tgz` | `npm pack ./plugin`: OpenClaw manifest, `.mjs` operators/runtime, replay shell helper, bundled corpus, README and migration guide. Install this archive with OpenClaw. |
| `antenna-companion-1.6.8-dev.4.tar.gz` | Companion source payload: `bin`, `scripts`, `lib`, `plugin`, references and root metadata/examples. Keep this directory layout intact. Not a second OpenClaw plugin archive. |

The plugin archive alone does **not** include the legacy companion CLI or its
Python helpers. The companion retains `plugin/` because `antenna mcs`, migrated
send/contact commands and migration helpers use those relative paths. Keep both
artifacts at the same candidate version; use recorded hashes, not filenames alone.
Renamed Python modules use underscores (`session_policy.py`, `clawreef_http.py`,
`clawreef_registration.py`, `clawreef_reports.py`, `clawreef_groups.py`). Replace
program files coherently; do not overlay just a caller onto old libraries.

## Prerequisites and tested scope

- Local evidence: Linux x64, Node 26.8.2 and OpenClaw 2026.9.5.
- Plugin: Node compatible with the selected OpenClaw, Bash, jq and flock;
  standalone operators need the OpenClaw SDK peer dependency.
- Companion: Python 3, Bash, jq, OpenSSL, curl and ordinary GNU/Linux helpers.
  Age/age-keygen are needed for encrypted exchange/backup operations.
- Manifest constraint `openclaw >=2026.9.5` is an API floor, **not** proof that
  every later release or every OS has been qualified. Windows-native/macOS and
  other provider/platform combinations are not certified by the local evidence.

## Isolated installation and operation

1. Unpack the companion into a separate candidate directory; never extract it over
   live state. Do not run the retained legacy `install.sh` / `antenna setup` to
   initialize plugin ingress: they configure the old relay/hooks path.
2. With disposable `OPENCLAW_STATE_DIR` and `OPENCLAW_CONFIG_PATH`, install the
   exact plugin archive:

   ```sh
   openclaw plugins install --force --accept-capabilities /absolute/path/to/clawreefantenna-antenna-plugin-1.6.8-dev.4.tgz
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

Diagnostics do not deliver or change policy. Smart/model diagnostics contact the
explicitly selected scanner endpoint; preview first and account for provider cost.
Default reports omit bodies; optional details can contain submitted text.

## Transport and accepted limits

HTTPS is the default. In retained setup and peer add/update, `--allow-insecure`
permits HTTP without transport encryption and produces one configuration warning.
Tokens/messages can be exposed unless an encrypted tunnel protects the connection.
Private addressing alone does not establish encryption; loopback relies on local
host security. Signatures authenticate content but do not encrypt it.

Delivery is best-effort. A runtime submission is not a final response or an
exactly-once guarantee. Do not automatically resend an uncertain outcome. The
accepted local 73.5 ms p95 is not a universal latency promise. Dumb's current
24/40 detections and 10/40 benign false flags are provisionally accepted only;
quality/corpus review remains before final hardening.

## Publication hold

No release tag, remote push, ClawHub/npm publication, live migration, announcement
or seven-day adoption countdown is started by these artifacts. Remaining handoff:
pre-hardening Dumb review, deployment-specific public DNS/CA/proxy qualification,
final support/recovery inventory and coordinated version/release approval. The
separate v1.6.7 recovery candidate is preserved; it is not replaced or published
by this development version. Reuse existing evidence by component and artifact;
do not repeat the full failure matrix without a relevant change or new concern.
