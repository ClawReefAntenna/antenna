#!/usr/bin/env bash
# ANT-165-005 regression: reports are private summaries by default; redacted
# provider payload capture requires an explicit diagnostic flag.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165005.XXXXXX")"
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
mkdir -p "$SKILL/scripts" "$SKILL/lib" "$TMP/bin"
cp "$ROOT/scripts/antenna-test-suite.sh" "$SKILL/scripts/"
cp "$ROOT/lib/peers.sh" "$ROOT/lib/config.sh" "$ROOT/lib/antenna-signature.sh" "$SKILL/lib/"

cat >"$SKILL/antenna-config.json" <<'JSON'
{"local_agent_id":"REAL-AGENT-SENTINEL"}
JSON
cat >"$SKILL/antenna-peers.json" <<'JSON'
{"REAL-HOST-SENTINEL":{"self":true,"url":"https://private.example"}}
JSON

cat >"$TMP/bin/curl" <<'FAKECURL'
#!/usr/bin/env bash
set -euo pipefail
body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="${2:-}"; shift 2 ;;
    -X|-H|-w|--max-time) shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "${ANT165005_STDERR:-}" ]]; then
  grep -q '^WARNING: raw provider diagnostic capture is enabled\.$' "$ANT165005_STDERR"
  printf 'warning-observed-before-call\n' >"$ANT165005_CALL_MARKER"
fi

user_message="$(jq -r '.messages[] | select(.role == "user") | .content' <<<"$body")"
allowed_path="$(jq -r '.tools[0].function.parameters.properties.path.enum[0]' <<<"$body")"
arguments="$(jq -cn --arg path "$allowed_path" --arg content "$user_message" '{path:$path,content:$content}')"
if [[ "${ANT165005_FORCE_FAILURE:-false}" == "true" ]]; then
  jq -cn --arg secret "$OPENAI_API_KEY" --arg host "$(hostname)" \
    '{error:{message:("rejected " + $secret + " on " + $host)}}'
  printf '\n__HTTP_CODE__401'
  exit 0
fi
jq -cn \
  --arg arguments "$arguments" \
  --arg secret "$OPENAI_API_KEY" \
  --arg host "$(hostname)" \
  '{
    choices:[{message:{tool_calls:[{id:"call_test",function:{name:"write",arguments:$arguments}}]},finish_reason:"tool_calls"}],
    api_key:$secret,
    nested:{authorization:("Bearer " + $secret),token:$secret},
    diagnostic:("provider echoed " + $secret + " from " + $host + " for REAL-HOST-SENTINEL")
  }'
printf '\n__HTTP_CODE__200'
FAKECURL
chmod +x "$TMP/bin/curl" "$SKILL/scripts/antenna-test-suite.sh"

run_suite() {
  PATH="$TMP/bin:$PATH" OPENAI_API_KEY="TRANSPORT-SECRET-SENTINEL" \
    ANT165005_STDERR="${ANT165005_STDERR:-}" \
    ANT165005_CALL_MARKER="${ANT165005_CALL_MARKER:-}" \
    ANT165005_FORCE_FAILURE="${ANT165005_FORCE_FAILURE:-false}" \
    bash "$SKILL/scripts/antenna-test-suite.sh" --tier B \
      --model openai/synthetic-model "$@"
}

DEFAULT_ROOT="$TMP/default-reports"
if run_suite --report "$DEFAULT_ROOT" >"$TMP/default.stdout" 2>"$TMP/default.stderr"; then
  pass "ordinary report run succeeds"
else
  fail "ordinary report run succeeds"
fi
DEFAULT_RUN="$(find "$DEFAULT_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
check "ordinary report creates one timestamped run" test -n "$DEFAULT_RUN"
check "ordinary report metadata says raw data was not captured" \
  jq -e '.raw_provider_data == false and .raw_payload_state == "not-captured"' "$DEFAULT_RUN/report-metadata.json" >/dev/null
check "ordinary report has no provider model directory" test ! -e "$DEFAULT_RUN/models"
check "ordinary report has no request dump" \
  bash -c '! find "$1" -type f -name "*request*" | grep -q .' _ "$DEFAULT_RUN"
check "ordinary report has no response dump" \
  bash -c '! find "$1" -type f -name "*response*" | grep -q .' _ "$DEFAULT_RUN"
check "ordinary report contains no provider payload sentinel" \
  bash -c '! grep -R -Fq -- "TRANSPORT-SECRET-SENTINEL" "$1"' _ "$DEFAULT_RUN"
check "ordinary report emits no raw-capture warning" \
  bash -c '! grep -q "raw provider diagnostic capture is enabled" "$1"' _ "$TMP/default.stderr"

if find "$DEFAULT_ROOT" -type d -printf '%m\n' | grep -qv '^700$'; then
  fail "ordinary report directories are mode 0700"
else
  pass "ordinary report directories are mode 0700"
