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
chmod 0644 "$TMP/public.pem"
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
noncanonical_sig="${vector_sig/%Q==/R==}"
signature_verify "$TMP/public.pem" "$TMP/vector-canonical" "$noncanonical_sig" \
  && no "non-canonical base64 signature rejected" || ok "non-canonical base64 signature rejected"
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
mkdir "$TMP/generated/real-parent"
cp "$TMP/generated/public.pem" "$TMP/generated/real-parent/public.pem"
ln -s real-parent "$TMP/generated/link-parent"
signature_public_key_ok "$TMP/generated/link-parent/public.pem" "$TMP/generated" \
  && no "symlinked public-key parent rejected" || ok "symlinked public-key parent rejected"
chmod 0666 "$TMP/generated/public.pem"
signature_public_key_ok "$TMP/generated/public.pem" "$TMP/generated" \
  && no "writable public key rejected" || ok "writable public key rejected"
chmod 0644 "$TMP/generated/public.pem"
mkdir "$TMP/generated/writable-parent"
cp "$TMP/generated/public.pem" "$TMP/generated/writable-parent/public.pem"
chmod 0777 "$TMP/generated/writable-parent"
signature_public_key_ok "$TMP/generated/writable-parent/public.pem" "$TMP/generated" \
  && no "writable public-key parent rejected" || ok "writable public-key parent rejected"

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
printf '[ANTENNA_RELAY]\nfrom: alpha\tadmin\n\nhi\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "control header rejected" || ok "control header rejected"
printf '[ANTENNA_RELAY]\nfrom: alpha\n\nhi\377\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "invalid UTF-8 rejected" || ok "invalid UTF-8 rejected"
printf '[ANTENNA_RELAY]\nfrom: alpha\n\n[ANTENNA_RELAY]\n[/ANTENNA_RELAY]' >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "ambiguous marker rejected" || ok "ambiguous marker rejected"
printf '[ANTENNA_RELAY]\nsubject: %0201d\n\nhi\n[/ANTENNA_RELAY]' 0 >"$TMP/raw"
parse "$TMP/raw" 2>/dev/null && no "oversized header rejected" || ok "oversized header rejected"

rid=123e4567-e89b-42d3-a456-426614174000
replay_reserve "$TMP/state/replay.json" 10 2 alpha "$rid" 100 && ok "replay reserve" || no "replay reserve"
set +e; replay_reserve "$TMP/state/replay.json" 10 2 alpha "$rid" 101; rc=$?; set -e
[[ $rc -eq 2 ]] && ok "replay duplicate persists" || no "replay duplicate persists"
replay_reserve "$TMP/state/replay.json" 10 2 alpha "$rid" 111 && ok "expired replay pruned" || no "expired replay pruned"
replay_reserve "$TMP/state/capacity.json" 99 1 alpha "$rid" 100
set +e; replay_reserve "$TMP/state/capacity.json" 99 1 alpha 223e4567-e89b-42d3-a456-426614174000 101; rc=$?; set -e
[[ $rc -eq 3 ]] && ok "replay capacity fails closed" || no "replay capacity fails closed"
capacity=$(replay_capacity_for_window 361 30)
[[ "$capacity" -eq 270 ]] && ok "replay capacity derives from TTL and admitted rate" \
  || no "replay capacity derives from TTL and admitted rate"
for n in $(seq 1 "$capacity"); do
  printf -v fill_id '00000000-0000-4000-8000-%012x' "$n"
  peer=alpha; (( n % 2 == 0 )) && peer=beta
  replay_reserve "$TMP/state/sustained.json" 361 "$capacity" "$peer" "$fill_id" 100 || break
