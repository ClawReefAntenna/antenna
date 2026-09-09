#!/usr/bin/env bash
# OC81 setup integration: real non-interactive setup against isolated 7.1/8.1
# gateway fixtures, including candidate-validation rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
# shellcheck source=../lib/v163-staging-cleanup.sh
source "$ROOT/lib/v163-staging-cleanup.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

make_case() {
  local name="$1" version="$2" gateway_json="$3"
  local case_dir="$TMP/$name"
  local skill="$case_dir/skill" home="$case_dir/home"
  mkdir -p "$skill/scripts" "$skill/lib/relay-policy/agent" "$skill/bin" "$skill/agent" \
    "$home/.openclaw" "$home/.local/bin" "$home/bin"
  cp "$ROOT/scripts/antenna-setup.sh" "$skill/scripts/"
  cp "$ROOT/lib/peers.sh" "$ROOT/lib/session-policy.py" "$ROOT/lib/gateway-roster.sh" "$ROOT/lib/relay-policy.sh" "$ROOT/lib/cli-link.sh" "$ROOT/lib/secret-file.sh" \
    "$ROOT/lib/change-plan.sh" \
    "$ROOT/lib/v163-staging-cleanup.sh" "$skill/lib/"
  cp "$ROOT/lib/relay-policy/manifest.txt" "$skill/lib/relay-policy/"
  cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$skill/lib/relay-policy/agent/"
  cp "$ROOT/agent/AGENTS.md" "$skill/agent/"
  cp "$ROOT/bin/antenna.sh" "$skill/bin/"
  printf '%s\n' "$gateway_json" > "$home/.openclaw/openclaw.json"
  printf 'fixture-token-012345678901234567890123456789\n' > "$home/hooks.token"
  chmod 600 "$home/.openclaw/openclaw.json" "$home/hooks.token"
  printf '%s\n' "$version" > "$case_dir/version"
  cat > "$home/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) echo "OpenClaw $(cat "${OC_CASE_DIR:?}/version") (fixture)" ;;
  config)
    [[ "${2:-}" == "validate" ]]
    jq empty "${OPENCLAW_CONFIG_PATH:?}"
    if [[ "${OC_REJECT_ANTENNA:-0}" == "1" ]] \
       && jq -e '((.agents.entries.antenna? | type)=="object") or any(.agents.list[]?; .id=="antenna")' \
          "$OPENCLAW_CONFIG_PATH" >/dev/null; then
      exit 1
    fi
    ;;
  approvals) exit 0 ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$home/bin/openclaw" "$skill/scripts/antenna-setup.sh" "$skill/bin/antenna.sh"
  printf '%s\t%s\t%s\n' "$case_dir" "$skill" "$home"
}

run_setup() {
  local case_dir="$1" skill="$2" home="$3"
  PATH="$home/bin:$home/.local/bin:$PATH" HOME="$home" USER=fixture OC_CASE_DIR="$case_dir" \
    bash "$skill/scripts/antenna-setup.sh" \
      --host-id fixture --display-name Fixture \
      --url https://fixture.example.com --agent-id betty \
      --model fixture/relay --token-file "$home/hooks.token" --inbox false --yes
}

IFS=$'\t' read -r list_case list_skill list_home < <(
  make_case list 2026.7.1 '{
    "agents":{"list":[{"id":"betty","workspace":"/keep/betty","custom":"keep"}]},
    "hooks":{"token":"fixture-token-012345678901234567890123456789"},
    "unknownTop":{"keep":true}
  }'
)
run_setup "$list_case" "$list_skill" "$list_home" >/dev/null
list_gateway="$list_home/.openclaw/openclaw.json"
check "real 7.1 setup keeps list-only roster" jq -e \
  '.agents.list and (.agents|has("entries")|not)' "$list_gateway"
