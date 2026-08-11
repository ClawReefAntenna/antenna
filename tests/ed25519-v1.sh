#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
no() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

source "$ROOT/lib/antenna-signature.sh"
source "$ROOT/lib/antenna-replay.sh"

# RFC 8032 test-1 seed encoded as PKCS#8 for the fixed Antenna vector.
printf '%s' '302e020100300506032b6570042204209d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60' \
  | xxd -r -p >"$TMP/private.der"
openssl pkey -inform DER -in "$TMP/private.der" -out "$TMP/private.pem" >/dev/null 2>&1
chmod 0600 "$TMP/private.pem"
openssl pkey -in "$TMP/private.pem" -pubout -out "$TMP/public.pem" >/dev/null 2>&1
printf 'Hello,\nreef.\n' >"$TMP/vector-body"
signature_canonical_file "$TMP/vector-canonical" antenna-ed25519-v1 alpha \
  2026-08-11T18:00:00Z 123e4567-e89b-42d3-a456-426614174000 '' Corey '' 'Vector ✓' "$TMP/vector-body"
vector_sig=$(signature_sign "$TMP/private.pem" "$TMP/vector-canonical")
[[ "$vector_sig" == 'n1d1ue19mD1vIEL9oOZXDypsLwDSv31Q83NPLPmBset32BKm657dP4NqylHgYCRWvZcbgDqSlcz0kbisfwbpDQ==' ]] \
  && ok "fixed Ed25519 signature vector" || no "fixed Ed25519 signature vector"
[[ $(wc -c <"$TMP/vector-canonical") -eq 216 ]] &&
  [[ $(sha256sum "$TMP/vector-canonical" | awk '{print $1}') == 02ec42dc56373e72b828ef050f0565c007a2e286e3d41d98f5aa24c530a07917 ]] \
  && ok "fixed canonical byte vector" || no "fixed canonical byte vector"
signature_verify "$TMP/public.pem" "$TMP/vector-canonical" "$vector_sig" \
  && ok "fixed vector verifies" || no "fixed vector verifies"
printf X >>"$TMP/vector-canonical"
signature_verify "$TMP/public.pem" "$TMP/vector-canonical" "$vector_sig" \
  && no "tampered canonical bytes rejected" || ok "tampered canonical bytes rejected"

signature_keygen "$TMP/generated/private.pem" "$TMP/generated/public.pem" &&
  signature_private_key_ok "$TMP/generated/private.pem" && signature_public_key_ok "$TMP/generated/public.pem" \
  && ok "generated Ed25519 keypair validates" || no "generated Ed25519 keypair validates"
chmod 0644 "$TMP/generated/private.pem"
signature_private_key_ok "$TMP/generated/private.pem" && no "unsafe private-key mode rejected" || ok "unsafe private-key mode rejected"
chmod 0600 "$TMP/generated/private.pem"
ln -s public.pem "$TMP/generated/link.pem"
signature_public_key_ok "$TMP/generated/link.pem" && no "symlinked public key rejected" || ok "symlinked public key rejected"

parse() { python3 "$ROOT/lib/antenna-envelope-parse.py" "$1" "$TMP/parsed" >/dev/null; }
printf '[ANTENNA_RELAY]\nprotocol: antenna-ed25519-v1\nfrom: alpha\n\nbody LF\n\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" && cmp -s "$TMP/parsed" <(printf 'body LF\n') \
  && ok "parser preserves terminal body LF" || no "parser preserves terminal body LF"
printf '[ANTENNA_RELAY]\nfrom: alpha\nfrom: beta\n\nhi\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "duplicate header rejected" || ok "duplicate header rejected"
printf '[ANTENNA_RELAY]\nfrom: alpha\nunknown: value\n\nhi\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "unknown header rejected" || ok "unknown header rejected"
printf '[ANTENNA_RELAY]\r\nfrom: alpha\r\n\r\nhi\r\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "CR envelope rejected" || ok "CR envelope rejected"
printf '[ANTENNA_RELAY]\nfrom: alpha\n\nhi\0there\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "NUL body rejected" || ok "NUL body rejected"

rid=123e4567-e89b-42d3-a456-426614174000
replay_reserve "$TMP/state/replay.json" 10 2 alpha "$rid" 100 && ok "replay reserve" || no "replay reserve"
set +e; replay_reserve "$TMP/state/replay.json" 10 2 alpha "$rid" 101; rc=$?; set -e
[[ $rc -eq 2 ]] && ok "replay duplicate persists" || no "replay duplicate persists"
replay_reserve "$TMP/state/replay.json" 10 2 alpha "$rid" 111 && ok "expired replay pruned" || no "expired replay pruned"
replay_reserve "$TMP/state/capacity.json" 99 1 alpha "$rid" 100
set +e; replay_reserve "$TMP/state/capacity.json" 99 1 alpha 223e4567-e89b-42d3-a456-426614174000 101; rc=$?; set -e
[[ $rc -eq 3 ]] && ok "replay capacity fails closed" || no "replay capacity fails closed"
printf '{broken' >"$TMP/state/corrupt.json"
set +e; replay_reserve "$TMP/state/corrupt.json" 10 2 alpha "$rid" 100; rc=$?; set -e
[[ $rc -eq 3 ]] && ok "corrupt replay state fails closed" || no "corrupt replay state fails closed"
for n in 1 2 3 4; do
  (set +e; replay_reserve "$TMP/state/concurrent.json" 99 10 alpha "$rid" 100; echo $? >"$TMP/rc.$n") &
