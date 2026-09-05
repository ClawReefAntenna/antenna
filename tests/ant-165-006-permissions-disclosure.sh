#!/usr/bin/env bash
# ANT-165-006 regression: effective permissions and administrative scope must
# be prominent, complete, and must not invent unsupported frontmatter metadata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/SKILL.md"
README="$ROOT/README.md"
GUIDE="$ROOT/references/USER-GUIDE.md"
CHANGELOG="$ROOT/CHANGELOG.md"

PASS=0
FAIL=0

pass() {
  printf 'PASS %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_fixed() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_regex() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eq -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

frontmatter="$(awk 'NR == 1 {next} /^---$/ {exit} {print}' "$SKILL")"
if grep -Eq '^[[:space:]]*permissions:' <<<"$frontmatter"; then
  fail "unsupported permissions frontmatter is absent"
else
  pass "unsupported permissions frontmatter is absent"
fi

assert_fixed "$SKILL" "Inter-host OpenClaw messaging and local gateway integration" \
  "skill description identifies local gateway integration"

for file in "$SKILL" "$README" "$GUIDE"; do
  label="$(basename "$file")"
  assert_fixed "$file" "## Effective Permissions and Trust Boundary" \
    "$label has a prominent trust-boundary section"
  assert_fixed "$file" 'openclaw.json' "$label discloses gateway configuration mutation"
  assert_regex "$file" 'hook(s| token)' "$label discloses gateway hooks or hook tokens"
  assert_fixed "$file" 'tools.sessions.visibility = "all"' \
    "$label discloses all-session visibility"
  assert_fixed "$file" 'tools.agentToAgent.enabled = true' \
    "$label discloses agent-to-agent access"
  assert_fixed "$file" 'sandbox.mode = "off"' "$label discloses sandbox posture"
  assert_regex "$file" '(fixed Antenna delivery wrapper|fixed delivery wrapper)' \
    "$label discloses bounded relay execution"
  assert_regex "$file" '(peer records|peers, allowlists)' \
    "$label discloses persistent peer state"
  assert_regex "$file" '(PATH directory|CLI into PATH)' "$label discloses CLI/PATH integration"
  assert_regex "$file" '(external-provider model tests|External-provider model tests)' \
    "$label discloses optional external-provider tests"
  assert_regex "$file" '(restart the gateway|gateway restart)' \
    "$label discloses gateway restart behavior"
  assert_regex "$file" '(does not promise|not a promise)' \
    "$label does not promise a clean scanner classification"
done

assert_fixed "$README" '> **Administrative setup:** `antenna setup`' \
  "README Quick Start warns before setup commands"
assert_fixed "$GUIDE" '> **Administrative setup:** `antenna setup`' \
  "User Guide Quick Start warns before setup commands"
assert_fixed "$CHANGELOG" 'ANT-165-006' "changelog records the disclosure repair"
assert_fixed "$CHANGELOG" 'no supported machine-readable permissions' \
  "changelog records the metadata contract finding"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
(( FAIL == 0 ))
