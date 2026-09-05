#!/usr/bin/env bash
# antenna-doctor.sh — Pre-flight and post-install health check for Antenna.
# Verifies gateway config has required entries and is valid JSON.
# Optionally backs up the gateway config before changes.
#
# Usage:
#   antenna doctor                     Full check
#   antenna doctor --backup            Back up openclaw.json before any changes
#   antenna doctor --fix-hints         Show copy-paste fix commands
#   antenna doctor --gateway <path>    Override gateway config path
#
set -uo pipefail
# Note: set -e intentionally omitted — diagnostic tool must not abort on non-fatal failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/antenna-config.json"
PEERS_FILE="$SKILL_DIR/antenna-peers.json"

# shellcheck source=../lib/peers.sh
source "$SKILL_DIR/lib/peers.sh"
# shellcheck source=../lib/config.sh
source "$SKILL_DIR/lib/config.sh"
# shellcheck source=../lib/gateway-roster.sh
source "$SKILL_DIR/lib/gateway-roster.sh"
# shellcheck source=../lib/relay-policy.sh
source "$SKILL_DIR/lib/relay-policy.sh"
# shellcheck source=../lib/v163-staging-cleanup.sh
source "$SKILL_DIR/lib/v163-staging-cleanup.sh"
# shellcheck source=../lib/change-plan.sh
source "$SKILL_DIR/lib/change-plan.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0
FIX_HINTS=false
DO_BACKUP=false
GATEWAY_PATH=""
RESTORE_POLICY=false
ASSUME_YES=false

# ── Helpers ──────────────────────────────────────────────────────────────────

pass() { echo -e "  ${GREEN}✓${NC}  $*"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; WARN=$((WARN + 1)); }
fail() { echo -e "  ${RED}✗${NC}  $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "  ${CYAN}ℹ${NC}  $*"; }
hint() { [[ "$FIX_HINTS" == true ]] && echo -e "     ${CYAN}→ $*${NC}"; }

good() { echo -e "  ${GREEN}✓${NC}  $*"; }
bad()  { echo -e "  ${RED}✗${NC}  $*" >&2; }

# ── ANT-163-002: explicit, backup-first relay-policy restore ────────────────
# Only runs when the operator passes `--restore-policy`. Restores agent/AGENTS.md
# from the pristine packaged default. It previews the change, requires interactive
# confirmation or --yes, preserves a timestamped private backup of any existing
# regular file, installs the local package copy atomically, verifies the result
# by hash, and never fetches over the network or touches any other file.
do_restore_policy() {
  local relname="agent/AGENTS.md"
  local live="$SKILL_DIR/agent/AGENTS.md"
  local def; def="$(relay_policy_default_file "$relname")"

  echo ""
  echo -e "${BOLD}📡 Antenna — Restore Relay Policy${NC}"
  echo ""

  # Never restore from an untrusted package.
  if ! relay_policy_default_ok "$relname"; then
    bad "Packaged relay-policy default is missing or fails its own manifest: $def"
    echo "  Refusing to restore from an untrusted package. Reinstall Antenna from the original download." >&2
    return 1
  fi
  local want; want="$(relay_policy_expected_hash "$relname")"

  # Preview.
  local cur_state="" cur_hash=""
  if [[ -L "$live" ]]; then
    cur_state="symlink → $(readlink "$live" 2>/dev/null || echo '?')"
  elif [[ ! -e "$live" ]]; then
    cur_state="missing"
  elif [[ ! -f "$live" ]]; then
    cur_state="not a regular file"
  else
    cur_hash="$(relay_policy_sha256 "$live" 2>/dev/null || echo unknown)"
    if [[ "$cur_hash" == "$want" ]]; then
      cur_state="already matches packaged policy (sha256 $cur_hash)"
    else
      cur_state="regular file, sha256 $cur_hash"
    fi
  fi

  echo "  Target file : $live"
  echo "  Current     : $cur_state"
  echo "  Restore from: $def"
  echo "  Target hash : $want"
  echo "  Backup      : any existing regular file is saved as a timestamped private copy first"
  echo "  Scope       : only agent/AGENTS.md is touched — OpenClaw-created workspace files are never modified"
  echo ""

  if [[ -f "$live" && ! -L "$live" && "$cur_hash" == "$want" ]]; then
    good "Nothing to do — agent/AGENTS.md already matches the packaged relay policy."
    return 0
  fi

  # Confirm once after the complete preview.
  if antenna_change_plan_confirm "$ASSUME_YES" "  Proceed with restore?"; then
    :
  else
    local confirm_rc=$?
    if [[ "$confirm_rc" -eq 2 ]]; then
      return 2
    fi
    echo "  Aborted. No changes made."
    return 1
  fi

  local agent_dir; agent_dir="$(dirname "$live")"
  if [[ -L "$agent_dir" || ( -e "$agent_dir" && ! -d "$agent_dir" ) ]]; then
    bad "Refusing unsafe agent directory: $agent_dir"
    return 1
  fi
  if [[ -e "$live" && ! -f "$live" && ! -L "$live" ]]; then
    bad "Refusing to replace a non-regular, non-symlink object: $live"
    return 1
  fi
  mkdir -p "$agent_dir" || { bad "Could not create $agent_dir"; return 1; }

  # Back up an existing regular file; a symlink is removed (its target is left
  # untouched) so the restore installs a real regular file in its place.
  local ts backup="" backup_dir=""
  ts="$(date +%Y%m%d-%H%M%S)"
  if [[ -L "$live" || -f "$live" ]]; then
    backup_dir="$(mktemp -d "$agent_dir/.antenna-relay-backup-$ts.XXXXXX")" \
      || { bad "Could not allocate a collision-safe backup directory"; return 1; }
    chmod 700 "$backup_dir" 2>/dev/null || true
    backup="$backup_dir/AGENTS.md"
    cp -a --no-dereference -- "$live" "$backup" \
      || { bad "Could not preserve existing file/symlink evidence"; return 1; }
    [[ -L "$backup" ]] || chmod 600 "$backup" 2>/dev/null || true
    echo "  Preserved current file/symlink evidence at: $backup"
  fi

  # Atomic install from the local package with a safe mode.
  local tmp
  tmp="$(mktemp "$agent_dir/.AGENTS.md.antenna-restore.XXXXXX")" \
    || { bad "Could not create a temp file in $agent_dir"; return 1; }
  if ! cp -- "$def" "$tmp"; then bad "Could not stage the packaged policy"; rm -f -- "$tmp"; return 1; fi
  chmod --reference="$def" "$tmp" 2>/dev/null || chmod 644 "$tmp"
  if ! mv -fT -- "$tmp" "$live"; then
    bad "Could not install the restored policy; original path remains in place"
    rm -f -- "$tmp"
    return 1
  fi

  # Re-verify and report the resulting hash.
  local rp_out rp_rc
  rp_out="$(relay_policy_audit "$live" "$relname")"; rp_rc=$?
  if [[ "$rp_rc" -eq 0 ]]; then
    good "Restored agent/AGENTS.md from the local package."
    echo "  Resulting sha256: ${rp_out#pass|}"
    [[ -n "$backup" ]] && echo "  Previous file/symlink preserved at: $backup"
    return 0
  fi
  bad "Post-restore verification failed: ${rp_out#*|}"
  if [[ -n "$backup" ]]; then
    rm -f -- "$live"
    cp -a --no-dereference -- "$backup" "$live" \
      && bad "Rolled back to the preserved original after verification failure"
  else
    rm -f -- "$live"
  fi
  return 1
}

# ── Parse flags ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)      DO_BACKUP=true; shift ;;
    --fix-hints)   FIX_HINTS=true; shift ;;
    --gateway)     GATEWAY_PATH="$2"; shift 2 ;;
    --restore-policy) RESTORE_POLICY=true; shift ;;
    --yes|-y)      ASSUME_YES=true; shift ;;
    -h|--help)
      cat <<'EOF'
