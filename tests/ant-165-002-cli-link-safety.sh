#!/usr/bin/env bash
# ANT-165-002 — CLI-link installation, replacement, rollback, upgrade, and
# uninstall ownership safety.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165002.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
# shellcheck source=../lib/cli-link.sh
source "$ROOT/lib/cli-link.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

BIN="$TMP/bin"
mkdir -p "$BIN"
OLD="$TMP/old/bin/antenna.sh"
NEW="$TMP/new/bin/antenna.sh"
FOREIGN="$TMP/foreign/bin/antenna.sh"
mkdir -p "$(dirname "$OLD")" "$(dirname "$NEW")" "$(dirname "$FOREIGN")"
printf '#!/usr/bin/env bash\necho old\n' >"$OLD"
printf '#!/usr/bin/env bash\necho new\n' >"$NEW"
printf '#!/usr/bin/env bash\necho foreign\n' >"$FOREIGN"
chmod +x "$OLD" "$NEW" "$FOREIGN"

# ── Install and idempotence ─────────────────────────────────────────────────
link="$BIN/antenna"
check "install/missing target creates symlink" cli_link_apply "$link" "$NEW" "" false
check "install/missing target points exactly at Antenna" test "$(readlink -f "$link")" = "$NEW"
inode_before="$(stat -c %i "$link")"
check "install/correct link is accepted idempotently" cli_link_apply "$link" "$NEW" "" false
check "install/correct link reports unchanged" test "$CLI_LINK_ACTION" = unchanged
check "install/correct link inode remains unchanged" test "$(stat -c %i "$link")" = "$inode_before"

missing_desired="$TMP/missing/bin/antenna.sh"
missing_link="$BIN/missing-antenna"
if cli_link_apply "$missing_link" "$missing_desired" "" false; then
  fail "install/missing dispatcher is refused"
else
  check "install/missing dispatcher returns policy refusal" test "$?" -eq 10
fi
check "install/missing dispatcher creates no dangling command" test ! -L "$missing_link"

# ── Default refusal states ───────────────────────────────────────────────────
rm -- "$link"
ln -s "$FOREIGN" "$link"
foreign_literal="$(readlink "$link")"
if cli_link_apply "$link" "$NEW" "" false; then
  fail "install/foreign symlink is refused by default"
else
  check "install/foreign symlink returns policy refusal" test "$?" -eq 10
fi
check "install/foreign symlink remains byte-for-byte unchanged" test "$(readlink "$link")" = "$foreign_literal"

rm -- "$link"
printf 'foreign-command\n' >"$link"
foreign_hash="$(sha256sum "$link" | awk '{print $1}')"
if cli_link_apply "$link" "$NEW" "" false; then
  fail "install/regular file is refused by default"
else
  check "install/regular file returns policy refusal" test "$?" -eq 10
fi
check "install/regular file remains unchanged" test "$(sha256sum "$link" | awk '{print $1}')" = "$foreign_hash"

rm -- "$link"
mkdir "$link"
if cli_link_apply "$link" "$NEW" "" true; then
  fail "install/directory is refused even with explicit replacement"
else
  check "install/directory returns policy refusal" test "$?" -eq 10
fi
check "install/directory remains a directory" test -d "$link"

rmdir "$link"
mkfifo "$link"
if cli_link_apply "$link" "$NEW" "" true; then
  fail "install/special file is refused even with explicit replacement"
else
  check "install/special file returns policy refusal" test "$?" -eq 10
fi
check "install/special file remains a FIFO" test -p "$link"

# ── Explicit replacement and recoverable backups ────────────────────────────
rm -- "$link"
ln -s "$FOREIGN" "$link"
check "install/explicit foreign-symlink replacement succeeds" cli_link_apply "$link" "$NEW" "" true
symlink_backup="$CLI_LINK_BACKUP"
check "install/replacement points at Antenna" test "$(readlink -f "$link")" = "$NEW"
check "install/displaced symlink is preserved" test -L "$symlink_backup"
check "install/displaced symlink retains its target" test "$(readlink "$symlink_backup")" = "$FOREIGN"
check "install/backup container is mode 0700" test "$(stat -c %a "$(dirname "$symlink_backup")")" = 700

