#!/usr/bin/env bash
# ANT-165-008 — Administrative lifecycle commands preview persistent changes,
# require one consent boundary, and preserve explicit automation.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/antenna-ant165008.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

line_of() {
  local needle="$1" file="$2"
  grep -n -F -m1 "$needle" "$file" | cut -d: -f1
}

# ── Shared consent semantics ────────────────────────────────────────────────

# shellcheck source=../lib/change-plan.sh
source "$ROOT/lib/change-plan.sh"
antenna_change_plan_reset "Fixture change plan"
antenna_change_plan_add "Change one fixture file"
helper_out="$TMP/helper.out"
antenna_change_plan_show >"$helper_out"
check "shared helper prints one concise plan heading" test \
  "$(grep -Fc 'Planned changes:' "$helper_out")" -eq 1
check "shared helper prints the supplied effect" grep -Fq \
  'Change one fixture file' "$helper_out"

if antenna_change_plan_confirm false </dev/null >"$TMP/non-tty.out" 2>&1; then
  fail "non-interactive helper requires explicit authorization"
else
  helper_rc=$?
  check "non-interactive refusal returns status 2" test "$helper_rc" -eq 2
fi
check "non-interactive refusal names --yes" grep -Fq -- '--yes' "$TMP/non-tty.out"
check "explicit automation authorization succeeds without a prompt" \
  antenna_change_plan_confirm true

if command -v script >/dev/null 2>&1; then
  pty_out="$TMP/helper-pty.out"
  printf 'y\n' | script -qefc \
    "bash -c 'source \"$ROOT/lib/change-plan.sh\"; antenna_change_plan_confirm false \"Proceed with fixture?\"'" \
    "$pty_out" >/dev/null
  check "interactive helper presents exactly one confirmation" test \
    "$(grep -Fc 'Proceed with fixture? [y/N]:' "$pty_out")" -eq 1
else
  pass "interactive prompt count skipped because script(1) is unavailable"
fi

# ── Setup: preview precedes token and configuration writes ─────────────────

SETUP_ROOT="$TMP/setup"
SETUP_SKILL="$SETUP_ROOT/skill"
SETUP_HOME="$SETUP_ROOT/home"
mkdir -p "$SETUP_SKILL/scripts" "$SETUP_SKILL/bin" \
  "$SETUP_SKILL/lib/relay-policy/agent" "$SETUP_SKILL/agent" \
  "$SETUP_HOME/.openclaw" "$SETUP_HOME/.local/bin" "$SETUP_HOME/bin"
