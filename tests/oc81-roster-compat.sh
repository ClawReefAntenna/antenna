#!/usr/bin/env bash
# OC81 / ANT-162 regression: cross-version roster preservation and refusal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version)
    echo "OpenClaw ${OC_FIXTURE_VERSION:-2026.8.1} (fixture)"
    ;;
  config)
    [[ "${2:-}" == "validate" ]]
    [[ "${OC_VALIDATE_FAIL:-0}" != "1" ]]
    jq empty "${OPENCLAW_CONFIG_PATH:?}"
    ;;
  agents)
    [[ "${2:-}" == "list" && "${3:-}" == "--json" ]]
    config_path="${OPENCLAW_CONFIG_PATH:?}"
    include_path="$(jq -r '."$include" // empty' "$config_path")"
    if [[ -n "$include_path" ]]; then
      config_path="$(dirname "$config_path")/$include_path"
    fi
    jq '
      if (.agents.entries | type) == "object" then
        [.agents.entries | to_entries[] | {id:.key} + .value]
      else
        [.agents.list[]?]
      end
    ' "$config_path"
    ;;
  approvals) exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/openclaw"
export PATH="$TMP/bin:$PATH"

# shellcheck source=../lib/gateway-roster.sh
source "$ROOT/lib/gateway-roster.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

write_json() {
  local destination="$1" content="$2"
  printf '%s\n' "$content" > "$destination"
}

LIST="$TMP/list.json"
write_json "$LIST" '{
  "agents":{"defaults":{"workspace":"/keep/default","model":{"primary":"fixture/default"}},"list":[
    {"id":"betty","workspace":"/keep/betty","custom":{"future":true}}
  ]},
  "hooks":{"token":"keep-token"},
  "bindings":[{"agentId":"betty","match":{"channel":"signal"}}],
  "unknownTop":{"keep":1}
}'
OC_FIXTURE_VERSION=2026.7.1
export OC_FIXTURE_VERSION
LIST_OUT="$TMP/list-out.json"
gateway_roster_write_setup_candidate "$LIST" "$LIST_OUT" betty fixture/relay /opt/antenna/agent /state
check "7.1 setup preserves list and never creates entries" jq -e \
  '.agents.list and (.agents | has("entries") | not)' "$LIST_OUT"
check "7.1 setup preserves unrelated agent and unknown fields" jq -e \
  '(.agents.list[] | select(.id=="betty") | .custom.future)==true and .unknownTop.keep==1' "$LIST_OUT"
check "7.1 setup adds one least-privilege Antenna entry" jq -e \
  '[.agents.list[] | select(.id=="antenna" and .sandbox.mode=="off" and .workspace=="/opt/antenna/agent" and .agentDir=="/state/agents/antenna/agent")] | length==1' "$LIST_OUT"

ENTRIES="$TMP/entries.json"
write_json "$ENTRIES" '{
  "agents":{"entries":{"ops":{"workspace":"/keep/ops","tools":{"exec":{"mode":"allowlist"}},"custom":"keep"}}},
  "hooks":{"token":"keep-token"},
  "bindings":[{"agentId":"ops","match":{"channel":"telegram"}}]
}'
OC_FIXTURE_VERSION=2026.8.1
export OC_FIXTURE_VERSION
ENTRIES_OUT="$TMP/entries-out.json"
gateway_roster_write_setup_candidate "$ENTRIES" "$ENTRIES_OUT" ops fixture/relay /opt/antenna/agent /state
check "8.1 setup preserves entries and never creates list" jq -e \
  '.agents.entries and (.agents | has("list") | not)' "$ENTRIES_OUT"
check "sole keyed owner transition becomes explicit" jq -e \
  '.agents.ownership=="explicit" and .agents.defaults.systemAgent.agentId=="ops"' "$ENTRIES_OUT"
check "sole non-main keyed owner keeps inherited-auth ownership" jq -e \
  '.agents.defaults.authInheritance.agentId=="ops"' "$ENTRIES_OUT"
check "keyed entry body is preserved and Antenna stores no id field" jq -e \
  '.agents.entries.ops.custom=="keep"
   and .agents.entries.ops.tools.exec.mode=="allowlist"
   and (.agents.entries.antenna | has("id") | not)' "$ENTRIES_OUT"