antenna doctor — Health check for Antenna installation

Usage:
  antenna doctor                     Full diagnostic check (read-only)
  antenna doctor --backup            Back up gateway config first
  antenna doctor --fix-hints         Show copy-paste fix suggestions
  antenna doctor --gateway <path>    Override gateway config path
  antenna doctor --restore-policy    Restore agent/AGENTS.md from the local
                                     package (preview + confirm; backup-first)
  antenna doctor --restore-policy --yes   Restore without the interactive prompt

Checks:
  1.  Antenna config files exist and are valid JSON
  1b. No orphan peer references in config allowlists
  1c. Antenna relay policy (agent/AGENTS.md) integrity
  2.  Gateway config exists and is valid JSON
  3.  Hooks are enabled with correct settings
  4.  Antenna agent is registered
  5.  Required allowlist entries are present
  6.  Secret files exist with correct permissions
  7.  Peer connectivity (basic)

Normal `antenna doctor` never writes to agent/AGENTS.md. Restoration only
happens when you explicitly run `--restore-policy`, and it never touches
OpenClaw-created workspace files or fetches anything over the network.
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Explicit restore mode (keeps normal doctor read-only) ───────────────────

if [[ "$RESTORE_POLICY" == true ]]; then
  do_restore_policy
  exit $?
fi

# ── Locate gateway config ───────────────────────────────────────────────────

find_gateway_config() {
  if [[ -n "$GATEWAY_PATH" ]]; then
    echo "$GATEWAY_PATH"
    return
  fi

  # Standard locations
  local candidates=(
    "$HOME/.openclaw/openclaw.json"
    "/home/$USER/.openclaw/openclaw.json"
  )
  # Add OPENCLAW_HOME if set
  [[ -n "${OPENCLAW_HOME:-}" ]] && candidates+=("$OPENCLAW_HOME/openclaw.json")

  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      echo "$c"
      return
    fi
  done

  echo ""
}

GATEWAY_CONFIG=$(find_gateway_config)

# ── Banner ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}📡 Antenna Doctor — Installation Health Check${NC}"
echo ""

# ── 1. Antenna config files ─────────────────────────────────────────────────

echo -e "${BOLD}1. Antenna Configuration${NC}"

if [[ -f "$CONFIG_FILE" ]]; then
  if jq empty "$CONFIG_FILE" 2>/dev/null; then
    pass "antenna-config.json exists and is valid JSON"
  else
    fail "antenna-config.json exists but is INVALID JSON"
    hint "Fix syntax errors in: $CONFIG_FILE"
  fi
else
  fail "antenna-config.json not found"
  hint "Run: antenna setup"
fi