fi
if find "$DEFAULT_ROOT" -type f -printf '%m\n' | grep -qv '^600$'; then
  fail "ordinary report files are mode 0600"
else
  pass "ordinary report files are mode 0600"
fi

FAILURE_ROOT="$TMP/failure-reports"
if ANT165005_FORCE_FAILURE=true run_suite --report "$FAILURE_ROOT" \
  >"$TMP/failure.stdout" 2>"$TMP/failure.stderr"; then
  fail "provider failure returns non-zero"
else
  pass "provider failure returns non-zero"
fi
FAILURE_RUN="$(find "$FAILURE_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
check "failure summary contains no transport credential" \
  bash -c '! grep -R -Fq -- "TRANSPORT-SECRET-SENTINEL" "$1"' _ "$FAILURE_RUN"
check "failure summary contains no local hostname" \
  bash -c '! grep -R -Fq -- "$2" "$1"' _ "$FAILURE_RUN" "$(hostname)"
check "failure summary retains a redaction marker" \
  grep -Fq '[REDACTED]' "$FAILURE_RUN/summary.json"

RAW_ROOT="$TMP/raw-reports"
: >"$TMP/raw.stderr"
if ANT165005_STDERR="$TMP/raw.stderr" ANT165005_CALL_MARKER="$TMP/raw.call-marker" \
  run_suite --report "$RAW_ROOT" --capture-raw-provider-data \
    >"$TMP/raw.stdout" 2>"$TMP/raw.stderr"; then
  pass "explicit raw diagnostic report run succeeds"
else
  fail "explicit raw diagnostic report run succeeds"
  sed 's/TRANSPORT-SECRET-SENTINEL/[REDACTED]/g' "$TMP/raw.stderr"
fi
RAW_RUN="$(find "$RAW_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
RAW_MODEL_DIR="$RAW_RUN/models/openai_synthetic-model"
RAW_REQUEST="$RAW_MODEL_DIR/tier-b-request.redacted.json"
RAW_RESPONSE="$RAW_MODEL_DIR/tier-b-response.redacted.json"

check "raw capture warning names sensitivity" \
  grep -q 'Provider-generated text can still contain sensitive context' "$TMP/raw.stderr"
check "raw capture warning documents operator-managed retention" \
  grep -q 'Retention is operator-managed' "$TMP/raw.stderr"
check "raw capture warning precedes provider call" \
  grep -q '^warning-observed-before-call$' "$TMP/raw.call-marker"
check "raw report metadata marks redacted diagnostic capture" \
  jq -e '.raw_provider_data == true and .raw_payload_state == "redacted-diagnostic-capture" and .retention == "operator-managed"' "$RAW_RUN/report-metadata.json" >/dev/null
check "redacted raw request is present" test -s "$RAW_REQUEST"
check "redacted raw response is present" test -s "$RAW_RESPONSE"
check "response secret-shaped keys are redacted" \
  jq -e '.api_key == "[REDACTED]" and .nested.authorization == "[REDACTED]" and .nested.token == "[REDACTED]"' "$RAW_RESPONSE" >/dev/null
check "raw report contains no transport credential" \
  bash -c '! grep -R -Fq -- "TRANSPORT-SECRET-SENTINEL" "$1"' _ "$RAW_RUN"
check "raw report contains no local hostname" \
  bash -c '! grep -R -Fq -- "$2" "$1"' _ "$RAW_RUN" "$(hostname)"
check "raw report contains no configured self peer" \
  bash -c '! grep -R -Fq -- "REAL-HOST-SENTINEL" "$1"' _ "$RAW_RUN"
check "raw report records redaction markers" grep -Fq '[REDACTED]' "$RAW_RESPONSE"

if find "$RAW_ROOT" -type d -printf '%m\n' | grep -qv '^700$'; then
  fail "raw report directories are mode 0700"
else
  pass "raw report directories are mode 0700"
fi
if find "$RAW_ROOT" -type f -printf '%m\n' | grep -qv '^600$'; then
  fail "raw report files are mode 0600"
else
  pass "raw report files are mode 0600"
fi

if run_suite --capture-raw-provider-data >"$TMP/no-report.stdout" 2>"$TMP/no-report.stderr"; then
  fail "raw capture without report is refused"
else
  pass "raw capture without report is refused"
fi
check "missing report refusal explains requirement" \
  grep -q -- '--capture-raw-provider-data requires --report' "$TMP/no-report.stderr"

rm -rf -- "$RAW_RUN"
check "documented run-directory cleanup removes captured diagnostics" test ! -e "$RAW_RUN"

check "README documents raw-report retention and cleanup" \
  grep -q 'reports persist until you remove their timestamped run directory' "$ROOT/README.md"
check "skill help advertises the explicit capture flag" \
  bash -c '"$1" --help | grep -q -- "--capture-raw-provider-data"' _ "$SKILL/scripts/antenna-test-suite.sh"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
