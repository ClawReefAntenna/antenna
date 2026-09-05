#!/usr/bin/env bash
# ANT-165-001 regression: URL-validation diagnostics use private,
# unpredictable scratch files and clean them on every exit path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165001.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

scratch_empty() {
  [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

# shellcheck source=../lib/peers.sh
source "$SKILL_REPO/lib/peers.sh"
ORIGINAL_VALIDATOR="$(declare -f validate_peer_url)"

printf '── ANT-165-001: secure URL-check scratch files ────────────────\n'

SCRATCH="$TEST_ROOT/success"
mkdir -m 700 "$SCRATCH"
reason="$(TMPDIR="$SCRATCH" validate_peer_url_capture "https://peer.example.com" false)"
rc=$?
if [[ $rc -eq 0 && -z "$reason" ]] && scratch_empty "$SCRATCH"; then
  pass "accepted URL leaves no scratch file"
else
  fail "accepted URL cleanup (rc=$rc reason='$reason')"
fi

SCRATCH="$TEST_ROOT/rejected"
mkdir -m 700 "$SCRATCH"
reason="$(TMPDIR="$SCRATCH" validate_peer_url_capture "main" false)"
rc=$?
if [[ $rc -eq 1 && "$reason" == *"must start with https://"* ]] && scratch_empty "$SCRATCH"; then
  pass "rejected URL returns its reason and leaves no scratch file"
else
  fail "rejected URL cleanup (rc=$rc reason='$reason')"
fi

SCRATCH="$TEST_ROOT/mode"
MODE_RESULT="$TEST_ROOT/mode-result"
mkdir -m 700 "$SCRATCH"
validate_peer_url() {
  local observed
  observed="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type f -print -quit)"
  [[ -n "$observed" ]] || return 1
  stat -c '%a' "$observed" >"$MODE_RESULT"
  return 0
}
TMPDIR="$SCRATCH" validate_peer_url_capture "https://peer.example.com" false >/dev/null
rc=$?
eval "$ORIGINAL_VALIDATOR"
mode="$(cat "$MODE_RESULT" 2>/dev/null || true)"
if [[ $rc -eq 0 && "$mode" == "600" ]] && scratch_empty "$SCRATCH"; then
  pass "scratch file is mode 0600 while validation runs"
else
  fail "scratch-file mode/cleanup (rc=$rc mode='$mode')"
fi

SCRATCH="$TEST_ROOT/interrupted"
mkdir -m 700 "$SCRATCH"
validate_peer_url() {
  kill -TERM "$BASHPID"
  return 1
}
reason="$(TMPDIR="$SCRATCH" validate_peer_url_capture "https://peer.example.com" false 2>/dev/null)"
rc=$?
eval "$ORIGINAL_VALIDATOR"
if [[ $rc -eq 143 ]] && scratch_empty "$SCRATCH"; then
  pass "TERM interruption leaves no scratch file"
else
  fail "TERM cleanup (rc=$rc reason='$reason')"
fi

MISSING_TMP="$TEST_ROOT/missing/child"
reason="$(TMPDIR="$MISSING_TMP" validate_peer_url_capture "https://peer.example.com" false 2>/dev/null)"
rc=$?
if [[ $rc -eq 2 && "$reason" == *"could not create secure"* && ! -e "$MISSING_TMP" ]]; then
  pass "scratch-creation failure is explicit and leaves no artifact"
else
  fail "scratch-creation failure handling (rc=$rc reason='$reason')"
fi

if rg -n -F '/tmp/antenna-urlcheck.$$' \
    "$SKILL_REPO/scripts/antenna-setup.sh" \
    "$SKILL_REPO/scripts/antenna-exchange.sh" >/dev/null; then
  fail "predictable PID-based URL-check pathname remains"
else
  pass "predictable PID-based URL-check pathname removed"
fi

for caller in scripts/antenna-setup.sh scripts/antenna-exchange.sh; do
  if rg -F 'validate_peer_url_capture' "$SKILL_REPO/$caller" >/dev/null; then
    pass "$caller uses the secure capture helper"
  else
    fail "$caller does not use the secure capture helper"
  fi
done

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ $FAIL -eq 0 ]]
