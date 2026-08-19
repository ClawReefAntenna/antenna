#!/usr/bin/env bash
# antenna-relay.sh — Deterministic relay processor for inbound Antenna messages.
# Parses [ANTENNA_RELAY] envelope, validates, formats delivery message, logs.
# Called by the Antenna agent via exec. Outputs JSON to stdout.
#
# Usage:
#   antenna-relay.sh <raw_message>
#   echo "<raw_message>" | antenna-relay.sh --stdin
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
# shellcheck source=../lib/antenna-replay.sh
source "$SKILL_DIR/lib/antenna-replay.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

json_ok() {
  jq -n \
    --arg sessionKey "$1" \
    --arg message "$2" \
    --arg from "$3" \
    --arg timestamp "$4" \
    --argjson chars "$5" \
    '{action:"relay", status:"ok", sessionKey:$sessionKey, message:$message, from:$from, timestamp:$timestamp, chars:$chars}'
}

json_reject() {
  local reason="$1"
  local from="${2:-unknown}"
  jq -n \
    --arg reason "$reason" \
    --arg from "$from" \
    '{action:"reject", status:"rejected", reason:$reason, from:$from}'
}

json_malformed() {
  local reason="$1"
  jq -n \
    --arg reason "$reason" \
    '{action:"reject", status:"malformed", reason:$reason}'
}

