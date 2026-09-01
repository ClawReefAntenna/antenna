# OpenClaw 2026.8.1 Host Upgrade Checklist

This checklist applies when an existing Antenna host moves from OpenClaw
2026.7.x to 2026.8.1 or later. Antenna does not own OpenClaw's database,
plugin, approvals, workspace, or Tailscale migrations and will not rewrite
those surfaces silently.

## 1. Freeze and back up

1. Stop the gateway and confirm no agent or Doctor process is writing state.
2. Back up the OpenClaw state directory, active workspaces, gateway config,
   service unit, Antenna runtime tree, and CLI link.
3. Copy the archive off-host and verify its checksum and critical members.
4. Record a pre-upgrade bidirectional Antenna unicast smoke test.

## 2. Install OpenClaw and compatible plugins

Install OpenClaw 2026.8.1 side-by-side where rollback can still invoke the old
binary. Install plugin releases compatible with that OpenClaw version before
validating the final config. Check `openclaw plugins list --json` and resolve
plugin errors explicitly.

Before any Doctor or Antenna command, prove the shell resolves the new CLI:

```bash
command -v openclaw
openclaw --version
openclaw gateway status --json
```

The CLI version and the gateway RPC version must both report the intended 8.1
release. A side-by-side user install may live in `~/.local/bin` while an older
system install still wins in non-interactive shells. Fix `PATH` for the whole
upgrade session (for example, `PATH="$HOME/.local/bin:$PATH"`) rather than
mixing old CLI commands with the new gateway.

Plugin schemas may retire settings independently. In the controlled upgrade,
lossless-claw 1.0.0 rejected `autoRotateSessionFiles`; that plugin-owned key
had to be reconciled before its new version would load. Do not have Antenna
delete arbitrary plugin configuration.

## 3. Let OpenClaw migrate its own state

With the gateway stopped and the old Antenna workspace still registered, run:

```bash
openclaw doctor --fix --non-interactive --yes
openclaw config validate
```

Review every proposed change. On the controlled host, OpenClaw owned these
changes:

- `agents.list` to `agents.entries` plus explicit ownership;
- removal of retired `meta.lastTouchedAt`,
  `gateway.controlUi.allowInsecureAuth`, and
  `gateway.tailscale.resetOnExit` keys;
- migration of relay `HEARTBEAT.md` into cron scratch and `TOOLS.md` into
  `AGENTS.md`;
- state and agent database schema migrations; and
- plugin registry and generated catalog migrations.

If `openclaw config validate` still fails, stop. Do not run `antenna upgrade`
against a config OpenClaw rejects.

## 4. Verify exec approvals

OpenClaw 8.1 stores exec approvals canonically in SQLite. If
`~/.openclaw/exec-approvals.json` remains, let Doctor migrate it or use the
OpenClaw approvals import procedure, compare the effective policy, and retain
the legacy file privately until rollback is no longer needed. Verify Antenna's
allowlist entries through the OpenClaw approvals CLI before starting traffic.

## 5. Hand Tailscale ingress to OpenClaw

Inspect `tailscale serve status --json` and `tailscale funnel status --json`.
A legacy Serve or Funnel route targeting the gateway port must not race the
8.1 gateway's managed ingress. Let OpenClaw Doctor migrate a safe legacy Serve
route; otherwise clear the old route deliberately, keep the gateway bound to
loopback, configure `gateway.tailscale.mode`, and let the restarted gateway
claim the route. Verify HTTPS after restart. Antenna never changes Tailscale
state itself.

## 6. If uninstalling Antenna 1.5.x instead

An operator who has already migrated OpenClaw to 2026.8.1 does not need to
upgrade Antenna merely to uninstall it. The Antenna v1.5.1 and v1.5.2
uninstallers already recognize OpenClaw 8.1's canonical `agents.entries`
roster. After OpenClaw Doctor and config validation have completed, preview
the removal against the explicit gateway config:

```bash
antenna uninstall --dry-run --gateway /path/to/openclaw.json
antenna uninstall --yes --gateway /path/to/openclaw.json
openclaw config validate
openclaw gateway restart
openclaw doctor --json
```

The v1.5.x uninstaller backs up the gateway config, removes the Antenna agent
and hook allowlist entries, removes its config, peer registry, logs,
rate-limit/test state, and Antenna-owned secrets, and removes an Antenna CLI
symlink that points into that installation. It leaves the skill source
directory unless `--purge-skill-dir` is requested.

Two exceptions require care:

- The v1.5.x uninstaller predates OpenClaw 8.1's `$include` roster-ownership
  safeguards. If `$include` owns `agents.entries`, do not let the old
  uninstaller edit only the top-level config: it may leave the active Antenna
  entry in the included source. Use `--keep-gateway-config` for runtime cleanup
  and remove the registration through OpenClaw's schema-aware configuration
  path, then validate the effective config.
- If a partial removal has already deleted `antenna-config.json`, the old
  `antenna` wrapper may refuse to dispatch `uninstall`. Invoke the script
  directly instead:

  ```bash
  bash /path/to/antenna-1.5.x/scripts/antenna-uninstall.sh \
    --yes --gateway /path/to/openclaw.json
  ```

## 7. Upgrade Antenna and qualify

Run the side-by-side Antenna upgrade only after the preceding checks pass:

```bash
antenna upgrade --from /path/to/old/antenna --gateway /path/to/openclaw.json
openclaw gateway restart
openclaw doctor --json
antenna doctor
```

Then test recipient-default and explicit named-session unicast, inbox
queue/approve/drain when enabled, Distribution Lists, Listed Public Groups,
model synchronization, restart persistence, HTTPS ingress, and rollback.
Reef friendship, Antenna peer/session access, and any transport fallback
remain separate trust grants.
