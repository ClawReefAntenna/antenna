#!/usr/bin/env bash
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d /tmp/antenna-dl001.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
expect() { local name="$1"; shift; "$@" && ok "$name" || no "$name"; }

SKILL="$ROOT/skill"
mkdir -p "$SKILL/scripts" "$SKILL/lib" "$SKILL/secrets" "$SKILL/bin"
cp "$REPO/scripts/antenna-list-send.sh" "$SKILL/scripts/"
cp "$REPO/lib/peers.sh" "$SKILL/lib/"
cp "$REPO/lib/antenna-signature.sh" "$SKILL/lib/"
cp "$REPO/lib/config.sh" "$SKILL/lib/"
cp "$REPO/bin/antenna.sh" "$SKILL/bin/"
cat >"$SKILL/antenna-peers.json" <<'JSON'
{
  "self":{"url":"https://self.example","self":true,"peer_secret_file":"secrets/self.secret"},
  "alpha":{"url":"https://alpha.example","token_file":"secrets/alpha.token","auth_mode":"plaintext-legacy"},
  "beta":{"url":"https://beta.example","token_file":"secrets/beta.token","auth_mode":"plaintext-legacy"},
  "gamma":{"url":"https://gamma.example","token_file":"secrets/gamma.token","auth_mode":"plaintext-legacy"}
}
JSON
cat >"$SKILL/antenna-config.json" <<'JSON'
{"allowed_outbound_peers":["alpha","beta","gamma"]}
JSON
cat >"$SKILL/scripts/antenna-send.sh" <<'STUB'
#!/usr/bin/env bash
peer="$1"; shift
body=""
for arg in "$@"; do [[ "$arg" == "--stdin" ]] && body=$(base64 -w0); done
jq -cn --arg peer "$peer" --arg args "$(printf '%q ' "$@")" --arg body "$body" \
  '{peer:$peer,args:$args,body_b64:$body}' >>"$CALL_LOG"
if [[ "$peer" == "beta" && "${FAIL_BETA:-false}" == true ]]; then
  echo 'beta warning' >&2
  echo '{"error":"beta failed"}'
  exit 5
fi
echo "{\"delivered\":\"$peer\"}"
STUB
chmod +x "$SKILL/scripts/"*.sh
printf '%064d\n' 0 >"$SKILL/secrets/self.secret"
for peer in alpha beta gamma; do printf token >"$SKILL/secrets/$peer.token"; done
chmod 600 "$SKILL/secrets/"*
export CALL_LOG="$ROOT/calls.jsonl"
RUN=(bash "$SKILL/scripts/antenna-list-send.sh")

write_list() { printf '%s\n' "$1" >"$SKILL/antenna-lists.json"; : >"$CALL_LOG"; }
call_count() { [[ ! -s "$CALL_LOG" ]] && echo 0 || wc -l <"$CALL_LOG"; }

