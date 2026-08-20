#!/usr/bin/env bash
# antenna-upgrade.sh — Preserve runtime state while moving to a side-by-side install.
#
# This is deliberately a local, one-host migration. It does not negotiate auth
# modes or contact peers. Existing v1.5.2 peers remain unusable until the
# operator completes the documented fresh Ed25519 re-pair.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

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

The destination is the Antenna tree containing this command. The migration:
  - refuses to overwrite any destination runtime state;
  - copies local config, peers, lists, Public Group routes, queues, keys,
    secrets, replay/rate state, logs, and ignored agent-local runtime files
    without changing the source;
  - updates only install_path in the copied Antenna config;
  - backs up openclaw.json and repoints the existing Antenna agent's agentDir
    and workspace to this release; and
  - repoints an existing Antenna CLI symlink when it targets the old release.

It does not silently convert legacy peer authentication. Re-pair every old
plaintext peer with Ed25519 after migration.
EOF
  exit 0
}

SOURCE_DIR=""
GATEWAY_CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) SOURCE_DIR="${2:-}"; shift 2 ;;
    --gateway) GATEWAY_CONFIG="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required for a safe upgrade"
command -v realpath >/dev/null 2>&1 || die "realpath is required for a safe upgrade"

[[ -n "$SOURCE_DIR" ]] || die "Missing --from /path/to/old/antenna"
[[ -d "$SOURCE_DIR" ]] || die "Source installation does not exist: $SOURCE_DIR"
SOURCE_DIR="$(realpath "$SOURCE_DIR")"
SKILL_DIR="$(realpath "$SKILL_DIR")"
[[ "$SOURCE_DIR" != "$SKILL_DIR" ]] || die "Source and destination are the same installation"

SOURCE_CONFIG="$SOURCE_DIR/antenna-config.json"
SOURCE_PEERS="$SOURCE_DIR/antenna-peers.json"
[[ -f "$SOURCE_CONFIG" && ! -L "$SOURCE_CONFIG" ]] || die "Source antenna-config.json is missing or unsafe"
[[ -f "$SOURCE_PEERS" && ! -L "$SOURCE_PEERS" ]] || die "Source antenna-peers.json is missing or unsafe"
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
jq -e '.agents.list | type == "array" and any(.[]; .id == "antenna")' \
  "$GATEWAY_CONFIG" >/dev/null 2>&1 \
  || die "Gateway config has no existing agents.list entry with id=antenna"

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
for name in "${agent_runtime_names[@]}"; do
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
gateway_backup="$GATEWAY_CONFIG.antenna-upgrade-backup-$(date +%Y%m%d-%H%M%S)"
gateway_tmp="$(mktemp "$gateway_dir/.openclaw.antenna-upgrade.XXXXXX")"
trap 'rm -f -- "$gateway_tmp"; cleanup' EXIT
jq --arg agentdir "$SKILL_DIR/agent" '
  .agents.list = [.agents.list[] |
    if .id == "antenna" then
      .agentDir = $agentdir | .workspace = $agentdir
    else . end
  ]
' "$GATEWAY_CONFIG" > "$gateway_tmp"
jq empty "$gateway_tmp" >/dev/null 2>&1 || die "Generated gateway config failed validation"

cp -- "$GATEWAY_CONFIG" "$gateway_backup"
chmod 600 "$gateway_backup" 2>/dev/null || true

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
chmod 600 "$GATEWAY_CONFIG" 2>/dev/null || true

repointed=0
for cli_link in "$HOME/.local/bin/antenna" /usr/local/bin/antenna; do
  [[ -L "$cli_link" ]] || continue
  link_target="$(readlink -f "$cli_link" 2>/dev/null || true)"
  if [[ "$link_target" == "$SOURCE_DIR/bin/antenna.sh" ]]; then
    if [[ -w "$(dirname "$cli_link")" ]]; then
      ln -sfn "$SKILL_DIR/bin/antenna.sh" "$cli_link"
      repointed=$((repointed + 1))
    else
      warn "Could not repoint unwritable CLI symlink: $cli_link"
    fi
  fi
done

ok "Copied runtime state without modifying $SOURCE_DIR"
ok "Updated install_path to $SKILL_DIR"
ok "Repointed gateway Antenna agentDir/workspace to $SKILL_DIR/agent"
ok "Gateway backup: $gateway_backup"
[[ "$repointed" -gt 0 ]] && ok "Repointed $repointed Antenna CLI symlink(s)" \
  || warn "No existing Antenna CLI symlink targeted the source; invoke $SKILL_DIR/bin/antenna.sh directly"
echo ""
warn "Legacy peers were preserved exactly and are not silently upgraded."
warn "Complete a fresh encrypted Ed25519 re-pair for each legacy peer before sending."
info "Restart OpenClaw, then run: $SKILL_DIR/bin/antenna.sh doctor"
