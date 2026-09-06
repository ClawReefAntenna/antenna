#!/usr/bin/env bash
# antenna-upgrade.sh — Preserve runtime state while moving to a side-by-side install.
#
# This is deliberately a local, one-host migration. It does not negotiate auth
# modes or contact peers. Existing v1.5.2 peers remain unusable until the
# operator completes the documented fresh Ed25519 re-pair.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../lib/gateway-roster.sh
source "$SKILL_DIR/lib/gateway-roster.sh"
# shellcheck source=../lib/relay-policy.sh
source "$SKILL_DIR/lib/relay-policy.sh"
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
NC='\033[0m'

info() { echo -e "${CYAN}ℹ${NC}  $*"; }
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
antenna upgrade — Move an existing installation into this side-by-side release

Usage:
  antenna upgrade --from /path/to/old/antenna [--gateway /path/to/openclaw.json]
    [--replace-cli-link /absolute/path/to/antenna] [--yes]

The destination is the Antenna tree containing this command. The migration:
  - refuses to overwrite any destination runtime state;
  - copies local config, peers, lists, Public Group routes, queues, keys,
    secrets, replay/rate state, logs, and ignored agent-local runtime files
    without changing the source;
  - updates only install_path in the copied Antenna config;
  - backs up openclaw.json, repoints the existing Antenna workspace to this
    release, and keeps agentDir under OpenClaw's stable state root; and
  - repoints an existing Antenna CLI symlink when it targets the old release,
    preserving the displaced link as a private rollback backup.

Foreign CLI symlinks and regular files are preserved by default. To replace
one deliberately, pass its exact absolute path with --replace-cli-link; the
displaced target is retained in a private backup beside the link. Directories
and ambiguous targets are always refused.

It does not silently convert legacy peer authentication. Re-pair every old
plaintext peer with Ed25519 after migration.

The upgrade displays its complete change plan before changing runtime state,
gateway configuration, or the CLI target.
Use --yes only for an already-authorized non-interactive upgrade.
EOF
  exit 0
}

