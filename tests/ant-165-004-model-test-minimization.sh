#!/usr/bin/env bash
# ANT-165-004 regression: external model probes use only synthetic data and a
# single probe-scoped write schema across OpenAI, Anthropic, and Google wires.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165004.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

SKILL="$TMP/skill"
CAPTURE="$TMP/captures"
mkdir -p "$SKILL/scripts" "$SKILL/lib" "$SKILL/agent" "$TMP/bin" "$CAPTURE"
cp "$ROOT/scripts/antenna-test-suite.sh" "$SKILL/scripts/"
cp "$ROOT/lib/peers.sh" "$ROOT/lib/config.sh" "$ROOT/lib/antenna-signature.sh" "$SKILL/lib/"

cat >"$SKILL/antenna-config.json" <<'JSON'
{
  "allowed_inbound_sessions": ["agent:REAL-SESSION-SENTINEL:private"],
  "default_target_session": "agent:REAL-DEFAULT-SENTINEL:main",
  "local_agent_id": "REAL-AGENT-SENTINEL"
}
JSON
cat >"$SKILL/antenna-peers.json" <<'JSON'
{
  "REAL-HOST-SENTINEL": {
    "self": true,
    "url": "https://real-host-sentinel.example"
  }
}
JSON
cat >"$SKILL/agent/AGENTS.md" <<'EOF'
# REAL-POLICY-SENTINEL

This complete local policy must never be sent to an external model test.
EOF

cat >"$TMP/bin/curl" <<'FAKECURL'
#!/usr/bin/env bash
set -euo pipefail
body=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="${2:-}"; shift 2 ;;
    -X|-H|-w|--max-time) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  *api.anthropic.com*) provider=anthropic ;;
  *generativelanguage.googleapis.com*) provider=google ;;
  *) provider=openai ;;
esac

# Prove the disclosure preview was emitted before the network boundary.
grep -q '^Model-test disclosure preflight:' "$ANT165004_STDERR"
grep -q "provider: ${provider}" "$ANT165004_STDERR"
grep -q '^  outbound data classes:' "$ANT165004_STDERR"

printf '%s\n' "$body" >"$ANT165004_CAPTURE_DIR/${provider}.json"

case "$provider" in
  openai)
    user_message="$(jq -r '.messages[] | select(.role == "user") | .content' <<<"$body")"
    allowed_path="$(jq -r '.tools[0].function.parameters.properties.path.enum[0]' <<<"$body")"
    arguments="$(jq -cn --arg path "$allowed_path" --arg content "$user_message" '{path:$path, content:$content}')"
    jq -cn --arg arguments "$arguments" '{choices:[{message:{tool_calls:[{id:"call_test",function:{name:"write",arguments:$arguments}}]},finish_reason:"tool_calls"}]}'
    ;;
  anthropic)
    user_message="$(jq -r '.messages[0].content' <<<"$body")"
    allowed_path="$(jq -r '.tools[0].input_schema.properties.path.enum[0]' <<<"$body")"
    jq -cn --arg path "$allowed_path" --arg content "$user_message" '{content:[{type:"tool_use",id:"toolu_test",name:"write",input:{path:$path,content:$content}}],stop_reason:"tool_use"}'
    ;;
  google)
    user_message="$(jq -r '.contents[0].parts[0].text' <<<"$body")"
    allowed_path="$(jq -r '.tools[0].functionDeclarations[0].parameters.properties.path.enum[0]' <<<"$body")"
    jq -cn --arg path "$allowed_path" --arg content "$user_message" '{candidates:[{content:{parts:[{functionCall:{name:"write",args:{path:$path,content:$content}}}]}}]}'
    ;;
esac
printf '\n__HTTP_CODE__200'
FAKECURL
chmod +x "$TMP/bin/curl" "$SKILL/scripts/antenna-test-suite.sh"

