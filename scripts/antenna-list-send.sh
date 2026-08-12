#!/usr/bin/env bash
# Expand one local @alias into independent existing unicast sends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
LISTS_FILE="$SKILL_DIR/antenna-lists.json"
PEERS_FILE="$SKILL_DIR/antenna-peers.json"
CONFIG_FILE="$SKILL_DIR/antenna-config.json"
SENDER="$SCRIPT_DIR/antenna-send.sh"

# shellcheck source=../lib/peers.sh
source "$SKILL_DIR/lib/peers.sh"
# shellcheck source=../lib/antenna-signature.sh
source "$SKILL_DIR/lib/antenna-signature.sh"

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

[[ $# -ge 1 ]] || die "Usage: antenna send @alias [options] <message>"
ALIAS_REF="$1"; shift
[[ "$ALIAS_REF" =~ ^@[a-z0-9][a-z0-9._-]{0,63}$ ]] || die "Invalid distribution-list alias"
ALIAS="${ALIAS_REF#@}"
[[ -f "$LISTS_FILE" && ! -L "$LISTS_FILE" ]] || die "Distribution-list file must be a regular non-symlink file: $LISTS_FILE"
[[ -f "$PEERS_FILE" && -f "$CONFIG_FILE" ]] || die "Antenna peer/config files are missing"

# Validate arguments before any member can be contacted. The existing sender
# remains authoritative for field/body limits and envelope construction.
READ_STDIN=false
POSITIONAL=0
ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session|--subject|--user|--reply-to) [[ $# -ge 2 ]] || die "$1 requires a value"; shift 2 ;;
    --dry-run|--json) shift ;;
    --stdin) READ_STDIN=true; shift ;;
    -*) die "Unknown option: $1" ;;
    *) POSITIONAL=$((POSITIONAL + 1)); shift ;;
  esac
done
[[ "$READ_STDIN" == false || "$POSITIONAL" -eq 0 ]] || die "Do not combine --stdin with a positional message"
[[ "$READ_STDIN" == true || "$POSITIONAL" -gt 0 ]] || die "No message provided. Use positional arg or --stdin."

