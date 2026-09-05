#!/usr/bin/env bash
# REL-007: the frozen v1.6.5 package must advertise one coherent release and
# must not carry the unsupported historical postInstall hint.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

check "SKILL metadata declares v1.6.5" grep -Fxq '  version: 1.6.5' "$ROOT/SKILL.md"
check "SKILL heading declares v1.6.5" grep -Fq '# Antenna — Inter-Host OpenClaw Messaging (v1.6.5)' "$ROOT/SKILL.md"
check "unsupported postInstall key is absent" bash -c \
  '! grep -Eq "^[[:space:]]*postInstall:" "$1"' _ "$ROOT/SKILL.md"
check "README version section declares v1.6.5" grep -Fq '**v1.6.5**' "$ROOT/README.md"
check "User Guide declares v1.6.5" grep -Fq '*Version 1.6.5 ·' "$ROOT/references/USER-GUIDE.md"
check "changelog contains the v1.6.5 release" grep -Fq '## [1.6.5] —' "$ROOT/CHANGELOG.md"
check "Doctor directs residue cleanup through v1.6.5" grep -Fq \
  'Run the v1.6.5 upgrade path' "$ROOT/scripts/antenna-doctor.sh"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