if [[ -f "$PEERS_FILE" ]]; then
  if jq empty "$PEERS_FILE" 2>/dev/null; then
    pass "antenna-peers.json exists and is valid JSON"

    # Check self-peer exists. `peers_self_id` filters to entries that have
    # a string .url field, so a self entry without .url wouldn't be found
    # here. REF-2001: look up a self peer by `self == true` independently of
    # the shape predicate so we can distinguish "no self at all" from
    # "self exists but URL is missing."
    local_self=$(peers_self_id)
    self_id_any=$(jq -r 'to_entries[] | select((.value | type) == "object" and .value.self == true) | .key' "$PEERS_FILE" 2>/dev/null | head -n 1)

    if [[ -n "$local_self" ]]; then
      pass "Self-peer found: $local_self"

      # REF-2001: self-peer URL shape check. Legacy installs could contain
      # `url: "main"` because the validator did not exist yet; Doctor surfaces
      # that drift explicitly.
      self_url=$(peers_get "$local_self" url)
      if [[ -z "$self_url" ]]; then
        fail "Self-peer has no URL configured"
        hint "Re-run: antenna setup --force  (or set .self.url in antenna-peers.json)"
      else
        _url_reason=""
        if _url_reason="$(validate_peer_url "$self_url" 2>&1 >/dev/null)"; then
          pass "Self-peer URL looks valid: $self_url"
        else
          fail "Self-peer URL is malformed: $self_url (${_url_reason:-invalid URL})"
          hint "Fix .self.url in antenna-peers.json or re-run: antenna setup --force"
        fi
      fi

      # REF-2001 (warn tier): scan other peers' URLs too. Warn, not fail,
      # because pre-1313 installs may legitimately have non-conforming URLs
      # that the operator hasn't had a chance to fix yet.
      bad_peers=()
      while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        [[ "$pid" == "$local_self" ]] && continue
        purl=$(peers_get "$pid" url)
        [[ -z "$purl" ]] && continue
        if ! validate_peer_url "$purl" >/dev/null 2>&1; then
          bad_peers+=("$pid ($purl)")
        fi
      done < <(peers_list_ids)
      if (( ${#bad_peers[@]} > 0 )); then
        warn "Peers with malformed URLs: ${#bad_peers[@]}"
        for bp in "${bad_peers[@]}"; do
          hint "  - $bp"
        done
        hint "Re-pair or fix .url in antenna-peers.json"
      else
        pass "All peer URLs pass shape validation"
      fi
    elif [[ -n "$self_id_any" ]]; then
      # REF-2001: self entry exists but has no string .url field.
      fail "Self-peer '$self_id_any' has no URL configured"
      hint "Re-run: antenna setup --force  (or set .url on the self entry in antenna-peers.json)"
    else
      fail "No self-peer defined (no entry with \"self\": true)"
      hint "Add a self entry to antenna-peers.json or re-run: antenna setup"
    fi
  else
    fail "antenna-peers.json exists but is INVALID JSON"
    hint "Fix syntax errors in: $PEERS_FILE"
  fi
else
  fail "antenna-peers.json not found"
  hint "Run: antenna setup"
fi

echo ""

# ── 1b. Peer-state drift (REF-2002) ───────────────────────────────────
#
# Cross-check peer-scoped allowlists in antenna-config.json against the peer
# IDs actually present in antenna-peers.json. Orphan entries (allowlist
# references to peers that no longer exist) are a warn, not a fail: the peer
# cannot communicate anyway, but the debris is a common migration hazard and
# previously had to be cleaned up by hand.
#
# `peers remove <id>` now prunes these lists (REF-1312), but this check covers
# configs that pre-date that fix or were edited manually.

echo -e "${BOLD}1b. Peer-State Drift${NC}"

if [[ -f "$CONFIG_FILE" ]] && [[ -f "$PEERS_FILE" ]] \
   && jq empty "$CONFIG_FILE" 2>/dev/null \
   && jq empty "$PEERS_FILE" 2>/dev/null; then

  # Collect known peer IDs: every top-level key whose value is an object with
  # a string .url (same predicate lib/peers.sh uses). This is the set of peers
  # that are actually usable by the rest of Antenna.
  known_peer_ids=$(jq -r '
    to_entries
    | map(select((.value | type) == "object" and (.value.url | type) == "string"))
    | .[].key
  ' "$PEERS_FILE" 2>/dev/null | sort -u)

  drift_total=0

  for field in allowed_inbound_peers allowed_outbound_peers inbox_auto_approve_peers; do
    # Read the list, tolerating missing field. Non-array => empty iteration.
    mapfile -t entries < <(jq -r --arg f "$field" '
      if (.[$f] | type) == "array" then .[$f][] else empty end
    ' "$CONFIG_FILE" 2>/dev/null)

    orphans=()
    for entry in "${entries[@]}"; do
      [[ -z "$entry" ]] && continue
      if ! grep -Fxq -- "$entry" <<<"$known_peer_ids"; then
        orphans+=("$entry")
      fi
    done

    if (( ${#orphans[@]} > 0 )); then
      drift_total=$((drift_total + ${#orphans[@]}))
      warn "$field references unknown peer(s): ${#orphans[@]}"
      # Orphan IDs are always visible (not gated on --fix-hints): the whole
      # point of the audit is "which peer do I need to look at?". Keep the
      # actionable remediation command in `hint` so it only shows with
      # --fix-hints.
      for orphan in "${orphans[@]}"; do
        echo -e "       ${YELLOW}- $orphan${NC}"
      done
      hint "Prune with: antenna peers remove <peer-id>  (or edit $CONFIG_FILE)"
    fi
  done

  if (( drift_total == 0 )); then
    pass "No orphan peer references in config allowlists"
  fi
elif [[ ! -f "$CONFIG_FILE" ]]; then
  info "Skipped (no antenna-config.json)"
elif [[ ! -f "$PEERS_FILE" ]]; then
  info "Skipped (no antenna-peers.json)"
else
  info "Skipped (config or peers file is invalid JSON — see earlier checks)"
fi

echo ""

# ── 1c. Relay policy integrity (ANT-163-002) ────────────────────────────────
#
# Checksum-backed audit of the Antenna-owned relay-agent policy file
# (agent/AGENTS.md). File size is never used. The live file is compared to a
# pristine packaged default by SHA-256, and its stable identity marker is
# required so the generic OpenClaw workspace template or foreign content fails
# even if a hash happens to be absent. This section is strictly read-only;
# repair only happens via `antenna doctor --restore-policy`.
#
# v1.6.3 scope is agent/AGENTS.md only. OpenClaw-created workspace files
# (BOOTSTRAP.md, IDENTITY.md, SOUL.md, USER.md, HEARTBEAT.md, memory, auth and
# model state) are never audited or repaired here.

echo -e "${BOLD}1c. Relay Policy File${NC}"

RELAY_POLICY_LIVE="$SKILL_DIR/agent/AGENTS.md"
if ! relay_policy_default_ok "agent/AGENTS.md"; then
  warn "Packaged relay-policy default is unavailable or fails its own manifest — cannot audit agent/AGENTS.md"
  hint "Reinstall this Antenna release from the original download"
else
  rp_out="$(relay_policy_audit "$RELAY_POLICY_LIVE" "agent/AGENTS.md")"; rp_rc=$?
  case "$rp_rc" in
    0)
      pass "agent/AGENTS.md matches the packaged relay policy (sha256 ${rp_out#pass|})"
      ;;
    10)
      rp_hash="${rp_out##*|}"
      warn "agent/AGENTS.md differs from the packaged relay policy (possible intentional customization)"
      echo -e "       ${YELLOW}live sha256: $rp_hash — left as-is; doctor never overwrites it${NC}"
      hint "If this change was not intentional, restore it with: antenna doctor --restore-policy"
      ;;
    *)
      fail "agent/AGENTS.md is not a valid Antenna relay policy: ${rp_out#fail|}"
      hint "Restore the canonical policy with: antenna doctor --restore-policy"
      ;;
  esac
fi

echo ""

# ── 2. Gateway config ───────────────────────────────────────────────────────

echo -e "${BOLD}2. Gateway Configuration${NC}"

if [[ -z "$GATEWAY_CONFIG" ]]; then
  fail "Gateway config not found (checked ~/.openclaw/openclaw.json)"
  hint "Specify with: antenna doctor --gateway /path/to/openclaw.json"
  echo ""
  echo -e "${BOLD}3–5. Skipped${NC} (no gateway config found)"
  echo ""
else
  if jq empty "$GATEWAY_CONFIG" 2>/dev/null; then
    pass "Gateway config is valid JSON: $GATEWAY_CONFIG"
  else
    fail "Gateway config is INVALID JSON: $GATEWAY_CONFIG"
    echo ""
    echo -e "  ${RED}⚠  THIS IS CRITICAL — your OpenClaw gateway will not start with invalid JSON.${NC}"
    echo ""

    # Try to identify the error
    json_err=$(jq empty "$GATEWAY_CONFIG" 2>&1 || true)
    if [[ -n "$json_err" ]]; then
      echo -e "  ${RED}  Error: $json_err${NC}"
    fi

    hint "Restore from backup: cp ${GATEWAY_CONFIG}.antenna-backup $GATEWAY_CONFIG"
    hint "Or validate with: jq empty $GATEWAY_CONFIG"
    echo ""
    echo -e "${BOLD}3–5. Skipped${NC} (gateway config is invalid)"
    echo ""

    # Jump to summary
    echo -e "${BOLD}═══ Summary ═══${NC}"
    echo ""
    echo -e "  ${GREEN}Passed: $PASS${NC}  ${YELLOW}Warnings: $WARN${NC}  ${RED}Failed: $FAIL${NC}"
    echo ""
    if [[ $FAIL -gt 0 ]]; then
      echo -e "  ${RED}Gateway config is broken — fix this first!${NC}"
      echo -e "  If you have a backup: ${CYAN}cp ${GATEWAY_CONFIG}.antenna-backup $GATEWAY_CONFIG${NC}"
      echo -e "  Then restart: ${CYAN}openclaw gateway restart${NC}"
    fi
    echo ""
    exit 1
  fi

  # ── Backup if requested ──────────────────────────────────────────────────

  if [[ "$DO_BACKUP" == true ]]; then
    backup_path="${GATEWAY_CONFIG}.antenna-backup"
    cp "$GATEWAY_CONFIG" "$backup_path"
    chmod 600 "$backup_path"
    pass "Backup created: $backup_path"
  fi

  echo ""

  # ── 3. Hooks configuration ──────────────────────────────────────────────

  echo -e "${BOLD}3. Hooks Configuration${NC}"

  hooks_enabled=$(jq -r '.hooks.enabled // false' "$GATEWAY_CONFIG" 2>/dev/null)
  if [[ "$hooks_enabled" == "true" ]]; then
    pass "hooks.enabled = true"
  else
    fail "hooks.enabled is not true"
    hint "Add to gateway config: \"hooks\": { \"enabled\": true, ... }"
  fi

  allow_session=$(jq -r '.hooks.allowRequestSessionKey // false' "$GATEWAY_CONFIG" 2>/dev/null)
  if [[ "$allow_session" == "true" ]]; then
    pass "hooks.allowRequestSessionKey = true"
  else
    fail "hooks.allowRequestSessionKey is not true"
    hint "Set hooks.allowRequestSessionKey: true in gateway config"
  fi

  # Check allowedAgentIds contains "antenna"
  has_antenna_agent=$(jq -r '.hooks.allowedAgentIds // [] | map(select(. == "antenna")) | length' "$GATEWAY_CONFIG" 2>/dev/null)
  if [[ "$has_antenna_agent" -gt 0 ]]; then
    pass "hooks.allowedAgentIds includes \"antenna\""
  else
    fail "hooks.allowedAgentIds does not include \"antenna\""
    hint "Add \"antenna\" to hooks.allowedAgentIds array"
  fi

  has_hook_prefix=$(jq -r '.hooks.allowedSessionKeyPrefixes // [] | map(select(. == "hook:" or . == "hook:antenna" or startswith("hook"))) | length' "$GATEWAY_CONFIG" 2>/dev/null)
  if [[ "$has_hook_prefix" -gt 0 ]]; then
    pass "hooks.allowedSessionKeyPrefixes includes hook prefix"
  else
    warn "hooks.allowedSessionKeyPrefixes may not include \"hook:\" or \"hook:antenna\""
    hint "Add \"hook:antenna\" to hooks.allowedSessionKeyPrefixes array"
  fi

  v163_mapping_audit="$(v163_staging_mapping_audit "$GATEWAY_CONFIG")"
  case "$v163_mapping_audit" in
    pass\|*)
      warn "Superseded v1.6.3 /hooks/antenna mapping remains installed"
      hint "Run the v1.6.5 upgrade path to remove the exact canonical mapping safely"
      ;;
    missing\|*) : ;;
    *) fail "Customized/conflicting v1.6.3 hook mapping requires manual review: ${v163_mapping_audit#fail|}" ;;
  esac

  v163_transform_dir=""
  if ! v163_staging_resolve_transforms_dir "$GATEWAY_CONFIG" v163_transform_dir; then
    fail "Cannot safely resolve hooks.transformsDir while auditing v1.6.3 residue"
  else
    v163_transform_live="$v163_transform_dir/$V163_STAGING_MODULE"
    v163_transform_audit="$(v163_staging_transform_audit "$v163_transform_live")"
    case "$v163_transform_audit" in
      pass\|*)
        warn "Superseded v1.6.3 staging transform remains installed: $v163_transform_live"
        hint "Run the v1.6.5 upgrade path to remove the exact canonical transform safely"
        ;;
      missing\|*) : ;;
      *) fail "Customized/unsafe v1.6.3 transform requires manual review: ${v163_transform_audit#fail|}" ;;
    esac
  fi

  v163_temp_dir="${TMPDIR:-/tmp}/antenna-relay-$(id -u)"
  if [[ -d "$v163_temp_dir" ]] \
      && find "$v163_temp_dir" -maxdepth 1 -type f -name 'antenna-*.envelope' -print -quit 2>/dev/null | grep -q .; then
    warn "Superseded v1.6.3 staged-envelope files remain under $v163_temp_dir"
    hint "Review and remove those private files after confirming no v1.6.3 relay is active"
  fi

  echo ""

  # ── 4. Agent registration ──────────────────────────────────────────────

  echo -e "${BOLD}4. Agent Registration${NC}"

  # Inspect either authored roster generation directly. Consult OpenClaw's
  # resolved roster only when direct inspection finds no Antenna entry; that
  # keeps ordinary Doctor runs fast while still supporting include layouts.
  has_agent=false
  direct_agent_count="$(jq '
    [
      (.agents.list[]? | select(((.id // "") | ascii_downcase) == "antenna")),
      (.agents.entries // {} | to_entries[]? | select((.key | ascii_downcase) == "antenna")),
      (if (.agents.antenna? | type) == "object" then .agents.antenna else empty end)
    ] | length
  ' "$GATEWAY_CONFIG" 2>/dev/null || echo 0)"
  if [[ "$direct_agent_count" =~ ^[0-9]+$ && "$direct_agent_count" -gt 0 ]]; then
    has_agent=true
  fi

  resolved_agent_count=""
  if [[ "$has_agent" == false ]] \
     && gateway_roster_has_unsafe_include "$GATEWAY_CONFIG" \
     && command -v openclaw >/dev/null 2>&1; then
    resolved_agent_count="$(
      OPENCLAW_CONFIG_PATH="$GATEWAY_CONFIG" openclaw agents list --json 2>/dev/null \
        | jq '[.[] | select(((.id // "") | ascii_downcase) == "antenna")] | length' \
          2>/dev/null || true
    )"
    if [[ "$resolved_agent_count" =~ ^[0-9]+$ && "$resolved_agent_count" -gt 0 ]]; then
      has_agent=true
    fi
  fi

  if [[ "$has_agent" == true ]]; then
    pass "Antenna agent is registered in gateway config"
    direct_paths="$(jq -r '
      if (.agents.entries | type) == "object" then
        ([.agents.entries | to_entries[] | select((.key | ascii_downcase) == "antenna")][0].value // {}) as $agent
        | [($agent.workspace // ""), ($agent.agentDir // "")] | @tsv
      elif (.agents.list | type) == "array" then
        ([.agents.list[] | select(((.id // "") | ascii_downcase) == "antenna")][0] // {}) as $agent
        | [($agent.workspace // ""), ($agent.agentDir // "")] | @tsv
      else "" end
    ' "$GATEWAY_CONFIG" 2>/dev/null || true)"
    if [[ -n "$direct_paths" ]]; then
      IFS=$'\t' read -r antenna_workspace antenna_agent_dir <<<"$direct_paths"
      if [[ -z "$antenna_workspace" || -z "$antenna_agent_dir" ]]; then
        fail "Antenna workspace/agentDir boundary is incomplete"
      else
        resolved_skill="$(realpath -m "$SKILL_DIR")"
        resolved_workspace="$(realpath -m "$antenna_workspace")"
        resolved_agent_dir="$(realpath -m "$antenna_agent_dir")"
        if [[ "$resolved_workspace" == "$resolved_agent_dir" \
             || "$resolved_agent_dir" == "$resolved_skill" \
             || "$resolved_agent_dir" == "$resolved_skill/"* ]]; then
          fail "Antenna agentDir must be stable OpenClaw state, separate from the replaceable relay workspace"
        else
          pass "Antenna relay workspace and OpenClaw agent state are separated"
        fi
      fi
    else
      info "Antenna paths are include-owned; direct workspace/state boundary audit skipped"
    fi
  else
    fail "Antenna agent not found in gateway config"
    if gateway_roster_has_unsafe_include "$GATEWAY_CONFIG"; then
      hint "The roster may be include-owned; inspect it with: OPENCLAW_CONFIG_PATH=$GATEWAY_CONFIG openclaw agents list --json"
    else
      hint "Register the antenna agent — see: antenna setup (prints the config block)"
    fi
  fi

  echo ""

  # ── 5. Token present ──────────────────────────────────────────────────

  echo -e "${BOLD}5. Hooks Token${NC}"

  hooks_token=$(jq -r '.hooks.token // empty' "$GATEWAY_CONFIG" 2>/dev/null)
  if [[ -n "$hooks_token" ]]; then
    token_len=${#hooks_token}
    if [[ $token_len -ge 20 ]]; then
      pass "Hooks token is set (${token_len} chars)"
    else
      warn "Hooks token seems short (${token_len} chars) — consider using a stronger token"
      hint "Generate with: openssl rand -base64 32"
    fi
  else
    fail "No hooks token configured"
    hint "Set hooks.token in gateway config"
  fi

  echo ""
fi

# ── 5b. Session allowlist ───────────────────────────────────────────────────

echo -e "${BOLD}5b. Session Allowlist${NC}"

if [[ -f "$CONFIG_FILE" ]]; then
  local_agent=$(config_local_agent_id)

  needs_main="agent:${local_agent}:main"
  needs_antenna="agent:${local_agent}:antenna"
  needs_modeltest="agent:antenna:modeltest"

  for s in "$needs_main" "$needs_antenna"; do
    if jq -e --arg s "$s" '.allowed_inbound_sessions // [] | index($s)' "$CONFIG_FILE" >/dev/null 2>&1; then
      pass "session allowlisted: $s"
    else
      warn "session not allowlisted: $s"
      hint "Run: antenna sessions add $s"
    fi
  done

  # Model-test session — needed by 'antenna test' (self-registers, but doctor surfaces it)
  if jq -e --arg s "$needs_modeltest" '.allowed_inbound_sessions // [] | index($s)' "$CONFIG_FILE" >/dev/null 2>&1; then
    pass "session allowlisted: $needs_modeltest (needed by 'antenna test')"
  else
    warn "session not allowlisted: $needs_modeltest (needed by 'antenna test')"
    hint "'antenna test' self-registers this; or add manually: antenna sessions add $needs_modeltest"
  fi
else
  warn "Cannot check session allowlist — no $CONFIG_FILE"
fi

echo ""

# ── 6. Secret files ─────────────────────────────────────────────────────────

echo -e "${BOLD}6. Secrets & Permissions${NC}"

if [[ -f "$PEERS_FILE" ]]; then
  while IFS= read -r peer_id; do
    [[ -z "$peer_id" ]] && continue

    # Token file
    tf=$(peers_get "$peer_id" token_file)
    if [[ -n "$tf" ]]; then
      # Resolve relative paths
      [[ "$tf" != /* ]] && tf="$SKILL_DIR/$tf"

      if [[ -f "$tf" ]]; then
        perms=$(stat -c '%a' "$tf" 2>/dev/null || stat -f '%Lp' "$tf" 2>/dev/null || echo "unknown")
        if [[ "$perms" == "600" || "$perms" == "400" ]]; then
          pass "$peer_id: token file OK ($perms)"
        else
          warn "$peer_id: token file permissions ($perms) — should be 600"
          hint "chmod 600 $tf"
        fi
      else
        fail "$peer_id: token file missing: $tf"
      fi
    fi

    # Peer secret file
    psf=$(peers_get "$peer_id" peer_secret_file)
    if [[ -n "$psf" ]]; then
      [[ "$psf" != /* ]] && psf="$SKILL_DIR/$psf"

      if [[ -f "$psf" ]]; then
        ps_perms=$(stat -c '%a' "$psf" 2>/dev/null || stat -f '%Lp' "$psf" 2>/dev/null || echo "unknown")
        if [[ "$ps_perms" == "600" || "$ps_perms" == "400" ]]; then
          pass "$peer_id: peer secret OK ($ps_perms)"
        else
          warn "$peer_id: peer secret permissions ($ps_perms) — should be 600"
          hint "chmod 600 $psf"
        fi
      else
        is_self_check=$(peers_get "$peer_id" self)
        if [[ "$is_self_check" == "true" ]]; then
          fail "$peer_id (self): identity secret missing: $psf"
          hint "Run: antenna setup (or openssl rand -hex 32 > $psf && chmod 600 $psf)"
        else
          warn "$peer_id: peer secret file missing: $psf (sender won't be verified)"
          hint "Run: antenna peers exchange $peer_id"
        fi
      fi
    else
      is_self=$(peers_get "$peer_id" self)
      if [[ "$is_self" == "true" ]]; then
        warn "$peer_id (self): no peer_secret_file configured"
        hint "Run: antenna setup --force (or add peer_secret_file to your self-peer entry)"
      fi
    fi
  done < <(peers_list_ids)
else
  warn "Cannot check secrets — no peers file"
fi

echo ""

# ── 6b. Secrets-directory hygiene ───────────────────────────────────────────
#
# Section 6 audits per-peer secrets *referenced from antenna-peers.json*. It
# says nothing about files sitting in secrets/ that no peer references anymore
# (orphans: the file equivalent of REF-1312 allowlist drift), and nothing about
# forgotten `.bak` backups whose permissions
# drift silently over time. It also doesn't check that secrets/ itself is not
# group/world-readable. This is the file-side counterpart to 1b.
#
# Severity is warn, not fail — matching 1b: orphan/backup secret files on
# disk can't authenticate anyone who isn't in the peer registry, but they are
# a real migration hygiene signal and an easy leak surface if perms drift.

echo -e "${BOLD}6b. Secrets Directory Hygiene${NC}"

SECRETS_DIR="$SKILL_DIR/secrets"

if [[ ! -d "$SECRETS_DIR" ]]; then
  info "No secrets directory at $SECRETS_DIR (skipping)"
else
  # ---- Directory permissions ----
  dir_perms=$(stat -c '%a' "$SECRETS_DIR" 2>/dev/null || stat -f '%Lp' "$SECRETS_DIR" 2>/dev/null || echo "unknown")
  case "$dir_perms" in
    700|750|500)
      pass "secrets/ directory permissions OK ($dir_perms)"
      ;;
    *)
      warn "secrets/ directory permissions ($dir_perms) — should be 700"
      hint "chmod 700 $SECRETS_DIR"
      ;;
  esac

  # ---- Classify loose files ----
  # Build the set of known peer IDs up front.
  known_peers=""
  if [[ -f "$PEERS_FILE" ]]; then
    known_peers=$(peers_list_ids 2>/dev/null | sort -u)
  fi

  # Known non-peer-scoped files that are expected to live in secrets/.
  # (The age keypair is Layer A bootstrap material; it isn't tied to one peer.)
  is_known_nonpeer_file() {
    case "$1" in
      antenna-exchange.agekey|antenna-exchange.agepub|antenna-signing-private.pem|antenna-signing-public.pem) return 0 ;;
      *) return 1 ;;
    esac
  }

  # Public-key material is intentionally readable and may safely use 0644.
  # Private keys, bearer tokens, and peer secrets remain restricted to 0600
  # (or 0400). Classify before the generic permission audit so Doctor does not
  # report a successful Ed25519/age pairing as a secrets-permission defect.
  is_known_public_file() {
    case "$1" in
      antenna-exchange.agepub|antenna-signing-public.pem) return 0 ;;
      *) return 1 ;;
    esac
  }

  # Extract `<peer_id>` from a filename if it looks like a peer-scoped file.
  # Returns empty if the file doesn't match any known peer-scoped pattern.
  peer_id_from_filename() {
    local fn="$1"
    case "$fn" in
      antenna-peer-*.secret)
        fn="${fn#antenna-peer-}"
        printf '%s\n' "${fn%.secret}"
        ;;
      hooks_token_*)
        printf '%s\n' "${fn#hooks_token_}"
        ;;
      peer_secret_*)
        printf '%s\n' "${fn#peer_secret_}"
        ;;
      *)
        printf '\n'
        ;;
    esac
  }

  is_backup_filename() {
    case "$1" in
      *.bak|*.bak.*|*.bak-*|*.backup|*.backup.*|*.backup-*|*~|*.old)
        return 0
        ;;
    esac
    return 1
  }

  orphan_list=""
  backup_list=""
  unknown_list=""
  loose_perm_list=""

  while IFS= read -r -d '' entry; do
    fn="$(basename "$entry")"

    # Secret material is expected to be 600/400. Packaged public-key files may
    # also be 644 because their contents are explicitly non-secret.
    f_perms=$(stat -c '%a' "$entry" 2>/dev/null || stat -f '%Lp' "$entry" 2>/dev/null || echo "unknown")
    if is_known_public_file "$fn"; then
      case "$f_perms" in
        644|600|400) ;;
        *) loose_perm_list+="$fn|$f_perms"$'\n' ;;
      esac
    else
      case "$f_perms" in
        600|400) ;;
        *) loose_perm_list+="$fn|$f_perms"$'\n' ;;
      esac
    fi

    # Classify by filename
    if is_backup_filename "$fn"; then
      backup_list+="$fn"$'\n'
      continue
    fi

    if is_known_nonpeer_file "$fn"; then
      continue
    fi

    pid="$(peer_id_from_filename "$fn" | tr -d '\n')"
    if [[ -z "$pid" ]]; then
      unknown_list+="$fn"$'\n'
      continue
    fi

    # Does this peer ID exist in the registry?
    if [[ -z "$known_peers" ]] || ! printf '%s\n' "$known_peers" | grep -qxF "$pid"; then
      orphan_list+="$fn"$'\n'
    fi
  done < <(find "$SECRETS_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

  # ---- Report orphans ----
  if [[ -n "$orphan_list" ]]; then
    n=$(printf '%s' "$orphan_list" | grep -c . || true)
    warn "orphan secret file(s) in secrets/: $n (peer not in registry)"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '      - %s\n' "$f"
    done <<<"$orphan_list"
    hint "Review and either re-add the peer or move the file out of secrets/"
  else
    pass "No orphan peer secrets in secrets/"
  fi

  # ---- Report backups ----
  if [[ -n "$backup_list" ]]; then
    n=$(printf '%s' "$backup_list" | grep -c . || true)
    warn "stale backup file(s) in secrets/: $n"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '      - %s\n' "$f"
    done <<<"$backup_list"
    hint "Remove or move backups out of secrets/ once they're no longer needed"
  else
    pass "No stale backup files in secrets/"
  fi

  # ---- Report loose permissions across the whole dir ----
  if [[ -n "$loose_perm_list" ]]; then
    n=$(printf '%s' "$loose_perm_list" | grep -c . || true)
    warn "file(s) in secrets/ with loose permissions: $n (should be 600)"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '      - %s (%s)\n' "${line%|*}" "${line#*|}"
    done <<<"$loose_perm_list"
    hint "chmod 600 $SECRETS_DIR/*"
  fi

  # ---- Report unknown-shape files ----
  if [[ -n "$unknown_list" ]]; then
    n=$(printf '%s' "$unknown_list" | grep -c . || true)
    warn "unrecognized file(s) in secrets/: $n"
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '      - %s\n' "$f"
    done <<<"$unknown_list"
    hint "Secrets/ should only contain peer-scoped secrets and bootstrap keys; review manually"
  fi
fi

echo ""

# ── 7. Basic connectivity ───────────────────────────────────────────────────

echo -e "${BOLD}7. Connectivity (quick check)${NC}"

if [[ -f "$PEERS_FILE" ]]; then
  while IFS= read -r peer_id; do
    [[ -z "$peer_id" ]] && continue

    is_self=$(peers_get "$peer_id" self)
    [[ "$is_self" == "true" ]] && continue

    peer_url=$(peers_get "$peer_id" url)
    [[ -z "$peer_url" ]] && continue

    # Quick reachability check (5s timeout)
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "${peer_url}" 2>/dev/null) || true

    # Normalize: strip anything non-numeric, treat empty/zero as unreachable
    http_code="${http_code//[^0-9]/}"
    http_code="${http_code:-000}"

    if [[ "$http_code" == "000" || "$http_code" == "0" ]]; then
      warn "$peer_id ($peer_url): unreachable"
      hint "Check: is the peer online? Is Tailscale Funnel/tunnel active?"
    elif [[ "$http_code" -ge 200 && "$http_code" -lt 500 ]]; then
      pass "$peer_id ($peer_url): reachable (HTTP $http_code)"
    else
      warn "$peer_id ($peer_url): responded with HTTP $http_code"
    fi
  done < <(peers_list_ids)
else
  warn "Cannot check connectivity — no peers file"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "${BOLD}═══ Summary ═══${NC}"
echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}  ${YELLOW}Warnings: $WARN${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "  ${GREEN}All checks passed — Antenna is healthy! 📡${NC}"
elif [[ $FAIL -eq 0 ]]; then
  echo -e "  ${YELLOW}No critical issues, but $WARN warning(s) to review.${NC}"
else
  echo -e "  ${RED}$FAIL critical issue(s) found — fix these before using Antenna.${NC}"
  if [[ "$FIX_HINTS" == false ]]; then
    echo -e "  Run with ${CYAN}--fix-hints${NC} for suggested fixes."
  fi
fi

if [[ $FAIL -gt 0 || $WARN -gt 0 ]]; then
  echo -e "  Still stuck? ${CYAN}help@clawreef.io${NC} · ${CYAN}https://github.com/ClawReefAntenna/antenna/issues${NC}"
fi

echo ""

# Exit code: 0 = all good, 1 = failures present
[[ $FAIL -eq 0 ]]