SOURCE_DIR=""
GATEWAY_CONFIG=""
CLI_REPLACE_PATH=""
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) SOURCE_DIR="${2:-}"; shift 2 ;;
    --gateway) GATEWAY_CONFIG="${2:-}"; shift 2 ;;
    --replace-cli-link)
      CLI_REPLACE_PATH="${2:-}"
      [[ -n "$CLI_REPLACE_PATH" ]] || die "--replace-cli-link requires an absolute path"
      shift 2
      ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ -n "$CLI_REPLACE_PATH" ]]; then
  [[ "$CLI_REPLACE_PATH" == /* ]] || die "--replace-cli-link must be an absolute path"
  [[ "$(basename -- "$CLI_REPLACE_PATH")" == "antenna" ]] \
    || die "--replace-cli-link must name an 'antenna' command path"
  [[ -d "$(dirname -- "$CLI_REPLACE_PATH")" ]] \
    || die "--replace-cli-link parent directory does not exist: $(dirname -- "$CLI_REPLACE_PATH")"
fi

command -v jq >/dev/null 2>&1 || die "jq is required for a safe upgrade"
command -v realpath >/dev/null 2>&1 || die "realpath is required for a safe upgrade"

[[ -n "$SOURCE_DIR" ]] || die "Missing --from /path/to/old/antenna"
[[ -d "$SOURCE_DIR" ]] || die "Source installation does not exist: $SOURCE_DIR"
SOURCE_DIR="$(realpath "$SOURCE_DIR")"
SKILL_DIR="$(realpath "$SKILL_DIR")"
[[ "$SOURCE_DIR" != "$SKILL_DIR" ]] || die "Source and destination are the same installation"

# An explicit foreign-command replacement is an exact-path authorization, but
# it still must be classifiable and writable before upgrade mutates runtime or
# gateway state. Correct links require no directory write and remain valid.
if [[ -n "$CLI_REPLACE_PATH" ]]; then
  cli_link_classify "$CLI_REPLACE_PATH" "$SKILL_DIR/bin/antenna.sh" \
    "$SOURCE_DIR/bin/antenna.sh" || die \
    "Cannot safely classify explicit CLI target: $CLI_REPLACE_PATH"
  case "$CLI_LINK_STATE" in
    directory|other|ambiguous)
      die "Refusing unsafe explicit CLI target: $CLI_REPLACE_PATH ($CLI_LINK_STATE)"
      ;;
    correct) : ;;
    *)
      [[ -w "$(dirname -- "$CLI_REPLACE_PATH")" ]] || die \
        "Explicit CLI target directory is not writable: $(dirname -- "$CLI_REPLACE_PATH")"
      ;;
  esac
fi

# ANT-162-006: refuse before ANY mutation if this release package's relay policy
# is missing, symlinked, the generic OpenClaw workspace template, or otherwise
# not the canonical Antenna relay contract. Upgrade qualification showed that
# copying runtime state and repointing the gateway onto a package
# whose agent/AGENTS.md had been deleted and recreated empty left the relay
# agent interpreting messages instead of executing the mechanical write/exec
# contract. This gate runs before any source copy, staging directory, gateway
# backup/temp, gateway edit, or CLI symlink change.
relay_policy_reason=""
if ! relay_policy_require_canonical "$SKILL_DIR/agent/AGENTS.md" "agent/AGENTS.md" relay_policy_reason; then
  die "Destination relay policy $SKILL_DIR/agent/AGENTS.md is not a canonical Antenna relay contract ($relay_policy_reason).
   Restore this release package's agent/AGENTS.md from the original Antenna download, then rerun the upgrade.
   No runtime state, gateway config, gateway backup, or CLI symlink was changed."
fi
for workspace_db in "$SKILL_DIR/agent/openclaw-agent.sqlite" "$SKILL_DIR/agent/openclaw-agent.sqlite-wal" "$SKILL_DIR/agent/openclaw-agent.sqlite-shm"; do
  [[ ! -e "$workspace_db" && ! -L "$workspace_db" ]] || die \
    "Destination Antenna workspace contains OpenClaw agent state: $workspace_db. Restore a clean release package and keep agentDir under OpenClaw's state directory."
done

SOURCE_CONFIG="$SOURCE_DIR/antenna-config.json"
SOURCE_PEERS="$SOURCE_DIR/antenna-peers.json"
[[ -f "$SOURCE_CONFIG" && ! -L "$SOURCE_CONFIG" ]] || die "Source antenna-config.json is missing or unsafe"
[[ -f "$SOURCE_PEERS" && ! -L "$SOURCE_PEERS" ]] || die "Source antenna-peers.json is missing or unsafe"
for source_db in "$SOURCE_DIR/agent/openclaw-agent.sqlite" "$SOURCE_DIR/agent/openclaw-agent.sqlite-wal" "$SOURCE_DIR/agent/openclaw-agent.sqlite-shm"; do
  [[ ! -e "$source_db" && ! -L "$source_db" ]] || die \
    "Source Antenna workspace contains OpenClaw agent state: $source_db. Stop OpenClaw and migrate that database into OpenClaw's stable agentDir before upgrading."
done
jq empty "$SOURCE_CONFIG" >/dev/null 2>&1 || die "Source antenna-config.json is invalid JSON"
jq empty "$SOURCE_PEERS" >/dev/null 2>&1 || die "Source antenna-peers.json is invalid JSON"
jq -e '[to_entries[] | select((.value | type) == "object" and .value.self == true)] | length == 1' \
  "$SOURCE_PEERS" >/dev/null 2>&1 || die "Source peers must contain exactly one self identity"

configured_path="$(jq -r '.install_path // empty' "$SOURCE_CONFIG")"
[[ -n "$configured_path" ]] || die "Source config has no install_path"
[[ "$(realpath -m "$configured_path")" == "$SOURCE_DIR" ]] \
  || die "Source config install_path does not match --from: $configured_path"

runtime_names=(
  antenna-config.json antenna-peers.json antenna-lists.json
  antenna-public-groups.json antenna-inbox.json antenna-ratelimit.json
  antenna.log secrets keys state
)
for name in "${runtime_names[@]}"; do
  [[ ! -e "$SKILL_DIR/$name" && ! -L "$SKILL_DIR/$name" ]] \
    || die "Destination runtime state already exists: $SKILL_DIR/$name"
done
if compgen -G "$SKILL_DIR/antenna.log.*" >/dev/null; then
  die "Destination rotated Antenna logs already exist"
fi
agent_runtime_names=(
  .openclaw BOOTSTRAP.md HEARTBEAT.md IDENTITY.md SOUL.md USER.md
  auth-profiles.json models.json memory
)
for name in "${agent_runtime_names[@]}"; do
  [[ ! -e "$SKILL_DIR/agent/$name" && ! -L "$SKILL_DIR/agent/$name" ]] \
    || die "Destination agent runtime state already exists: $SKILL_DIR/agent/$name"
done

if [[ -z "$GATEWAY_CONFIG" ]]; then
  for candidate in "$HOME/.openclaw/openclaw.json" "/home/${USER:-}/.openclaw/openclaw.json"; do
    if [[ -f "$candidate" ]]; then GATEWAY_CONFIG="$candidate"; break; fi
  done
fi
[[ -n "$GATEWAY_CONFIG" && -f "$GATEWAY_CONFIG" && ! -L "$GATEWAY_CONFIG" ]] \
  || die "OpenClaw gateway config not found; pass --gateway explicitly"
jq empty "$GATEWAY_CONFIG" >/dev/null 2>&1 || die "Gateway config is invalid JSON: $GATEWAY_CONFIG"

# OpenClaw 8.1 owns the one-time migration of retired workspace/config/state
# surfaces. Refuse before copying any state or changing the gateway so the
# operator can run Doctor while the old Antenna workspace is still active.
agent_runtime_copy_names=("${agent_runtime_names[@]}")
gateway_openclaw_generation \
  || die "Could not identify the installed OpenClaw generation"
if [[ "$GATEWAY_OPENCLAW_GENERATION" == "entries" ]]; then
  legacy_config_paths="$(jq -r '
    [
      (if ((.meta? | type) == "object" and (.meta | has("lastTouchedAt")))
       then "meta.lastTouchedAt" else empty end),
      (if ((.gateway.controlUi? | type) == "object" and (.gateway.controlUi | has("allowInsecureAuth")))
       then "gateway.controlUi.allowInsecureAuth" else empty end),
      (if ((.gateway.tailscale? | type) == "object" and (.gateway.tailscale | has("resetOnExit")))
       then "gateway.tailscale.resetOnExit" else empty end)
    ] | join(", ")
  ' "$GATEWAY_CONFIG")"
  [[ -z "$legacy_config_paths" ]] || die \
    "OpenClaw 8.1 config migration is incomplete ($legacy_config_paths); with the gateway stopped, run 'OPENCLAW_CONFIG_PATH=$GATEWAY_CONFIG openclaw doctor --fix', validate, then rerun Antenna upgrade"

  if jq -e '.plugins.entries["lossless-claw"].config | has("autoRotateSessionFiles")' \
      "$GATEWAY_CONFIG" >/dev/null 2>&1; then
    die "Configured lossless-claw still uses retired autoRotateSessionFiles; install a compatible plugin version, reconcile that plugin-owned setting, validate with OpenClaw, then rerun Antenna upgrade"
  fi

  openclaw_state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
  if [[ -f "$openclaw_state_dir/exec-approvals.json" ]]; then
    die "Legacy exec approvals remain at $openclaw_state_dir/exec-approvals.json; migrate and verify them in OpenClaw's canonical approvals store with the gateway stopped, then rerun Antenna upgrade"
  fi

  if [[ -e "$SOURCE_DIR/agent/HEARTBEAT.md" || -L "$SOURCE_DIR/agent/HEARTBEAT.md" ]]; then
    die "OpenClaw 8.1 no longer reads agent/HEARTBEAT.md; while the gateway still points to $SOURCE_DIR/agent, run 'OPENCLAW_CONFIG_PATH=$GATEWAY_CONFIG openclaw doctor --fix', verify HEARTBEAT.md was migrated into cron scratch and removed, then rerun Antenna upgrade"
  fi
  if [[ -e "$SKILL_DIR/agent/HEARTBEAT.md" || -L "$SKILL_DIR/agent/HEARTBEAT.md" \
      || -e "$SKILL_DIR/agent/TOOLS.md" || -L "$SKILL_DIR/agent/TOOLS.md" ]]; then
    die "Destination relay workspace contains retired OpenClaw 8.1 bootstrap files (HEARTBEAT.md or TOOLS.md)"
  fi

  # HEARTBEAT.md is deliberately retained for supported 7.x upgrades only.
  agent_runtime_copy_names=()
  for name in "${agent_runtime_names[@]}"; do
    [[ "$name" == "HEARTBEAT.md" ]] || agent_runtime_copy_names+=("$name")
  done
fi

gateway_roster_prepare_mutation "$GATEWAY_CONFIG" \
  || die "Gateway roster is not safe for automatic Antenna upgrade"
gateway_roster_has_agent "$GATEWAY_CONFIG" antenna "$GATEWAY_ROSTER_KIND" \
  || die "Gateway config has no existing Antenna agent"

# A v1.6.3 installation may have left the rejected deterministic mapping and
# transform in OpenClaw state. Audit both before any mutation. Only the exact
# canonical v1.6.3 artifacts are eligible for automatic removal.
v163_mapping_audit="$(v163_staging_mapping_audit "$GATEWAY_CONFIG")" \
  || die "Could not audit the superseded v1.6.3 hook mapping"
[[ "$v163_mapping_audit" != fail\|* ]] \
  || die "Refusing customized/conflicting v1.6.3 hook mapping: ${v163_mapping_audit#fail|}"
v163_transform_dir=""
v163_staging_resolve_transforms_dir "$GATEWAY_CONFIG" v163_transform_dir \
  || die "Cannot safely resolve hooks.transformsDir for v1.6.3 staging cleanup"
v163_transform_live="$v163_transform_dir/$V163_STAGING_MODULE"
v163_transform_audit="$(v163_staging_transform_audit "$v163_transform_live")"
[[ "$v163_transform_audit" != fail\|* ]] \
  || die "Refusing customized/unsafe v1.6.3 transform: ${v163_transform_audit#fail|}"

antenna_change_plan_reset "Antenna upgrade change plan"
antenna_change_plan_add "Copy runtime and agent state from $SOURCE_DIR to $SKILL_DIR without changing the source"
antenna_change_plan_add "Update install_path in the copied Antenna configuration"
antenna_change_plan_add "Back up and repoint the Antenna agent in $GATEWAY_CONFIG"
if [[ "$v163_mapping_audit" == pass\|* || "$v163_transform_audit" == pass\|* ]]; then
  antenna_change_plan_add "Remove only the exact canonical v1.6.3 staging residue"
fi
if [[ -n "$CLI_REPLACE_PATH" ]]; then
  antenna_change_plan_add "Install the Antenna command at $CLI_REPLACE_PATH; preserve any displaced target in a private backup"
else
  antenna_change_plan_add "Repoint Antenna-owned standard CLI links; preserve foreign targets"
fi
antenna_change_plan_add "Preserve peer authentication exactly; no peer is contacted or silently converted"
antenna_change_plan_add "Require a gateway restart after upgrade; upgrade will not restart it automatically"
antenna_change_plan_show

if antenna_change_plan_confirm "$ASSUME_YES" "Proceed with Antenna upgrade?"; then
  :
else
  plan_rc=$?
  if [[ "$plan_rc" -eq 2 ]]; then
    exit 2
  fi
  info "Upgrade cancelled. No runtime state, credentials, gateway configuration, CLI target, or peer state was changed."
  exit 0
fi

stage="$(mktemp -d "$SKILL_DIR/.antenna-upgrade.XXXXXX")"
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT

copy_state() {
  local name="$1" source="$SOURCE_DIR/$1"
  [[ -e "$source" || -L "$source" ]] || return 0
  [[ ! -L "$source" ]] || die "Refusing symlinked runtime state: $source"
  if [[ -d "$source" ]] && find "$source" -type l -print -quit | grep -q .; then
    die "Refusing runtime directory containing symlinks: $source"
  fi
  cp -a -- "$source" "$stage/$name"
}

for name in "${runtime_names[@]}"; do copy_state "$name"; done
while IFS= read -r log_file; do
  copy_state "$(basename "$log_file")"
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name 'antenna.log.*' -print | sort)

mkdir -p "$stage/agent-runtime"
for name in "${agent_runtime_copy_names[@]}"; do
  source="$SOURCE_DIR/agent/$name"
  [[ -e "$source" || -L "$source" ]] || continue
  [[ ! -L "$source" ]] || die "Refusing symlinked agent runtime state: $source"
  if [[ -d "$source" ]] && find "$source" -type l -print -quit | grep -q .; then
    die "Refusing agent runtime directory containing symlinks: $source"
  fi
  cp -a -- "$source" "$stage/agent-runtime/$name"
done

for json_name in antenna-lists.json antenna-public-groups.json antenna-inbox.json antenna-ratelimit.json; do
  if [[ -f "$stage/$json_name" ]]; then
    jq empty "$stage/$json_name" >/dev/null 2>&1 || die "Source $json_name is invalid JSON"
  fi
done

# Older installs may have created private runtime directories under the
# process umask. Harden only the copied destination; never mutate the source.
for private_dir in secrets keys state agent-runtime/.openclaw agent-runtime/memory; do
  [[ -d "$stage/$private_dir" ]] && chmod 700 "$stage/$private_dir"
done

config_tmp="$stage/.antenna-config.next"
jq --arg install_path "$SKILL_DIR" '.install_path = $install_path' \
  "$stage/antenna-config.json" > "$config_tmp"
chmod --reference="$stage/antenna-config.json" "$config_tmp" 2>/dev/null || chmod 600 "$config_tmp"
mv -- "$config_tmp" "$stage/antenna-config.json"

gateway_dir="$(dirname "$GATEWAY_CONFIG")"
openclaw_state_root="$(realpath -m "${OPENCLAW_STATE_DIR:-$gateway_dir}")"
gateway_backup="$(mktemp "$GATEWAY_CONFIG.antenna-upgrade-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")"
gateway_paths_tmp="$(mktemp "$gateway_dir/.openclaw.antenna-paths.XXXXXX")"
gateway_tmp="$(mktemp "$gateway_dir/.openclaw.antenna-upgrade.XXXXXX")"
trap 'rm -f -- "$gateway_paths_tmp" "$gateway_tmp"; cleanup' EXIT
gateway_roster_write_agent_paths_candidate \
  "$GATEWAY_CONFIG" "$gateway_paths_tmp" "$SKILL_DIR/agent" "$openclaw_state_root" \
  || die "Could not construct the gateway path update"
v163_staging_write_cleanup_candidate "$gateway_paths_tmp" "$gateway_tmp" \
  || die "Could not remove the exact superseded v1.6.3 hook mapping"
rm -f -- "$gateway_paths_tmp"
gateway_roster_prepare_mutation "$gateway_tmp" \
  || die "Generated gateway config failed OpenClaw validation"

cp -- "$GATEWAY_CONFIG" "$gateway_backup"
chmod 600 "$gateway_backup" 2>/dev/null || true
chmod --reference="$GATEWAY_CONFIG" "$gateway_tmp" 2>/dev/null || true
chown --reference="$GATEWAY_CONFIG" "$gateway_tmp" 2>/dev/null || true

moved=()
rollback_destination() {
  local item
  for item in "${moved[@]}"; do rm -rf -- "$SKILL_DIR/$item"; done
}
for staged_path in "$stage"/*; do
  [[ -e "$staged_path" ]] || continue
  name="$(basename "$staged_path")"
  if [[ "$name" == "agent-runtime" ]]; then
    continue
  fi
  mv -- "$staged_path" "$SKILL_DIR/$name" || {
    rollback_destination
    die "Could not install migrated runtime state"
  }
  moved+=("$name")
done

agent_moved=()
for staged_path in "$stage/agent-runtime"/* "$stage/agent-runtime"/.[!.]*; do
  [[ -e "$staged_path" ]] || continue
  name="$(basename "$staged_path")"
  mv -- "$staged_path" "$SKILL_DIR/agent/$name" || {
    for item in "${agent_moved[@]}"; do rm -rf -- "$SKILL_DIR/agent/$item"; done
    rollback_destination
    die "Could not install migrated agent runtime state"
  }
  agent_moved+=("$name")
done

if ! mv -- "$gateway_tmp" "$GATEWAY_CONFIG"; then
  for item in "${agent_moved[@]}"; do rm -rf -- "$SKILL_DIR/agent/$item"; done
  rollback_destination
  die "Could not update gateway config; source and gateway backup remain intact"
fi

if [[ "$v163_transform_audit" == pass\|* ]]; then
  v163_staging_remove_transform_if_canonical "$v163_transform_live" \
    || die "Gateway was updated, but the canonical v1.6.3 transform could not be removed: $v163_transform_live"
fi

repointed=0
cli_ready=0
cli_backups=()
for cli_link in "$HOME/.local/bin/antenna" /usr/local/bin/antenna; do
  [[ -e "$cli_link" || -L "$cli_link" || "$CLI_REPLACE_PATH" == "$cli_link" ]] || continue
  replace_foreign=false
  [[ "$CLI_REPLACE_PATH" == "$cli_link" ]] && replace_foreign=true
  if [[ "$replace_foreign" == "true" ]]; then
    warn "Explicit CLI replacement requested: $cli_link"
    info "Any displaced target will be preserved in a private backup beside the link."
  fi
  if cli_link_apply "$cli_link" "$SKILL_DIR/bin/antenna.sh" \
      "$SOURCE_DIR/bin/antenna.sh" "$replace_foreign"; then
    case "$CLI_LINK_ACTION" in
      repointed|replaced)
        repointed=$((repointed + 1))
        cli_ready=$((cli_ready + 1))
        [[ -z "$CLI_LINK_BACKUP" ]] || cli_backups+=("$CLI_LINK_BACKUP")
        ;;
      unchanged) cli_ready=$((cli_ready + 1)) ;;
    esac
  else
    case "$CLI_LINK_STATE" in
      foreign_symlink|regular_file)
        warn "Preserving foreign CLI target: $cli_link ($CLI_LINK_STATE)"
        info "To replace this exact target with a recoverable backup, rerun with: --replace-cli-link $cli_link"
        ;;
      directory|other|ambiguous) warn "Refusing unsafe CLI target: $cli_link ($CLI_LINK_STATE)" ;;
      *) warn "Could not safely repoint CLI link: $cli_link" ;;
    esac
  fi
done

# An explicit path outside the standard locations is handled exactly once.
if [[ -n "$CLI_REPLACE_PATH" \
    && "$CLI_REPLACE_PATH" != "$HOME/.local/bin/antenna" \
    && "$CLI_REPLACE_PATH" != "/usr/local/bin/antenna" ]]; then
  warn "Explicit CLI replacement requested: $CLI_REPLACE_PATH"
  info "The displaced target will be preserved in a private backup beside the link."
  if cli_link_apply "$CLI_REPLACE_PATH" "$SKILL_DIR/bin/antenna.sh" \
      "$SOURCE_DIR/bin/antenna.sh" true; then
    case "$CLI_LINK_ACTION" in
      repointed|replaced|installed)
        repointed=$((repointed + 1))
        cli_ready=$((cli_ready + 1))
        ;;
      unchanged) cli_ready=$((cli_ready + 1)) ;;
    esac
    [[ -z "$CLI_LINK_BACKUP" ]] || cli_backups+=("$CLI_LINK_BACKUP")
  else
    warn "Could not safely replace explicit CLI target: $CLI_REPLACE_PATH ($CLI_LINK_STATE)"
  fi
fi

ok "Copied runtime state without modifying $SOURCE_DIR"
ok "Updated install_path to $SKILL_DIR"
ok "Repointed gateway Antenna workspace to $SKILL_DIR/agent"
ok "Kept Antenna agent state under $openclaw_state_root/agents/antenna/agent"
if [[ "$v163_mapping_audit" == pass\|* || "$v163_transform_audit" == pass\|* ]]; then
  ok "Removed exact canonical v1.6.3 deterministic-staging residue"
fi
ok "Gateway backup: $gateway_backup"
if [[ "$repointed" -gt 0 ]]; then
  ok "Updated $repointed Antenna CLI symlink(s)"
elif [[ "$cli_ready" -gt 0 ]]; then
  ok "Antenna CLI symlink already targets this release"
else
  warn "No existing Antenna CLI symlink targeted the source; invoke $SKILL_DIR/bin/antenna.sh directly"
fi
for cli_backup in "${cli_backups[@]}"; do
  warn "Recoverable displaced CLI target: $cli_backup"
done
echo ""
warn "Legacy peers were preserved exactly and are not silently upgraded."
warn "Complete a fresh encrypted Ed25519 re-pair for each legacy peer before sending."
if [[ "$GATEWAY_OPENCLAW_GENERATION" == "entries" ]]; then
  info "OpenClaw 8.1 workspace/config preflight passed; Tailscale ingress and plugin lifecycle remain OpenClaw-owned."
  info "Upgrade checklist: $SKILL_DIR/references/OPENCLAW-2026.8.1-UPGRADE.md"
fi
info "Restart OpenClaw, then run: $SKILL_DIR/bin/antenna.sh doctor"
