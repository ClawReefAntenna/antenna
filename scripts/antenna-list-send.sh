#!/usr/bin/env bash
# Local Distribution List fan-out and metadata-based reply-all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
LISTS_FILE="$SKILL_DIR/antenna-lists.json"
PEERS_FILE="$SKILL_DIR/antenna-peers.json"
CONFIG_FILE="$SKILL_DIR/antenna-config.json"
SENDER="$SCRIPT_DIR/antenna-send.sh"
META="$SKILL_DIR/lib/antenna-list-meta.py"
source "$SKILL_DIR/lib/peers.sh"
source "$SKILL_DIR/lib/antenna-signature.sh"
die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

MODE=list SHOW=false SOURCE="" DISPLAY="" LABEL="" READ_STDIN=false
MEMBERS=() OPTIONS=() POSITIONAL=()
[[ $# -ge 1 ]] || die "Usage: antenna send @alias ... | antenna reply-all <sender> --source <file> ..."
if [[ "$1" == "--reply-all" ]]; then
  MODE=reply; shift
  [[ $# -ge 1 && "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die "Reply-all requires a valid original sender peer ID"
  ORIGINAL_SENDER="$1"; shift
else
  ALIAS_REF="$1"; shift
  [[ "$ALIAS_REF" =~ ^@[a-z0-9][a-z0-9._-]{0,63}$ ]] || die "Invalid distribution-list alias"
  ALIAS="${ALIAS_REF#@}"; LABEL="@$ALIAS"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) [[ "$MODE" == reply && $# -ge 2 ]] || die "--source requires reply-all and a file"; SOURCE="$2"; shift 2 ;;
    --show-recipients) [[ "$MODE" == list ]] || die "--show-recipients is only valid with @alias"; SHOW=true; shift ;;
    --session|--subject|--user|--reply-to) [[ $# -ge 2 ]] || die "$1 requires a value"; OPTIONS+=("$1" "$2"); shift 2 ;;
    --dry-run|--json) OPTIONS+=("$1"); shift ;;
    --stdin) READ_STDIN=true; shift ;;
    -*) die "Unknown option: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[[ "$READ_STDIN" == false || ${#POSITIONAL[@]} -eq 0 ]] || die "Do not combine --stdin with a positional message"
[[ "$READ_STDIN" == true || ${#POSITIONAL[@]} -gt 0 ]] || die "No message provided. Use positional arg or --stdin."

if [[ "$MODE" == list ]]; then
  [[ -f "$LISTS_FILE" && ! -L "$LISTS_FILE" ]] || die "Distribution-list file must be a regular non-symlink file"
  jq -e 'type=="object" and length<=100 and all(to_entries[];
    (.key|test("^[a-z0-9][a-z0-9._-]{0,63}$")) and
    ((.value|type)=="array" or ((.value|type)=="object" and (.value|keys|sort)==["display_name","peers"])) and
    ((if (.value|type)=="array" then .value else .value.peers end) as $p |
      ($p|type)=="array" and ($p|length)>0 and ($p|length)<=100 and
      all($p[]; type=="string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))) and
    (if (.value|type)=="object" then
      (.value.display_name|type)=="string" and (.value.display_name|length)>0 and
      (.value.display_name|length)<=100 and (.value.display_name|explode|all(.>=32 and .!=127))
     else true end))' "$LISTS_FILE" >/dev/null 2>&1 || die "Malformed or oversized antenna-lists.json"
  jq -e --arg alias "$ALIAS" 'has($alias)' "$LISTS_FILE" >/dev/null || die "Unknown distribution list: @$ALIAS"
  DISPLAY=$(jq -r --arg alias "$ALIAS" '.[$alias] | if type=="array" then $alias else .display_name end' "$LISTS_FILE")
  mapfile -t MEMBERS < <(jq -r --arg alias "$ALIAS" '.[$alias] | if type=="array" then . else .peers end | unique | sort[]' "$LISTS_FILE")
else
  [[ -n "$SOURCE" && -f "$SOURCE" && ! -L "$SOURCE" ]] || die "Reply-all source must be a regular non-symlink file"
  META_JSON=$(python3 "$META" parse "$SOURCE") || exit 1
  DISPLAY=$(jq -r '.display_name' <<<"$META_JSON"); LABEL="reply-all:$DISPLAY"
  mapfile -t MEMBERS < <(jq -r --arg sender "$ORIGINAL_SENDER" '[.peers[], $sender] | unique | sort[]' <<<"$META_JSON")
fi

SELF_ID=$(peers_single_self_id) || die "Expected exactly one configured self peer"
VALID=() NEED_ED=false NEED_LEGACY=false
for member in "${MEMBERS[@]}"; do
  if [[ "$member" == "$SELF_ID" ]]; then
    [[ "$MODE" == reply ]] && continue
    die "Distribution list $LABEL contains self peer '$member'"
  fi
  reason=""
  peers_exists "$member" || reason="unknown peer"
  if [[ -z "$reason" ]] && ! jq -e --arg peer "$member" '(.allowed_outbound_peers|type)=="array" and all(.allowed_outbound_peers[];type=="string") and (.allowed_outbound_peers|index($peer)!=null)' "$CONFIG_FILE" >/dev/null 2>&1; then reason="not outbound-allowed"; fi
  if [[ -z "$reason" ]]; then url=$(peers_get "$member" url); validate_peer_url "$url" >/dev/null 2>&1 || reason="invalid URL"; fi
  if [[ -z "$reason" ]]; then token=$(peers_get "$member" token_file); [[ -n "$token" && "$token" != /* ]] && token="$SKILL_DIR/$token"; [[ -f "$token" && -r "$token" ]] || reason="missing token"; fi
  if [[ -z "$reason" ]]; then mode=$(peers_get "$member" auth_mode); case "$mode" in ed25519-v1) NEED_ED=true;; plaintext-legacy) NEED_LEGACY=true;; *) reason="unsupported auth mode";; esac; fi
  if [[ -n "$reason" ]]; then
    if [[ "$MODE" == reply ]]; then printf "Warning: skipping peer '%s' (%s)\n" "$member" "$reason" >&2; continue; fi
    die "Distribution list $LABEL contains unavailable peer '$member' ($reason)"
  fi
  VALID+=("$member")
done
MEMBERS=("${VALID[@]}"); [[ ${#MEMBERS[@]} -gt 0 ]] || die "No locally usable recipients remain"
if [[ "$NEED_ED" == true ]]; then key=$(peers_get "$SELF_ID" signing_private_key_file); [[ -n "$key" && "$key" != /* ]] && key="$SKILL_DIR/$key"; signature_private_key_ok "$key" || die "Self Ed25519 credential is missing or unsafe"; fi
if [[ "$NEED_LEGACY" == true ]]; then key=$(peers_get "$SELF_ID" peer_secret_file); [[ -n "$key" && "$key" != /* ]] && key="$SKILL_DIR/$key"; legacy_secret_file_ok "$key" || die "Self legacy credential is missing or unsafe"; fi

BODY="" PREFIXED="" RESULTS="" OUT="" ERR="" SEND_STDIN=false
trap 'rm -f "$BODY" "$PREFIXED" "$RESULTS" "$OUT" "$ERR"' EXIT
if [[ "$READ_STDIN" == true || "$SHOW" == true ]]; then
  BODY=$(mktemp "${TMPDIR:-/tmp}/antenna-list-body.XXXXXX") || die "Could not stage body"; chmod 0600 "$BODY"; SEND_STDIN=true
  if [[ "$READ_STDIN" == true ]]; then cat >"$BODY"; else printf '%s' "${POSITIONAL[*]}" >"$BODY"; fi
fi
if [[ "$SHOW" == true ]]; then
  PREFIXED=$(mktemp "${TMPDIR:-/tmp}/antenna-list-prefixed.XXXXXX") || die "Could not stage metadata"; chmod 0600 "$PREFIXED"
  python3 "$META" prefix "$DISPLAY" "$(IFS=,; echo "${MEMBERS[*]}")" "$BODY" "$PREFIXED" || exit 1
  rm -f "$BODY"; BODY="$PREFIXED"; PREFIXED=""
fi

RESULTS=$(mktemp "${TMPDIR:-/tmp}/antenna-list-results.XXXXXX"); OUT=$(mktemp "${TMPDIR:-/tmp}/antenna-list-out.XXXXXX"); ERR=$(mktemp "${TMPDIR:-/tmp}/antenna-list-err.XXXXXX")
chmod 0600 "$RESULTS" "$OUT" "$ERR"
overall=0
for member in "${MEMBERS[@]}"; do
  set +e
  if [[ "$SEND_STDIN" == true ]]; then bash "$SENDER" "$member" "${OPTIONS[@]}" --stdin <"$BODY" >"$OUT" 2>"$ERR"; else bash "$SENDER" "$member" "${OPTIONS[@]}" "${POSITIONAL[@]}" >"$OUT" 2>"$ERR"; fi
  rc=$?; set -e; [[ ! -s "$ERR" ]] || cat "$ERR" >&2; [[ $rc -eq 0 ]] || overall=1
  if jq -e . "$OUT" >/dev/null 2>&1; then jq -n --arg peer "$member" --argjson rc "$rc" --slurpfile sender "$OUT" '{peer:$peer,ok:($rc==0),exit_code:$rc,sender:$sender[0]}' >>"$RESULTS"; else jq -n --arg peer "$member" --argjson rc "$rc" --rawfile output "$OUT" '{peer:$peer,ok:($rc==0),exit_code:$rc,sender_output:$output}' >>"$RESULTS"; fi
done
jq -s --arg label "$LABEL" --arg alias "${ALIAS_REF:-}" '{alias:(if $alias=="" then null else $alias end),list:$label,total:length,succeeded:map(select(.ok))|length,failed:map(select(.ok|not))|length,results:.}' "$RESULTS"
exit "$overall"
