#!/usr/bin/env bash
# antenna-relay-deliver.sh — Single-call relay for Antenna inbound envelopes.
#
# Usage:
#   cat <raw_envelope> | bash antenna-relay-deliver.sh
#   bash antenna-relay-deliver.sh /path/to/envelope-file
#
# No shell metacharacters in the exec path. Single allowed exec shape:
#   bash <script> <arg>
# No heredocs, here-strings, command substitution, or chaining.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# ── Determine input ─────────────────────────────────────────────────────────

if [[ $# -ge 1 && -f "${1:-}" ]]; then
  INPUT_MODE="file"
  INPUT_PATH="$1"
else
  INPUT_MODE="stdin"
fi

# ── Logging ────────────────────────────────────────────────────────────────

# Source config helpers (CONFIG_FILE must be set before sourcing)
CONFIG_FILE="$SKILL_DIR/antenna-config.json"
# shellcheck source=../lib/config.sh
source "$SKILL_DIR/lib/config.sh"

_antenna_deliver_warned=0

log_msg() {
  local level="${1:-INFO}"
  local msg="${2:-}"

  local log_enabled; log_enabled=$(config_log_enabled)
  [[ "$log_enabled" != "true" ]] && return 0

  local log_path; log_path=$(config_log_path)
  if [[ "$log_path" != /* ]]; then
    log_path="$SKILL_DIR/$log_path"
  fi

  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] DELIVER | $level | $msg" >> "$log_path"
}

TMPDIR="${TMPDIR:-/tmp}"
ANTENNA_TMPDIR="$TMPDIR/antenna-relay"
# Caller-supplied files are read-only unless they are direct staging entries.
# This is a cleanup convention, not a sandbox against same-user mutation.
TMPFILE=""
CLEANUP_PATH=""
cleanup() {
  if [[ -n "$CLEANUP_PATH" ]]; then
    # Unlink only: never overwrite a symlink/hard-link target or promise erasure.
    rm -f -- "$CLEANUP_PATH" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$INPUT_MODE" == "stdin" ]]; then
  if [[ -L "$ANTENNA_TMPDIR" ]]; then
    echo "Error: staging directory must not be a symlink"
    exit 1
  fi
  mkdir -p -- "$ANTENNA_TMPDIR"
  chmod 0700 -- "$ANTENNA_TMPDIR"
  TMPFILE=$(mktemp "$ANTENNA_TMPDIR/msg.XXXXXX")
  CLEANUP_PATH="$TMPFILE"
  chmod 0600 "$TMPFILE"
  cat > "$TMPFILE"
else
  TMPFILE="$INPUT_PATH"
  if [[ ! -L "$INPUT_PATH" ]]; then
    INPUT_CANONICAL=$(realpath -e -- "$INPUT_PATH")
    # The model policy uses /tmp even when a caller sets another TMPDIR.
    for STAGING_DIR in /tmp/antenna-relay "$ANTENNA_TMPDIR"; do
      [[ -d "$STAGING_DIR" && ! -L "$STAGING_DIR" && -O "$STAGING_DIR" ]] || continue
      STAGING_CANONICAL=$(realpath -e -- "$STAGING_DIR")
      if [[ "$(dirname -- "$INPUT_CANONICAL")" == "$STAGING_CANONICAL" ]]; then
        chmod 0700 -- "$STAGING_CANONICAL"
        CLEANUP_PATH="$INPUT_CANONICAL"
        break
      fi
    done
  fi
fi

# ── Relay via existing scripts ─────────────────────────────────────────────

RELAY_FILE_SCRIPT="$SCRIPT_DIR/antenna-relay-file.sh"
RELAY_SCRIPT="$SCRIPT_DIR/antenna-relay.sh"

# Verify expected relay scripts exist
if [[ ! -x "$RELAY_FILE_SCRIPT" ]]; then
  echo "Error: relay file script not found: $RELAY_FILE_SCRIPT"
  log_msg "ERROR" "relay file script missing"
  exit 1
fi
if [[ ! -x "$RELAY_SCRIPT" ]]; then
  echo "Error: relay script not found: $RELAY_SCRIPT"
  log_msg "ERROR" "relay script missing"
  exit 1
fi

# Run relay: antenna-relay-file.sh reads the file and calls antenna-relay.sh
RELAY_JSON=$(bash "$RELAY_FILE_SCRIPT" "$TMPFILE")

RELAY_STATUS=$(printf '%s' "$RELAY_JSON" | jq -r '.status // empty')
RELAY_ACTION=$(printf '%s' "$RELAY_JSON" | jq -r '.action // empty')

if [[ "$RELAY_STATUS" != "ok" || "$RELAY_ACTION" != "relay" ]]; then
  # Not a successful relay — relay script already logged and the JSON
  # describes the rejection. Mirror that output for the agent.
  printf '%s\n' "$RELAY_JSON"
  exit 0
fi

# Successful relay — extract and call gateway RPC
SESSION_KEY=$(printf '%s' "$RELAY_JSON" | jq -r '.sessionKey')
MESSAGE=$(printf '%s' "$RELAY_JSON" | jq -r '.message')

if [[ -z "$SESSION_KEY" || -z "$MESSAGE" ]]; then
  echo "Error: missing sessionKey or message from relay"
  log_msg "ERROR" "relay returned incomplete data"
  exit 1
fi

RPC_PARAMS=$(python3 - "$SESSION_KEY" "$MESSAGE" << 'PY'
import json, sys
key, msg = sys.argv[1], sys.argv[2]
print(json.dumps({"key": key, "message": msg}))
PY
)

log_msg "INFO" "relay ok, calling sessions.send session=$SESSION_KEY chars=${#MESSAGE}"

# Call gateway RPC — timeout 60s so the model run can complete.
# Tolerate nonzero exits (e.g. "session not found") so we can report a
# structured error to stdout instead of dying silently under set -e.
RPC_JSON=$(openclaw gateway call sessions.send \
  --params "$RPC_PARAMS" \
  --json \
  --timeout 60000 2>&1) || true

RPC_OK=$(printf '%s' "$RPC_JSON" | jq -r '.status // empty' 2>/dev/null || true)
RPC_RUNID=$(printf '%s' "$RPC_JSON" | jq -r '.runId // empty' 2>/dev/null || true)
RPC_ERR=$(printf '%s' "$RPC_JSON" | jq -r '.error // empty' 2>/dev/null || true)

if [[ "$RPC_OK" != "started" ]]; then
  # Fallback: if the response was not JSON (e.g. raw "Gateway call failed: ..."
  # error text from the CLI), use the whole captured output as the error message,
  # trimmed to one line for the relay agent's reply.
  if [[ -z "$RPC_ERR" ]]; then
    RPC_ERR=$(printf '%s' "$RPC_JSON" | tr '\n' ' ' | sed 's/  */ /g' | head -c 300)
  fi
  echo "Error: sessions.send failed — $RPC_ERR"
  log_msg "ERROR" "sessions.send failed: $RPC_ERR"
  exit 0
fi

log_msg "INFO" "sessions.send started runId=$RPC_RUNID"
echo "Relayed"