sanitize_log_value() {
  # Strip newlines, carriage returns, and control characters; truncate to max length
  local value="$1"
  local max_len="${2:-200}"
  # Replace control chars (including newlines/tabs) with spaces
  value=$(echo "$value" | tr '\n\r\t' '   ' | sed 's/[[:cntrl:]]//g')
  # Collapse multiple spaces and trim leading/trailing whitespace
  value=$(echo "$value" | sed 's/  */ /g; s/^ //; s/ $//')
  # Truncate
  if [[ ${#value} -gt $max_len ]]; then
    value="${value:0:$max_len}…"
  fi
  echo "$value"
}

secret_equal_constant_time() {
  local left="$1" right="$2"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$left" "$right" <<'PY'
import hmac
import sys
sys.exit(0 if hmac.compare_digest(sys.argv[1], sys.argv[2]) else 1)
PY
    return $?
  fi

  local left_hash right_hash
  left_hash=$(printf '%s' "$left" | sha256sum | awk '{print $1}')
  right_hash=$(printf '%s' "$right" | sha256sum | awk '{print $1}')
  [[ "$left_hash" == "$right_hash" ]]
}

log_entry() {
  local log_enabled log_path
  log_enabled=$(config_log_enabled)
  log_path=$(config_log_path)

  if [[ "$log_enabled" != "true" ]]; then
    return 0
  fi

  # Resolve relative log path against skill dir
  if [[ "$log_path" != /* ]]; then
    log_path="$SKILL_DIR/$log_path"
  fi

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" >> "$log_path"
}

# ── Strict byte-preserving parse ────────────────────────────────────────────

if ! command -v python3 >/dev/null 2>&1; then
  json_reject "Signed-message parser unavailable"
  exit 0
fi
RAW_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-envelope.XXXXXX") || exit 1
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-body.XXXXXX") || exit 1
CANONICAL_FILE=$(mktemp "${TMPDIR:-/tmp}/antenna-canonical.XXXXXX") || exit 1
PINNED_KEY_COPY=$(mktemp "${TMPDIR:-/tmp}/antenna-pinned-key.XXXXXX") || exit 1
chmod 0600 "$RAW_FILE" "$BODY_FILE" "$CANONICAL_FILE" "$PINNED_KEY_COPY"
trap 'rm -f "$RAW_FILE" "$BODY_FILE" "$CANONICAL_FILE" "$PINNED_KEY_COPY"' EXIT
if [[ "${1:-}" == "--stdin" ]]; then cat >"$RAW_FILE"
elif [[ $# -ge 1 ]]; then printf '%s' "$1" >"$RAW_FILE"
else json_malformed "No input provided"; exit 0
fi
MAX_LEN=$(config_max_message_length)
if [[ ! "$MAX_LEN" =~ ^[1-9][0-9]*$ ]] || (( MAX_LEN > 1000000 )); then
  json_reject "Invalid maximum-message-length configuration"
  exit 0
fi
RAW_MAX_BYTES=$((MAX_LEN * 4 + 4096))
if (( $(wc -c <"$RAW_FILE") > RAW_MAX_BYTES )); then
  json_malformed "Envelope exceeds raw byte limit"
  exit 0
fi
if ! HEADERS_JSON=$(python3 "$SKILL_DIR/lib/antenna-envelope-parse.py" "$RAW_FILE" "$BODY_FILE" 2>&1); then
  json_malformed "Invalid envelope grammar"
  log_entry "INBOUND | status:MALFORMED (strict parser)"
  exit 0
fi
header() { jq -r --arg k "$1" '.[$k] // empty' <<<"$HEADERS_JSON"; }
PROTOCOL=$(header protocol); FROM=$(header from); TIMESTAMP=$(header timestamp)
MESSAGE_ID=$(header message_id); SIGNATURE_HEADER=$(header signature)
AUTH_HEADER=$(header auth)
REPLY_TO=$(header reply_to); TARGET_SESSION=$(header target_session)
SUBJECT=$(header subject); USER_NAME=$(header user)
SIGNED_TARGET_SESSION="$TARGET_SESSION"
# Preserve a terminal LF while importing the already validated UTF-8 body.
BODY=$(cat "$BODY_FILE"; printf '\001'); BODY=${BODY%$'\001'}

# ── REF-400: reject reserved envelope markers inside parsed values ──────────
if [[ "$BODY" == *"[ANTENNA_RELAY]"* ]] || [[ "$BODY" == *"[/ANTENNA_RELAY]"* ]]; then
  json_malformed "Envelope markers detected inside body"
  log_entry "INBOUND  | status:MALFORMED (marker in body)"
  exit 0
fi

if [[ "$SUBJECT" == *"[ANTENNA_RELAY]"* ]] || [[ "$SUBJECT" == *"[/ANTENNA_RELAY]"* ]] || \
   [[ "$USER_NAME" == *"[ANTENNA_RELAY]"* ]] || [[ "$USER_NAME" == *"[/ANTENNA_RELAY]"* ]] || \
   [[ "$REPLY_TO" == *"[ANTENNA_RELAY]"* ]] || [[ "$REPLY_TO" == *"[/ANTENNA_RELAY]"* ]]; then
  json_malformed "Envelope markers detected inside header values"
  log_entry "INBOUND  | status:MALFORMED (marker in headers)"
  exit 0
fi

# ── REF-1502: extract optional correlation nonce from body ──────────────────
# The body may contain a `nonce: <value>` line (used by antenna-model-test.sh
# and anyone else who wants log correlation). Extract it with a strict
# character class to prevent log injection / ANSI / gigantic values. Default
# to `-` (absent) when nothing valid is present. This is NOT authentication;
# peers_get + peer secret verification already did that. The nonce is purely
# for scoping a receiver-side log scan to one caller's message.
NONCE=$(echo "$BODY" | grep -m1 -E '^nonce:[[:space:]]*[A-Za-z0-9_-]{1,40}[[:space:]]*$' \
  | sed -E 's/^nonce:[[:space:]]*([A-Za-z0-9_-]{1,40})[[:space:]]*$/\1/' || true)
NONCE="${NONCE:--}"

# ── Validate required fields ────────────────────────────────────────────────

if [[ -z "$FROM" || -z "$TIMESTAMP" ]]; then
  if [[ "$PROTOCOL" == "antenna-ed25519-v1" ]]; then
    json_reject "Signed envelope is missing a required field" "${FROM:-unknown}"
  else
    json_reject "Envelope is missing sender or timestamp" "${FROM:-unknown}"
  fi
  exit 0
fi

if [[ -z "$TARGET_SESSION" ]]; then
  # Use default from config; if absent, build full key for main session
  TARGET_SESSION=$(config_default_target_session)
  if [[ -z "$TARGET_SESSION" ]]; then
    LOCAL_AGENT=$(config_local_agent_id)
    TARGET_SESSION="agent:${LOCAL_AGENT}:main"
  fi
fi

# ── Validate sender against explicit inbound policy ─────────────────────────

ALLOWED=$(jq -er --arg from "$FROM" '
  if (has("allowed_inbound_peers") | not) then "denied"
  elif (.allowed_inbound_peers | type) != "array" or
       (all(.allowed_inbound_peers[]; type == "string") | not)
  then error("invalid inbound allowlist")
  elif (.allowed_inbound_peers | index($from)) then "allowed"
  else "denied" end
' "$CONFIG_FILE" 2>/dev/null || echo "invalid")

if [[ "$ALLOWED" != "allowed" ]]; then
  json_reject "Unknown or disallowed sender: $FROM" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (not in allowed_inbound_peers)"
  exit 0
fi

if ! peers_exists "$FROM"; then
  json_reject "Unknown peer: $FROM (not in peers registry)" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (unknown peer)"
  exit 0
fi

# ── REF-402: timestamp freshness window to limit replay exposure ───────────
if [[ ! "$TIMESTAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  json_malformed "Invalid timestamp format"; exit 0
fi
TIMESTAMP_EPOCH=$(date -u -d "$TIMESTAMP" +%s 2>/dev/null || echo "")
if [[ -z "$TIMESTAMP_EPOCH" ]]; then
  json_malformed "Invalid timestamp format"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:MALFORMED (invalid timestamp)"
  exit 0
fi
if [[ "$(date -u -d "@$TIMESTAMP_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" != "$TIMESTAMP" ]]; then
  json_malformed "Invalid timestamp format"; exit 0
fi

NOW_EPOCH=$(date -u +%s)
bounded_security_seconds() {
  local key="$1" default="$2" maximum="$3"
  jq -er --arg key "$key" --argjson default "$default" --argjson maximum "$maximum" '
    if has("security") then
      if (.security | type) != "object" then error("security must be an object")
      elif (.security | has($key)) then
        .security[$key] as $value |
        if (($value | type) == "number" and ($value | floor) == $value and
            $value >= 0 and $value <= $maximum)
        then ($value | tostring) else error("invalid bounded integer") end
      else ($default | tostring) end
    else ($default | tostring) end
  ' "$CONFIG_FILE" 2>/dev/null
}
if ! MAX_AGE_SECONDS=$(bounded_security_seconds max_message_age_seconds 300 3600) ||
   ! MAX_FUTURE_SKEW_SECONDS=$(bounded_security_seconds max_future_skew_seconds 60 300); then
  json_reject "Invalid freshness configuration" "$FROM"
  log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid freshness configuration)"
  exit 0
fi
AGE_SECONDS=$((NOW_EPOCH - TIMESTAMP_EPOCH))
FUTURE_SKEW_SECONDS=$((TIMESTAMP_EPOCH - NOW_EPOCH))

if (( AGE_SECONDS > MAX_AGE_SECONDS )); then
  json_reject "Message timestamp too old (${AGE_SECONDS}s > ${MAX_AGE_SECONDS}s)" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (timestamp too old: ${AGE_SECONDS}s > ${MAX_AGE_SECONDS}s)"
  exit 0
fi

if (( FUTURE_SKEW_SECONDS > MAX_FUTURE_SKEW_SECONDS )); then
  json_reject "Message timestamp too far in future (${FUTURE_SKEW_SECONDS}s > ${MAX_FUTURE_SKEW_SECONDS}s)" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (timestamp in future: ${FUTURE_SKEW_SECONDS}s > ${MAX_FUTURE_SKEW_SECONDS}s)"
  exit 0
fi

# ── Exact per-peer authentication mode ──────────────────────────────────────
AUTH_MODE=$(peers_get "$FROM" auth_mode)
case "$AUTH_MODE" in
  ed25519-v1)
    [[ "$PROTOCOL" == "antenna-ed25519-v1" ]] || { json_reject "Unsupported or missing protocol" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid Ed25519 protocol)"; exit 0; }
    [[ -n "$MESSAGE_ID" && -n "$SIGNATURE_HEADER" ]] || { json_reject "Signed envelope is missing a required field" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (missing Ed25519 field)"; exit 0; }
    [[ -z "$AUTH_HEADER" ]] || { json_reject "Invalid Ed25519 envelope" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (mixed authentication fields)"; exit 0; }
    [[ "$MESSAGE_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || { json_reject "Invalid message_id" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid message id)"; exit 0; }
    [[ "$SIGNATURE_HEADER" =~ ^ed25519-v1:([A-Za-z0-9+/]{86}==)$ ]] || { json_reject "Malformed Ed25519 signature" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (malformed Ed25519 signature)"; exit 0; }
    SIGNATURE_VALUE="${BASH_REMATCH[1]}"
    PUBLIC_KEY_FILE=$(peers_get "$FROM" signing_public_key_file)
    [[ -n "$PUBLIC_KEY_FILE" && "$PUBLIC_KEY_FILE" != /* ]] && PUBLIC_KEY_FILE="$SKILL_DIR/$PUBLIC_KEY_FILE"
    signature_capture_public_key "$PUBLIC_KEY_FILE" "$SKILL_DIR/keys" "$PINNED_KEY_COPY" || { json_reject "Pinned Ed25519 public key is missing or invalid" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid Ed25519 public key)"; exit 0; }
    signature_canonical_file "$CANONICAL_FILE" "$PROTOCOL" "$FROM" "$TIMESTAMP" "$MESSAGE_ID" "$SIGNED_TARGET_SESSION" "$USER_NAME" "$REPLY_TO" "$SUBJECT" "$BODY_FILE" || { json_reject "Could not construct canonical message" "$FROM"; exit 0; }
    signature_verify "$PINNED_KEY_COPY" "$CANONICAL_FILE" "$SIGNATURE_VALUE" || { json_reject "Ed25519 signature verification failed" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid Ed25519 signature)"; exit 0; }
    ;;
  plaintext-legacy)
    [[ -z "$PROTOCOL" && -z "$MESSAGE_ID" && -z "$SIGNATURE_HEADER" && "$AUTH_HEADER" =~ ^[0-9a-f]{64}$ ]] || { json_reject "Invalid plaintext-legacy envelope" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid plaintext-legacy envelope)"; exit 0; }
    EXPECTED_SECRET_FILE=$(peers_get "$FROM" peer_secret_file)
    [[ -n "$EXPECTED_SECRET_FILE" && "$EXPECTED_SECRET_FILE" != /* ]] && EXPECTED_SECRET_FILE="$SKILL_DIR/$EXPECTED_SECRET_FILE"
    legacy_secret_file_ok "$EXPECTED_SECRET_FILE" || { json_reject "Legacy peer secret is missing or unsafe" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (unsafe legacy secret)"; exit 0; }
    EXPECTED_SECRET=$(tr -d '[:space:]' <"$EXPECTED_SECRET_FILE")
    [[ "$EXPECTED_SECRET" =~ ^[0-9a-f]{64}$ ]] && secret_equal_constant_time "$AUTH_HEADER" "$EXPECTED_SECRET" || { json_reject "Legacy peer authentication failed" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (invalid legacy secret)"; exit 0; }
    log_entry "INBOUND | from:$FROM | peer_auth:plaintext-legacy | warning:reusable-secret"
    ;;
  *) json_reject "Peer has missing or unsupported auth_mode" "$FROM"; log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (unsupported auth mode)"; exit 0 ;;
esac

# ── Rate limiting ────────────────────────────────────────────────────────────

RATE_LIMIT_FILE="$SKILL_DIR/antenna-ratelimit.json"
RATE_LIMIT_LOCK_FILE="${RATE_LIMIT_FILE}.lock"
bounded_rate_limit() {
  local key="$1" default="$2" maximum="$3"
  jq -er --arg key "$key" --argjson default "$default" --argjson maximum "$maximum" '
    if has("rate_limit") then
      if (.rate_limit | type) != "object" then error("rate_limit must be an object")
      elif (.rate_limit | has($key)) then
        .rate_limit[$key] as $value |
        if (($value | type) == "number" and ($value | floor) == $value and
            $value >= 1 and $value <= $maximum)
        then ($value | tostring) else error("invalid bounded rate") end
      else ($default | tostring) end
    else ($default | tostring) end
  ' "$CONFIG_FILE" 2>/dev/null
}
if ! PEER_LIMIT=$(bounded_rate_limit per_peer_per_minute 10 100) ||
   ! GLOBAL_LIMIT=$(bounded_rate_limit global_per_minute 30 300) ||
   (( GLOBAL_LIMIT < PEER_LIMIT )); then
  json_reject "Invalid rate-limit configuration" "$FROM"
  exit 0
fi

mkdir -p "$(dirname "$RATE_LIMIT_FILE")"
if [[ ! -f "$RATE_LIMIT_FILE" ]]; then
  echo '{}' > "$RATE_LIMIT_FILE"
fi

NOW_EPOCH=$(date +%s)
WINDOW_START=$((NOW_EPOCH - 60))

rate_limit_check_and_record() {
  local result tmp_file
  tmp_file="${RATE_LIMIT_FILE}.tmp.$$"

  result=$(jq -er --arg from "$FROM" --argjson now "$NOW_EPOCH" --argjson cutoff "$WINDOW_START" \
    --argjson peer_limit "$PEER_LIMIT" --argjson global_limit "$GLOBAL_LIMIT" '
    . as $state |
    ([$state | to_entries[] | {key, value: [.value[] | select(. > $cutoff)]}] | from_entries) as $pruned |
    ($pruned[$from] // [] | length) as $peer_count |
    ([($pruned | to_entries[] | .value | length)] | add // 0) as $global_count |
    if $peer_count >= $peer_limit then
      "peer_limited|\($peer_count)|\($global_count)"
    elif $global_count >= $global_limit then
      "global_limited|\($peer_count)|\($global_count)"
    else
      ($pruned | .[$from] = ((.[$from] // []) + [$now])) as $updated |
      ($updated | tostring) as $state_json |
      "ok|\($peer_count)|\($global_count)|\($state_json)"
    end
  ' "$RATE_LIMIT_FILE" 2>/dev/null) || return 1

  RATE_VERDICT=$(echo "$result" | cut -d'|' -f1)
  RATE_PEER_COUNT=$(echo "$result" | cut -d'|' -f2)
  RATE_GLOBAL_COUNT=$(echo "$result" | cut -d'|' -f3)

  if [[ "$RATE_VERDICT" == "ok" ]]; then
    RATE_UPDATED_STATE=$(echo "$result" | cut -d'|' -f4-)
    printf '%s\n' "$RATE_UPDATED_STATE" > "$tmp_file"
    mv "$tmp_file" "$RATE_LIMIT_FILE"
  fi
}

exec 8>"$RATE_LIMIT_LOCK_FILE"
flock -x 8
if ! rate_limit_check_and_record; then
  json_reject "Rate limiting unavailable" "$FROM"
  exit 0
fi

if [[ "$RATE_VERDICT" == "peer_limited" ]]; then
  json_reject "Rate limited: peer '$FROM' exceeded $PEER_LIMIT messages/minute ($RATE_PEER_COUNT in window)" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (rate limited: peer $RATE_PEER_COUNT/$PEER_LIMIT per min)"
  exit 0
fi

if [[ "$RATE_VERDICT" == "global_limited" ]]; then
  json_reject "Rate limited: global limit exceeded ($RATE_GLOBAL_COUNT/$GLOBAL_LIMIT messages/minute)" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (rate limited: global $RATE_GLOBAL_COUNT/$GLOBAL_LIMIT per min)"
  exit 0
fi

# ── Validate message length ─────────────────────────────────────────────────

BODY_LEN=${#BODY}

if [[ "$BODY_LEN" -gt "$MAX_LEN" ]]; then
  json_reject "Message body exceeds max length ($BODY_LEN > $MAX_LEN chars)" "$FROM"
  log_entry "INBOUND  | from:$FROM | nonce:$NONCE | status:REJECTED (over max length: $BODY_LEN > $MAX_LEN)"
  exit 0
fi

# ── Validate target session against allowlist (REF-500, pre-inbox gate) ────
# Full session keys only. Exact match. No expansion — senders must use full keys.
# Enforced BEFORE the inbox branch so queued messages can never target a
# session outside allowed_inbound_sessions. The inbox is for human approval of
# *content/peer*, not for laundering session-target policy around the allowlist.

ALLOWED_SESSIONS=$(jq -r '
  .allowed_inbound_sessions // [] | .[]
' "$CONFIG_FILE" 2>/dev/null)

session_allowed() {
  local target="$1"
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    [[ "$target" == "$pattern" ]] && return 0
  done <<< "$ALLOWED_SESSIONS"
  return 1
}

if ! session_allowed "$TARGET_SESSION"; then
  json_reject "Session target '$TARGET_SESSION' not in allowed_inbound_sessions" "$FROM"
  log_entry "INBOUND  | from:$FROM | session:$TARGET_SESSION | nonce:$NONCE | status:REJECTED (session not allowed)"
  exit 0
fi

# Reserve only policy-admissible, authenticated messages. Persist before
# queue/delivery so a retry cannot bypass exact replay rejection.
REPLAY_CACHE="$SKILL_DIR/state/antenna-replay.json"
REPLAY_TTL=$((MAX_AGE_SECONDS + MAX_FUTURE_SKEW_SECONDS + 1))
REPLAY_CAPACITY=$(replay_capacity_for_window "$REPLAY_TTL" "$GLOBAL_LIMIT") || {
  json_reject "Replay protection unavailable" "$FROM"; exit 0;
}
if [[ "$AUTH_MODE" == "plaintext-legacy" ]]; then
  : # v1.5.2-compatible envelopes have no message ID; freshness is the legacy bound.
elif replay_reserve "$REPLAY_CACHE" "$REPLAY_TTL" "$REPLAY_CAPACITY" "$FROM" "$MESSAGE_ID"; then
  log_entry "INBOUND | from:$FROM | peer_auth:verified | message_id:$MESSAGE_ID"
else
  replay_rc=$?
  if [[ "$replay_rc" -eq 2 ]]; then
    json_reject "Replay detected" "$FROM"
    log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (replay detected)"
  else
    json_reject "Replay protection unavailable" "$FROM"
    log_entry "INBOUND | from:$FROM | nonce:$NONCE | status:REJECTED (replay protection unavailable)"
  fi
  exit 0
fi

# ── Inbox queue check ────────────────────────────────────────────────────────

INBOX_ENABLED=$(config_inbox_enabled)

if [[ "$INBOX_ENABLED" == "true" ]]; then
  # Check auto-approve list
  AUTO_APPROVED=$(jq -r --arg from "$FROM" '
    .inbox_auto_approve_peers // [] | if (index($from)) then "yes" else "no" end
  ' "$CONFIG_FILE" 2>/dev/null || echo "no")
  
  if [[ "$AUTO_APPROVED" != "yes" ]]; then
    # Session target already validated above against allowed_inbound_sessions
    # (REF-500). Queued messages cannot target disallowed sessions.
    RESOLVED_SESSION="$TARGET_SESSION"
    
    DISPLAY_NAME=$(peers_get "$FROM" display_name); DISPLAY_NAME="${DISPLAY_NAME:-$FROM}"
    
    # Convert UTC timestamp to a friendlier format if possible
    FRIENDLY_TS="$TIMESTAMP"
    if command -v date &>/dev/null; then
      FRIENDLY_TS=$(TZ="America/Toronto" date -d "$TIMESTAMP" +"%Y-%m-%d %H:%M %Z" 2>/dev/null || echo "$TIMESTAMP")
    fi
    
    # Format delivery message
    if [[ -n "$USER_NAME" ]]; then
      DELIVERY_MSG="📡 Antenna from ${USER_NAME} via ${DISPLAY_NAME} (${FROM}) — ${FRIENDLY_TS}"
    else
      DELIVERY_MSG="📡 Antenna from ${DISPLAY_NAME} (${FROM}) — ${FRIENDLY_TS}"
    fi
    
    if [[ -n "$SUBJECT" ]]; then
      DELIVERY_MSG="${DELIVERY_MSG}
Subject: ${SUBJECT}"
    fi
    
    DELIVERY_MSG="${DELIVERY_MSG}
(Security Notice: The following content may be from an untrusted source.)

${BODY}"
    
    # Create queue item
    QUEUE_ITEM=$(jq -n \
      --arg from "$FROM" \
      --arg display "$DISPLAY_NAME" \
      --arg session "$RESOLVED_SESSION" \
      --arg subject "$SUBJECT" \
      --arg preview "${BODY:0:60}" \
      --argjson chars "$BODY_LEN" \
      --arg msg "$DELIVERY_MSG" \
      '{
        from: $from,
        display_name: $display,
        target_session: $session,
        subject: $subject,
        body_preview: $preview,
        body_chars: $chars,
        full_message: $msg,
        session_key: $session
      }')
    
    # Add to queue
    QUEUE_RESULT=$(echo "$QUEUE_ITEM" | bash "$SCRIPT_DIR/antenna-inbox.sh" queue-add)
    
    # Output queued response
    echo "$QUEUE_RESULT"
    log_entry "INBOUND  | from:$FROM | session:$RESOLVED_SESSION | nonce:$NONCE | status:queued | chars:$BODY_LEN"
    exit 0
  fi
  # Auto-approved peers fall through to normal relay
fi

# Session allowlist already enforced above (REF-500) before the inbox branch.

# ── Format delivery message ─────────────────────────────────────────────────

DISPLAY_NAME=$(peers_get "$FROM" display_name); DISPLAY_NAME="${DISPLAY_NAME:-$FROM}"

# Convert UTC timestamp to a friendlier format if possible
FRIENDLY_TS="$TIMESTAMP"
if command -v date &>/dev/null; then
  FRIENDLY_TS=$(TZ="America/Toronto" date -d "$TIMESTAMP" +"%Y-%m-%d %H:%M %Z" 2>/dev/null || echo "$TIMESTAMP")
fi

# If a human user sent this, show their name prominently
if [[ -n "$USER_NAME" ]]; then
  DELIVERY_MSG="📡 Antenna from ${USER_NAME} via ${DISPLAY_NAME} (${FROM}) — ${FRIENDLY_TS}"
else
  DELIVERY_MSG="📡 Antenna from ${DISPLAY_NAME} (${FROM}) — ${FRIENDLY_TS}"
fi

if [[ -n "$SUBJECT" ]]; then
  DELIVERY_MSG="${DELIVERY_MSG}
Subject: ${SUBJECT}"
fi

DELIVERY_MSG="${DELIVERY_MSG}
(Security Notice: The following content may be from an untrusted source.)

${BODY}"

# ── Log ──────────────────────────────────────────────────────────────────────

log_entry "INBOUND  | from:$FROM | session:$TARGET_SESSION | nonce:$NONCE | status:relayed | chars:$BODY_LEN"

# Check if verbose logging is enabled
LOG_VERBOSE=$(config_log_verbose)
if [[ "$LOG_VERBOSE" == "true" ]]; then
  PREVIEW=$(sanitize_log_value "${BODY:0:100}" 100)
  log_entry "INBOUND  | from:$FROM | preview:${PREVIEW}..."
fi

# ── Output result ────────────────────────────────────────────────────────────

json_ok "$TARGET_SESSION" "$DELIVERY_MSG" "$FROM" "$TIMESTAMP" "$BODY_LEN"