write_list '{"team":["gamma","alpha","beta","alpha"]}'
OUT=$(${RUN[@]} @team --subject notice --user Corey --reply-to https://reply.example --session agent:x:main --dry-run hello 2>"$ROOT/err"); RC=$?
expect "sorted and deduplicated members" test "$(jq -sr '[.[].peer] | join(",")' "$CALL_LOG")" = alpha,beta,gamma
expect "success aggregate contract" jq -e '.alias=="@team" and .total==3 and .succeeded==3 and .failed==0 and [.results[].peer]==["alpha","beta","gamma"] and all(.results[];.exit_code==0)' <<<"$OUT" >/dev/null
expect "all supported flags forwarded" jq -e 'all(.[];.args|contains("--subject notice") and contains("--user Corey") and contains("--reply-to https://reply.example") and contains("--session agent:x:main") and contains("--dry-run") and contains("hello"))' "$CALL_LOG" --slurp >/dev/null
expect "all-success exit zero" test "$RC" -eq 0
write_list '{"team":["alpha"]}'
OUT=$(bash "$SKILL/bin/antenna.sh" send @team hello 2>"$ROOT/err"); RC=$?
expect "CLI dispatches @alias to list wrapper" jq -e '.alias=="@team" and .total==1 and .failed==0' <<<"$OUT" >/dev/null
expect "CLI dispatch returns success" test "$RC" -eq 0

write_list '{"team":["gamma","alpha","beta"]}'
export FAIL_BETA=true
OUT=$(${RUN[@]} @team hello 2>"$ROOT/err"); RC=$?
unset FAIL_BETA
expect "partial failure attempts every member once" test "$(call_count)" -eq 3
expect "partial failure aggregate" jq -e '.total==3 and .succeeded==2 and .failed==1 and (.results[]|select(.peer=="beta")|.exit_code)==5 and (.results[]|select(.peer=="beta")|.sender.error)=="beta failed"' <<<"$OUT" >/dev/null
expect "partial failure returns nonzero" test "$RC" -ne 0
expect "sender warning remains on stderr" grep -q 'beta warning' "$ROOT/err"

write_list '{"team":["beta","alpha"]}'
printf 'first\nsecond\n\n' >"$ROOT/body"
OUT=$(${RUN[@]} @team --subject exact --stdin <"$ROOT/body" 2>"$ROOT/err"); RC=$?
EXPECTED=$(base64 -w0 "$ROOT/body")
expect "stdin sent once to every member" test "$(call_count)" -eq 2
expect "stdin exact bytes replayed" jq -e --arg body "$EXPECTED" 'all(.[];.body_b64==$body)' "$CALL_LOG" --slurp >/dev/null
expect "stdin aggregate success" test "$RC" -eq 0

assert_invalid_before_send() {
  local name="$1" json="$2" alias="${3:-@team}"
  write_list "$json"
  ${RUN[@]} "$alias" hello >"$ROOT/out" 2>"$ROOT/err"
  local rc=$?
  [[ $rc -ne 0 && $(call_count) -eq 0 ]] && ok "$name" || no "$name"
}
assert_invalid_before_send "self rejected before send" '{"team":["alpha","self"]}'
assert_invalid_before_send "nested alias rejected before send" '{"team":["@other"]}'
assert_invalid_before_send "unknown peer rejected before send" '{"team":["alpha","missing"]}'
write_list '{"team":["alpha","beta"]}'
rm "$SKILL/secrets/beta.token"
${RUN[@]} @team hello >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "later unconfigured member rejects before send" test "$RC" -ne 0
expect "later unconfigured member performs no send" test "$(call_count)" -eq 0
printf token >"$SKILL/secrets/beta.token"; chmod 600 "$SKILL/secrets/beta.token"
write_list '{"team":["alpha","beta"]}'
jq '.beta.url="main"' "$SKILL/antenna-peers.json" >"$ROOT/peers" && mv "$ROOT/peers" "$SKILL/antenna-peers.json"
${RUN[@]} @team hello >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "invalid member URL rejects before send" test "$RC" -ne 0
expect "invalid member URL performs no send" test "$(call_count)" -eq 0
jq '.beta.url="https://beta.example"' "$SKILL/antenna-peers.json" >"$ROOT/peers" && mv "$ROOT/peers" "$SKILL/antenna-peers.json"
write_list '{"team":["alpha","beta"]}'
jq '.allowed_outbound_peers=["alpha"]' "$SKILL/antenna-config.json" >"$ROOT/config" && mv "$ROOT/config" "$SKILL/antenna-config.json"
${RUN[@]} @team hello >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "disallowed rejected before send" test "$RC" -ne 0
expect "disallowed performs no send" test "$(call_count)" -eq 0
printf '%s\n' '{"allowed_outbound_peers":["alpha","beta","gamma"]}' >"$SKILL/antenna-config.json"
assert_invalid_before_send "empty list rejected" '{"team":[]}'
assert_invalid_before_send "malformed list file rejected" '{"team":"alpha"}'
assert_invalid_before_send "invalid alias rejected" '{"Bad":["alpha"]}' @Bad
BIG=$(jq -cn '{team:[range(0;101)|"alpha"]}')
assert_invalid_before_send "oversized list rejected" "$BIG"
write_list '{"team":["alpha"]}'
mv "$SKILL/antenna-lists.json" "$ROOT/list-real.json" && ln -s "$ROOT/list-real.json" "$SKILL/antenna-lists.json"
${RUN[@]} @team hello >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "symlinked list file rejected" test "$RC" -ne 0
expect "symlinked list performs no send" test "$(call_count)" -eq 0
rm "$SKILL/antenna-lists.json"; mv "$ROOT/list-real.json" "$SKILL/antenna-lists.json"
write_list '{"team":["alpha"]}'
chmod 644 "$SKILL/secrets/self.secret"
${RUN[@]} @team hello >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "unsafe self credential rejected before send" test "$RC" -ne 0
expect "unsafe self credential performs no send" test "$(call_count)" -eq 0

printf 'RESULT: pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