done
set +e
replay_reserve "$TMP/state/sustained.json" 361 "$capacity" gamma 00000000-0000-4000-8000-00000000ffff 101
rc=$?
set -e
[[ $rc -eq 3 ]] && ok "multi-peer replay headroom is bounded" || no "multi-peer replay headroom is bounded"
replay_reserve "$TMP/state/sustained.json" 361 "$capacity" gamma 00000000-0000-4000-8000-00000000ffff 462 \
  && ok "full replay cache recovers after TTL" || no "full replay cache recovers after TTL"
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
  mkdir -p "$TMP/$host/lib" "$TMP/$host/scripts" "$TMP/$host/secrets" "$TMP/$host/keys"
  chmod 0700 "$TMP/$host/secrets" "$TMP/$host/keys"
  cp -R "$ROOT/scripts/." "$TMP/$host/scripts/"
  cp "$ROOT/lib/peers.sh" "$ROOT/lib/config.sh" "$ROOT/lib/antenna-signature.sh" \
    "$ROOT/lib/antenna-replay.sh" "$ROOT/lib/antenna-envelope-parse.py" "$TMP/$host/lib/"
  printf token >"$TMP/$host/secrets/token"
done
signature_keygen "$TMP/sender/secrets/private.pem" "$TMP/sender/secrets/public.pem"
install -m 0644 "$TMP/sender/secrets/public.pem" "$TMP/receiver/keys/sender-public.pem"
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
{"receiver":{"url":"https://receiver.test","self":true,"signing_private_key_file":"secrets/private.pem","signing_public_key_file":"secrets/public.pem"},"sender":{"url":"https://sender.test","auth_mode":"ed25519-v1","signing_public_key_file":"keys/sender-public.pem"}}
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

mv "$TMP/receiver/keys/sender-public.pem" "$TMP/receiver/keys/sender-public.saved"
make_envelope 'missing key' "$TMP/missing"
response=$(relay_file "$TMP/missing")
jq -e '.reason == "Pinned Ed25519 public key is missing or invalid"' <<<"$response" >/dev/null \
  && ok "relay fails closed on missing public key" || no "relay fails closed on missing public key"
cp "$TMP/receiver/secrets/public.pem" "$TMP/receiver/keys/sender-public.pem"
response=$(relay_file "$TMP/missing")
jq -e '.reason == "Ed25519 signature verification failed"' <<<"$response" >/dev/null \
  && ok "relay rejects wrong public key" || no "relay rejects wrong public key"
cp "$TMP/receiver/keys/sender-public.saved" "$TMP/receiver/keys/sender-public.pem"

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

(cd "$TMP/sender" && printf '' | bash scripts/antenna-send.sh receiver --stdin --dry-run) >"$TMP/dry"
awk '/^=== ENVELOPE ===$/{on=1;next}/^=== POST PAYLOAD ===$/{on=0}on' "$TMP/dry" >"$TMP/empty"
response=$(relay_file "$TMP/empty")
jq -e '.status == "ok" and .chars == 0' <<<"$response" >/dev/null \
  && ok "send and relay authenticate empty body" || no "empty body path"

(cd "$TMP/sender" && printf 'line one\nline two\nline three' | bash scripts/antenna-send.sh receiver --stdin --dry-run) >"$TMP/dry"
awk '/^=== ENVELOPE ===$/{on=1;next}/^=== POST PAYLOAD ===$/{on=0}on' "$TMP/dry" >"$TMP/multiline"
response=$(relay_file "$TMP/multiline")
jq -e '.status == "ok"' <<<"$response" >/dev/null \
  && ok "send and relay authenticate multiline body" || no "multiline body path"

make_signed_at() {
  local timestamp="$1" body_text="$2" output="$3" body_file="$TMP/manual-body" canonical="$TMP/manual-canonical"
  local id signature
  printf '%s' "$body_text" >"$body_file"
  id=$(signature_uuid_v4)
  signature_canonical_file "$canonical" antenna-ed25519-v1 sender "$timestamp" "$id" '' '' '' '' "$body_file"
  signature=$(signature_sign "$TMP/sender/secrets/private.pem" "$canonical")
  {
    printf '[ANTENNA_RELAY]\nprotocol: antenna-ed25519-v1\nfrom: sender\ntimestamp: %s\nmessage_id: %s\nsignature: ed25519-v1:%s\n\n' \
      "$timestamp" "$id" "$signature"
    cat "$body_file"
    printf '\n[/ANTENNA_RELAY]'
  } >"$output"
}

make_signed_at "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" stale "$TMP/stale"
response=$(relay_file "$TMP/stale")
jq -e '.reason | contains("timestamp too old")' <<<"$response" >/dev/null \
  && ok "relay rejects genuinely stale signed envelope" || no "stale signed envelope rejected"
