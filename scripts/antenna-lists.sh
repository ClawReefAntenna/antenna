#!/usr/bin/env bash
# Export/import credential-free local Distribution List snapshots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
LISTS="$SKILL_DIR/antenna-lists.json"
PEERS_FILE="$SKILL_DIR/antenna-peers.json"
CONFIG="$SKILL_DIR/antenna-config.json"
META="$SKILL_DIR/lib/antenna-list-meta.py"
source "$SKILL_DIR/lib/peers.sh"

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }
alias_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }
lists_ok() {
  jq -e 'type=="object" and length<=100 and all(to_entries[];
    (.key|test("^[a-z0-9][a-z0-9._-]{0,63}$")) and
    ((.value|type)=="array" or ((.value|type)=="object" and (.value|keys|sort)==["display_name","peers"])) and
    ((if (.value|type)=="array" then .value else .value.peers end) as $p |
      ($p|type)=="array" and ($p|length)>0 and ($p|length)<=100 and
      all($p[];type=="string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))) and
    (if (.value|type)=="object" then (.value.display_name|type)=="string" and
      (.value.display_name|length)>0 and (.value.display_name|length)<=100 and
      (.value.display_name|explode|all(.>=32 and .!=127)) else true end))' "$1" >/dev/null 2>&1
}

peer_unavailable_reason() {
  local peer="$1" url token mode
  peers_exists "$peer" || { printf 'unknown peer'; return; }
  jq -e --arg p "$peer" '(.allowed_outbound_peers|type)=="array" and
    all(.allowed_outbound_peers[];type=="string") and
    (.allowed_outbound_peers|index($p)!=null)' "$CONFIG" >/dev/null 2>&1 || {
      printf 'not outbound-allowed'; return;
    }
  url=$(peers_get "$peer" url)
  validate_peer_url "$url" >/dev/null 2>&1 || { printf 'invalid or missing URL'; return; }
  token=$(peers_get "$peer" token_file)
  [[ -n "$token" && "$token" != /* ]] && token="$SKILL_DIR/$token"
  [[ -f "$token" && -r "$token" ]] || { printf 'missing or unreadable token'; return; }
  mode=$(peers_get "$peer" auth_mode)
  case "$mode" in
    ed25519-v1|plaintext-legacy) ;;
    *) printf 'unsupported or missing auth_mode'; return ;;
  esac
}

cmd="${1:-}"
shift || true
case "$cmd" in
  export)
    [[ $# -ge 1 ]] || die "Usage: antenna lists export <alias> [--output <file>]"
    alias="${1#@}"; shift
    alias_ok "$alias" || die "Invalid alias"
    output="-"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output) [[ $# -ge 2 ]] || die "--output requires a file"; output="$2"; shift 2 ;;
        *) die "Unknown option: $1" ;;
      esac
    done
    [[ -f "$LISTS" && ! -L "$LISTS" ]] && lists_ok "$LISTS" || die "Distribution-list file is missing or malformed"
    jq -e --arg a "$alias" 'has($a)' "$LISTS" >/dev/null || die "Unknown distribution list: @$alias"
    snapshot=$(jq -c --arg a "$alias" '{schema_version:1,
      display_name:(.[$a]|if type=="array" then $a else .display_name end),
      preferred_alias:$a,
      peers:(.[$a]|if type=="array" then . else .peers end|unique|sort)}' "$LISTS")
    if [[ "$output" == - ]]; then
      jq . <<<"$snapshot"
    else
      [[ ! -L "$output" ]] || die "Refusing symlink output"
      umask 077
      printf '%s\n' "$snapshot" >"$output"
    fi
    ;;
  import)
    [[ $# -ge 1 ]] || die "Usage: antenna lists import <snapshot> [--alias <alias>] [--replace]"
    source_file="$1"; shift
    [[ -f "$source_file" && ! -L "$source_file" ]] || die "Snapshot must be a regular non-symlink file"
    rename=""; replace=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --alias) [[ $# -ge 2 ]] || die "--alias requires a value"; rename="${2#@}"; shift 2 ;;
        --replace) replace=true; shift ;;
        *) die "Unknown option: $1" ;;
      esac
    done
    normalized=$(python3 "$META" snapshot "$source_file") || exit 1
    preferred=$(jq -r '.preferred_alias' <<<"$normalized")
    alias="${rename:-$preferred}"
    alias_ok "$alias" || die "Invalid import alias"
    peers_json=$(jq -c '.peers' <<<"$normalized")
    for peer in $(jq -r '.[]' <<<"$peers_json"); do
      reason=$(peer_unavailable_reason "$peer")
      [[ -z "$reason" ]] || printf "Warning: imported peer '%s' is not locally available (%s)\n" "$peer" "$reason" >&2
    done

    lock="$SKILL_DIR/.antenna-lists.lock"
    exec 9>"$lock"; chmod 0600 "$lock"; flock -x 9
    if [[ -e "$LISTS" ]]; then
      [[ -f "$LISTS" && ! -L "$LISTS" ]] && lists_ok "$LISTS" || die "Distribution-list file is unsafe or malformed"
    else
      printf '{}\n' >"$LISTS"; chmod 600 "$LISTS"
    fi
    if jq -e --arg a "$alias" 'has($a)' "$LISTS" >/dev/null && [[ "$replace" != true ]]; then
      die "Alias @$alias already exists; choose --alias <unused> or --replace"
    fi
    display=$(jq -r '.display_name' <<<"$normalized")
    tmp=$(mktemp "$SKILL_DIR/.antenna-lists.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    jq --arg a "$alias" --arg d "$display" --argjson p "$peers_json" '.[$a]={display_name:$d,peers:$p}' "$LISTS" >"$tmp"
    jq -e 'length<=100' "$tmp" >/dev/null || die "Import would exceed the 100-list limit"
    chmod 600 "$tmp"; mv -f "$tmp" "$LISTS"; trap - EXIT
    jq -n --arg alias "@$alias" --argjson replaced "$replace" --argjson peers "$peers_json" \
      '{alias:$alias,replaced:$replaced,peers:$peers}'
    ;;
  *) die "Usage: antenna lists export|import ..." ;;
esac
