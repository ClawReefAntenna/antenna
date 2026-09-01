#!/usr/bin/env bash
# OC81 upgrade integration: side-by-side state migration against an 8.1 keyed roster.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

OLD="$TMP/old"
NEW="$TMP/new"
HOME_DIR="$TMP/home"
GATEWAY="$HOME_DIR/.openclaw/openclaw.json"
mkdir -p "$OLD/secrets" "$OLD/keys" "$OLD/state" "$OLD/agent/memory" "$OLD/bin" \
  "$NEW/scripts" "$NEW/lib" "$NEW/bin" "$NEW/agent" \
  "$HOME_DIR/.openclaw" "$HOME_DIR/.local/bin" "$HOME_DIR/bin"
cp "$ROOT/scripts/antenna-upgrade.sh" "$NEW/scripts/"
cp "$ROOT/lib/gateway-roster.sh" "$NEW/lib/"
cp "$ROOT/bin/antenna.sh" "$NEW/bin/"
printf '#!/usr/bin/env bash\n' > "$OLD/bin/antenna.sh"
chmod +x "$OLD/bin/antenna.sh" "$NEW/bin/antenna.sh" "$NEW/scripts/antenna-upgrade.sh"

jq -n --arg old "$OLD" '{install_path:$old,default_target_session:"agent:betty:main"}' \
  > "$OLD/antenna-config.json"
printf '%s\n' '{
  "self":{"self":true,"url":"https://self.example","token_file":"secrets/self.token"},
  "peer":{"url":"https://peer.example","token_file":"secrets/peer.token"}
}' > "$OLD/antenna-peers.json"
printf 'self-token\n' > "$OLD/secrets/self.token"
printf 'peer-token\n' > "$OLD/secrets/peer.token"
printf 'state\n' > "$OLD/state/keep"
printf 'memory\n' > "$OLD/agent/memory/keep"
chmod 600 "$OLD"/*.json "$OLD"/secrets/* "$OLD"/state/* "$OLD"/agent/memory/*

cat > "$GATEWAY" <<JSON
{
  "agents":{
    "ownership":"explicit",
    "defaults":{"systemAgent":{"agentId":"betty"},"heartbeat":{"agentId":"betty"}},
    "entries":{
      "betty":{"workspace":"/keep/betty","custom":"keep"},
      "antenna":{
        "agentDir":"$OLD/agent","workspace":"$OLD/agent","custom":"keep",
        "sandbox":{"mode":"off"},
        "tools":{"exec":{"mode":"allowlist"},"deny":["custom:deny"]}
      }
    }
  },
  "hooks":{"enabled":true,"token":"keep-token"},
  "bindings":[{"agentId":"betty","match":{"channel":"signal"}}],
  "unknownTop":{"keep":true}
}
JSON
chmod 640 "$GATEWAY"
ln -s "$OLD/bin/antenna.sh" "$HOME_DIR/.local/bin/antenna"
cat > "$HOME_DIR/bin/openclaw" <<'STUB'
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
chmod +x "$HOME_DIR/bin/openclaw"

before="$(find "$OLD" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
PATH="$HOME_DIR/bin:$PATH" HOME="$HOME_DIR" USER=fixture \
  bash "$NEW/scripts/antenna-upgrade.sh" --from "$OLD" --gateway "$GATEWAY" >/dev/null
after="$(find "$OLD" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

check "8.1 upgrade leaves source tree byte-identical" test "$before" = "$after"
check "8.1 upgrade rewrites destination install path" test \
  "$(jq -r .install_path "$NEW/antenna-config.json")" = "$NEW"
check "8.1 upgrade preserves entries-only roster" jq -e \
  '.agents.entries and (.agents|has("list")|not)' "$GATEWAY"
check "8.1 upgrade changes only keyed Antenna paths" jq -e --arg path "$NEW/agent" \
  '.agents.entries.antenna.agentDir==$path
   and .agents.entries.antenna.workspace==$path
   and .agents.entries.betty.workspace=="/keep/betty"' "$GATEWAY"
check "8.1 upgrade preserves ownership, defaults, policy, and unknown fields" jq -e \
  '.agents.ownership=="explicit"
   and .agents.defaults.systemAgent.agentId=="betty"
   and .agents.defaults.heartbeat.agentId=="betty"
   and .agents.entries.antenna.tools.exec.mode=="allowlist"
   and .agents.entries.antenna.tools.deny==["custom:deny"]
   and .agents.entries.antenna.custom=="keep"
   and .bindings[0].agentId=="betty"
   and .unknownTop.keep==true' "$GATEWAY"
check "8.1 upgrade preserves gateway mode" test "$(stat -c %a "$GATEWAY")" = 640
check "8.1 upgrade leaves private rollback backup" bash -c \
  'files=("$1".antenna-upgrade-backup-*); [[ -f "${files[0]}" && "$(stat -c %a "${files[0]}")" == 600 ]]' \
  _ "$GATEWAY"
check "8.1 upgrade repoints existing CLI link" test \
  "$(readlink -f "$HOME_DIR/.local/bin/antenna")" = "$NEW/bin/antenna.sh"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