check "real 7.1 setup preserves unrelated config and adds Antenna once" jq -e \
  '.unknownTop.keep==true
   and (.agents.list[]|select(.id=="betty")|.custom)=="keep"
   and ([.agents.list[]|select(.id=="antenna")]|length)==1' "$list_gateway"
check "real 7.1 setup commits hooks and session policy together" jq -e \
  '.hooks.enabled==true
   and .hooks.allowRequestSessionKey==true
   and (.hooks.allowedAgentIds|index("antenna"))!=null
   and (.hooks.allowedSessionKeyPrefixes|index("hook:"))!=null
   and ((.hooks.mappings // [])|map(.id)|index("antenna-deterministic-staging"))==null
   and .tools.sessions.visibility=="all"
   and .tools.agentToAgent.enabled==true' "$list_gateway"
check "real 7.1 setup separates relay workspace from agent state" jq -e --arg workspace "$list_skill/agent" --arg state "$list_home/.openclaw/agents/antenna/agent" \
  '(.agents.list[]|select(.id=="antenna")|.workspace)==$workspace
   and (.agents.list[]|select(.id=="antenna")|.agentDir)==$state' "$list_gateway"
check "real 7.1 setup installs no staging transform" test \
  ! -e "$list_home/.openclaw/hooks/transforms/antenna-stage.mjs"

IFS=$'\t' read -r entries_case entries_skill entries_home < <(
  make_case entries 2026.8.1 '{
    "agents":{"entries":{"betty":{"workspace":"/keep/betty","custom":"keep"}}},
    "hooks":{"token":"fixture-token-012345678901234567890123456789"},
    "bindings":[{"agentId":"betty","match":{"channel":"signal"}}]
  }'
)
run_setup "$entries_case" "$entries_skill" "$entries_home" >/dev/null
entries_gateway="$entries_home/.openclaw/openclaw.json"
check "real 8.1 setup keeps entries-only roster" jq -e \
  '.agents.entries and (.agents|has("list")|not)' "$entries_gateway"
check "real 8.1 setup materializes sole-owner transition" jq -e \
  '.agents.ownership=="explicit"
   and .agents.defaults.systemAgent.agentId=="betty"
   and .agents.entries.betty.custom=="keep"
   and (.agents.entries.antenna|has("id")|not)' "$entries_gateway"
check "real 8.1 setup preserves bindings and writes Antenna policy" jq -e \
  '.bindings[0].agentId=="betty"
   and .agents.entries.antenna.sandbox.mode=="off"
   and (.agents.entries.antenna.tools.deny|index("group:web"))!=null' "$entries_gateway"
check "real 8.1 setup separates relay workspace from agent state" jq -e --arg workspace "$entries_skill/agent" --arg state "$entries_home/.openclaw/agents/antenna/agent" \
  '.agents.entries.antenna.workspace==$workspace
   and .agents.entries.antenna.agentDir==$state' "$entries_gateway"
check "real 8.1 setup creates a private secrets directory" test \
  "$(stat -c %a "$entries_skill/secrets")" = 700
check "real 8.1 setup installs no staging transform" test \
  ! -e "$entries_home/.openclaw/hooks/transforms/antenna-stage.mjs"

IFS=$'\t' read -r cleanup_case cleanup_skill cleanup_home < <(
  make_case cleanup 2026.8.1 "{
    \"agents\":{\"ownership\":\"explicit\",\"defaults\":{\"systemAgent\":{\"agentId\":\"betty\"}},\"entries\":{\"betty\":{}}},
    \"hooks\":{\"token\":\"fixture-token-012345678901234567890123456789\",\"mappings\":[
      {\"id\":\"unrelated\",\"match\":{\"path\":\"other\"},\"action\":\"agent\"},
      $v163_staging_mapping_filter
    ]}
  }"
)
run_setup "$cleanup_case" "$cleanup_skill" "$cleanup_home" >/dev/null
cleanup_gateway="$cleanup_home/.openclaw/openclaw.json"
check "setup removes exact v1.6.3 mapping" jq -e \
  '([.hooks.mappings[]? | select(.id=="antenna-deterministic-staging")]|length)==0' \
  "$cleanup_gateway"