done
wait
[[ $(grep -l '^0$' "$TMP"/rc.* | wc -l) -eq 1 ]] \
  && ok "concurrent replay reservation admits once" || no "concurrent replay reservation admits once"

# Hermetic sender/receiver integration fixtures.
for host in sender receiver; do
  mkdir -p "$TMP/$host/lib" "$TMP/$host/scripts" "$TMP/$host/secrets"
  cp -R "$ROOT/scripts/." "$TMP/$host/scripts/"
  cp "$ROOT/lib/peers.sh" "$ROOT/lib/config.sh" "$ROOT/lib/antenna-signature.sh" \
    "$ROOT/lib/antenna-replay.sh" "$ROOT/lib/antenna-envelope-parse.py" "$TMP/$host/lib/"
  printf token >"$TMP/$host/secrets/token"
done
signature_keygen "$TMP/sender/secrets/private.pem" "$TMP/sender/secrets/public.pem"
cp "$TMP/sender/secrets/public.pem" "$TMP/receiver/secrets/sender-public.pem"
signature_keygen "$TMP/receiver/secrets/private.pem" "$TMP/receiver/secrets/public.pem"
cat >"$TMP/sender/antenna-config.json" <<'EOF'
{"log_enabled":false,"allowed_outbound_peers":["receiver"],"max_message_length":10000}
EOF
cat >"$TMP/sender/antenna-peers.json" <<'EOF'
{"sender":{"url":"https://sender.test","self":true,"signing_private_key_file":"secrets/private.pem","signing_public_key_file":"secrets/public.pem"},"receiver":{"url":"https://receiver.test","token_file":"secrets/token","agentId":"antenna","auth_mode":"ed25519-v1"}}
EOF
cat >"$TMP/receiver/antenna-config.json" <<'EOF'
{"log_enabled":false,"allowed_inbound_peers":["sender"],"allowed_inbound_sessions":["agent:receiver:main"],"default_target_session":"agent:receiver:main","local_agent_id":"receiver","max_message_length":10000,"security":{"max_message_age_seconds":300,"max_future_skew_seconds":60}}
EOF
cat >"$TMP/receiver/antenna-peers.json" <<'EOF'
{"receiver":{"url":"https://receiver.test","self":true,"signing_private_key_file":"secrets/private.pem","signing_public_key_file":"secrets/public.pem"},"sender":{"url":"https://sender.test","auth_mode":"ed25519-v1","signing_public_key_file":"secrets/sender-public.pem"}}
EOF

make_envelope() {
  local body="$1" output="$2"
  (cd "$TMP/sender" && bash scripts/antenna-send.sh receiver --dry-run --subject signed "$body") >"$TMP/dry"
  awk '/^=== ENVELOPE ===$/{on=1;next}/^=== POST PAYLOAD ===$/{on=0}on' "$TMP/dry" >"$output"
}
relay_file() { (cd "$TMP/receiver" && bash scripts/antenna-relay.sh --stdin) <"$1"; }
make_envelope 'signed body' "$TMP/envelope"
response=$(relay_file "$TMP/envelope")
jq -e '.status == "ok" and .from == "sender"' <<<"$response" >/dev/null \
  && ok "signed sender-to-relay path" || { echo "$response" >&2; no "signed sender-to-relay path"; }
response=$(relay_file "$TMP/envelope")
jq -e '.status == "rejected" and .reason == "Replay detected"' <<<"$response" >/dev/null \
  && ok "relay rejects repeated signed envelope" || no "relay rejects repeated signed envelope"

make_envelope 'original body' "$TMP/tamper"
sed -i 's/original body/forged body/' "$TMP/tamper"
response=$(relay_file "$TMP/tamper")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects body tamper" || no "relay rejects body tamper"
make_envelope 'subject body' "$TMP/tamper"
sed -i 's/^subject: signed$/subject: forged/' "$TMP/tamper"
response=$(relay_file "$TMP/tamper")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects signed-header tamper" || no "relay rejects signed-header tamper"

(cd "$TMP/sender" && bash scripts/antenna-send.sh receiver --dry-run \
  --session agent:receiver:main --user Ada --reply-to https://sender.test/reply \
  --subject signed 'all fields') >"$TMP/dry"
