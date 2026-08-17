#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
ROUTES_FILE="$SKILL_DIR/antenna-public-groups.json"
SEND_SCRIPT="$SKILL_DIR/scripts/antenna-send.sh"

die() { printf 'Error: %s\n' "$1" >&2; exit "${2:-1}"; }

validate_routes() {
  [[ -f "$ROUTES_FILE" && ! -L "$ROUTES_FILE" ]] || die "Create antenna-public-groups.json from the example first"
  jq -e '
    type == "object" and length > 0 and
    all(to_entries[];
      (.key | test("^[a-z0-9][a-z0-9._-]{0,63}$")) and
      (.value | type == "object" and keys == ["group_id", "name", "relay_peer"]) and
      (.value.group_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
      (.value.name | type == "string" and length > 0 and length <= 128) and
      (.value.relay_peer | test("^[a-z0-9][a-z0-9._-]{0,63}$"))
    )
  ' "$ROUTES_FILE" >/dev/null 2>&1 || die "Invalid Public Group route file"
}

list_groups() {
  validate_routes
  jq -r 'to_entries | sort_by(.key)[] | "@\(.key)\t\(.value.name)\t\(.value.group_id)\trelay=\(.value.relay_peer)"' "$ROUTES_FILE"
}

send_group() {
  local alias="${1:-}" message="${2:-}" subject=""
  [[ -n "$alias" && -n "$message" ]] || die "Usage: antenna groups send <alias> <message> [--subject <text>]"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject) [[ $# -ge 2 ]] || die "--subject requires a value"; subject="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  alias="${alias#@}"
  validate_routes
  local route group_id relay body send_output send_rc failed
  route=$(jq -cer --arg alias "$alias" '.[$alias]' "$ROUTES_FILE") || die "Unknown Public Group: @$alias"
  group_id=$(jq -r '.group_id' <<<"$route")
  relay=$(jq -r '.relay_peer' <<<"$route")
  body=$(mktemp "${TMPDIR:-/tmp}/antenna-public-group.XXXXXX")
  chmod 0600 "$body"
  trap "rm -f -- $(printf '%q' "$body")" EXIT
  {
    printf '[ANTENNA_PUBLIC_GROUP v=1]\n'
    printf 'group_id: %s\n' "$group_id"
    printf '[/ANTENNA_PUBLIC_GROUP]\n\n'
    printf '%s' "$message"
  } >"$body"
  if [[ -n "$subject" ]]; then
    if send_output=$("$SEND_SCRIPT" "$relay" --include-response --subject "$subject" --stdin <"$body"); then
      send_rc=0
    else
      send_rc=$?
    fi
  else
    if send_output=$("$SEND_SCRIPT" "$relay" --include-response --stdin <"$body"); then
      send_rc=0
    else
      send_rc=$?
    fi
  fi
  printf '%s\n' "$send_output"
  (( send_rc == 0 )) || exit "$send_rc"
  failed=$(jq -er '.response.failed | select(type == "number" and . >= 0 and floor == .)' <<<"$send_output") \
    || die "ClawReef did not return Public Group delivery results" 5
  (( failed == 0 )) || die "Public Group fan-out reported $failed failed delivery attempt(s)" 5
}

case "${1:-}" in
  list) list_groups ;;
  send) shift; send_group "$@" ;;
  *)
    echo "Usage: antenna groups list" >&2
    echo "       antenna groups send <alias> <message> [--subject <text>]" >&2
    exit 1
    ;;
esac
