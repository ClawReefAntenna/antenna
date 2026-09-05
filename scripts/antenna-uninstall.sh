#!/usr/bin/env bash
# antenna-uninstall.sh — Remove Antenna runtime state and optionally gateway registration.
# Conservative by design: only removes Antenna-owned/runtime artifacts unless explicitly
# asked to purge the entire skill directory.
#
# Usage:
#   antenna uninstall
#   antenna uninstall --dry-run
#   antenna uninstall --yes --purge-skill-dir
#   antenna uninstall --keep-gateway-config
#   antenna uninstall --gateway /path/to/openclaw.json
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SKILL_DIR/antenna-config.json"
PEERS_FILE="$SKILL_DIR/antenna-peers.json"
INBOX_FILE="$SKILL_DIR/antenna-inbox.json"
LISTS_FILE="$SKILL_DIR/antenna-lists.json"
PUBLIC_GROUPS_FILE="$SKILL_DIR/antenna-public-groups.json"
SECRETS_DIR="$SKILL_DIR/secrets"
KEYS_DIR="$SKILL_DIR/keys"
LOG_FILE="$SKILL_DIR/antenna.log"
RATE_FILE="$SKILL_DIR/antenna-ratelimit.json"
TEST_RESULTS_DIR="$SKILL_DIR/test-results"
STATE_DIR="$SKILL_DIR/state"
# shellcheck source=../lib/v163-staging-cleanup.sh
source "$SKILL_DIR/lib/v163-staging-cleanup.sh"
# shellcheck source=../lib/cli-link.sh
source "$SKILL_DIR/lib/cli-link.sh"
# shellcheck source=../lib/change-plan.sh
source "$SKILL_DIR/lib/change-plan.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC}  $*"; }
ok()    { echo -e "${GREEN}✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC}  $*" >&2; }
header(){ echo -e "\n${BOLD}$*${NC}"; }

usage() {
  cat <<'EOF'
antenna uninstall — Remove Antenna runtime state and optional gateway registration

Usage:
  antenna uninstall
  antenna uninstall --dry-run
  antenna uninstall --yes --purge-skill-dir
  antenna uninstall --keep-gateway-config
  antenna uninstall --gateway /path/to/openclaw.json

What it removes by default:
  - antenna-config.json
  - antenna-peers.json
  - antenna-inbox.json
  - antenna-lists.json
  - antenna-public-groups.json
  - antenna.log and rotated antenna.log.*
  - antenna-ratelimit.json
  - state/ (replay cache)
  - test-results/
  - Antenna-owned secrets under skills/antenna/secrets/
  - Antenna-owned public keys under skills/antenna/keys/
  - Antenna agent/hooks entries from gateway config (unless --keep-gateway-config)

What it does NOT remove by default:
  - the Antenna skill directory itself
  - external token files referenced outside the Antenna skill directory
  - the rest of OpenClaw

Options:
  --dry-run              Show planned actions without changing anything
  --yes                  Skip confirmation prompts
  --keep-gateway-config  Leave OpenClaw gateway config untouched
  --gateway <path>       Explicit path to openclaw.json
  --purge-skill-dir      Remove the entire skills/antenna directory at the end
  -h, --help             Show this help
EOF
  exit 0
}

DRY_RUN=false
ASSUME_YES=false
KEEP_GATEWAY=false
PURGE_SKILL_DIR=false
GATEWAY_CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --keep-gateway-config) KEEP_GATEWAY=true; shift ;;
    --gateway) GATEWAY_CONFIG="$2"; shift 2 ;;
    --purge-skill-dir) PURGE_SKILL_DIR=true; shift ;;
    -h|--help) usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

remove_if_exists() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    run_cmd rm -rf -- "$path"
    if [[ "$DRY_RUN" == true ]]; then
      info "Would remove: $path"
    else
      ok "Removed: $path"
    fi
  else
    info "Not present: $path"
  fi
}

discover_gateway_config() {
  if [[ -n "$GATEWAY_CONFIG" ]]; then
    return 0
  fi

  for candidate in "$HOME/.openclaw/openclaw.json" "/home/$USER/.openclaw/openclaw.json"; do
    if [[ -f "$candidate" ]]; then
      GATEWAY_CONFIG="$candidate"
      return 0
    fi
  done
}

gateway_backup_path() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  printf '%s.antenna-uninstall-backup-%s' "$GATEWAY_CONFIG" "$ts"
}

