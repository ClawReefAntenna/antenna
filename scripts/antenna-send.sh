#!/usr/bin/env bash
# antenna-send.sh — Send an Antenna relay message to a remote OpenClaw peer.
# Builds [ANTENNA_RELAY] envelope, POSTs to peer's /hooks/agent endpoint.
#
# Usage:
#   antenna-send.sh <peer> [options] <message>
#   antenna-send.sh <peer> [options] --stdin
#
# Options:
#   --session <key>     Target session on recipient (full key, e.g. agent:betty:main)
#   --subject <text>    Optional subject line
#   --reply-to <url>    Override reply URL
#   --include-response  Include a JSON relay response in successful output
#   --dry-run           Print envelope and POST payload without sending
#   --json              Output result as JSON (default)
#
# Exit codes:
#   0 = delivered successfully
#   1 = unknown peer
#   2 = message exceeds max length
#   3 = peer unreachable / connection error
#   4 = auth rejected (401/403)
#   5 = relay rejected by recipient
#   6 = relay timeout
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
PEERS_FILE="$SKILL_DIR/antenna-peers.json"
CONFIG_FILE="$SKILL_DIR/antenna-config.json"

# shellcheck source=../lib/peers.sh
source "$SKILL_DIR/lib/peers.sh"
# shellcheck source=../lib/config.sh
source "$SKILL_DIR/lib/config.sh"
# shellcheck source=../lib/antenna-signature.sh
source "$SKILL_DIR/lib/antenna-signature.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "{\"error\":\"$1\"}" >&2; exit "${2:-1}"; }

# ── REF-400: envelope-marker collision guard ────────────────────────────────
# The [ANTENNA_RELAY] / [/ANTENNA_RELAY] markers frame the wire envelope.
# Any user-controlled value that contains one of those literal strings would
# let an attacker inject a fake close (truncating the real body) and forge a
# second envelope with attacker-chosen headers. There is no legitimate reason
# for a user-supplied field to contain the marker, so we hard-reject.
assert_no_envelope_markers() {
  local field_name="$1"
  local value="$2"
  if [[ "$value" == *"[ANTENNA_RELAY]"* ]] || [[ "$value" == *"[/ANTENNA_RELAY]"* ]]; then
    die "$field_name contains reserved envelope marker ([ANTENNA_RELAY] or [/ANTENNA_RELAY]); refuse to send" 2
  fi
}

