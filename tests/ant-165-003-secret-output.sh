#!/usr/bin/env bash
# ANT-165-003 regression: reusable peer secrets stay in protected files by
# default. The value is displayed only after an explicit --show-secret request
# made through an interactive terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165003.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() {
  local description="$1"
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

SKILL="$TMP/skill"
mkdir -p "$SKILL/bin" "$SKILL/scripts" "$SKILL/lib" "$TMP/fake-bin"
cp "$ROOT/bin/antenna.sh" "$SKILL/bin/antenna.sh"
cp -a "$ROOT/lib/." "$SKILL/lib/"
chmod +x "$SKILL/bin/antenna.sh"

cat >"$SKILL/antenna-config.json" <<'JSON'
{"log_path":"antenna.log","allowed_inbound_peers":[],"allowed_outbound_peers":[]}
JSON
cat >"$SKILL/antenna-peers.json" <<'JSON'
{}
JSON

SENTINEL="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
cat >"$TMP/fake-bin/openssl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == rand && "\${2:-}" == -hex && "\${3:-}" == 32 ]]; then
  printf '%s\\n' '$SENTINEL'
  exit 0
fi
exec /usr/bin/openssl "\$@"
EOF
chmod +x "$TMP/fake-bin/openssl"
export PATH="$TMP/fake-bin:$PATH"

echo "── ANT-165-003 protected peer-secret output ──"

OUT="$TMP/default.out"
ERR="$TMP/default.err"
"$SKILL/bin/antenna.sh" peers generate-secret remote-one >"$OUT" 2>"$ERR"
SECRET_FILE="$SKILL/secrets/antenna-peer-remote-one.secret"

check "default generation creates the requested secret file" test -f "$SECRET_FILE"
check "stored secret is the generated 256-bit value" test "$(tr -d '[:space:]' <"$SECRET_FILE")" = "$SENTINEL"
check "secrets directory is mode 700" test "$(stat -c %a "$SKILL/secrets")" = 700
check "stored secret is mode 600" test "$(stat -c %a "$SECRET_FILE")" = 600
if ! grep -Fq "$SENTINEL" "$OUT" "$ERR"; then
  pass "ordinary stdout and stderr do not disclose the secret"
else
  fail "ordinary stdout and stderr do not disclose the secret"
fi
check "ordinary output names the protected file" grep -Fq "$SECRET_FILE" "$OUT"
check "ordinary output labels the value hidden" grep -Fq 'Value: hidden' "$OUT"
if [[ ! -e "$SKILL/antenna.log" ]] || ! grep -Fq "$SENTINEL" "$SKILL/antenna.log"; then
  pass "ordinary generation does not log the secret"
else
  fail "ordinary generation does not log the secret"
fi

NON_TTY_OUT="$TMP/non-tty.out"
NON_TTY_ERR="$TMP/non-tty.err"
if "$SKILL/bin/antenna.sh" peers generate-secret captured --show-secret >"$NON_TTY_OUT" 2>"$NON_TTY_ERR"; then
  fail "--show-secret refuses a non-interactive output path"
else
  pass "--show-secret refuses a non-interactive output path"
fi
check "refused display does not create or rotate a secret" test ! -e "$SKILL/secrets/antenna-peer-captured.secret"
if ! grep -Fq "$SENTINEL" "$NON_TTY_OUT" "$NON_TTY_ERR"; then
  pass "non-interactive refusal emits no credential"
else
  fail "non-interactive refusal emits no credential"
fi
check "non-interactive refusal explains the capture boundary" grep -Fq 'requires an interactive terminal' "$NON_TTY_ERR"

PTY_OUT="$TMP/interactive.out"
script -qefc "$SKILL/bin/antenna.sh peers generate-secret manual-peer --show-secret" "$PTY_OUT" >/dev/null
tr -d '\r' <"$PTY_OUT" >"$TMP/interactive.clean"
MANUAL_FILE="$SKILL/secrets/antenna-peer-manual-peer.secret"
check "explicit interactive display creates a mode-600 file" test "$(stat -c %a "$MANUAL_FILE")" = 600
check "explicit interactive display shows the stored credential" grep -Fq "$SENTINEL" "$TMP/interactive.clean"
check "explicit display carries a reusable-credential warning" grep -Fq 'WARNING: displaying a reusable peer credential' "$TMP/interactive.clean"
check "explicit display recommends encrypted exchange" grep -Fq "Prefer the encrypted 'antenna peers exchange initiate' flow" "$TMP/interactive.clean"

MISSING_OUT="$TMP/missing.out"
MISSING_ERR="$TMP/missing.err"
if "$SKILL/bin/antenna.sh" peers generate-secret >"$MISSING_OUT" 2>"$MISSING_ERR"; then
  fail "missing peer ID is refused"
else
  pass "missing peer ID is refused"
fi
if ! grep -Fq "$SENTINEL" "$MISSING_OUT" "$MISSING_ERR"; then
  pass "missing-ID usage path generates and prints no secret"
else
  fail "missing-ID usage path generates and prints no secret"
fi

if "$SKILL/bin/antenna.sh" peers generate-secret ../escape >"$TMP/escape.out" 2>"$TMP/escape.err"; then
  fail "unsafe peer ID is refused before path construction"
else
  pass "unsafe peer ID is refused before path construction"
fi
check "unsafe peer ID creates no escaped file" test ! -e "$SKILL/escape.secret"

mkdir "$SKILL/secrets/antenna-peer-directory.secret"
if "$SKILL/bin/antenna.sh" peers generate-secret directory >"$TMP/directory.out" 2>"$TMP/directory.err"; then
  fail "directory at the exact secret path is refused"
else
  pass "directory at the exact secret path is refused"
fi
check "refused directory remains a directory" test -d "$SKILL/secrets/antenna-peer-directory.secret"
if find "$SKILL/secrets/antenna-peer-directory.secret" -mindepth 1 -print -quit | grep -q .; then
  fail "refused directory receives no temporary secret child"
else
  pass "refused directory receives no temporary secret child"
fi

if rg -n 'echo .*Secret:|Generated secret: \\$secret|Secret: \\$secret' "$ROOT/bin/antenna.sh" >/dev/null; then
  fail "legacy ordinary secret-print statements are absent"
else
  pass "legacy ordinary secret-print statements are absent"
fi
check "setup uses the protected secret-file helper" rg -Fq 'antenna_secret_generate_hex_file "$SECRET_PATH"' "$ROOT/scripts/antenna-setup.sh"
check "exchange uses the protected secret-file helper" rg -Fq 'antenna_secret_generate_hex_file "$abs"' "$ROOT/scripts/antenna-exchange.sh"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]]