awk '/^=== ENVELOPE ===$/{on=1;next}/^=== POST PAYLOAD ===$/{on=0}on' "$TMP/dry" >"$TMP/all-fields"
for field in target_session user reply_to subject; do
  cp "$TMP/all-fields" "$TMP/field-tamper"
  sed -i "s#^${field}: .*#${field}: forged#" "$TMP/field-tamper"
  response=$(relay_file "$TMP/field-tamper")
  jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
    && ok "relay rejects $field tamper" || no "relay rejects $field tamper"
done
cp "$TMP/all-fields" "$TMP/field-tamper"
sed -i 's/^message_id: .*/message_id: 00000000-0000-4000-8000-000000000000/' "$TMP/field-tamper"
response=$(relay_file "$TMP/field-tamper")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects message_id tamper" || no "relay rejects message_id tamper"
cp "$TMP/all-fields" "$TMP/field-tamper"
old_stamp=$(sed -n 's/^timestamp: //p' "$TMP/field-tamper")
new_stamp=$(date -u -d "$old_stamp - 1 second" +%Y-%m-%dT%H:%M:%SZ)
sed -i "s/^timestamp: .*/timestamp: $new_stamp/" "$TMP/field-tamper"
response=$(relay_file "$TMP/field-tamper")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects timestamp tamper" || no "relay rejects timestamp tamper"
jq '.beta=(.sender | .url="https://beta.test")' "$TMP/receiver/antenna-peers.json" >"$TMP/p" && mv "$TMP/p" "$TMP/receiver/antenna-peers.json"
jq '.allowed_inbound_peers += ["beta"]' "$TMP/receiver/antenna-config.json" >"$TMP/p" && mv "$TMP/p" "$TMP/receiver/antenna-config.json"
cp "$TMP/all-fields" "$TMP/field-tamper"
sed -i 's/^from: sender$/from: beta/' "$TMP/field-tamper"
response=$(relay_file "$TMP/field-tamper")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects from tamper" || no "relay rejects from tamper"
cp "$TMP/all-fields" "$TMP/field-tamper"
sed -i 's/^protocol: antenna-ed25519-v1$/protocol: antenna-ed25519-v2/' "$TMP/field-tamper"
response=$(relay_file "$TMP/field-tamper")
jq -e '.reason == "Unsupported or missing protocol"' <<<"$response" >/dev/null \
  && ok "relay rejects protocol tamper" || no "relay rejects protocol tamper"

mv "$TMP/receiver/secrets/sender-public.pem" "$TMP/receiver/secrets/sender-public.saved"
make_envelope 'missing key' "$TMP/missing"
response=$(relay_file "$TMP/missing")
jq -e '.reason == "Pinned Ed25519 public key is missing or invalid"' <<<"$response" >/dev/null \
  && ok "relay fails closed on missing public key" || no "relay fails closed on missing public key"
cp "$TMP/receiver/secrets/public.pem" "$TMP/receiver/secrets/sender-public.pem"
response=$(relay_file "$TMP/missing")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects wrong public key" || no "relay rejects wrong public key"
cp "$TMP/receiver/secrets/sender-public.saved" "$TMP/receiver/secrets/sender-public.pem"

make_envelope 'freshness config' "$TMP/freshness"
jq '.security.max_message_age_seconds="300"' "$TMP/receiver/antenna-config.json" >"$TMP/p" && mv "$TMP/p" "$TMP/receiver/antenna-config.json"
response=$(relay_file "$TMP/freshness")
jq -e '.reason == "Invalid freshness configuration"' <<<"$response" >/dev/null \
  && ok "malformed freshness policy fails closed" || no "malformed freshness policy fails closed"
jq '.security.max_message_age_seconds=300' "$TMP/receiver/antenna-config.json" >"$TMP/p" && mv "$TMP/p" "$TMP/receiver/antenna-config.json"

(cd "$TMP/sender" && printf 'terminal LF\n' | bash scripts/antenna-send.sh receiver --stdin --dry-run) >"$TMP/dry"
awk '/^=== ENVELOPE ===$/{on=1;next}/^=== POST PAYLOAD ===$/{on=0}on' "$TMP/dry" >"$TMP/terminal"
response=$(relay_file "$TMP/terminal")
jq -e '.status == "ok" and .chars == 12' <<<"$response" >/dev/null \
  && ok "send and relay preserve terminal body LF" || { echo "$response" >&2; no "terminal LF path"; }

(cd "$TMP/sender" && printf 'héllo 🦞\n第二行' | bash scripts/antenna-send.sh receiver --stdin --dry-run) >"$TMP/dry"
awk '/^=== ENVELOPE ===$/{on=1;next}/^=== POST PAYLOAD ===$/{on=0}on' "$TMP/dry" >"$TMP/unicode"
response=$(relay_file "$TMP/unicode")
jq -e '.status == "ok"' <<<"$response" >/dev/null \
  && ok "send and relay authenticate Unicode body" || no "Unicode body path"

echo "RESULT: pass=$pass fail=$fail"
(( fail == 0 ))
