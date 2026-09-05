#!/usr/bin/env bash
# ANT-165-007 regression: Public Groups are ClawReef-readable public messages;
# Private Groups are local peer-to-peer Distribution Lists, not an E2E claim.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
SKILL="$ROOT/SKILL.md"
GUIDE="$ROOT/references/USER-GUIDE.md"
CLI="$ROOT/bin/antenna.sh"
GROUP_SCRIPT="$ROOT/scripts/antenna-public-group.sh"
SETUP_SCRIPT="$ROOT/scripts/antenna-setup.sh"

PASS=0
FAIL=0

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

assert_fixed() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then pass "$label"; else fail "$label"; fi
}

assert_regex() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eiq -- "$pattern" "$file"; then pass "$label"; else fail "$label"; fi
}

assert_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eiq -- "$pattern" "$file"; then fail "$label"; else pass "$label"; fi
}

assert_flat_regex() {
  local file="$1" pattern="$2" label="$3"
  if tr '\n' ' ' <"$file" | grep -Eiq -- "$pattern"; then pass "$label"; else fail "$label"; fi
}

for file in "$SKILL" "$README" "$GUIDE"; do
  label="$(basename "$file")"
  assert_regex "$file" 'Public means public' "$label says Public means public"
  assert_regex "$file" 'ClawReef reads (each|and relays their) Public Group|ClawReef reads each Public Group' \
    "$label says ClawReef reads Public Group messages"
  assert_regex "$file" 'passwords, private keys,[[:space:]]*$|passwords, private keys,' \
    "$label warns against passwords and private keys"
  assert_regex "$file" 'credentials, regulated data,' \
    "$label warns against credentials and regulated data"
  assert_regex "$file" 'Private Groups.*Distribution Lists|Private Groups \(`antenna-lists.json`\)' \
    "$label maps Private Groups to Distribution Lists"
  assert_regex "$file" 'ClawReef is not (in|involved)' \
    "$label says ClawReef is outside Private Group delivery"
  assert_flat_regex "$file" '(does not mean payload end-to-end encryption|not payload end-to-end encryption|payloads are not end-to-end encrypted)' \
    "$label avoids an E2E promise for Private Groups"
  assert_absent "$file" 'Private Groups (are|provide|use) end-to-end encrypt' \
    "$label contains no positive Private Group E2E claim"
done

help_output="$(bash "$CLI" help)"
if grep -Fq 'Send to a Private Group (direct peer fan-out)' <<<"$help_output"; then
  pass "CLI help identifies Private Group routing"
else
  fail "CLI help identifies Private Group routing"
fi
if grep -Fq 'Send to a Public Group through ClawReef' <<<"$help_output"; then
  pass "CLI help identifies Public Group routing"
else
  fail "CLI help identifies Public Group routing"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165007.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/lib" "$fixture/keys"
chmod 700 "$fixture/keys"
cp "$GROUP_SCRIPT" "$fixture/scripts/"
cp "$ROOT/lib/antenna-signature.sh" "$fixture/lib/"
openssl genpkey -algorithm ED25519 -out "$fixture/keys/private.pem" >/dev/null 2>&1
openssl pkey -in "$fixture/keys/private.pem" -pubout -out "$fixture/keys/clawreef.pem" >/dev/null 2>&1
chmod 600 "$fixture/keys/private.pem"
chmod 644 "$fixture/keys/clawreef.pem"
cat >"$fixture/antenna-public-groups.json" <<'JSON'
{"reef":{"group_id":"11111111-1111-4111-8111-111111111111","name":"Reef","relay_peer":"clawreef"}}
JSON
chmod 600 "$fixture/antenna-public-groups.json"
cat >"$fixture/antenna-peers.json" <<'JSON'
{"clawreef":{"auth_mode":"ed25519-v1","signing_public_key_file":"keys/clawreef.pem"}}
JSON
cat >"$fixture/scripts/antenna-send.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'SENDER_CALLED\n' >&2
printf '%s\n' '{"status":"delivered","response":{"accepted":1,"failed":0,"results":[]}}'
SH
chmod 700 "$fixture/scripts/antenna-send.sh"

if bash "$fixture/scripts/antenna-public-group.sh" send @reef 'hello' \
    >"$fixture/out" 2>"$fixture/err"; then
  pass "Public Group send succeeds through fixture"
else
  fail "Public Group send succeeds through fixture"
fi
assert_fixed "$fixture/err" 'PUBLIC GROUP: ClawReef reads and relays this plaintext message.' \
  "send-time warning states the public relay boundary"
assert_fixed "$fixture/err" 'Do not send passwords, private keys, credentials, regulated data, or other sensitive plaintext.' \
  "send-time warning names prohibited sensitive data"
warning_line="$(grep -n 'PUBLIC GROUP:' "$fixture/err" | cut -d: -f1)"
sender_line="$(grep -n 'SENDER_CALLED' "$fixture/err" | cut -d: -f1)"
if [[ -n "$warning_line" && -n "$sender_line" && "$warning_line" -lt "$sender_line" ]]; then
  pass "Public Group warning appears before network send"
else
  fail "Public Group warning appears before network send"
fi

assert_fixed "$SKILL" '`antenna-lists.json` (optional Private Groups implemented as local' \
  "skill configuration labels the Private Group file"
assert_fixed "$SKILL" '`antenna-public-groups.json` (optional Public Group aliases routed through' \
  "skill configuration labels the Public Group file"
assert_fixed "$GUIDE" '`antenna-lists.json` holds local Private Group membership' \
  "user-guide configuration labels Private Group state"
assert_fixed "$GUIDE" '`antenna-public-groups.json` holds aliases for Public' \
  "user-guide configuration labels Public Group state"
assert_fixed "$SETUP_SCRIPT" 'Direct messages and Private Groups stay peer-to-peer.' \
  "setup identifies the direct and Private Group route"
assert_fixed "$SETUP_SCRIPT" 'Public Groups are public; ClawReef reads and relays their plaintext.' \
  "setup identifies the Public Group boundary"
for file in "$SETUP_SCRIPT" "$README" "$GUIDE"; do
  assert_absent "$file" '(stores public info only|just makes discovery easier|ClawReef handles the introductions\.)' \
    "$(basename "$file") removes obsolete discovery-only ClawReef copy"
done

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
(( FAIL == 0 ))
