#!/usr/bin/env bash
# OC81 upgrade boundary: OpenClaw-owned 8.1 migrations fail closed before Antenna mutation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

make_case() {
  local name="$1"
  local root="$TMP/$1"
  local old="$root/old" new="$root/new" home="$root/home"
  mkdir -p "$old/agent" "$old/bin" "$new/scripts" "$new/lib/relay-policy/agent" "$new/bin" "$new/agent" \
    "$home/.openclaw" "$home/bin"
  cp "$ROOT/scripts/antenna-upgrade.sh" "$new/scripts/"
  cp "$ROOT/lib/gateway-roster.sh" "$new/lib/"
  cp "$ROOT/lib/relay-policy.sh" "$new/lib/"
  cp "$ROOT/lib/v163-staging-cleanup.sh" "$new/lib/"
  cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$new/lib/relay-policy/agent/"
  cp "$ROOT/lib/relay-policy/manifest.sha256" "$new/lib/relay-policy/"
  cp "$ROOT/bin/antenna.sh" "$new/bin/"
  cp "$ROOT/agent/AGENTS.md" "$new/agent/"
  chmod +x "$new/scripts/antenna-upgrade.sh" "$new/bin/antenna.sh"
  printf '#!/usr/bin/env bash\n' > "$old/bin/antenna.sh"
  jq -n --arg old "$old" '{install_path:$old}' > "$old/antenna-config.json"
  printf '%s\n' '{"self":{"self":true,"url":"https://self.example"}}' > "$old/antenna-peers.json"
  cat > "$home/.openclaw/openclaw.json" <<JSON
{
  "agents": {
    "ownership": "explicit",
    "entries": {
      "main": {"workspace": "$home/workspace"},
      "antenna": {"agentDir": "$old/agent", "workspace": "$old/agent"}
    }
  }
}
JSON
  cat > "$home/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "OpenClaw 2026.8.1 (fixture)"
elif [[ "${1:-}" == "config" && "${2:-}" == "validate" ]]; then
  jq empty "${OPENCLAW_CONFIG_PATH:?}"
else
  exit 2
fi
STUB
  chmod +x "$home/bin/openclaw"
}

expect_refusal() {
  local name="$1" expected="$2"
  local root="$TMP/$name"
  local old="$root/old" new="$root/new" home="$root/home"
  local gateway="$home/.openclaw/openclaw.json"
  local before output rc
  before="$(sha256sum "$gateway" | awk '{print $1}')"
  set +e
  output="$(PATH="$home/bin:$PATH" HOME="$home" USER=fixture \
    bash "$new/scripts/antenna-upgrade.sh" --from "$old" --gateway "$gateway" 2>&1)"
  rc=$?
  set -e
  check "$name refuses before mutation" test "$rc" -ne 0
  check "$name explains the boundary" grep -Fq "$expected" <<<"$output"
  check "$name preserves gateway bytes" test \
    "$before" = "$(sha256sum "$gateway" | awk '{print $1}')"
  check "$name installs no runtime state" test ! -e "$new/antenna-config.json"
}

make_case retired-config
jq '.meta.lastTouchedAt="retired" | .gateway.controlUi.allowInsecureAuth=true
    | .gateway.tailscale.resetOnExit=false' \
  "$TMP/retired-config/home/.openclaw/openclaw.json" > "$TMP/retired-config/gateway.next"
mv "$TMP/retired-config/gateway.next" "$TMP/retired-config/home/.openclaw/openclaw.json"
expect_refusal retired-config "OpenClaw 8.1 config migration is incomplete"

make_case retired-plugin-setting
jq '.plugins.entries["lossless-claw"].config.autoRotateSessionFiles=true' \
  "$TMP/retired-plugin-setting/home/.openclaw/openclaw.json" > "$TMP/retired-plugin-setting/gateway.next"
mv "$TMP/retired-plugin-setting/gateway.next" \
  "$TMP/retired-plugin-setting/home/.openclaw/openclaw.json"
expect_refusal retired-plugin-setting "retired autoRotateSessionFiles"

make_case legacy-approvals
printf '{"version":1}\n' > "$TMP/legacy-approvals/home/.openclaw/exec-approvals.json"
expect_refusal legacy-approvals "Legacy exec approvals remain"

make_case legacy-heartbeat
printf 'Check Antenna inbox.\n' > "$TMP/legacy-heartbeat/old/agent/HEARTBEAT.md"
expect_refusal legacy-heartbeat "migrated into cron scratch"

check "relay tool contract is consolidated into AGENTS.md" grep -Fq "## Tools" "$ROOT/agent/AGENTS.md"
check "package no longer ships relay TOOLS.md" test ! -e "$ROOT/agent/TOOLS.md"
check "runbook assigns plugin lifecycle to OpenClaw" grep -Fq \
  "Install OpenClaw and compatible plugins" "$ROOT/references/OPENCLAW-2026.8.1-UPGRADE.md"
check "runbook requires CLI and gateway version agreement" grep -Fq \
  "CLI version and the gateway RPC version" "$ROOT/references/OPENCLAW-2026.8.1-UPGRADE.md"
check "runbook assigns approvals migration to OpenClaw" grep -Fq \
  "Verify exec approvals" "$ROOT/references/OPENCLAW-2026.8.1-UPGRADE.md"
check "runbook assigns Tailscale ingress to OpenClaw" grep -Fq \
  "Hand Tailscale ingress to OpenClaw" "$ROOT/references/OPENCLAW-2026.8.1-UPGRADE.md"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
