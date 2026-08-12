#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; ROOT=$(mktemp -d /tmp/antenna-dl002.XXXXXX)
trap 'rm -rf "$ROOT"' EXIT; PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }; no(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }; expect(){ n="$1"; shift; "$@" && ok "$n" || no "$n"; }
SKILL="$ROOT/skill"; mkdir -p "$SKILL"/{scripts,lib,secrets,bin}
cp "$REPO/scripts/antenna-list-send.sh" "$REPO/scripts/antenna-lists.sh" "$SKILL/scripts/"
cp "$REPO/lib/peers.sh" "$REPO/lib/config.sh" "$REPO/lib/antenna-signature.sh" "$REPO/lib/antenna-list-meta.py" "$SKILL/lib/"
cp "$REPO/bin/antenna.sh" "$SKILL/bin/"
cat >"$SKILL/antenna-peers.json" <<'JSON'
{"self":{"url":"https://self.example","self":true,"peer_secret_file":"secrets/self.secret"},"alpha":{"url":"https://alpha.example","token_file":"secrets/alpha.token","auth_mode":"plaintext-legacy"},"beta":{"url":"https://beta.example","token_file":"secrets/beta.token","auth_mode":"plaintext-legacy"},"gamma":{"url":"https://gamma.example","token_file":"secrets/gamma.token","auth_mode":"plaintext-legacy"}}
JSON
printf '%s\n' '{"allowed_outbound_peers":["alpha","beta","gamma"]}' >"$SKILL/antenna-config.json"
cat >"$SKILL/scripts/antenna-send.sh" <<'SH'
#!/usr/bin/env bash
peer="$1"; shift; body=""; for a in "$@"; do [[ "$a" == --stdin ]] && body=$(base64 -w0); done
jq -cn --arg peer "$peer" --arg args "$(printf '%q ' "$@")" --arg body "$body" '{peer:$peer,args:$args,body_b64:$body}' >>"$CALL_LOG"
echo "{\"delivered\":\"$peer\"}"
SH
chmod +x "$SKILL/scripts/"*.sh; printf '%064d\n' 0 >"$SKILL/secrets/self.secret"
for p in alpha beta gamma; do printf token >"$SKILL/secrets/$p.token"; done; chmod 600 "$SKILL/secrets/"*
export CALL_LOG="$ROOT/calls"; : >"$CALL_LOG"
printf '%s\n' '{"ops":{"display_name":"AGS Operations","peers":["gamma","alpha","alpha"]},"legacy":["beta"]}' >"$SKILL/antenna-lists.json"

OUT=$(bash "$SKILL/bin/antenna.sh" send @ops --show-recipients 'hello world' 2>"$ROOT/err"); RC=$?
expected='[ANTENNA_META v=1]
list: AGS Operations
recipients: alpha,gamma
[/ANTENNA_META]

hello world'
expect "visible send succeeds" test "$RC" -eq 0
expect "visible metadata and body exact" jq -e --arg b "$(printf %s "$expected"|base64 -w0)" 'all(.[];.body_b64==$b)' "$CALL_LOG" --slurp >/dev/null
expect "visible members sorted" test "$(jq -sr '[.[].peer]|join(",")' "$CALL_LOG")" = alpha,gamma
: >"$CALL_LOG"; bash "$SKILL/bin/antenna.sh" send @ops --show-recipients '' >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "empty positional visible body rejected" test "$RC" -ne 0
expect "empty positional visible body sends nothing" test ! -s "$CALL_LOG"
: >"$CALL_LOG"; bash "$SKILL/bin/antenna.sh" send @ops --show-recipients --stdin </dev/null >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "zero-byte stdin visible body rejected" test "$RC" -ne 0
expect "zero-byte stdin visible body sends nothing" test ! -s "$CALL_LOG"
for delimiter in '[ANTENNA_META v=1]' '[/ANTENNA_META]'; do
  : >"$CALL_LOG"
  bash "$SKILL/bin/antenna.sh" send @ops --show-recipients "before $delimiter after" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
  expect "reserved delimiter $delimiter rejected" test "$RC" -ne 0
  expect "reserved delimiter $delimiter sends nothing" test ! -s "$CALL_LOG"