run_provider() {
  local provider="$1" model="$2" key_name="$3"
  local stdout="$TMP/${provider}.stdout" stderr="$TMP/${provider}.stderr"
  : >"$stderr"
  ANT165004_STDERR="$stderr" ANT165004_CAPTURE_DIR="$CAPTURE" \
    PATH="$TMP/bin:$PATH" env "$key_name=transport-secret-${provider}" \
    bash "$SKILL/scripts/antenna-test-suite.sh" --tier B --model "$model" \
    >"$stdout" 2>"$stderr"
}

check "OpenAI provider contract passes" run_provider openai openai/synthetic-model OPENAI_API_KEY
check "Anthropic provider contract passes" run_provider anthropic anthropic/synthetic-model ANTHROPIC_API_KEY
check "Google provider contract passes" run_provider google google/synthetic-model GOOGLE_API_KEY

for provider in openai anthropic google; do
  payload="$CAPTURE/${provider}.json"
  stderr="$TMP/${provider}.stderr"
  check "$provider request was captured" test -s "$payload"
  check "$provider preview names outbound classes" grep -q '^  outbound data classes: selected model ID; minimal synthetic relay policy; synthetic envelope; one probe-scoped write schema$' "$stderr"
  check "$provider preview names excluded local classes" grep -q '^  excluded local data: agent/AGENTS.md; host and peer names; configured sessions; runtime messages; local files; credentials in request content$' "$stderr"
done

check "OpenAI advertises only the write tool" \
  jq -e '[.tools[].function.name] == ["write"]' "$CAPTURE/openai.json" >/dev/null
check "Anthropic advertises only the write tool" \
  jq -e '[.tools[].name] == ["write"]' "$CAPTURE/anthropic.json" >/dev/null
check "Google advertises only the write tool" \
  jq -e '[.tools[].functionDeclarations[].name] == ["write"]' "$CAPTURE/google.json" >/dev/null

check "OpenAI write path is probe-scoped in schema" \
  jq -e '.tools[0].function.parameters.properties.path.enum[0] | test("^/tmp/antenna-relay/msg-test-[0-9a-f]{24}\\.txt$")' "$CAPTURE/openai.json" >/dev/null
check "Anthropic write path is probe-scoped in schema" \
  jq -e '.tools[0].input_schema.properties.path.enum[0] | test("^/tmp/antenna-relay/msg-test-[0-9a-f]{24}\\.txt$")' "$CAPTURE/anthropic.json" >/dev/null
check "Google write path is probe-scoped in schema" \
  jq -e '.tools[0].functionDeclarations[0].parameters.properties.path.enum[0] | test("^/tmp/antenna-relay/msg-test-[0-9a-f]{24}\\.txt$")' "$CAPTURE/google.json" >/dev/null

all_payloads="$TMP/all-provider-payloads.txt"
cat "$CAPTURE/openai.json" "$CAPTURE/anthropic.json" "$CAPTURE/google.json" >"$all_payloads"
for forbidden in \
  REAL-POLICY-SENTINEL REAL-HOST-SENTINEL REAL-SESSION-SENTINEL \
  REAL-DEFAULT-SENTINEL REAL-AGENT-SENTINEL \
  sessions_send '"name":"exec"' '"name": "exec"' \
  "$SKILL" "$(hostname)" transport-secret-openai transport-secret-anthropic transport-secret-google
do
  if grep -Fq -- "$forbidden" "$all_payloads"; then
    fail "provider payloads exclude $forbidden"
  else
    pass "provider payloads exclude $forbidden"
  fi
done

check "all provider payloads carry the synthetic peer" \
  test "$(grep -Foc 'synthetic-peer' "$all_payloads")" -eq 3
check "all provider payloads carry the synthetic session" \
  test "$(grep -Foc 'agent:synthetic:main' "$all_payloads")" -eq 3
check "source no longer reads the complete relay policy" \
  bash -c '! rg -n "AGENT_INSTRUCTIONS|cat .*AGENTS\\.md" "$1" >/dev/null' _ "$SKILL/scripts/antenna-test-suite.sh"
check "source no longer defines administrative test tools" \
  bash -c '! rg -n "TOOLS_(JSON|ANTHROPIC|GOOGLE)|name.*(exec|sessions_send)" "$1" >/dev/null' _ "$SKILL/scripts/antenna-test-suite.sh"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