make_signed_at "$(date -u -d '2 minutes' +%Y-%m-%dT%H:%M:%SZ)" future "$TMP/future"
response=$(relay_file "$TMP/future")
jq -e '.reason | contains("timestamp too far in future")' <<<"$response" >/dev/null \
  && ok "relay rejects genuinely future signed envelope" || no "future signed envelope rejected"

make_envelope 'malformed fields' "$TMP/malformed-base"
cp "$TMP/malformed-base" "$TMP/malformed"
sed -i 's/^message_id: .*/message_id: not-a-uuid/' "$TMP/malformed"
response=$(relay_file "$TMP/malformed")
jq -e '.reason == "Invalid message_id"' <<<"$response" >/dev/null \
  && ok "relay rejects malformed UUID" || no "malformed UUID rejected"
cp "$TMP/malformed-base" "$TMP/malformed"
sed -i 's/^signature: .*/signature: ed25519-v1:bad/' "$TMP/malformed"
response=$(relay_file "$TMP/malformed")
jq -e '.reason == "Malformed Ed25519 signature"' <<<"$response" >/dev/null \
  && ok "relay rejects malformed signature" || no "malformed signature rejected"
cp "$TMP/malformed-base" "$TMP/malformed"
sed -i 's/^timestamp: .*/timestamp: 2026-02-30T00:00:00Z/' "$TMP/malformed"
response=$(relay_file "$TMP/malformed")
jq -e '.reason == "Invalid timestamp format"' <<<"$response" >/dev/null \
  && ok "relay rejects malformed timestamp" || no "malformed timestamp rejected"
cp "$TMP/malformed-base" "$TMP/malformed"
sed -i '/^from: /d' "$TMP/malformed"
response=$(relay_file "$TMP/malformed")
jq -e '.reason == "Signed envelope is missing a required field"' <<<"$response" >/dev/null \
  && ok "relay rejects missing required field" || no "missing required field rejected"

make_envelope 'allowlist checks' "$TMP/policy-envelope"
cp "$TMP/receiver/antenna-config.json" "$TMP/config.saved"
jq '.allowed_inbound_peers=[]' "$TMP/config.saved" >"$TMP/receiver/antenna-config.json"
response=$(relay_file "$TMP/policy-envelope")
jq -e '.reason | contains("Unknown or disallowed sender")' <<<"$response" >/dev/null \
  && ok "empty inbound allowlist denies all" || no "empty inbound allowlist denies all"
jq 'del(.allowed_inbound_peers)' "$TMP/config.saved" >"$TMP/receiver/antenna-config.json"
response=$(relay_file "$TMP/policy-envelope")
jq -e '.reason | contains("Unknown or disallowed sender")' <<<"$response" >/dev/null \
  && ok "missing inbound allowlist denies all" || no "missing inbound allowlist denies all"
jq '.allowed_inbound_peers=["sender", 7]' "$TMP/config.saved" >"$TMP/receiver/antenna-config.json"
response=$(relay_file "$TMP/policy-envelope")
jq -e '.reason | contains("Unknown or disallowed sender")' <<<"$response" >/dev/null \
  && ok "malformed inbound allowlist fails closed" || no "malformed inbound allowlist fails closed"
cp "$TMP/config.saved" "$TMP/receiver/antenna-config.json"

cp "$TMP/sender/antenna-config.json" "$TMP/sender-config.saved"
for variant in empty missing malformed; do
  case "$variant" in
    empty) jq '.allowed_outbound_peers=[]' "$TMP/sender-config.saved" >"$TMP/sender/antenna-config.json" ;;
    missing) jq 'del(.allowed_outbound_peers)' "$TMP/sender-config.saved" >"$TMP/sender/antenna-config.json" ;;
    malformed) jq '.allowed_outbound_peers=["receiver", 7]' "$TMP/sender-config.saved" >"$TMP/sender/antenna-config.json" ;;
  esac
  if (cd "$TMP/sender" && bash scripts/antenna-send.sh receiver --dry-run denied) >/dev/null 2>&1; then
    no "$variant outbound allowlist denies send"
  else
    ok "$variant outbound allowlist denies send"
  fi