log_entry() {
  local log_enabled log_path
  log_enabled=$(config_log_enabled)
  log_path=$(config_log_path)

  if [[ "$log_enabled" != "true" ]]; then return 0; fi

  if [[ "$log_path" != /* ]]; then
    log_path="$SKILL_DIR/$log_path"
  fi

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" >> "$log_path"
}

# ── Parse arguments ─────────────────────────────────────────────────────────

PEER=""
SESSION=""
SUBJECT=""
REPLY_TO_OVERRIDE=""
DRY_RUN=false
READ_STDIN=false
INCLUDE_RESPONSE=false

# First positional arg is the peer
if [[ $# -lt 1 ]]; then
  die "Usage: antenna-send.sh <peer> [options] <message>" 1
fi

PEER="$1"
shift

# Parse remaining args
POSITIONAL=()
USER_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)    SESSION="$2"; shift 2 ;;
    --subject)    SUBJECT="$2"; shift 2 ;;
    --reply-to)   REPLY_TO_OVERRIDE="$2"; shift 2 ;;
    --include-response) INCLUDE_RESPONSE=true; shift ;;
    --user)       USER_NAME="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --json)       shift ;;  # JSON is default, accept silently
    --stdin)      READ_STDIN=true; shift ;;
    -*)           die "Unknown option: $1" 1 ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done

# Stage exact body bytes. Command substitution would discard terminal LFs.
command -v python3 &>/dev/null || die "python3 not found — required for signed message handling" 1
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-send-body.XXXXXX") || die "Could not create body file" 1
CANONICAL_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-send-canonical.XXXXXX") || { rm -f "$BODY_FILE"; die "Could not create canonical file" 1; }
ENVELOPE_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-send-envelope.XXXXXX") || { rm -f "$BODY_FILE" "$CANONICAL_FILE"; die "Could not create envelope file" 1; }
chmod 0600 "$BODY_FILE" "$CANONICAL_FILE" "$ENVELOPE_FILE"
trap 'rm -f "$BODY_FILE" "$CANONICAL_FILE" "$ENVELOPE_FILE"' EXIT
if [[ "$READ_STDIN" == "true" ]]; then
  cat >"$BODY_FILE"
elif [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  printf '%s' "${POSITIONAL[*]}" >"$BODY_FILE"
else
  die "No message provided. Use positional arg or --stdin." 1
fi
python3 - "$BODY_FILE" <<'PY' || die "Message body must be valid UTF-8 without NUL bytes" 2
import pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
assert b"\0" not in data
data.decode("utf-8")
PY

# ── Dependency check ────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  die "jq not found — required for JSON processing" 1
fi

if ! command -v curl &>/dev/null; then
  die "curl not found — required for HTTP requests" 1
fi
if ! command -v openssl &>/dev/null; then
  die "openssl not found — required for Ed25519 signatures" 1
fi

# ── Load peer config ────────────────────────────────────────────────────────

PEER_URL=$(peers_get "$PEER" url)
PEER_AGENT=$(peers_get "$PEER" agentId)
[[ -n "$PEER_AGENT" ]] || PEER_AGENT="antenna"
TOKEN_FILE=$(peers_get "$PEER" token_file)

if [[ -z "$PEER_URL" ]]; then
  die "Unknown peer: $PEER" 1
fi

# Resolve relative token paths against SKILL_DIR
[[ -n "$TOKEN_FILE" && "$TOKEN_FILE" != /* ]] && TOKEN_FILE="$SKILL_DIR/$TOKEN_FILE"

if [[ -z "$TOKEN_FILE" || ! -f "$TOKEN_FILE" ]]; then
  die "Token file not found for peer: $PEER (expected: $TOKEN_FILE)" 1
fi

TOKEN=$(cat "$TOKEN_FILE")

# ── Load config defaults ────────────────────────────────────────────────────

MAX_LEN=$(config_max_message_length)
if [[ ! "$MAX_LEN" =~ ^[1-9][0-9]*$ ]] || (( MAX_LEN > 1000000 )); then
  die "Invalid maximum-message-length configuration" 1
fi

# Session resolution:
# - If --session was explicitly provided, include target_session in envelope.
# - If not, OMIT target_session entirely and let the recipient resolve it
#   from their own default_target_session config. The sender should not need
#   to know the recipient's internal session layout.
TARGET_SESSION="$SESSION"

# Check allowed outbound peers
ALLOWED=$(jq -er --arg peer "$PEER" '
  if (has("allowed_outbound_peers") | not) then "denied"
  elif (.allowed_outbound_peers | type) != "array" or
       (all(.allowed_outbound_peers[]; type == "string") | not)
  then error("invalid outbound allowlist")
  elif (.allowed_outbound_peers | index($peer)) then "allowed"
  else "denied" end
' "$CONFIG_FILE" 2>/dev/null || echo "invalid")

if [[ "$ALLOWED" != "allowed" ]]; then
  die "Peer '$PEER' is not in allowed_outbound_peers" 1
fi

# ── Validate message length ─────────────────────────────────────────────────

MSG_LEN=$(python3 - "$BODY_FILE" <<'PY'
import pathlib, sys
print(len(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")))
PY
)
if [[ "$MSG_LEN" -gt "$MAX_LEN" ]]; then
  die "Message exceeds max length ($MSG_LEN > $MAX_LEN chars)" 2
fi

# ── REF-400: reject envelope markers in user-controlled fields ──────────────
if grep -aFq '[ANTENNA_RELAY]' "$BODY_FILE" || grep -aFq '[/ANTENNA_RELAY]' "$BODY_FILE"; then
  die "message body contains reserved envelope marker ([ANTENNA_RELAY] or [/ANTENNA_RELAY]); refuse to send" 2
fi
assert_no_envelope_markers "--subject" "$SUBJECT"
assert_no_envelope_markers "--user" "$USER_NAME"
assert_no_envelope_markers "--reply-to" "$REPLY_TO_OVERRIDE"

# ── Build sender identity ───────────────────────────────────────────────────

# Find the local peer entry (self: true)
if ! SELF_ID=$(peers_single_self_id); then
  die "Expected exactly one self peer in antenna-peers.json (.self == true). Refusing to guess sender identity from hostname or accept an ambiguous identity." 1
fi
SELF_URL=$(peers_get "$SELF_ID" url)
AUTH_MODE=$(peers_get "$PEER" auth_mode)
case "$AUTH_MODE" in
  ed25519-v1|plaintext-legacy) ;;
  *) die "Peer '$PEER' has missing or unsupported auth_mode" 1 ;;
esac

REPLY_TO="${REPLY_TO_OVERRIDE:-${SELF_URL:+${SELF_URL}/hooks/agent}}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Build envelope ──────────────────────────────────────────────────────────

{
printf '[ANTENNA_RELAY]\n'
if [[ "$AUTH_MODE" == "ed25519-v1" ]]; then
  PRIVATE_KEY_FILE=$(peers_get "$SELF_ID" signing_private_key_file)
  [[ -n "$PRIVATE_KEY_FILE" && "$PRIVATE_KEY_FILE" != /* ]] && PRIVATE_KEY_FILE="$SKILL_DIR/$PRIVATE_KEY_FILE"
  signature_private_key_ok "$PRIVATE_KEY_FILE" || die "Self peer has missing, unsafe, or invalid Ed25519 private key" 1
  MESSAGE_ID=$(signature_uuid_v4) || die "Could not generate message ID" 1
  PROTOCOL="antenna-ed25519-v1"
  signature_canonical_file "$CANONICAL_FILE" "$PROTOCOL" "$SELF_ID" "$TIMESTAMP" "$MESSAGE_ID" \
    "$TARGET_SESSION" "$USER_NAME" "$REPLY_TO" "$SUBJECT" "$BODY_FILE" || die "Could not construct canonical message" 1
  SIGNATURE=$(signature_sign "$PRIVATE_KEY_FILE" "$CANONICAL_FILE") || die "Could not sign message" 1
  printf 'protocol: %s\nfrom: %s\ntimestamp: %s\nmessage_id: %s\n' "$PROTOCOL" "$SELF_ID" "$TIMESTAMP" "$MESSAGE_ID"
else
  SELF_SECRET_FILE=$(peers_get "$SELF_ID" peer_secret_file)
  [[ -n "$SELF_SECRET_FILE" && "$SELF_SECRET_FILE" != /* ]] && SELF_SECRET_FILE="$SKILL_DIR/$SELF_SECRET_FILE"
  legacy_secret_file_ok "$SELF_SECRET_FILE" || die "Self legacy identity secret is missing or unsafe" 1
  SELF_SECRET=$(tr -d '[:space:]' <"$SELF_SECRET_FILE")
  [[ "$SELF_SECRET" =~ ^[0-9a-f]{64}$ ]] || die "Self legacy identity secret is invalid" 1
  echo "WARNING: plaintext-legacy sends a reusable identity secret in every envelope; re-pair to ed25519-v1." >&2
  printf 'from: %s\ntimestamp: %s\n' "$SELF_ID" "$TIMESTAMP"
fi

# Only include target_session if explicitly specified via --session.
# Otherwise, the recipient resolves it from their own config.
if [[ -n "$TARGET_SESSION" ]]; then
  printf 'target_session: %s\n' "$TARGET_SESSION"
fi

if [[ -n "$USER_NAME" ]]; then
  printf 'user: %s\n' "$USER_NAME"
fi

if [[ -n "$REPLY_TO" ]]; then
  printf 'reply_to: %s\n' "$REPLY_TO"
fi

if [[ -n "$SUBJECT" ]]; then
  printf 'subject: %s\n' "$SUBJECT"
fi
if [[ "$AUTH_MODE" == "ed25519-v1" ]]; then
  printf 'signature: ed25519-v1:%s\n' "$SIGNATURE"
else
  printf 'auth: %s\n' "$SELF_SECRET"
fi
printf '\n'
cat "$BODY_FILE"
printf '\n[/ANTENNA_RELAY]'
} >"$ENVELOPE_FILE"

# ── Build POST payload ──────────────────────────────────────────────────────

PAYLOAD=$(jq -n \
  --rawfile msg "$ENVELOPE_FILE" \
  --arg agent "$PEER_AGENT" \
  --arg sk "hook:antenna" \
  --arg name "Antenna/${SELF_ID}" \
  '{message: $msg, agentId: $agent, sessionKey: $sk, name: $name}')

# ── Dry run ──────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== ENVELOPE ==="
  cat "$ENVELOPE_FILE"
  echo
  echo ""
  echo "=== POST PAYLOAD ==="
  echo "$PAYLOAD" | jq .
  echo ""
  echo "=== TARGET ==="
  echo "URL: ${PEER_URL}/hooks/agent"
  echo "Agent: $PEER_AGENT"
  exit 0
fi

# ── Send ─────────────────────────────────────────────────────────────────────

HTTP_RESPONSE=$(curl -s --max-time 30 -w '\n__HTTP_CODE__%{http_code}' \
  -X POST "${PEER_URL}/hooks/agent" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1) || {
  log_entry "OUTBOUND | to:$PEER | session:${TARGET_SESSION:-recipient-default} | status:FAILED (connection error) | chars:$MSG_LEN"
  die "Connection failed to $PEER ($PEER_URL)" 3
}

# Split response body from HTTP code
BODY=$(echo "$HTTP_RESPONSE" | sed '/__HTTP_CODE__/d')
HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')

# ── Handle response ──────────────────────────────────────────────────────────

case "$HTTP_CODE" in
  200)
    RUN_ID=$(echo "$BODY" | jq -r '.runId // empty' 2>/dev/null || echo "")
    log_entry "OUTBOUND | to:$PEER | session:${TARGET_SESSION:-recipient-default} | status:delivered | chars:$MSG_LEN"
    if [[ "$INCLUDE_RESPONSE" == "true" ]] && RELAY_RESPONSE=$(echo "$BODY" | jq -ce 'select(type == "object")' 2>/dev/null); then
      jq -n \
        --arg peer "$PEER" \
        --arg session "${TARGET_SESSION:-recipient-default}" \
        --arg runId "$RUN_ID" \
        --argjson chars "$MSG_LEN" \
        --argjson response "$RELAY_RESPONSE" \
        '{status:"delivered", peer:$peer, session:$session, runId:$runId, chars:$chars, response:$response}'
    else
      jq -n \
        --arg peer "$PEER" \
        --arg session "${TARGET_SESSION:-recipient-default}" \
        --arg runId "$RUN_ID" \
        --argjson chars "$MSG_LEN" \
        '{status:"delivered", peer:$peer, session:$session, runId:$runId, chars:$chars}'
    fi
    exit 0
    ;;
  401|403)
    log_entry "OUTBOUND | to:$PEER | status:FAILED (auth rejected: $HTTP_CODE) | chars:$MSG_LEN"
    die "Auth rejected by $PEER (HTTP $HTTP_CODE)" 4
    ;;
  *)
    ERROR_MSG=$(echo "$BODY" | jq -r '.error // empty' 2>/dev/null || echo "$BODY")
    log_entry "OUTBOUND | to:$PEER | status:FAILED (HTTP $HTTP_CODE: $ERROR_MSG) | chars:$MSG_LEN"
    die "Relay failed: HTTP $HTTP_CODE — $ERROR_MSG" 5
    ;;
esac
