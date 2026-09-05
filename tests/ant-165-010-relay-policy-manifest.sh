#!/usr/bin/env bash
# ANT-165-010 regression: the relay-policy manifest uses a ClawHub-supported
# filename, retains a bounded legacy fallback, and fails closed on ambiguity,
# malformed records, missing files, symlinks, or digest mismatch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/relay-policy.sh"
DEFAULT="$ROOT/lib/relay-policy/agent/AGENTS.md"
CANONICAL="$ROOT/lib/relay-policy/manifest.txt"
LEGACY="$ROOT/lib/relay-policy/manifest.sha256"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165010.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

new_fixture() {
  local name="$1"
  local fixture="$TMP/$name"
  mkdir -p "$fixture/lib/relay-policy/agent"
  cp "$LIB" "$fixture/lib/"
  cp "$DEFAULT" "$fixture/lib/relay-policy/agent/"
  printf '%s\n' "$fixture"
}

fixture_default_ok() {
  bash -c 'source "$1/lib/relay-policy.sh"; relay_policy_default_ok "agent/AGENTS.md"' _ "$1"
}

fixture_expected_hash() {
  bash -c 'source "$1/lib/relay-policy.sh"; relay_policy_expected_hash "agent/AGENTS.md"' _ "$1"
}

fixture_manifest_path() {
  bash -c 'source "$1/lib/relay-policy.sh"; relay_policy_manifest_file' _ "$1"
}

expected_hash="$(sha256sum "$DEFAULT" | awk '{print $1}')"

check "canonical source manifest exists" test -f "$CANONICAL"
check "canonical source manifest is tracked" \
  bash -c 'git -C "$1" ls-files --error-unmatch lib/relay-policy/manifest.txt >/dev/null' _ "$ROOT"
check "canonical manifest has a ClawHub-supported .txt extension" \
  test "${CANONICAL##*.}" = txt
check "legacy source manifest is absent" test ! -e "$LEGACY"
check "ClawHub ignore rules retain the canonical manifest" \
  bash -c '! git check-ignore -q -- "$1"' _ "$CANONICAL"

canonical_fixture="$(new_fixture canonical)"
cp "$CANONICAL" "$canonical_fixture/lib/relay-policy/"
check "canonical manifest resolves" test \
  "$(fixture_manifest_path "$canonical_fixture")" = \
  "$canonical_fixture/lib/relay-policy/manifest.txt"
check "canonical manifest returns the expected digest" test \
  "$(fixture_expected_hash "$canonical_fixture")" = "$expected_hash"
check "canonical packaged default verifies" fixture_default_ok "$canonical_fixture"

legacy_fixture="$(new_fixture legacy)"
cp "$CANONICAL" "$legacy_fixture/lib/relay-policy/manifest.sha256"
check "legacy-only manifest remains compatible" fixture_default_ok "$legacy_fixture"
check "legacy-only resolver selects the old filename" test \
  "$(fixture_manifest_path "$legacy_fixture")" = \
  "$legacy_fixture/lib/relay-policy/manifest.sha256"

both_fixture="$(new_fixture both)"
cp "$CANONICAL" "$both_fixture/lib/relay-policy/manifest.txt"
cp "$CANONICAL" "$both_fixture/lib/relay-policy/manifest.sha256"
check "dual manifests fail as ambiguous" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_manifest_file' _ "$both_fixture"
check "dual manifests cannot verify a packaged default" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_default_ok "agent/AGENTS.md"' _ "$both_fixture"

missing_fixture="$(new_fixture missing)"
check "missing manifest fails closed" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_default_ok "agent/AGENTS.md"' _ "$missing_fixture"

symlink_fixture="$(new_fixture symlink)"
ln -s "$CANONICAL" "$symlink_fixture/lib/relay-policy/manifest.txt"
check "symlinked manifest fails closed" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_default_ok "agent/AGENTS.md"' _ "$symlink_fixture"

short_fixture="$(new_fixture short-hash)"
printf 'abc123  agent/AGENTS.md\n' >"$short_fixture/lib/relay-policy/manifest.txt"
check "short digest fails closed" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_expected_hash "agent/AGENTS.md"' _ "$short_fixture"

upper_fixture="$(new_fixture uppercase-hash)"
printf '%s  agent/AGENTS.md\n' "${expected_hash^^}" >"$upper_fixture/lib/relay-policy/manifest.txt"
check "uppercase digest fails the canonical format" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_expected_hash "agent/AGENTS.md"' _ "$upper_fixture"

separator_fixture="$(new_fixture separator)"
printf '%s agent/AGENTS.md\n' "$expected_hash" >"$separator_fixture/lib/relay-policy/manifest.txt"
check "single-space separator fails closed" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_expected_hash "agent/AGENTS.md"' _ "$separator_fixture"

duplicate_fixture="$(new_fixture duplicate)"
printf '%s  agent/AGENTS.md\n%s  agent/AGENTS.md\n' \
  "$expected_hash" "$expected_hash" >"$duplicate_fixture/lib/relay-policy/manifest.txt"
check "duplicate manifest entry fails closed" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_expected_hash "agent/AGENTS.md"' _ "$duplicate_fixture"

foreign_fixture="$(new_fixture foreign-record)"
printf '%s  agent/AGENTS.md\n%s  ../foreign\n' \
  "$expected_hash" "$expected_hash" >"$foreign_fixture/lib/relay-policy/manifest.txt"
check "unsafe record invalidates the whole manifest" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_expected_hash "agent/AGENTS.md"' _ "$foreign_fixture"

digest_fixture="$(new_fixture wrong-digest)"
printf '%064d  agent/AGENTS.md\n' 0 >"$digest_fixture/lib/relay-policy/manifest.txt"
check "wrong digest cannot verify the packaged default" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_default_ok "agent/AGENTS.md"' _ "$digest_fixture"

tamper_fixture="$(new_fixture tampered-default)"
cp "$CANONICAL" "$tamper_fixture/lib/relay-policy/manifest.txt"
printf '\n# tampered\n' >>"$tamper_fixture/lib/relay-policy/agent/AGENTS.md"
check "tampered packaged default fails closed" \
  bash -c 'source "$1/lib/relay-policy.sh"; ! relay_policy_default_ok "agent/AGENTS.md"' _ "$tamper_fixture"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
(( FAIL == 0 ))