RERUN="$TMP/rerun.json"
write_json "$RERUN" '{
  "agents":{
    "ownership":"explicit",
    "defaults":{"systemAgent":{"agentId":"betty"},"heartbeat":{"agentId":"betty"}},
    "entries":{
      "betty":{"workspace":"/keep/betty"},
      "antenna":{
        "workspace":"/old","agentDir":"/old","custom":"keep",
        "sandbox":{"mode":"all","docker":{"image":"keep"}},
        "tools":{"exec":{"mode":"deny"},"deny":["custom:one"],"skills":["keep"]}
      }
    }
  },
  "bindings":[{"agentId":"betty","match":{"channel":"signal"}}]
}'
RERUN_OUT="$TMP/rerun-out.json"
gateway_roster_write_setup_candidate "$RERUN" "$RERUN_OUT" betty fixture/relay /opt/antenna/agent /state
check "8.1 rerun preserves ownership, defaults, bindings, and custom fields" jq -e \
  '.agents.ownership=="explicit"
   and .agents.defaults.systemAgent.agentId=="betty"
   and .agents.defaults.heartbeat.agentId=="betty"
   and .bindings[0].agentId=="betty"
   and .agents.entries.antenna.custom=="keep"
   and .agents.entries.antenna.workspace=="/opt/antenna/agent"
   and .agents.entries.antenna.agentDir=="/state/agents/antenna/agent"' "$RERUN_OUT"
check "8.1 rerun preserves exec, deny, skills, and sandbox extensions" jq -e \
  '.agents.entries.antenna.tools.exec.mode=="deny"
   and .agents.entries.antenna.tools.deny==["custom:one"]
   and .agents.entries.antenna.tools.skills==["keep"]
   and .agents.entries.antenna.sandbox.docker.image=="keep"
   and .agents.entries.antenna.sandbox.mode=="off"' "$RERUN_OUT"

ABSENT="$TMP/absent.json"
write_json "$ABSENT" '{"agents":{"defaults":{"workspace":"/default","model":{"primary":"fixture/default"}}},"gateway":{"port":18789}}'
OC_FIXTURE_VERSION=2026.7.1
export OC_FIXTURE_VERSION
ABSENT_LIST="$TMP/absent-list.json"
gateway_roster_write_setup_candidate "$ABSENT" "$ABSENT_LIST" betty fixture/relay /opt/antenna/agent /state
check "absent 7.1 roster creates native list" jq -e \
  '.agents.list|length==2' "$ABSENT_LIST"
OC_FIXTURE_VERSION=2026.8.1
export OC_FIXTURE_VERSION
ABSENT_ENTRIES="$TMP/absent-entries.json"
gateway_roster_write_setup_candidate "$ABSENT" "$ABSENT_ENTRIES" betty fixture/relay /opt/antenna/agent /state
check "absent 8.1 roster creates native entries with explicit system owner" jq -e \
  '.agents.ownership=="explicit"
   and .agents.defaults.systemAgent.agentId=="betty"
   and (.agents.entries|keys|sort)==["antenna","betty"]' "$ABSENT_ENTRIES"

EMPTY_ENTRIES="$TMP/empty-entries.json"
write_json "$EMPTY_ENTRIES" '{"agents":{"entries":{}},"gateway":{"port":18789}}'
EMPTY_ENTRIES_OUT="$TMP/empty-entries-out.json"
gateway_roster_write_setup_candidate \
  "$EMPTY_ENTRIES" "$EMPTY_ENTRIES_OUT" betty fixture/relay /opt/antenna/agent /state
check "empty 8.1 entries roster creates primary and Antenna agents" jq -e \
  '.agents.ownership=="explicit"
   and .agents.defaults.systemAgent.agentId=="betty"
   and (.agents.entries|keys|sort)==["antenna","betty"]' "$EMPTY_ENTRIES_OUT"

OC_FIXTURE_VERSION=2026.7.1
export OC_FIXTURE_VERSION
LIST_PATHS="$TMP/list-paths.json"
gateway_roster_write_agent_paths_candidate "$LIST_OUT" "$LIST_PATHS" /new/agent /new-state
check "7.1 upgrade changes only Antenna paths" jq -e \
  '(.agents.list[]|select(.id=="antenna")|.agentDir)=="/new-state/agents/antenna/agent"
   and (.agents.list[]|select(.id=="antenna")|.workspace)=="/new/agent"
   and (.agents.list[]|select(.id=="betty")|.workspace)=="/keep/betty"
   and .unknownTop.keep==1' "$LIST_PATHS"
LIST_MODEL="$TMP/list-model.json"
gateway_roster_write_model_candidate "$LIST_PATHS" "$LIST_MODEL" fixture/new
check "7.1 model sync preserves unrelated list data" jq -e \
  '(.agents.list[]|select(.id=="antenna")|.model)=="fixture/new"
   and (.agents.list[]|select(.id=="betty")|.custom.future)==true' "$LIST_MODEL"

OC_FIXTURE_VERSION=2026.8.1
export OC_FIXTURE_VERSION
ENTRIES_PATHS="$TMP/entries-paths.json"
gateway_roster_write_agent_paths_candidate "$RERUN_OUT" "$ENTRIES_PATHS" /new/agent /new-state
check "8.1 upgrade changes only keyed Antenna paths" jq -e \
  '.agents.entries.antenna.agentDir=="/new-state/agents/antenna/agent"
   and .agents.entries.antenna.workspace=="/new/agent"
   and .agents.entries.betty.workspace=="/keep/betty"
   and .agents.defaults.systemAgent.agentId=="betty"' "$ENTRIES_PATHS"