rm -- "$link"
printf 'foreign-regular\n' >"$link"
check "install/explicit regular-file replacement succeeds" cli_link_apply "$link" "$NEW" "" true
regular_backup="$CLI_LINK_BACKUP"
check "install/displaced regular file is preserved" grep -qx 'foreign-regular' "$regular_backup"
check "install/regular replacement points at Antenna" test "$(readlink -f "$link")" = "$NEW"

# ── Upgrade and rollback ─────────────────────────────────────────────────────
rm -- "$link"
ln -s "$OLD" "$link"
check "upgrade/source-owned link repoints safely" cli_link_apply "$link" "$NEW" "$OLD" false
upgrade_backup="$CLI_LINK_BACKUP"
check "upgrade/repointed link targets new release" test "$(readlink -f "$link")" = "$NEW"
check "upgrade/old link is retained for rollback" test "$(readlink -f "$upgrade_backup")" = "$OLD"

# Simulate link creation failure after the displaced command is backed up.
# The helper must restore the original pathname instead of stranding it.
rm -- "$link"
printf 'rollback-me\n' >"$link"
mkdir -p "$TMP/fail-bin"
cat >"$TMP/fail-bin/ln" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/fail-bin/ln"
if PATH="$TMP/fail-bin:$PATH" cli_link_apply "$link" "$NEW" "" true; then
  fail "rollback/link-creation failure returns nonzero"
else
  check "rollback/link-creation failure reports filesystem error" test "$?" -eq 2
fi
check "rollback/original regular file is restored" grep -qx 'rollback-me' "$link"
check "rollback/action reports restored transaction" test "$CLI_LINK_ACTION" = rolled_back

# ── Uninstall exact ownership ────────────────────────────────────────────────
rm -- "$link"
ln -s "$NEW" "$link"
check "uninstall/dry-run recognizes exact owned link" cli_link_remove_if_owned "$link" "$NEW" true
check "uninstall/dry-run leaves owned link present" test -L "$link"
check "uninstall/exact owned link is removed" cli_link_remove_if_owned "$link" "$NEW" false
check "uninstall/owned link pathname is absent" test ! -e "$link"

ln -s "$TMP/missing-foreign-command" "$link"
if cli_link_remove_if_owned "$link" "$NEW" false; then
  fail "uninstall/foreign dangling symlink is preserved"
else
  check "uninstall/foreign dangling link returns policy refusal" test "$?" -eq 10
fi
check "uninstall/foreign dangling symlink remains" test -L "$link"

rm -- "$link"
ln -s "${NEW}-other" "$link"
if cli_link_remove_if_owned "$link" "$NEW" false; then
  fail "uninstall/prefix-matching foreign symlink is preserved"
else
  check "uninstall/prefix-matching link returns policy refusal" test "$?" -eq 10
fi
check "uninstall/prefix-matching foreign link remains" test -L "$link"

# Real uninstall fixture: a dangling foreign symlink at the standard user path
# survives the shipped uninstaller, while runtime cleanup still completes.
UNINSTALL_ROOT="$TMP/uninstall-case"
UNINSTALL_SKILL="$UNINSTALL_ROOT/skill"
UNINSTALL_HOME="$UNINSTALL_ROOT/home"
mkdir -p "$UNINSTALL_SKILL/scripts" "$UNINSTALL_SKILL/lib" "$UNINSTALL_SKILL/bin" \
  "$UNINSTALL_HOME/.local/bin"
cp "$ROOT/scripts/antenna-uninstall.sh" "$UNINSTALL_SKILL/scripts/"
cp "$ROOT/lib/cli-link.sh" "$ROOT/lib/v163-staging-cleanup.sh" \
  "$ROOT/lib/change-plan.sh" "$UNINSTALL_SKILL/lib/"
