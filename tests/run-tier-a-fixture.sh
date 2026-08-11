#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skill/lib" "$TMP/skill/scripts" "$TMP/skill/agent" "$TMP/skill/secrets"
cp -R "$ROOT/lib/." "$TMP/skill/lib/"
cp -R "$ROOT/scripts/." "$TMP/skill/scripts/"
cp "$ROOT/agent/AGENTS.md" "$TMP/skill/agent/"

source "$TMP/skill/lib/antenna-signature.sh"
signature_keygen "$TMP/skill/secrets/private.pem" "$TMP/skill/secrets/public.pem"
cat >"$TMP/skill/antenna-peers.json" <<'EOF'
{"fixture":{"url":"https://fixture.test","self":true,"auth_mode":"ed25519-v1","signing_private_key_file":"secrets/private.pem","signing_public_key_file":"secrets/public.pem"}}
EOF
cat >"$TMP/skill/antenna-config.json" <<'EOF'
{
  "log_enabled": false,
  "log_path": "antenna.log",
  "local_agent_id": "betty",
  "max_message_length": 10000,
  "default_target_session": "agent:betty:main",
  "allowed_inbound_peers": ["fixture"],
  "allowed_outbound_peers": ["fixture"],
  "allowed_inbound_sessions": ["agent:betty:main", "agent:betty:antenna"],
  "inbox_enabled": false,
  "inbox_auto_approve_peers": [],
  "rate_limit": {"per_peer_per_minute": 10, "global_per_minute": 30},
  "security": {"max_message_age_seconds": 300, "max_future_skew_seconds": 60}
}
EOF
printf '[]\n' >"$TMP/skill/antenna-inbox.json"
bash "$TMP/skill/scripts/antenna-test-suite.sh" --tier A
