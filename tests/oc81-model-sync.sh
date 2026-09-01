#!/usr/bin/env bash
# OC81 CLI model-sync integration for both OpenClaw roster generations.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

run_case() {
  local name="$1" version="$2" gateway_json="$3" query="$4"
  local case_dir="$TMP/$name"
  local skill="$case_dir/skill" home="$case_dir/home"
  mkdir -p "$skill/bin" "$skill/lib" "$skill/scripts" "$home/.openclaw" "$home/bin"
  cp "$ROOT/bin/antenna.sh" "$skill/bin/"
  cp "$ROOT/lib/config.sh" "$ROOT/lib/peers.sh" "$ROOT/lib/antenna-signature.sh" \
    "$ROOT/lib/gateway-roster.sh" "$skill/lib/"
  printf '%s\n' '{"relay_agent_model":"fixture/old","log_enabled":false}' > "$skill/antenna-config.json"
  printf '{}\n' > "$skill/antenna-peers.json"
  printf '%s\n' "$gateway_json" > "$home/.openclaw/openclaw.json"
  chmod 640 "$home/.openclaw/openclaw.json"
  cat > "$home/bin/openclaw" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" ]]; then
  echo "OpenClaw $version (fixture)"
elif [[ "\${1:-}" == "config" && "\${2:-}" == "validate" ]]; then
  jq empty "\${OPENCLAW_CONFIG_PATH:?}"
else
  exit 2
fi
STUB
  chmod +x "$home/bin/openclaw" "$skill/bin/antenna.sh"
  PATH="$home/bin:$PATH" HOME="$home" USER=fixture \
    bash "$skill/bin/antenna.sh" model set fixture/new --no-restart >/dev/null
  check "$name model sync writes the native roster" jq -e "$query" "$home/.openclaw/openclaw.json"
  check "$name model sync preserves gateway mode" test \
    "$(stat -c %a "$home/.openclaw/openclaw.json")" = 640
  check "$name model sync leaves private rollback backup" bash -c \
    'files=("$1".antenna-model-backup.*); [[ -f "${files[0]}" && "$(stat -c %a "${files[0]}")" == 600 ]]' \
    _ "$home/.openclaw/openclaw.json"
}

run_case list-7.1 2026.7.1 '{
  "agents":{"list":[
    {"id":"betty","workspace":"/keep","custom":"keep"},
    {"id":"antenna","model":"fixture/old","tools":{"exec":{"mode":"allowlist"}}}
  ]},"unknownTop":{"keep":true}
}' '(.agents.list[]|select(.id=="antenna")|.model)=="fixture/new"
    and (.agents.list[]|select(.id=="betty")|.custom)=="keep"
    and (.agents|has("entries")|not)
    and .unknownTop.keep==true'

run_case entries-8.1 2026.8.1 '{
  "agents":{"ownership":"explicit","defaults":{"systemAgent":{"agentId":"betty"}},"entries":{
    "betty":{"workspace":"/keep","custom":"keep"},
    "antenna":{"model":"fixture/old","tools":{"exec":{"mode":"allowlist"}}}
  }},"unknownTop":{"keep":true}
}' '.agents.entries.antenna.model=="fixture/new"
    and .agents.entries.antenna.tools.exec.mode=="allowlist"
    and .agents.entries.betty.custom=="keep"
    and .agents.ownership=="explicit"
    and (.agents|has("list")|not)
    and .unknownTop.keep==true'

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
