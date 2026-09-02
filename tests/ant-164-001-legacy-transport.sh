#!/usr/bin/env bash
# ANT-164-001 regression: the corrective release must send through the
# v1.5.x-v1.6.2 /hooks/agent transport and its established payload shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d /tmp/antenna-ant164-legacy-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '      %s\n' "$2"
}

check() {
  local label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

printf '%s\n' '── ANT-164-001 legacy transport regression ──'

SKILL="$TMP/skill"
mkdir -p "$SKILL/scripts" "$SKILL/lib" "$SKILL/secrets" "$TMP/bin"
cp "$ROOT/scripts/antenna-send.sh" "$SKILL/scripts/"
cp "$ROOT/scripts/antenna-relay.sh" "$SKILL/scripts/"
cp -R "$ROOT/lib/." "$SKILL/lib/"

cat >"$SKILL/antenna-config.json" <<'JSON'
{
  "max_message_length": 10000,
  "log_enabled": false,
  "allowed_outbound_peers": ["receiver"],
  "allowed_inbound_peers": ["sender"],
  "allowed_inbound_sessions": ["agent:betty:main"],
  "default_target_session": "agent:betty:main"
}
JSON

cat >"$SKILL/antenna-peers.json" <<'JSON'
{
  "sender": {
    "url": "https://sender.example.test",
    "self": true,
    "peer_secret_file": "secrets/peer_secret_sender",
    "auth_mode": "plaintext-legacy"
  },
  "receiver": {
    "url": "https://receiver.example.test",
    "token_file": "secrets/hooks_token_receiver",
    "agentId": "antenna",
    "auth_mode": "plaintext-legacy"
  }
}
JSON

printf '%064d\n' 0 >"$SKILL/secrets/peer_secret_sender"
printf '%s\n' 'receiver-hook-token' >"$SKILL/secrets/hooks_token_receiver"
chmod 0600 "$SKILL/secrets/peer_secret_sender" "$SKILL/secrets/hooks_token_receiver"

cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$ANT164_CURL_ARGS"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-d" ]]; then
    printf '%s' "$2" >"$ANT164_CURL_PAYLOAD"
    break
  fi
  shift
done
printf '{"runId":"legacy-contract"}\n__HTTP_CODE__200\n'
SH
chmod 0700 "$TMP/bin/curl"

export ANT164_CURL_ARGS="$TMP/curl.args"
export ANT164_CURL_PAYLOAD="$TMP/curl.payload.json"

set +e
SEND_OUTPUT="$(
  PATH="$TMP/bin:$PATH" \
    "$SKILL/scripts/antenna-send.sh" receiver \
      --session agent:betty:main \
      $'compatibility probe — café 🦞\nsecond line' 2>"$TMP/send.stderr"
)"
SEND_RC=$?
set -e

check 'send completes against the simulated legacy receiver' test "$SEND_RC" -eq 0

if grep -Fxq 'https://receiver.example.test/hooks/agent' "$ANT164_CURL_ARGS"; then
  pass 'outbound URL uses /hooks/agent'
else
  ACTUAL_URL="$(grep -E '^https?://' "$ANT164_CURL_ARGS" | tail -n 1 || true)"
  fail 'outbound URL uses /hooks/agent' "actual=${ACTUAL_URL:-missing}"
fi

if jq -e '
  .agentId == "antenna" and
  .sessionKey == "hook:antenna" and
  .name == "Antenna/sender" and
  (.message | type == "string")
' "$ANT164_CURL_PAYLOAD" >/dev/null; then
  pass 'payload preserves message, agentId, sessionKey, and name'
else
  fail 'payload preserves message, agentId, sessionKey, and name' \
    "payload=$(jq -c . "$ANT164_CURL_PAYLOAD" 2>/dev/null || printf unreadable)"
fi

if jq -r '.message' "$ANT164_CURL_PAYLOAD" \
  | grep -Fxq 'reply_to: https://sender.example.test/hooks/agent'; then
  pass 'envelope reply URL uses /hooks/agent'
else
  ACTUAL_REPLY="$(jq -r '.message' "$ANT164_CURL_PAYLOAD" 2>/dev/null \
    | grep '^reply_to:' || true)"
  fail 'envelope reply URL uses /hooks/agent' "actual=${ACTUAL_REPLY:-missing}"
fi

jq -r '.message' "$ANT164_CURL_PAYLOAD" >"$TMP/decoded-envelope"
if [[ "$(head -n 1 "$TMP/decoded-envelope")" == '[ANTENNA_RELAY]' ]] \
  && [[ "$(tail -n 1 "$TMP/decoded-envelope")" == '[/ANTENNA_RELAY]' ]]; then
  pass 'payload still contains the complete Antenna envelope'
else
  fail 'payload still contains the complete Antenna envelope'
fi

# A v1.6.2 receiver consumed this same envelope grammar from /hooks/agent.
# Feed the decoded request into the corrective receiver to prove the reverse
# mixed-version direction without any endpoint mapping or transform.
INBOUND_RESULT="$(
  cd "$SKILL"
  bash scripts/antenna-relay.sh --stdin <"$TMP/decoded-envelope"
)"
if jq -e '
  .status == "ok" and
  .from == "sender" and
  .sessionKey == "agent:betty:main" and
  (.message | contains("compatibility probe — café 🦞\nsecond line"))
' <<<"$INBOUND_RESULT" >/dev/null; then
  pass 'corrective receiver accepts the established legacy envelope byte-for-byte'
else
  fail 'corrective receiver accepts the established legacy envelope byte-for-byte' \
    "result=$(jq -c . <<<"$INBOUND_RESULT" 2>/dev/null || printf unreadable)"
fi

printf '\n── Summary ──\n'
printf '  Passed: %d\n' "$PASS"
printf '  Failed: %d\n' "$FAIL"

[[ "$FAIL" -eq 0 ]]
