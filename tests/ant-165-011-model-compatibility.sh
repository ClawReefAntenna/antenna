#!/usr/bin/env bash
# ANT-165-011 regression: the model utility checks one bounded Antenna tool
# contract, compares providers, emits compact JSON, and persists nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165011.XXXXXX")"
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

mkdir -p "$TMP/bin" "$TMP/captures" "$TMP/run"

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
printf '%s\n' "$body" >"$ANT165011_CAPTURE_DIR/${provider}.json"

if grep -q 'text-only' <<<"$body"; then
  printf '%s\n' '{"choices":[{"message":{"content":"plain text"},"finish_reason":"stop"}]}'
  printf '\n__ANTENNA_HTTP__200'
  exit 0
fi

case "$provider" in
  openai)
    content="$(jq -r '.messages[] | select(.role=="user") | .content' <<<"$body")"
    path="$(jq -r '.tools[0].function.parameters.properties.path.enum[0]' <<<"$body")"
    arguments="$(jq -cn --arg path "$path" --arg content "$content" '{path:$path,content:$content}')"
    jq -cn --arg arguments "$arguments" \
      '{choices:[{message:{tool_calls:[{function:{name:"write",arguments:$arguments}}]},finish_reason:"tool_calls"}]}'
    ;;
  anthropic)
    content="$(jq -r '.messages[0].content' <<<"$body")"
    path="$(jq -r '.tools[0].input_schema.properties.path.enum[0]' <<<"$body")"
    jq -cn --arg path "$path" --arg content "$content" \
      '{content:[{type:"tool_use",name:"write",input:{path:$path,content:$content}}],stop_reason:"tool_use"}'
    ;;
  google)
    content="$(jq -r '.contents[0].parts[0].text' <<<"$body")"
    path="$(jq -r '.tools[0].functionDeclarations[0].parameters.properties.path.enum[0]' <<<"$body")"
    jq -cn --arg path "$path" --arg content "$content" \
      '{candidates:[{content:{parts:[{functionCall:{name:"write",args:{path:$path,content:$content}}}]},finishReason:"STOP"}]}'
    ;;
esac
printf '\n__ANTENNA_HTTP__200'
FAKECURL
chmod +x "$TMP/bin/curl"

run_checker() {
  ANT165011_CAPTURE_DIR="$TMP/captures" \
  OPENAI_API_KEY=test-openai ANTHROPIC_API_KEY=test-anthropic \
  GOOGLE_API_KEY=test-google PATH="$TMP/bin:$PATH" \
    bash "$ROOT/scripts/antenna-test-suite.sh" "$@"
}

if (cd "$TMP/run" && run_checker \
    --models "openai/synthetic,anthropic/synthetic,google/synthetic") \
    >"$TMP/compare.out" 2>"$TMP/compare.err"; then
  pass "three-provider comparison succeeds"
else
  fail "three-provider comparison succeeds"
fi
for model in openai/synthetic anthropic/synthetic google/synthetic; do
  check "comparison includes $model" grep -Fq "$model" "$TMP/compare.out"
done
check "comparison gives three compatible verdicts" \
  test "$(grep -c 'compatible' "$TMP/compare.out")" -eq 3
check "comparison includes latency" grep -Eq '[0-9]+ms' "$TMP/compare.out"
check "provider notice is concise" \
  test "$(grep -c 'with synthetic data only' "$TMP/compare.err")" -eq 3

for provider in openai anthropic google; do
  check "$provider request captured" test -s "$TMP/captures/$provider.json"
done
check "OpenAI advertises one write tool" \
  jq -e '[.tools[].function.name] == ["write"]' "$TMP/captures/openai.json" >/dev/null
check "Anthropic advertises one write tool" \
  jq -e '[.tools[].name] == ["write"]' "$TMP/captures/anthropic.json" >/dev/null
check "Google advertises one write tool" \
  jq -e '[.tools[].functionDeclarations[].name] == ["write"]' "$TMP/captures/google.json" >/dev/null

all_payloads="$TMP/all-payloads"
cat "$TMP/captures/openai.json" "$TMP/captures/anthropic.json" \
  "$TMP/captures/google.json" >"$all_payloads"
check "requests use the synthetic envelope" grep -Fq 'synthetic-peer' "$all_payloads"
check "requests contain no administrative tools" \
  bash -c '! grep -Eq '\''"name"[[:space:]]*:[[:space:]]*"(exec|sessions_send)"'\'' "$1"' _ "$all_payloads"
check "requests contain no transport credentials" \
  bash -c '! grep -Fq "test-openai" "$1" && ! grep -Fq "test-anthropic" "$1" && ! grep -Fq "test-google" "$1"' _ "$all_payloads"

if (cd "$TMP/run" && run_checker \
    --models "openai/synthetic,anthropic/synthetic,google/synthetic" \
    --format json) >"$TMP/results.json" 2>"$TMP/json.err"; then
  pass "JSON comparison succeeds"
else
  fail "JSON comparison succeeds"
fi
check "JSON has compact result summary" \
  jq -e '.summary == {total:3,compatible:3,incompatible:0,errors:0} and (.results|length)==3 and all(.results[]; has("model") and has("verdict") and has("latency_ms") and has("reason"))' "$TMP/results.json" >/dev/null

if (cd "$TMP/run" && run_checker --model openai/text-only) \
    >"$TMP/failure.out" 2>"$TMP/failure.err"; then
  fail "non-tool response is incompatible"
else
  pass "non-tool response is incompatible"
fi
check "incompatible result explains failure" \
  grep -Fq 'expected one write call' "$TMP/failure.out"

if ANT165011_CAPTURE_DIR="$TMP/captures" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/scripts/antenna-test-suite.sh" --model openai/synthetic \
    >"$TMP/missing.out" 2>"$TMP/missing.err"; then
  fail "missing credential returns non-zero"
else
  pass "missing credential returns non-zero"
fi
check "missing credential is clear" grep -Fq 'missing API credential' "$TMP/missing.out"

if run_checker --model unknown/synthetic >"$TMP/unsupported.out" 2>"$TMP/unsupported.err"; then
  fail "unsupported provider returns non-zero"
else
  pass "unsupported provider returns non-zero"
fi
check "unsupported provider is clear" grep -Fq 'unsupported provider' "$TMP/unsupported.out"

check "checker persists no files" \
  bash -c '[[ -z "$(find "$1" -mindepth 1 -print -quit)" ]]' _ "$TMP/run"
check "removed report and tier options stay absent" \
  bash -c '! rg -n -- "--report|capture-raw|--tier|--verbose|markdown|run_tier_a|write_report|redact_" "$1" >/dev/null' _ "$ROOT/scripts/antenna-test-suite.sh"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