cp "$ROOT/scripts/antenna-setup.sh" "$SETUP_SKILL/scripts/"
cp "$ROOT"/lib/*.sh "$SETUP_SKILL/lib/"
cp "$ROOT/lib/relay-policy/manifest.sha256" "$SETUP_SKILL/lib/relay-policy/"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$SETUP_SKILL/lib/relay-policy/agent/"
cp "$ROOT/agent/AGENTS.md" "$SETUP_SKILL/agent/"
cp "$ROOT/bin/antenna.sh" "$SETUP_SKILL/bin/"
cat >"$SETUP_HOME/.openclaw/openclaw.json" <<JSON
{
  "agents": {"list": [{"id": "betty", "workspace": "$SETUP_HOME/workspace"}]},
  "hooks": {"token": "fixture-hooks-token-012345678901234567890123"}
}
JSON
cat >"$SETUP_HOME/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) echo 'OpenClaw 2026.7.1 (fixture)' ;;
  config) [[ "${2:-}" == validate ]]; jq empty "${OPENCLAW_CONFIG_PATH:?}" ;;
  approvals) exit 0 ;;
  models) exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$SETUP_HOME/bin/openclaw" "$SETUP_SKILL/scripts/antenna-setup.sh"
setup_gateway_hash="$(sha256sum "$SETUP_HOME/.openclaw/openclaw.json" | awk '{print $1}')"

run_setup() {
  PATH="$SETUP_HOME/bin:$SETUP_HOME/.local/bin:/usr/bin:/bin" \
    HOME="$SETUP_HOME" USER=fixture \
    bash "$SETUP_SKILL/scripts/antenna-setup.sh" \
      --host-id fixture --display-name Fixture \
      --url https://fixture.example.com --agent-id betty \
      --model fixture/relay --token-file auto --inbox false "$@"
}

if command -v script >/dev/null 2>&1; then
  setup_pty_out="$TMP/setup-decline-pty.out"
  printf '\n\nhttps://fixture.example.com\n\n\nn\ny\ny\nn\n' | \
    script -qefc \
      "env PATH='$SETUP_HOME/bin:$SETUP_HOME/.local/bin:/usr/bin:/bin' HOME='$SETUP_HOME' USER=fixture bash '$SETUP_SKILL/scripts/antenna-setup.sh'" \
      "$setup_pty_out" >/dev/null
  check "interactive setup asks for administrative consent once" test \
    "$(grep -Fc 'Proceed with Antenna setup? [y/N]:' "$setup_pty_out")" -eq 1
  check "declined interactive setup creates no runtime config" test ! -e "$SETUP_SKILL/antenna-config.json"
  check "declined interactive setup creates no token directory" test ! -e "$SETUP_SKILL/secrets"
  check "declined interactive setup preserves gateway bytes" test \
    "$(sha256sum "$SETUP_HOME/.openclaw/openclaw.json" | awk '{print $1}')" = "$setup_gateway_hash"
else
  pass "interactive setup decline skipped because script(1) is unavailable"
  pass "interactive setup no-runtime assertion skipped because script(1) is unavailable"
  pass "interactive setup no-token assertion skipped because script(1) is unavailable"
  pass "interactive setup gateway assertion skipped because script(1) is unavailable"
fi

set +e
run_setup </dev/null >"$TMP/setup-refuse.out" 2>&1
setup_refuse_rc=$?
set -e
check "setup without --yes refuses non-interactive mutation" test "$setup_refuse_rc" -eq 2
check "setup refusal displays the plan" grep -Fq 'Antenna setup change plan' "$TMP/setup-refuse.out"
check "setup plan names sandbox posture" grep -Fq 'sandbox mode off' "$TMP/setup-refuse.out"
check "setup plan names hook and session allowlists" grep -Fq \
  'hook/session allowlist entries' "$TMP/setup-refuse.out"
check "setup plan names session visibility" grep -Fq \
  'session visibility to all' "$TMP/setup-refuse.out"
check "setup plan names token handling" grep -Fq \
  'Register the hook token only' "$TMP/setup-refuse.out"
check "setup refusal creates no runtime config" test ! -e "$SETUP_SKILL/antenna-config.json"
check "setup refusal creates no token directory" test ! -e "$SETUP_SKILL/secrets"
check "setup refusal creates no gateway backup" test ! -e "$SETUP_HOME/.openclaw/openclaw.json.antenna-backup"
check "setup refusal preserves gateway bytes" test \
  "$(sha256sum "$SETUP_HOME/.openclaw/openclaw.json" | awk '{print $1}')" = "$setup_gateway_hash"

run_setup --yes >"$TMP/setup-yes.out" 2>&1
check "authorized setup creates runtime config" test -f "$SETUP_SKILL/antenna-config.json"
check "authorized setup creates protected token" test \
  "$(stat -c %a "$SETUP_SKILL/secrets/hooks_token_fixture")" = 600
check "authorized setup updates gateway" jq -e \
  'any(.agents.list[]; .id == "antenna") and .hooks.enabled == true' \
  "$SETUP_HOME/.openclaw/openclaw.json"
setup_plan_line="$(line_of 'Antenna setup change plan' "$TMP/setup-yes.out")"
setup_token_line="$(line_of 'Created protected token file' "$TMP/setup-yes.out")"
setup_config_line="$(line_of 'Created ' "$TMP/setup-yes.out")"
check "setup plan precedes token materialization" test \
  "$setup_plan_line" -lt "$setup_token_line"
check "setup plan precedes runtime configuration" test \
  "$setup_plan_line" -lt "$setup_config_line"
check "authorized setup prints no confirmation prompt" \
  bash -c '! grep -Fq "Proceed with Antenna setup?" "$1"' _ "$TMP/setup-yes.out"

# ── Upgrade: preview and explicit non-interactive authorization ─────────────

UPGRADE_ROOT="$TMP/upgrade"
OLD="$UPGRADE_ROOT/old"
NEW="$UPGRADE_ROOT/new"
UPGRADE_HOME="$UPGRADE_ROOT/home"
mkdir -p "$OLD/bin" "$OLD/agent" "$NEW/scripts" "$NEW/bin" \
  "$NEW/lib/relay-policy/agent" "$NEW/agent" \
  "$UPGRADE_HOME/.openclaw" "$UPGRADE_HOME/.local/bin" "$UPGRADE_HOME/bin"
cp "$ROOT/scripts/antenna-upgrade.sh" "$NEW/scripts/"
cp "$ROOT"/lib/*.sh "$NEW/lib/"
cp "$ROOT/lib/relay-policy/manifest.sha256" "$NEW/lib/relay-policy/"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$NEW/lib/relay-policy/agent/"
cp "$ROOT/agent/AGENTS.md" "$NEW/agent/"
cp "$ROOT/bin/antenna.sh" "$NEW/bin/"
printf '#!/usr/bin/env bash\n' >"$OLD/bin/antenna.sh"
jq -n --arg old "$OLD" '{install_path:$old}' >"$OLD/antenna-config.json"
printf '%s\n' '{"fixture":{"self":true,"url":"https://fixture.example.com"}}' \
  >"$OLD/antenna-peers.json"
cat >"$UPGRADE_HOME/.openclaw/openclaw.json" <<JSON
{"agents":{"list":[{"id":"betty"},{"id":"antenna","workspace":"$OLD/agent","agentDir":"$UPGRADE_HOME/.openclaw/agents/antenna/agent"}]}}
JSON
cat >"$UPGRADE_HOME/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo 'OpenClaw 2026.7.1 (fixture)'
  exit 0
elif [[ "${1:-}" == config && "${2:-}" == validate ]]; then
  jq empty "${OPENCLAW_CONFIG_PATH:?}"
  exit $?
fi
exit 2
STUB
chmod +x "$UPGRADE_HOME/bin/openclaw" "$NEW/scripts/antenna-upgrade.sh"
ln -s "$OLD/bin/antenna.sh" "$UPGRADE_HOME/.local/bin/antenna"
upgrade_gateway_hash="$(sha256sum "$UPGRADE_HOME/.openclaw/openclaw.json" | awk '{print $1}')"

run_upgrade() {
  PATH="$UPGRADE_HOME/bin:$UPGRADE_HOME/.local/bin:/usr/bin:/bin" \
    HOME="$UPGRADE_HOME" USER=fixture \
    bash "$NEW/scripts/antenna-upgrade.sh" --from "$OLD" \
      --gateway "$UPGRADE_HOME/.openclaw/openclaw.json" "$@"
}

if command -v script >/dev/null 2>&1; then
  upgrade_pty_out="$TMP/upgrade-decline-pty.out"
  printf 'n\n' | script -qefc \
    "env PATH='$UPGRADE_HOME/bin:$UPGRADE_HOME/.local/bin:/usr/bin:/bin' HOME='$UPGRADE_HOME' USER=fixture bash '$NEW/scripts/antenna-upgrade.sh' --from '$OLD' --gateway '$UPGRADE_HOME/.openclaw/openclaw.json'" \
    "$upgrade_pty_out" >/dev/null
  check "interactive upgrade asks for administrative consent once" test \
    "$(grep -Fc 'Proceed with Antenna upgrade? [y/N]:' "$upgrade_pty_out")" -eq 1
  check "declined interactive upgrade installs no destination runtime" test ! -e "$NEW/antenna-config.json"
  check "declined interactive upgrade preserves gateway bytes" test \
    "$(sha256sum "$UPGRADE_HOME/.openclaw/openclaw.json" | awk '{print $1}')" = "$upgrade_gateway_hash"
else
  pass "interactive upgrade decline skipped because script(1) is unavailable"
  pass "interactive upgrade no-runtime assertion skipped because script(1) is unavailable"
  pass "interactive upgrade gateway assertion skipped because script(1) is unavailable"
fi

set +e
run_upgrade </dev/null >"$TMP/upgrade-refuse.out" 2>&1
upgrade_refuse_rc=$?
set -e
if [[ "$upgrade_refuse_rc" -ne 2 ]]; then
  sed 's/^/  diagnostic: /' "$TMP/upgrade-refuse.out" >&2
fi
check "upgrade without --yes refuses non-interactive mutation" test "$upgrade_refuse_rc" -eq 2
check "upgrade refusal displays the plan" grep -Fq 'Antenna upgrade change plan' "$TMP/upgrade-refuse.out"
check "upgrade refusal installs no destination runtime" test ! -e "$NEW/antenna-config.json"
check "upgrade refusal preserves gateway bytes" test \
  "$(sha256sum "$UPGRADE_HOME/.openclaw/openclaw.json" | awk '{print $1}')" = "$upgrade_gateway_hash"
check "upgrade refusal creates no gateway backup" \
  bash -c '! compgen -G "$1.antenna-upgrade-backup-*" >/dev/null' _ \
  "$UPGRADE_HOME/.openclaw/openclaw.json"

run_upgrade --yes >"$TMP/upgrade-yes.out" 2>&1
check "authorized upgrade migrates runtime state" test -f "$NEW/antenna-config.json"
check "authorized upgrade repoints the CLI" test \
  "$(readlink -f "$UPGRADE_HOME/.local/bin/antenna")" = "$NEW/bin/antenna.sh"
upgrade_plan_line="$(line_of 'Antenna upgrade change plan' "$TMP/upgrade-yes.out")"
upgrade_copy_line="$(line_of 'Copied runtime state' "$TMP/upgrade-yes.out")"
check "upgrade plan precedes persistent migration" test \
  "$upgrade_plan_line" -lt "$upgrade_copy_line"
check "authorized upgrade prints no confirmation prompt" \
  bash -c '! grep -Fq "Proceed with Antenna upgrade?" "$1"' _ "$TMP/upgrade-yes.out"

# ── Uninstall: existing dry run and explicit automation stay intact ─────────

UNINSTALL_ROOT="$TMP/uninstall"
UNINSTALL_SKILL="$UNINSTALL_ROOT/skill"
UNINSTALL_HOME="$UNINSTALL_ROOT/home"
mkdir -p "$UNINSTALL_SKILL/scripts" "$UNINSTALL_SKILL/lib" \
  "$UNINSTALL_SKILL/bin" "$UNINSTALL_HOME/.local/bin"
cp "$ROOT/scripts/antenna-uninstall.sh" "$UNINSTALL_SKILL/scripts/"
cp "$ROOT/lib/cli-link.sh" "$ROOT/lib/v163-staging-cleanup.sh" \
  "$ROOT/lib/change-plan.sh" "$UNINSTALL_SKILL/lib/"
printf '#!/usr/bin/env bash\n' >"$UNINSTALL_SKILL/bin/antenna.sh"
printf '{}\n' >"$UNINSTALL_SKILL/antenna-config.json"
printf '{}\n' >"$UNINSTALL_SKILL/antenna-peers.json"
ln -s "$UNINSTALL_SKILL/bin/antenna.sh" "$UNINSTALL_HOME/.local/bin/antenna"

run_uninstall() {
  HOME="$UNINSTALL_HOME" USER=fixture \
    bash "$UNINSTALL_SKILL/scripts/antenna-uninstall.sh" \
      --keep-gateway-config "$@"
}

run_uninstall --dry-run </dev/null >"$TMP/uninstall-dry.out" 2>&1
check "uninstall dry run needs no confirmation" grep -Fq \
  'Dry run only; no confirmation is required' "$TMP/uninstall-dry.out"
check "uninstall dry run preserves runtime" test -f "$UNINSTALL_SKILL/antenna-config.json"

set +e
run_uninstall </dev/null >"$TMP/uninstall-refuse.out" 2>&1
uninstall_refuse_rc=$?
set -e
check "uninstall without --yes refuses non-interactive mutation" test "$uninstall_refuse_rc" -eq 2
check "uninstall refusal preserves runtime" test -f "$UNINSTALL_SKILL/antenna-config.json"
check "uninstall plan names preserved gateway settings" grep -Fq \
  'leave gateway agent, hooks, allowlists, session visibility, and sandbox settings unchanged' \
  "$TMP/uninstall-refuse.out"
run_uninstall --yes >"$TMP/uninstall-yes.out" 2>&1
check "authorized uninstall removes runtime" test ! -e "$UNINSTALL_SKILL/antenna-config.json"
check "authorized uninstall removes its owned CLI link" test ! -L "$UNINSTALL_HOME/.local/bin/antenna"

# Doctor's existing restore regression covers preview, --yes, backups, and
# byte-preserving refusal. Keep this focused ticket wired to the shared helper.
check "relay-policy restore uses shared consent helper" rg -Fq \
  'antenna_change_plan_confirm "$ASSUME_YES"' "$ROOT/scripts/antenna-doctor.sh"

printf '\nPASS=%d FAIL=%d TOTAL=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]]