done
: >"$CALL_LOG"; printf 'tail\n\n' >"$ROOT/body"
bash "$SKILL/bin/antenna.sh" send @legacy --show-recipients --stdin <"$ROOT/body" >"$ROOT/out" 2>"$ROOT/err"
expected_file="$ROOT/expected"; printf '[ANTENNA_META v=1]\nlist: legacy\nrecipients: beta\n[/ANTENNA_META]\n\n' >"$expected_file"; cat "$ROOT/body" >>"$expected_file"
expect "show-recipients preserves terminal body bytes" jq -e --arg b "$(base64 -w0 "$expected_file")" '.[0].body_b64==$b' "$CALL_LOG" --slurp >/dev/null
: >"$CALL_LOG"; bash "$SKILL/bin/antenna.sh" send @legacy plain >"$ROOT/out" 2>"$ROOT/err"
expect "default list send remains unprefixed" jq -e '.[0].body_b64=="" and (. [0].args|contains("plain"))' "$CALL_LOG" --slurp >/dev/null

printf '%s' "$expected" >"$ROOT/source"; : >"$CALL_LOG"
jq '.allowed_outbound_peers=["alpha","beta"]' "$SKILL/antenna-config.json" >"$ROOT/c" && mv "$ROOT/c" "$SKILL/antenna-config.json"
OUT=$(bash "$SKILL/bin/antenna.sh" reply-all beta --source "$ROOT/source" --subject reply 'new body' 2>"$ROOT/err"); RC=$?
expect "reply-all succeeds with usable union" test "$RC" -eq 0
expect "reply-all unions sender, excludes self, skips disallowed" test "$(jq -sr '[.[].peer]|join(",")' "$CALL_LOG")" = alpha,beta
expect "reply-all warns for skipped peer" grep -q "skipping peer 'gamma'" "$ROOT/err"
expect "reply-all sends new body without retained metadata" jq -e 'all(.[];.body_b64=="" and (.args|contains("new\\ body")))' "$CALL_LOG" --slurp >/dev/null

bad_before_send(){ name="$1" body="$2"; printf '%b' "$body" >"$ROOT/bad"; : >"$CALL_LOG"; bash "$SKILL/bin/antenna.sh" reply-all beta --source "$ROOT/bad" x >"$ROOT/out" 2>"$ROOT/err"; rc=$?; [[ $rc -ne 0 && ! -s "$CALL_LOG" ]] && ok "$name" || no "$name"; }
bad_before_send "missing metadata rejected" 'ordinary body'
bad_before_send "duplicate metadata rejected" "$expected\n$expected"
bad_before_send "noncanonical recipients rejected" '[ANTENNA_META v=1]\nlist: Ops\nrecipients: gamma,alpha\n[/ANTENNA_META]\n\nx'
python3 - <<'PY' >"$ROOT/big"
print('[ANTENNA_META v=1]\nlist: ' + 'x'*9000 + '\nrecipients: alpha\n[/ANTENNA_META]\n\nx', end='')
PY
: >"$CALL_LOG"; bash "$SKILL/bin/antenna.sh" reply-all beta --source "$ROOT/big" x >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "oversized metadata rejected" test "$RC" -ne 0; expect "oversized metadata sends nothing" test ! -s "$CALL_LOG"

# Existing Ed25519 primitive proves the metadata is authenticated as body bytes.
openssl genpkey -algorithm ED25519 -out "$ROOT/private.pem" >/dev/null 2>&1; chmod 600 "$ROOT/private.pem"
openssl pkey -in "$ROOT/private.pem" -pubout -out "$ROOT/public.pem" >/dev/null 2>&1; chmod 644 "$ROOT/public.pem"
printf '%s' "$expected" >"$ROOT/signed-body"; source "$SKILL/lib/antenna-signature.sh"
signature_canonical_file "$ROOT/canon" antenna-ed25519-v1 self 2026-08-11T00:00:00Z 123e4567-e89b-42d3-a456-426614174000 '' '' '' '' "$ROOT/signed-body"
SIG=$(signature_sign "$ROOT/private.pem" "$ROOT/canon")
expect "metadata-bearing body signature verifies" signature_verify "$ROOT/public.pem" "$ROOT/canon" "$SIG"
sed 's/alpha/gamma/' "$ROOT/signed-body" >"$ROOT/tampered"; signature_canonical_file "$ROOT/canon2" antenna-ed25519-v1 self 2026-08-11T00:00:00Z 123e4567-e89b-42d3-a456-426614174000 '' '' '' '' "$ROOT/tampered"
signature_verify "$ROOT/public.pem" "$ROOT/canon2" "$SIG" && no "metadata tamper rejected" || ok "metadata tamper rejected"