done
cp "$TMP/sender-config.saved" "$TMP/sender/antenna-config.json"
jq '.duplicate=(.sender | .url="https://duplicate.test")' "$TMP/sender/antenna-peers.json" >"$TMP/p" && mv "$TMP/p" "$TMP/sender/antenna-peers.json"
if (cd "$TMP/sender" && bash scripts/antenna-send.sh receiver --dry-run ambiguous) >/dev/null 2>&1; then
  no "multiple self identities fail closed"
else
  ok "multiple self identities fail closed"
fi
jq 'del(.duplicate)' "$TMP/sender/antenna-peers.json" >"$TMP/p" && mv "$TMP/p" "$TMP/sender/antenna-peers.json"

install_good_key() { install -m 0644 "$TMP/receiver/keys/sender-public.saved" "$TMP/receiver/keys/sender-public.pem"; }
make_envelope 'key policy' "$TMP/key-envelope"
chmod 0666 "$TMP/receiver/keys/sender-public.pem"
response=$(relay_file "$TMP/key-envelope")
jq -e '.reason == "Pinned Ed25519 public key is missing or invalid"' <<<"$response" >/dev/null \
  && ok "relay rejects writable pinned key" || no "relay rejects writable pinned key"
install_good_key
mv "$TMP/receiver/keys" "$TMP/receiver/keys-real"
ln -s keys-real "$TMP/receiver/keys"
response=$(relay_file "$TMP/key-envelope")
jq -e '.reason == "Pinned Ed25519 public key is missing or invalid"' <<<"$response" >/dev/null \
  && ok "relay rejects symlinked key directory" || no "relay rejects symlinked key directory"
rm "$TMP/receiver/keys"; mv "$TMP/receiver/keys-real" "$TMP/receiver/keys"
printf 'not a key\n' >"$TMP/receiver/keys/sender-public.pem"; chmod 0644 "$TMP/receiver/keys/sender-public.pem"
response=$(relay_file "$TMP/key-envelope")
jq -e '.reason == "Pinned Ed25519 public key is missing or invalid"' <<<"$response" >/dev/null \
  && ok "relay rejects malformed public key" || no "relay rejects malformed public key"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/rsa-private.pem" >/dev/null 2>&1
openssl pkey -in "$TMP/rsa-private.pem" -pubout -out "$TMP/receiver/keys/sender-public.pem" >/dev/null 2>&1
chmod 0644 "$TMP/receiver/keys/sender-public.pem"
response=$(relay_file "$TMP/key-envelope")
jq -e '.reason == "Pinned Ed25519 public key is missing or invalid"' <<<"$response" >/dev/null \
  && ok "relay rejects non-Ed25519 public key" || no "relay rejects non-Ed25519 public key"
install_good_key

jq '.rate_limit.global_per_minute="30"' "$TMP/config.saved" >"$TMP/receiver/antenna-config.json"
make_envelope 'invalid rate' "$TMP/invalid-rate"
response=$(relay_file "$TMP/invalid-rate")
jq -e '.reason == "Invalid rate-limit configuration"' <<<"$response" >/dev/null \
  && ok "malformed rate configuration fails closed" || no "malformed rate configuration fails closed"
cp "$TMP/config.saved" "$TMP/receiver/antenna-config.json"

jq '.max_message_length=10' "$TMP/config.saved" >"$TMP/receiver/antenna-config.json"
{ printf '[ANTENNA_RELAY]\nprotocol: antenna-ed25519-v1\nfrom: sender\n\n'; head -c 5000 /dev/zero | tr '\0' x; printf '\n[/ANTENNA_RELAY]'; } >"$TMP/oversized-raw"
response=$(relay_file "$TMP/oversized-raw")
jq -e '.reason == "Envelope exceeds raw byte limit"' <<<"$response" >/dev/null \
  && ok "raw envelope cap rejects before parsing" || no "raw envelope cap rejects before parsing"
cp "$TMP/config.saved" "$TMP/receiver/antenna-config.json"

echo "RESULT: pass=$pass fail=$fail"
(( fail == 0 ))
