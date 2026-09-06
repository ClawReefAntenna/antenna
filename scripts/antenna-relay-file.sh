#!/usr/bin/env bash
# antenna-relay-file.sh — Read raw message from a file and pass it to
# antenna-relay.sh via stdin.
#
# Usage: bash antenna-relay-file.sh /path/to/message-file
#
# Designed so the calling agent never needs to base64-encode or use shell
# metacharacters. The agent writes raw message text to a unique private temp
# file, then execs antenna-relay-deliver.sh with that file path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FILE="${1:-}"

if [[ -z "$INPUT_FILE" ]]; then
    echo '{"action":"reject","status":"error","reason":"No input file path provided"}'
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "{\"action\":\"reject\",\"status\":\"error\",\"reason\":\"Input file not found: $INPUT_FILE\"}"
    exit 1
fi

# Read-only adapter. The delivery wrapper owns disposable staging cleanup.

# Feed the raw message to the relay script via stdin
bash "$SCRIPT_DIR/antenna-relay.sh" --stdin < "$INPUT_FILE"
