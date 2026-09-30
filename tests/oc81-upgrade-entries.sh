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
  "$NEW/scripts" "$NEW/lib/relay-policy/agent" "$NEW/bin" "$NEW/agent" "$NEW/hooks" \
  "$HOME_DIR/.openclaw" "$HOME_DIR/.local/bin" "$HOME_DIR/bin"
cp "$ROOT/scripts/antenna-upgrade.sh" "$NEW/scripts/"
cp "$ROOT/lib/session_policy.py" "$ROOT/lib/gateway-roster.sh" "$ROOT/lib/cli-link.sh" "$ROOT/lib/secret-file.sh" \
  "$ROOT/lib/change-plan.sh" "$NEW/lib/"
cp "$ROOT/lib/relay-policy.sh" "$NEW/lib/"
cp "$ROOT/lib/v163-staging-cleanup.sh" "$NEW/lib/"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$NEW/lib/relay-policy/agent/"
cp "$ROOT/lib/relay-policy/manifest.txt" "$NEW/lib/relay-policy/"
cp "$ROOT/agent/AGENTS.md" "$NEW/agent/"
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
  "hooks":{
    "enabled":true,
    "allowRequestSessionKey":true,
    "allowedAgentIds":["antenna"],
    "allowedSessionKeyPrefixes":["hook:"],
    "token":"keep-token",
    "mappings":[{
      "id":"antenna-deterministic-staging",
      "match":{"path":"antenna"},
      "action":"agent",
      "agentId":"antenna",
      "wakeMode":"now",
      "name":"Antenna",
      "sessionKey":"hook:antenna",
      "deliver":false,
      "allowUnsafeExternalContent":false,
      "transform":{"module":"antenna-stage.mjs","export":"default"}
    }]
  },
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

python3 - "$OLD" <<'PYFIX'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]);f=root/'antenna-config.json';c=json.loads(f.read_text())
k='agent:betty:main';entry={'entry_id':'22222222-2222-4222-8222-222222222222','alias_revision':1,'alias':'ideas','inbox':True}
c.update(allowed_inbound_sessions=[k],session_policy_version=1,session_policies={k:entry},inbox_mode='allowlist',inbox_enabled=True,inbox_queue_path='review/inbox.json')
f.write_text(json.dumps(c));(root/'review').mkdir()
item={'ref':1,'from':'peer','status':'pending','session_key':k,'target_session':k,'full_message':'fixture','binding':{'canonical_key':k,'reference_kind':'alias','original_reference':'agent:betty:ideas','resolved_reference':'agent:betty:ideas','entry_id':entry['entry_id'],'alias_revision':1}}
(root/'review/inbox.json').write_text(json.dumps([item]))
PYFIX

before="$(find "$OLD" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
PATH="$HOME_DIR/bin:$PATH" HOME="$HOME_DIR" USER=fixture \
  bash "$NEW/scripts/antenna-upgrade.sh" --from "$OLD" --gateway "$GATEWAY" --yes >/dev/null
after="$(find "$OLD" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

check "8.1 upgrade leaves source tree byte-identical" test "$before" = "$after"
check "8.1 upgrade rewrites destination install path" test \
  "$(jq -r .install_path "$NEW/antenna-config.json")" = "$NEW"
check "upgrade preserves session metadata and selective mode" jq -e \
  '.session_policies["agent:betty:main"].alias=="ideas" and .inbox_mode=="allowlist" and .inbox_enabled==true' "$NEW/antenna-config.json"
check "upgrade preserves custom queue binding bytes" cmp "$OLD/review/inbox.json" "$NEW/review/inbox.json"
check "8.1 upgrade preserves entries-only roster" jq -e \
  '.agents.entries and (.agents|has("list")|not)' "$GATEWAY"
check "8.1 upgrade separates keyed Antenna workspace and state" jq -e --arg workspace "$NEW/agent" --arg state "$HOME_DIR/.openclaw/agents/antenna/agent" \
  '.agents.entries.antenna.agentDir==$state
   and .agents.entries.antenna.workspace==$workspace
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
check "8.1 upgrade removes v1.6.3 mapping and preserves hook prefix" jq -e '
  ((.hooks.mappings // [])|map(.id)|index("antenna-deterministic-staging"))==null
  and (.hooks.allowedSessionKeyPrefixes|index("hook:"))!=null' "$GATEWAY"
check "8.1 upgrade leaves no staging transform" test \
  ! -e "$HOME_DIR/.openclaw/hooks/transforms/antenna-stage.mjs"
check "8.1 destination has no retired relay workspace files" bash -c \
  '[[ ! -e "$1/agent/HEARTBEAT.md" && ! -e "$1/agent/TOOLS.md" ]]' _ "$NEW"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