ENTRIES_MODEL="$TMP/entries-model.json"
gateway_roster_write_model_candidate "$ENTRIES_PATHS" "$ENTRIES_MODEL" fixture/new
check "8.1 model sync preserves keyed policy" jq -e \
  '.agents.entries.antenna.model=="fixture/new"
   and .agents.entries.antenna.tools.exec.mode=="deny"
   and .agents.ownership=="explicit"' "$ENTRIES_MODEL"

expect_refusal() {
  local label="$1" fixture="$2" version="$3" needle="$4"
  local output="$TMP/refusal.out"
  OC_FIXTURE_VERSION="$version"
  export OC_FIXTURE_VERSION
  if gateway_roster_prepare_mutation "$fixture" >"$output" 2>&1; then
    fail "$label"
  elif grep -Fq "$needle" "$output"; then
    pass "$label"
  else
    fail "$label (wrong diagnostic)"
  fi
}

MIXED="$TMP/mixed.json"
write_json "$MIXED" '{"agents":{"list":[{"id":"main"}],"entries":{"main":{}}}}'
expect_refusal "mixed roster fails closed" "$MIXED" 2026.8.1 "both agents.list and agents.entries"
expect_refusal "legacy list on 8.1 requires Doctor migration" "$LIST" 2026.8.1 "openclaw doctor --fix"
expect_refusal "canonical entries on 7.1 fail closed" "$ENTRIES" 2026.7.1 "does not support canonical agents.entries"
INCLUDE="$TMP/include.json"
write_json "$INCLUDE" '{"$include":"./base.json","agents":{"entries":{"main":{}}}}'
expect_refusal "include-owned roster fails closed" "$INCLUDE" 2026.8.1 "owned by \$include"
DUPLICATE="$TMP/duplicate.json"
write_json "$DUPLICATE" '{"agents":{"entries":{"Main":{},"main":{}}}}'
expect_refusal "case-colliding agent IDs fail closed" "$DUPLICATE" 2026.8.1 "duplicate/invalid agent IDs"

COMMIT_SOURCE="$TMP/commit.json"
cp "$RERUN_OUT" "$COMMIT_SOURCE"
chmod 640 "$COMMIT_SOURCE"
COMMIT_CANDIDATE="$TMP/commit-candidate.json"
cp "$ENTRIES_MODEL" "$COMMIT_CANDIDATE"
before_hash="$(sha256sum "$COMMIT_SOURCE" | awk '{print $1}')"
OC_VALIDATE_FAIL=1
export OC_VALIDATE_FAIL
if gateway_config_commit_candidate "$COMMIT_SOURCE" "$COMMIT_CANDIDATE" test-backup >/dev/null 2>&1; then
  fail "OpenClaw validation failure blocks atomic commit"
else
  check "validation failure leaves original byte-identical" test \
    "$before_hash" = "$(sha256sum "$COMMIT_SOURCE" | awk '{print $1}')"
fi
unset OC_VALIDATE_FAIL
cp "$ENTRIES_MODEL" "$COMMIT_CANDIDATE"
gateway_config_commit_candidate "$COMMIT_SOURCE" "$COMMIT_CANDIDATE" test-backup
check "successful commit preserves gateway mode" test "$(stat -c %a "$COMMIT_SOURCE")" = 640
check "successful commit leaves a private rollback backup" test \
  "$(stat -c %a "$GATEWAY_CONFIG_LAST_BACKUP")" = 600

DOCTOR_HOME="$TMP/doctor-home"
mkdir -p "$DOCTOR_HOME"
doctor_output="$(HOME="$DOCTOR_HOME" USER=fixture OC_FIXTURE_VERSION=2026.8.1 \
  bash "$ROOT/scripts/antenna-doctor.sh" --gateway "$RERUN_OUT" 2>&1 || true)"
if grep -Fq 'Antenna agent is registered in gateway config' <<<"$doctor_output"; then
  pass "Doctor recognizes canonical 8.1 Antenna entry"
else
  fail "Doctor recognizes canonical 8.1 Antenna entry"
fi

INCLUDE_BASE="$TMP/include-base.json"
INCLUDE_ROOT="$TMP/include-root.json"
cp "$RERUN_OUT" "$INCLUDE_BASE"
write_json "$INCLUDE_ROOT" '{"$include":"include-base.json"}'
include_doctor_output="$(HOME="$DOCTOR_HOME" USER=fixture OC_FIXTURE_VERSION=2026.8.1 \
  bash "$ROOT/scripts/antenna-doctor.sh" --gateway "$INCLUDE_ROOT" 2>&1 || true)"
if grep -Fq 'Antenna agent is registered in gateway config' <<<"$include_doctor_output"; then
  pass "Doctor resolves an include-owned roster read-only"
else
  fail "Doctor resolves an include-owned roster read-only"
fi

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