SNAP="$ROOT/snapshot.json"; bash "$SKILL/bin/antenna.sh" lists export ops --output "$SNAP" >"$ROOT/out" 2>"$ROOT/err"
expect "snapshot strict credential-free schema" jq -e '(keys|sort)==["display_name","peers","preferred_alias","schema_version"] and .schema_version==1 and .peers==["alpha","gamma"]' "$SNAP" >/dev/null
expect "snapshot contains no credential material" sh -c "! grep -Eqi 'token|secret|endpoint|url|key' '$SNAP'"
bash "$SKILL/bin/antenna.sh" lists import "$SNAP" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "collision requires explicit choice" test "$RC" -ne 0
bash "$SKILL/bin/antenna.sh" lists import "$SNAP" --alias copied >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "explicit rename imports" test "$RC" -eq 0
expect "import stores normalized rich entry" jq -e '.copied=={"display_name":"AGS Operations","peers":["alpha","gamma"]}' "$SKILL/antenna-lists.json" >/dev/null
jq '.display_name="Replacement"|.peers=["beta","alpha","beta"]' "$SNAP" >"$ROOT/replacement"
bash "$SKILL/bin/antenna.sh" lists import "$ROOT/replacement" --replace >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "explicit replace succeeds" test "$RC" -eq 0
expect "replace sorts and deduplicates" jq -e '.ops=={"display_name":"Replacement","peers":["alpha","beta"]}' "$SKILL/antenna-lists.json" >/dev/null
jq '.peers=["alpha","missing"]|.preferred_alias="warned"' "$SNAP" >"$ROOT/warn"
bash "$SKILL/bin/antenna.sh" lists import "$ROOT/warn" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "unavailable snapshot peer warns but imports" sh -c "test '$RC' -eq 0 && grep -q \"not locally available\" '$ROOT/err'"
expect "unavailable peer gains no peer credentials" jq -e 'has("missing")|not' "$SKILL/antenna-peers.json" >/dev/null

jq '.preferred_alias="readiness"|.peers=["alpha","beta","gamma"]' "$SNAP" >"$ROOT/readiness"
printf '%s\n' '{"allowed_outbound_peers":["alpha","beta","gamma"]}' >"$SKILL/antenna-config.json"
jq 'del(.alpha.auth_mode)|.gamma.url=""' "$SKILL/antenna-peers.json" >"$ROOT/peers" && mv "$ROOT/peers" "$SKILL/antenna-peers.json"
rm "$SKILL/secrets/beta.token"
bash "$SKILL/bin/antenna.sh" lists import "$ROOT/readiness" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
expect "readiness warnings do not block credential-free import" test "$RC" -eq 0
expect "missing auth_mode warning emitted" grep -q "alpha.*unsupported or missing auth_mode" "$ROOT/err"
expect "missing token warning emitted" grep -q "beta.*missing or unreadable token" "$ROOT/err"
expect "invalid URL warning emitted" grep -q "gamma.*invalid or missing URL" "$ROOT/err"
expect "readiness import preserves membership only" jq -e '.readiness=={"display_name":"AGS Operations","peers":["alpha","beta","gamma"]}' "$SKILL/antenna-lists.json" >/dev/null
expect "readiness import does not alter peer records" jq -e '(.alpha|has("auth_mode")|not) and .gamma.url==""' "$SKILL/antenna-peers.json" >/dev/null

printf 'RESULT: pass=%d fail=%d\n' "$PASS" "$FAIL"; [[ $FAIL -eq 0 ]]
