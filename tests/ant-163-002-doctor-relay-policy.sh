#!/usr/bin/env bash
# ANT-163-002 — Doctor relay-policy audit (read-only) and explicit restore.
#
# Proves: exact match passes; intentional customization warns and is NOT
# overwritten; missing / symlink / generic-template / marker-free fail; restore
# previews, requires confirmation (or --yes), backs up first, restores
# atomically from the LOCAL package, verifies by hash, and never touches
# OpenClaw-created workspace files. File size is never used as a signal.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$ROOT/scripts/antenna-doctor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

DEFAULT_HASH="$(awk '$2=="agent/AGENTS.md" {print $1}' "$ROOT/lib/relay-policy/manifest.sha256")"

# Build an isolated skill dir carrying only what doctor needs.
new_skill() {
  local sk="$TMP/skill-$1"
  mkdir -p "$sk/scripts" "$sk/lib/relay-policy/agent" "$sk/agent"
  cp "$DOCTOR" "$sk/scripts/"
  cp "$ROOT"/lib/*.sh "$sk/lib/"
  cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$sk/lib/relay-policy/agent/"
  cp "$ROOT/lib/relay-policy/manifest.sha256" "$sk/lib/relay-policy/"
  printf '%s\n' "$sk"
}

# Run the read-only audit (section 1c) with no gateway; capture its output.
audit_out() {
  local sk="$1"
  bash "$sk/scripts/antenna-doctor.sh" --gateway "$sk/nonexistent.json" </dev/null 2>&1
}

# ── Audit: exact match passes ───────────────────────────────────────────────
sk="$(new_skill pass)"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$sk/agent/AGENTS.md"
out="$(audit_out "$sk")"
check "exact match: audit passes" grep -Fq "matches the packaged relay policy" <<<"$out"

# ── Audit: intentional customization warns and is not overwritten ───────────
sk="$(new_skill warn)"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$sk/agent/AGENTS.md"
printf '\n<!-- operator note: local tweak -->\n' >> "$sk/agent/AGENTS.md"
before="$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"
out="$(audit_out "$sk")"
check "customized: audit warns" grep -Fq "differs from the packaged relay policy" <<<"$out"
check "customized: read-only audit does not overwrite" test \
  "$before" = "$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"

# ── Audit: missing fails ────────────────────────────────────────────────────
sk="$(new_skill missing)"
out="$(audit_out "$sk")"
check "missing: audit fails" grep -Fq "is not a valid Antenna relay policy" <<<"$out"
check "missing: reason names missing file" grep -Fq "missing policy file" <<<"$out"

# ── Audit: symlink fails ────────────────────────────────────────────────────
sk="$(new_skill symlink)"
ln -s "$sk/lib/relay-policy/agent/AGENTS.md" "$sk/agent/AGENTS.md"
out="$(audit_out "$sk")"
check "symlink: audit fails" grep -Fq "symlinked policy file" <<<"$out"

# ── Audit: generic OpenClaw template fails ──────────────────────────────────
sk="$(new_skill generic)"
printf '# AGENTS.md - Your Workspace\n\nWelcome to your workspace.\n' > "$sk/agent/AGENTS.md"
out="$(audit_out "$sk")"
check "generic template: audit fails" grep -Fq "identity marker" <<<"$out"

# ── Audit: marker-free / malformed fails ────────────────────────────────────
sk="$(new_skill markerfree)"
printf 'random content without the antenna marker\n' > "$sk/agent/AGENTS.md"
out="$(audit_out "$sk")"
check "marker-free: audit fails" grep -Fq "is not a valid Antenna relay policy" <<<"$out"

# ── Audit ignores byte size (identical size, different bytes still warns) ────
sk="$(new_skill samesize)"
src="$ROOT/lib/relay-policy/agent/AGENTS.md"
python3 - "$src" "$sk/agent/AGENTS.md" <<'PY'
import sys
data=open(sys.argv[1],'rb').read()
# Flip one byte in the body (keep the marker line intact, keep same length).
b=bytearray(data)
i=len(b)-1
b[i]= b[i]^0x20 if chr(b[i]).isalpha() else (ord('X') if b[i]!=ord('X') else ord('Y'))
open(sys.argv[2],'wb').write(bytes(b))
PY
same_len=$( [ "$(wc -c <"$src")" -eq "$(wc -c <"$sk/agent/AGENTS.md")" ] && echo yes || echo no )
check "tamper keeps identical byte length" test "$same_len" = yes
out="$(audit_out "$sk")"
check "same-size tamper: audit still warns (size not used)" grep -Fq "differs from the packaged relay policy" <<<"$out"

# ── Restore: refuses without confirmation (non-interactive, no --yes) ───────
sk="$(new_skill norestore)"
printf '# AGENTS.md - Your Workspace\n\ngeneric\n' > "$sk/agent/AGENTS.md"
before="$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"
out="$(bash "$sk/scripts/antenna-doctor.sh" --restore-policy </dev/null 2>&1)"; rc=$?
check "restore without --yes refuses (nonzero)" test "$rc" -ne 0
check "restore without --yes changes nothing" test \
  "$before" = "$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"

# ── Restore: --yes backs up first, restores atomically, verifies hash ───────
sk="$(new_skill dorestore)"
printf '# AGENTS.md - Your Workspace\n\ngeneric seeded by OpenClaw\n' > "$sk/agent/AGENTS.md"
# An unrelated OpenClaw-created workspace file that must never be touched.
printf 'soul state\n' > "$sk/agent/SOUL.md"
soul_before="$(sha256sum "$sk/agent/SOUL.md" | awk '{print $1}')"
out="$(bash "$sk/scripts/antenna-doctor.sh" --restore-policy --yes </dev/null 2>&1)"; rc=$?
check "restore --yes succeeds" test "$rc" -eq 0
check "restore installs packaged default (hash matches manifest)" test \
  "$DEFAULT_HASH" = "$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"
check "restore reports resulting hash" grep -Fq "$DEFAULT_HASH" <<<"$out"
backup_count=$(find "$sk/agent" -maxdepth 1 -type d -name '.antenna-relay-backup-*' | wc -l)
check "restore created exactly one timestamped backup" test "$backup_count" -eq 1
bkp="$(find "$sk/agent" -maxdepth 2 -path '*/.antenna-relay-backup-*/AGENTS.md' | head -n1)"
check "backup preserves the pre-restore content" grep -Fq "generic seeded by OpenClaw" "$bkp"
bperm=$(stat -c '%a' "$bkp" 2>/dev/null || echo unknown)
check "backup is private (600)" test "$bperm" = 600
check "restore left the unrelated SOUL.md untouched" test \
  "$soul_before" = "$(sha256sum "$sk/agent/SOUL.md" | awk '{print $1}')"

# ── Restore: replaces a symlink with a regular file, target left alone ──────
sk="$(new_skill symrestore)"
printf 'external target contents\n' > "$sk/external.md"
ext_before="$(sha256sum "$sk/external.md" | awk '{print $1}')"
ln -s "$sk/external.md" "$sk/agent/AGENTS.md"
out="$(bash "$sk/scripts/antenna-doctor.sh" --restore-policy --yes </dev/null 2>&1)"; rc=$?
check "restore over symlink succeeds" test "$rc" -eq 0
check "restore replaced symlink with a regular file" test \
  \( ! -L "$sk/agent/AGENTS.md" \) -a -f "$sk/agent/AGENTS.md"
check "restore installed the packaged default over the symlink" test \
  "$DEFAULT_HASH" = "$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"
check "restore left the symlink target file untouched" test \
  "$ext_before" = "$(sha256sum "$sk/external.md" | awk '{print $1}')"
symlink_evidence="$(find "$sk/agent" -maxdepth 2 -path '*/.antenna-relay-backup-*/AGENTS.md' -type l | head -n1)"
check "restore preserves symlink evidence without following it" test -L "$symlink_evidence"

# ── Restore: refuses to restore from a tampered package (fail-closed) ───────
sk="$(new_skill badpkg)"
printf 'tampered package default without marker\n' > "$sk/lib/relay-policy/agent/AGENTS.md"
printf '# AGENTS.md - Your Workspace\n\ngeneric\n' > "$sk/agent/AGENTS.md"
live_before="$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"
out="$(bash "$sk/scripts/antenna-doctor.sh" --restore-policy --yes </dev/null 2>&1)"; rc=$?
check "restore from tampered package refuses (nonzero)" test "$rc" -ne 0
check "restore from tampered package explains why" grep -Fq "untrusted package" <<<"$out"
check "restore from tampered package changes nothing" test \
  "$live_before" = "$(sha256sum "$sk/agent/AGENTS.md" | awk '{print $1}')"

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