cleanup_gateway_config() {
  local backup_path tmp mapping_audit remove_mapping=false transform_dir="" transform_live="" transform_audit=""

  if [[ -z "$GATEWAY_CONFIG" ]]; then
    warn "No gateway config found; skipping gateway cleanup."
    return 0
  fi

  if [[ ! -f "$GATEWAY_CONFIG" ]]; then
    warn "Gateway config path does not exist: $GATEWAY_CONFIG"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required to modify the gateway config safely."
    exit 1
  fi

  if ! jq empty "$GATEWAY_CONFIG" >/dev/null 2>&1; then
    err "Gateway config is invalid JSON: $GATEWAY_CONFIG"
    err "Refusing to edit it. Fix JSON first or use --keep-gateway-config."
    exit 1
  fi

  mapping_audit="$(v163_staging_mapping_audit "$GATEWAY_CONFIG")" || mapping_audit="fail|could not audit mappings"
  case "$mapping_audit" in
    pass\|*) remove_mapping=true ;;
    missing\|*) : ;;
    *) warn "Preserving customized/conflicting v1.6.3 /hooks/antenna mapping: ${mapping_audit#fail|}" ;;
  esac
  if v163_staging_resolve_transforms_dir "$GATEWAY_CONFIG" transform_dir; then
    transform_live="$transform_dir/$V163_STAGING_MODULE"
    transform_audit="$(v163_staging_transform_audit "$transform_live")"
  else
    warn "Cannot safely resolve hooks.transformsDir; no external transform will be removed."
  fi

  backup_path="$(gateway_backup_path)"
  run_cmd cp -- "$GATEWAY_CONFIG" "$backup_path"
  if [[ "$DRY_RUN" != true ]]; then
    chmod 600 "$backup_path"
  fi
  ok "Backed up gateway config: $backup_path"

  local antenna_agent_id
  antenna_agent_id="$({
    jq -r '.agents.list // [] | map(select(.id == "antenna" or .name == "antenna" or (.name // "" | ascii_downcase) == "antenna relay"))[0].id // empty' "$GATEWAY_CONFIG" 2>/dev/null
    jq -r 'if (.agents | type) == "array" then (.agents | map(select(.id == "antenna" or .name == "antenna" or (.name // "" | ascii_downcase) == "antenna relay"))[0].id // empty) else empty end' "$GATEWAY_CONFIG" 2>/dev/null
    jq -r 'if (.agents.entries | type) == "object" and (.agents.entries.antenna? != null) then "antenna" else empty end' "$GATEWAY_CONFIG" 2>/dev/null
    jq -r 'if (.agents.antenna? != null) then "antenna" else empty end' "$GATEWAY_CONFIG" 2>/dev/null
  } | sed '/^$/d' | head -1)"

  tmp="$(mktemp)"
  jq --arg antenna_id "${antenna_agent_id:-antenna}" --argjson remove_mapping "$remove_mapping" \
    --arg mapping_id "$V163_STAGING_MAPPING_ID" '
    if (.agents | type) == "array" then
      .agents |= map(select(.id != $antenna_id))
    else
      .
    end
    | if (.agents | type) == "object" then
        if (.agents.list | type) == "array" then
          .agents.list |= map(select(.id != $antenna_id))
        else
          .
        end
      else
        .
      end
    | if (.agents | type) == "object" then
        if (.agents.entries | type) == "object" then
          .agents.entries |= del(.[$antenna_id])
        else
          .
        end
      else
        .
      end
    | if (.agents | type) == "object" and .agents[$antenna_id]? != null then
        .agents |= del(.[$antenna_id])
      else
        .
      end
    | if (.hooks | type) == "object" then
        .hooks.allowedAgentIds = ((.hooks.allowedAgentIds // []) | map(select(. != $antenna_id)))
      else
        .
      end
    | if (.hooks | type) == "object" then
        .hooks.allowedSessionKeyPrefixes = ((.hooks.allowedSessionKeyPrefixes // [])
          | map(select(. != "hook:antenna" and . != "hook:antenna:")))
      else
        .
      end
    | if $remove_mapping and (.hooks.mappings | type) == "array" then
        .hooks.mappings |= map(select(.id != $mapping_id))
      else . end
  ' "$GATEWAY_CONFIG" > "$tmp"

  if [[ "$DRY_RUN" == true ]]; then
    info "Would update gateway config to remove Antenna agent/hooks entries: $GATEWAY_CONFIG"
    rm -f -- "$tmp"
  else
    mv -- "$tmp" "$GATEWAY_CONFIG"
    chmod 600 "$GATEWAY_CONFIG" 2>/dev/null || true
    ok "Updated gateway config: removed Antenna agent/hooks entries"
  fi

  if [[ "$mapping_audit" == fail\|* ]]; then
    [[ -z "$transform_live" ]] || warn "Preserving transform because a customized/conflicting /hooks/antenna mapping still references the hook surface: $transform_live"
  elif [[ "$transform_audit" == pass\|* ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      info "Would remove exact canonical Antenna transform: $transform_live"
    elif v163_staging_remove_transform_if_canonical "$transform_live"; then
      ok "Removed exact canonical Antenna transform: $transform_live"
    else
      warn "Transform changed during uninstall; preserving it: $transform_live"
    fi
  elif [[ "$transform_audit" == fail\|* ]]; then
    warn "Preserving customized/unsafe transform at $transform_live: ${transform_audit#fail|}"
  fi
}

header "📡 Antenna Uninstall"
echo ""
echo "  Skill dir:        $SKILL_DIR"
echo "  Remove runtime:   yes"
echo "  Clean gateway:    $([[ "$KEEP_GATEWAY" == true ]] && echo no || echo yes)"
echo "  Purge skill dir:  $([[ "$PURGE_SKILL_DIR" == true ]] && echo yes || echo no)"
echo "  Dry run:          $([[ "$DRY_RUN" == true ]] && echo yes || echo no)"

discover_gateway_config
if [[ -n "$GATEWAY_CONFIG" ]]; then
  echo "  Gateway config:   $GATEWAY_CONFIG"
else
  echo "  Gateway config:   (not found)"
fi

echo ""
echo "Planned changes:"
echo "  - $CONFIG_FILE"
echo "  - $PEERS_FILE"
echo "  - $INBOX_FILE"
echo "  - $LISTS_FILE"
echo "  - $PUBLIC_GROUPS_FILE"
echo "  - $LOG_FILE and rotated logs"
echo "  - $RATE_FILE"
echo "  - $STATE_DIR"
echo "  - $TEST_RESULTS_DIR"
echo "  - $SECRETS_DIR"
echo "  - $KEYS_DIR"
if [[ "$PURGE_SKILL_DIR" == true ]]; then
  echo "  - entire skill directory: $SKILL_DIR"
fi
if [[ "$KEEP_GATEWAY" != true ]]; then
  echo "  - back up the gateway config, then remove Antenna's agent, hook mapping, and allowlist entries"
  echo "  - require a gateway restart after cleanup; uninstall will not restart it automatically"
else
  echo "  - leave gateway agent, hooks, allowlists, session visibility, and sandbox settings unchanged"
fi
echo ""
warn "External token files referenced outside the Antenna skill directory will NOT be deleted automatically."
warn "The rest of OpenClaw will NOT be touched."

if [[ "$DRY_RUN" == true ]]; then
  info "Dry run only; no confirmation is required and no changes will be made."
elif antenna_change_plan_confirm "$ASSUME_YES" "Proceed with Antenna uninstall?"; then
  :
else
  plan_rc=$?
  echo ""
  if [[ "$plan_rc" -eq 2 ]]; then
    exit 2
  fi
  info "Uninstall cancelled. No changes were made."
  exit 0
fi

if [[ "$KEEP_GATEWAY" != true ]]; then
  cleanup_gateway_config
else
  info "Leaving gateway config untouched (--keep-gateway-config)."
fi

remove_if_exists "$CONFIG_FILE"
remove_if_exists "$PEERS_FILE"
remove_if_exists "$INBOX_FILE"
remove_if_exists "$LISTS_FILE"
remove_if_exists "$PUBLIC_GROUPS_FILE"
remove_if_exists "$RATE_FILE"
remove_if_exists "$STATE_DIR"
remove_if_exists "$TEST_RESULTS_DIR"
remove_if_exists "$SECRETS_DIR"
remove_if_exists "$KEYS_DIR"

shopt -s nullglob
for path in "$LOG_FILE" "$LOG_FILE".*; do
  remove_if_exists "$path"
done
shopt -u nullglob

# ── Remove CLI symlink ────────────────────────────────────────────────────────
# Setup creates a symlink at /usr/local/bin/antenna or ~/.local/bin/antenna.
# Clean it up only when it resolves to this installation's exact dispatcher.
# A dangling or prefix-matching foreign link is not proof of ownership.
for _symlink_candidate in /usr/local/bin/antenna "$HOME/.local/bin/antenna"; do
  if cli_link_remove_if_owned "$_symlink_candidate" "$SKILL_DIR/bin/antenna.sh" "$DRY_RUN"; then
    case "$CLI_LINK_ACTION" in
      would_remove) info "Would remove owned symlink: $_symlink_candidate" ;;
      removed) ok "Removed owned symlink: $_symlink_candidate" ;;
    esac
  elif [[ -e "$_symlink_candidate" || -L "$_symlink_candidate" ]]; then
    warn "Preserving CLI target not proven to belong to this install: $_symlink_candidate ($CLI_LINK_STATE)"
  fi
done

if [[ "$PURGE_SKILL_DIR" == true ]]; then
  warn "Purging the Antenna skill directory will remove the uninstall command itself from this install."
  remove_if_exists "$SKILL_DIR"
fi

echo ""
ok "Antenna uninstall complete."
if [[ "$KEEP_GATEWAY" != true ]]; then
  info "If this host is running OpenClaw, restart the gateway to apply gateway-config changes:"
  echo "  openclaw gateway restart"
fi
if [[ "$PURGE_SKILL_DIR" != true ]]; then
  info "To reinstall cleanly later, keep the skill code and run:"
  echo "  antenna setup"
fi
