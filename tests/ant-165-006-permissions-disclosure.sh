#!/usr/bin/env bash
# ANT-165-006 regression: setup effects must be clear, user-first, and must not
# invent unsupported frontmatter metadata or scanner-directed product copy.
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

assert_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -Eiq -- "$pattern" "$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_flat_fixed() {
  local file="$1" needle="$2" label="$3"
  if sed 's/^>[[:space:]]*//' "$file" | tr '\n' ' ' | grep -Fq -- "$needle"; then
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

assert_fixed "$SKILL" "Authenticated messaging between OpenClaw instances" \
  "skill description leads with the user-facing feature"

frontmatter_description="$(awk '
  /^description:/ {capture=1}
  capture {print}
  capture && /^metadata:/ {exit}
' "$SKILL")"
if grep -Fq "local gateway integration" <<<"$frontmatter_description"; then
  fail "skill description does not present setup plumbing as a feature"
else
  pass "skill description does not present setup plumbing as a feature"
fi

for file in "$SKILL" "$README" "$GUIDE"; do
  label="$(basename "$file")"
  assert_regex "$file" '(What Setup Changes|What setup changes)' \
    "$label explains setup effects in user-facing language"
  assert_regex "$file" '(backs up and updates the gateway|backs up and updates the gateway configuration)' \
    "$label discloses gateway configuration changes"
  assert_flat_fixed "$file" 'registers the Antenna relay agent' \
    "$label discloses relay-agent registration"
  assert_flat_fixed "$file" 'stores local credentials and peer settings' \
    "$label discloses persistent local state"
  assert_regex "$file" '(command to your PATH|CLI to PATH)' \
    "$label discloses CLI/PATH integration"
  assert_flat_fixed "$file" 'gateway restart is required' \
    "$label discloses restart behavior"
  assert_absent "$file" '(scanner|classif(y|ication)|low[ -]privilege)' \
    "$label contains no scanner-directed copy"
  assert_absent "$file" 'Effective Permissions and Trust Boundary' \
    "$label removes the overcorrected heading"
done

assert_fixed "$SKILL" 'tools.sessions.visibility = "all"' \
  "SKILL.md retains exact all-session permission details"
assert_fixed "$SKILL" 'tools.agentToAgent.enabled = true' \
  "SKILL.md retains exact agent-to-agent permission details"
assert_fixed "$SKILL" 'sandbox.mode = "off"' \
  "SKILL.md retains exact sandbox details"
assert_fixed "$SKILL" 'Optional model tests run only when requested' \
  "SKILL.md retains external-model consent guidance"

assert_fixed "$README" '> **What setup changes:**' \
  "README Quick Start explains setup effects before commands"
assert_fixed "$GUIDE" '> **What setup changes:**' \
  "User Guide Quick Start explains setup effects before commands"
assert_fixed "$CHANGELOG" 'ANT-165-006' "changelog records the disclosure repair"
assert_fixed "$CHANGELOG" 'leads with authenticated inter-host messaging' \
  "changelog records the user-first copy correction"
assert_absent "$CHANGELOG" '(scanner|classif(y|ication)|low[ -]privilege)' \
  "changelog contains no scanner-directed copy"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
(( FAIL == 0 ))