jq -e '
  type == "object" and length <= 100 and
  all(to_entries[];
    (.key | test("^[a-z0-9][a-z0-9._-]{0,63}$")) and
    (.value | type == "array" and length > 0 and length <= 100) and
    all(.value[]; type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$")))
' "$LISTS_FILE" >/dev/null 2>&1 || die "Malformed or oversized antenna-lists.json"
jq -e --arg alias "$ALIAS" 'has($alias)' "$LISTS_FILE" >/dev/null || die "Unknown distribution list: @$ALIAS"
mapfile -t MEMBERS < <(jq -r --arg alias "$ALIAS" '.[$alias] | unique | sort[]' "$LISTS_FILE")
[[ ${#MEMBERS[@]} -gt 0 ]] || die "Distribution list @$ALIAS is empty"

SELF_ID=$(peers_single_self_id) || die "Expected exactly one configured self peer"
NEED_ED=false NEED_LEGACY=false
for member in "${MEMBERS[@]}"; do
  PEER_URL="" TOKEN_FILE="" AUTH_MODE=""
  [[ "$member" != "$SELF_ID" ]] || die "Distribution list @$ALIAS contains self peer '$member'"
  peers_exists "$member" || die "Distribution list @$ALIAS contains unknown peer '$member'"
  jq -e --arg peer "$member" '
    (.allowed_outbound_peers | type == "array") and
    all(.allowed_outbound_peers[]; type == "string") and
    (.allowed_outbound_peers | index($peer) != null)
  ' "$CONFIG_FILE" >/dev/null 2>&1 || die "Distribution list @$ALIAS contains disallowed peer '$member'"
  PEER_URL=$(peers_get "$member" url)
  validate_peer_url "$PEER_URL" >/dev/null 2>&1 || die "Distribution list @$ALIAS contains unconfigured peer '$member' (url)"
  TOKEN_FILE=$(peers_get "$member" token_file)
  [[ -n "$TOKEN_FILE" && "$TOKEN_FILE" != /* ]] && TOKEN_FILE="$SKILL_DIR/$TOKEN_FILE"
  [[ -f "$TOKEN_FILE" && -r "$TOKEN_FILE" ]] || die "Distribution list @$ALIAS contains unconfigured peer '$member' (token)"
  AUTH_MODE=$(peers_get "$member" auth_mode)
  case "$AUTH_MODE" in
    ed25519-v1) NEED_ED=true ;;
    plaintext-legacy) NEED_LEGACY=true ;;
    *) die "Distribution list @$ALIAS contains unconfigured peer '$member' (auth_mode)" ;;
  esac
done
if [[ "$NEED_ED" == true ]]; then
  PRIVATE_KEY=$(peers_get "$SELF_ID" signing_private_key_file)
  [[ -n "$PRIVATE_KEY" && "$PRIVATE_KEY" != /* ]] && PRIVATE_KEY="$SKILL_DIR/$PRIVATE_KEY"
  signature_private_key_ok "$PRIVATE_KEY" || die "Self Ed25519 credential is missing or unsafe"
fi
if [[ "$NEED_LEGACY" == true ]]; then
  SECRET_FILE=$(peers_get "$SELF_ID" peer_secret_file)
  [[ -n "$SECRET_FILE" && "$SECRET_FILE" != /* ]] && SECRET_FILE="$SKILL_DIR/$SECRET_FILE"
  legacy_secret_file_ok "$SECRET_FILE" || die "Self legacy credential is missing or unsafe"
fi

BODY_FILE=""
RESULTS_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-list-results.XXXXXX") || die "Could not create results file"
OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-list-output.XXXXXX") || { rm -f "$RESULTS_FILE"; die "Could not create output file"; }
ERROR_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-list-error.XXXXXX") || { rm -f "$RESULTS_FILE" "$OUTPUT_FILE"; die "Could not create error file"; }
trap 'rm -f "$BODY_FILE" "$RESULTS_FILE" "$OUTPUT_FILE" "$ERROR_FILE"' EXIT
chmod 0600 "$RESULTS_FILE" "$OUTPUT_FILE" "$ERROR_FILE"
if [[ "$READ_STDIN" == true ]]; then
  BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-list-body.XXXXXX") || die "Could not stage stdin"
  chmod 0600 "$BODY_FILE"
  cat >"$BODY_FILE"
fi

OVERALL=0
for member in "${MEMBERS[@]}"; do
  set +e
  if [[ "$READ_STDIN" == true ]]; then
    bash "$SENDER" "$member" "${ARGS[@]}" <"$BODY_FILE" >"$OUTPUT_FILE" 2>"$ERROR_FILE"
  else
    bash "$SENDER" "$member" "${ARGS[@]}" >"$OUTPUT_FILE" 2>"$ERROR_FILE"
  fi
  rc=$?
  set -e
  [[ ! -s "$ERROR_FILE" ]] || cat "$ERROR_FILE" >&2
  [[ $rc -eq 0 ]] || OVERALL=1
  if jq -e . "$OUTPUT_FILE" >/dev/null 2>&1; then
    jq -n --arg peer "$member" --argjson exit_code "$rc" --slurpfile sender "$OUTPUT_FILE" \
      '{peer:$peer,ok:($exit_code == 0),exit_code:$exit_code,sender:$sender[0]}' >>"$RESULTS_FILE"
  else
    jq -n --arg peer "$member" --argjson exit_code "$rc" --rawfile output "$OUTPUT_FILE" \
      '{peer:$peer,ok:($exit_code == 0),exit_code:$exit_code,sender_output:$output}' >>"$RESULTS_FILE"
  fi
done
jq -s --arg alias "@$ALIAS" '{alias:$alias,total:length,succeeded:map(select(.ok))|length,failed:map(select(.ok|not))|length,results:.}' "$RESULTS_FILE"
exit "$OVERALL"