printf '#!/usr/bin/env bash\n' >"$UNINSTALL_SKILL/bin/antenna.sh"
ln -s "$UNINSTALL_ROOT/missing-foreign" "$UNINSTALL_HOME/.local/bin/antenna"
uninstall_output="$(HOME="$UNINSTALL_HOME" USER=fixture \
  bash "$UNINSTALL_SKILL/scripts/antenna-uninstall.sh" --yes --keep-gateway-config 2>&1)"
check "uninstall/script preserves dangling foreign standard link" test -L "$UNINSTALL_HOME/.local/bin/antenna"
check "uninstall/script reports preserved foreign target" grep -Fq \
  'Preserving CLI target not proven to belong to this install' <<<"$uninstall_output"

# ── Real setup fixture ───────────────────────────────────────────────────────
SETUP_ROOT="$TMP/setup-case"
SETUP_SKILL="$SETUP_ROOT/skill"
SETUP_HOME="$SETUP_ROOT/home"
mkdir -p "$SETUP_SKILL" "$SETUP_HOME/.openclaw" "$SETUP_HOME/.local/bin" "$SETUP_HOME/bin"
cp -a "$ROOT/scripts" "$ROOT/lib" "$ROOT/bin" "$ROOT/agent" "$SETUP_SKILL/"
printf '{"agents":{"list":[{"id":"betty"}]},"hooks":{"token":"fixture-token-012345678901234567890123456789"}}\n' \
  >"$SETUP_HOME/.openclaw/openclaw.json"
printf 'fixture-token-012345678901234567890123456789\n' >"$SETUP_HOME/hooks.token"
cat >"$SETUP_HOME/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) echo 'OpenClaw 2026.7.1 (fixture)' ;;
  config) [[ "${2:-}" == validate ]]; jq empty "${OPENCLAW_CONFIG_PATH:?}" ;;
  approvals) exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SETUP_HOME/bin/openclaw"
printf 'foreign-setup-command\n' >"$SETUP_HOME/.local/bin/antenna"
setup_hash="$(sha256sum "$SETUP_HOME/.local/bin/antenna" | awk '{print $1}')"

run_setup_fixture() {
  PATH="$SETUP_HOME/bin:$SETUP_HOME/.local/bin:/usr/bin:/bin" \
    HOME="$SETUP_HOME" USER=fixture \
    bash "$SETUP_SKILL/scripts/antenna-setup.sh" \
      --host-id fixture --display-name Fixture \
      --url https://fixture.example.com --agent-id betty \
      --model fixture/relay --token-file "$SETUP_HOME/hooks.token" --inbox false --yes "$@"
}

setup_output="$(run_setup_fixture 2>&1)"
check "setup/default path reports refusal" grep -Fq 'Refusing to overwrite existing regular_file' <<<"$setup_output"
check "setup/default path preserves foreign command" test \
  "$(sha256sum "$SETUP_HOME/.local/bin/antenna" | awk '{print $1}')" = "$setup_hash"

setup_output="$(run_setup_fixture --force --replace-cli-link "$SETUP_HOME/.local/bin/antenna" 2>&1)"
check "setup/explicit path reports recoverable backup" grep -Fq 'Recoverable displaced target:' <<<"$setup_output"
check "setup/explicit path installs current dispatcher" test \
  "$(readlink -f "$SETUP_HOME/.local/bin/antenna")" = "$SETUP_SKILL/bin/antenna.sh"
setup_backup="$(find "$SETUP_HOME/.local/bin" -mindepth 2 -maxdepth 2 \
  -path '*/antenna.antenna-backup-*/displaced' -print -quit)"
check "setup/explicit path preserves displaced command" grep -qx 'foreign-setup-command' "$setup_backup"

# Static caller contract: the original unconditional deletion must be gone.
if rg -n 'rm -f[[:space:]]+"?\$SYMLINK_TARGET' "$ROOT/scripts/antenna-setup.sh" >/dev/null; then
  fail "setup/source contains unconditional CLI-target deletion"
else
  pass "setup/source contains no unconditional CLI-target deletion"
fi

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]]
