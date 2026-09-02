#!/usr/bin/env bash
# Package integrity for the Antenna-owned relay policy: the shipped live file,
# the pristine packaged default, and the SHA-256 manifest must stay in lockstep,
# and the identity marker must be present. Catches a future edit to
# agent/AGENTS.md that forgets to regenerate lib/relay-policy/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/relay-policy.sh
source "$ROOT/lib/relay-policy.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

LIVE="$ROOT/agent/AGENTS.md"
DEFAULT="$(relay_policy_default_file "agent/AGENTS.md")"
MANIFEST_HASH="$(relay_policy_expected_hash "agent/AGENTS.md" || true)"

check "manifest lists agent/AGENTS.md" test -n "$MANIFEST_HASH"
check "packaged default self-verifies against manifest" relay_policy_default_ok "agent/AGENTS.md"
check "shipped agent/AGENTS.md matches manifest hash" test \
  "$MANIFEST_HASH" = "$(relay_policy_sha256 "$LIVE")"
check "packaged default matches manifest hash" test \
  "$MANIFEST_HASH" = "$(relay_policy_sha256 "$DEFAULT")"
check "shipped agent/AGENTS.md carries the identity marker" relay_policy_has_marker "$LIVE"
check "packaged default carries the identity marker" relay_policy_has_marker "$DEFAULT"
check "shipped agent/AGENTS.md is a regular file (not a symlink)" test \
  -f "$LIVE" -a ! -L "$LIVE"
check "packaged default is a regular file (not a symlink)" test \
  -f "$DEFAULT" -a ! -L "$DEFAULT"
check "audit of the shipped live file passes" bash -c '
  source "$1/lib/relay-policy.sh"
  out="$(relay_policy_audit "$1/agent/AGENTS.md" "agent/AGENTS.md")"; rc=$?
  [[ "$rc" -eq 0 ]]' _ "$ROOT"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