check "setup preserves unrelated hook mappings" jq -e \
  '([.hooks.mappings[]? | select(.id=="unrelated")]|length)==1' "$cleanup_gateway"

IFS=$'\t' read -r custom_case custom_skill custom_home < <(
  make_case custom-mapping 2026.8.1 "{
    \"agents\":{\"ownership\":\"explicit\",\"defaults\":{\"systemAgent\":{\"agentId\":\"betty\"}},\"entries\":{\"betty\":{}}},
    \"hooks\":{\"token\":\"fixture-token-012345678901234567890123456789\",\"mappings\":[
      $v163_staging_mapping_filter
    ]}
  }"
)
jq '.hooks.mappings[0].name="Operator customization"' \
  "$custom_home/.openclaw/openclaw.json" >"$custom_home/.openclaw/custom.json"
mv "$custom_home/.openclaw/custom.json" "$custom_home/.openclaw/openclaw.json"
custom_gateway="$custom_home/.openclaw/openclaw.json"
custom_before_hash="$(sha256sum "$custom_gateway" | awk '{print $1}')"
if run_setup "$custom_case" "$custom_skill" "$custom_home" >/dev/null 2>&1; then
  fail "setup refuses customized v1.6.3 mapping"
else
  pass "setup refuses customized v1.6.3 mapping"
fi
check "customized-mapping refusal leaves gateway byte-identical" test \
  "$custom_before_hash" = "$(sha256sum "$custom_gateway" | awk '{print $1}')"

IFS=$'\t' read -r reject_case reject_skill reject_home < <(
  make_case reject 2026.8.1 '{
    "agents":{"ownership":"explicit","defaults":{"systemAgent":{"agentId":"betty"}},"entries":{"betty":{}}},
    "gateway":{"port":18789},"sentinel":"unchanged"
  }'
)
reject_gateway="$reject_home/.openclaw/openclaw.json"
before_hash="$(sha256sum "$reject_gateway" | awk '{print $1}')"
if OC_REJECT_ANTENNA=1 run_setup "$reject_case" "$reject_skill" "$reject_home" >/dev/null 2>&1; then
  fail "candidate validation rejection makes setup fail"
else
  pass "candidate validation rejection makes setup fail"
fi
check "candidate validation rejection leaves gateway byte-identical" test \
  "$before_hash" = "$(sha256sum "$reject_gateway" | awk '{print $1}')"
check "candidate validation rejection creates no staging transform" test \
  ! -e "$reject_home/.openclaw/hooks/transforms/antenna-stage.mjs"
check "successful setup rollback backup is private" bash -c \
  'files=("$1".antenna-pre-register.*); [[ -f "${files[0]}" && "$(stat -c %a "${files[0]}")" == 600 ]]' \
  _ "$entries_gateway"

IFS=$'\t' read -r db_case db_skill db_home < <(
  make_case workspace-db 2026.8.1 '{
    "agents":{"ownership":"explicit","defaults":{"systemAgent":{"agentId":"betty"}},"entries":{"betty":{}}},
    "gateway":{"port":18789},"sentinel":"unchanged"
  }'
)
db_gateway="$db_home/.openclaw/openclaw.json"
printf 'foreign state\n' > "$db_skill/agent/openclaw-agent.sqlite"
db_before_hash="$(sha256sum "$db_gateway" | awk '{print $1}')"
if run_setup "$db_case" "$db_skill" "$db_home" >/dev/null 2>&1; then
  fail "setup refuses OpenClaw database inside relay workspace"
else
  pass "setup refuses OpenClaw database inside relay workspace"
fi
check "workspace-database refusal leaves gateway byte-identical" test \
  "$db_before_hash" = "$(sha256sum "$db_gateway" | awk '{print $1}')"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
