#!/usr/bin/env bash
# ANT-165-009 regression: autonomous paired-peer delivery remains the default;
# inbox is optional global supervision with an explicit durable bypass list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
SKILL="$ROOT/SKILL.md"
GUIDE="$ROOT/references/USER-GUIDE.md"
SETUP="$ROOT/scripts/antenna-setup.sh"
RELAY="$ROOT/scripts/antenna-relay.sh"
CLI="$ROOT/bin/antenna.sh"
EXAMPLE="$ROOT/antenna-config.example.json"
CHANGELOG="$ROOT/CHANGELOG.md"

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

assert_flat_regex() {
  local file="$1" pattern="$2" label="$3"
  if tr '\n' ' ' <"$file" | grep -Eiq -- "$pattern"; then pass "$label"; else fail "$label"; fi
}

assert_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eiq -- "$pattern" "$file"; then fail "$label"; else pass "$label"; fi
}

for file in "$README" "$SKILL" "$GUIDE"; do
  label="$(basename "$file")"
  assert_regex "$file" 'paired, authenticated, and allowlisted|pairing, authentication, and allowlist' \
    "$label names the existing peer trust boundary"
  assert_flat_regex "$file" 'autonomous delivery.*normal|normal Antenna posture' \
    "$label identifies autonomous delivery as normal"
  assert_regex "$file" 'inbox.*optional (supervision|operational)|optional supervision' \
    "$label presents inbox as optional supervision"
  assert_regex "$file" 'review applies globally|inbox currently applies globally' \
    "$label explains the current global selector"
  assert_regex "$file" 'durable bypass' \
    "$label explains auto-approval durability"
  assert_regex "$file" 'does not (establish|create).*peer trust|does not pair or' \
    "$label separates pairing trust from inbox bypass"
  assert_absent "$file" 'progressive trust|non-trusted peers' \
    "$label removes misleading trust language"
done

assert_fixed "$SETUP" 'Whether to enable optional inbox review' \
  "setup presents inbox as optional review"
assert_fixed "$SETUP" 'Review applies globally; messages wait in a queue first.' \
  "setup explains global review"
assert_fixed "$SETUP" 'This bypass remains in effect until you remove the peer from the list.' \
  "setup explains durable bypass"
assert_absent "$SETUP" 'inbox mode \(optional, more secure\)|Inbox queue.*more secure' \
  "setup does not label inbox generally safer"
assert_fixed "$SETUP" 'prompt_yn "Enable inbox queue for inbound messages?" "n"' \
  "interactive setup retains inbox-off default"
assert_fixed "$SETUP" 'INBOX_ENABLED=false' \
  "setup initializes inbox disabled"
assert_fixed "$SETUP" 'INBOX_AUTO_APPROVE=""' \
  "setup initializes auto-approval empty"

if jq -e '.inbox_enabled == false and .inbox_auto_approve_peers == []' \
    "$EXAMPLE" >/dev/null; then
  pass "example config retains inbox-off and empty auto-approval defaults"
else
  fail "example config retains inbox-off and empty auto-approval defaults"
fi

assert_fixed "$RELAY" 'config_policy admit "$FROM" "$SIGNED_TARGET_SESSION"' \
  "relay delegates canonical review selection to shared policy"
assert_fixed "$(dirname "$RELAY")/../lib/session_policy.py" "mode == 'on' and sender not in" \
  "trusted-peer bypass remains confined to On mode"
assert_absent "$EXAMPLE" 'inbox_(peers|quarantine_peers)' \
  "v1.6.5 adds no selective quarantine field"

help_output="$(bash "$CLI" help)"
if grep -Fq 'Inbox is an optional global review queue; autonomous delivery is the default.' \
    <<<"$help_output"; then
  pass "CLI help states the inbox posture"
else
  fail "CLI help states the inbox posture"
fi

assert_fixed "$CHANGELOG" 'ANT-165-009' \
  "changelog records the inbox guidance correction"
assert_fixed "$CHANGELOG" 'No delivery logic or default changed.' \
  "changelog records the non-behavioral scope"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
(( FAIL == 0 ))
