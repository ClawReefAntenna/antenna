#!/usr/bin/env bash
# Phase 4 regression: a side-by-side upgrade preserves runtime state and only
# rewrites the destination install path plus the Antenna agent's local paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
no() { echo "FAIL $*"; fail=$((fail + 1)); }
check() { local label="$1"; shift; if "$@"; then ok "$label"; else no "$label"; fi; }

OLD="$TMP/antenna-v1.5.2"
NEW="$TMP/antenna-v1.6.0"
HOME_DIR="$TMP/home"
GATEWAY="$HOME_DIR/.openclaw/openclaw.json"
mkdir -p "$OLD/secrets" "$OLD/keys" "$OLD/state" "$OLD/bin" "$OLD/agent/memory" \
  "$NEW/scripts" "$NEW/bin" "$NEW/lib/relay-policy/agent" "$NEW/agent" \
  "$HOME_DIR/.openclaw" "$HOME_DIR/.local/bin" "$HOME_DIR/bin" "$HOME_DIR/custom"
cp "$ROOT/scripts/antenna-upgrade.sh" "$NEW/scripts/"
cp "$ROOT/bin/antenna.sh" "$NEW/bin/"
cp "$ROOT/lib/gateway-roster.sh" "$ROOT/lib/cli-link.sh" "$ROOT/lib/secret-file.sh" \
  "$ROOT/lib/change-plan.sh" "$NEW/lib/"
cp "$ROOT/lib/relay-policy.sh" "$NEW/lib/"
cp "$ROOT/lib/v163-staging-cleanup.sh" "$NEW/lib/"
cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$NEW/lib/relay-policy/agent/"
cp "$ROOT/lib/relay-policy/manifest.sha256" "$NEW/lib/relay-policy/"
cp "$ROOT/agent/AGENTS.md" "$NEW/agent/"
printf '#!/usr/bin/env bash\n' > "$OLD/bin/antenna.sh"
chmod +x "$OLD/bin/antenna.sh" "$NEW/bin/antenna.sh" "$NEW/scripts/antenna-upgrade.sh"

jq -n --arg old "$OLD" '{
  install_path:$old,
  default_target_session:"agent:betty:main",
  allowed_inbound_peers:["legacy-peer"],
  allowed_outbound_peers:["legacy-peer"]
}' > "$OLD/antenna-config.json"
cat > "$OLD/antenna-peers.json" <<'JSON'
{
  "self-host": {"self":true,"url":"https://self.example","token_file":"secrets/self.token"},
  "legacy-peer": {"url":"https://peer.example","token_file":"secrets/peer.token","peer_secret_file":"secrets/peer.secret"}
}
JSON
printf '{"ops":[{"peer":"legacy-peer"}]}\n' > "$OLD/antenna-lists.json"
printf '{"reef":{"group_id":"11111111-1111-4111-8111-111111111111","name":"Reef","relay_peer":"clawreef"}}\n' > "$OLD/antenna-public-groups.json"
printf '[]\n' > "$OLD/antenna-inbox.json"
printf '{"entries":[]}\n' > "$OLD/antenna-ratelimit.json"
printf '{"entries":[]}\n' > "$OLD/state/antenna-replay.json"
printf 'secret\n' > "$OLD/secrets/peer.secret"
printf 'token\n' > "$OLD/secrets/peer.token"
printf 'self-token\n' > "$OLD/secrets/self.token"
printf 'PUBLIC KEY\n' > "$OLD/keys/legacy.pem"
printf 'old log\n' > "$OLD/antenna.log"
printf 'older log\n' > "$OLD/antenna.log.1"
printf '{"profiles":{"relay":{"provider":"fixture"}}}\n' > "$OLD/agent/auth-profiles.json"
printf 'agent note\n' > "$OLD/agent/memory/local.txt"
printf 'Check legacy Antenna inbox.\n' > "$OLD/agent/HEARTBEAT.md"
chmod 600 "$OLD"/*.json "$OLD"/secrets/* "$OLD"/keys/* "$OLD"/state/* "$OLD"/antenna.log*
chmod 600 "$OLD/agent/auth-profiles.json" "$OLD/agent/memory/local.txt" "$OLD/agent/HEARTBEAT.md"

cat > "$GATEWAY" <<JSON
{
  "agents": {"list": [
    {"id":"betty","workspace":"/keep/betty"},
    {"id":"antenna","agentDir":"$OLD/agent","workspace":"$OLD/agent","tools":{"exec":{"security":"allowlist"}}}
  ]},
  "hooks":{"enabled":true,"token":"keep-me"}
}
JSON
chmod 600 "$GATEWAY"
ln -s "$OLD/bin/antenna.sh" "$HOME_DIR/.local/bin/antenna"
printf 'foreign-cli\n' >"$HOME_DIR/custom/antenna"
cat > "$HOME_DIR/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "OpenClaw 2026.7.1 (fixture)"
elif [[ "${1:-}" == "config" && "${2:-}" == "validate" ]]; then
  jq empty "${OPENCLAW_CONFIG_PATH:?}"
else
  exit 2
fi
EOF
chmod +x "$HOME_DIR/bin/openclaw"

before="$(find "$OLD" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
output="$(PATH="$HOME_DIR/bin:$PATH" HOME="$HOME_DIR" USER=tester \
  bash "$NEW/scripts/antenna-upgrade.sh" --from "$OLD" --gateway "$GATEWAY" \
    --replace-cli-link "$HOME_DIR/custom/antenna" --yes)"
after="$(find "$OLD" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"

check "source tree remains byte-identical" test "$before" = "$after"
check "destination install_path is rewritten" test "$(jq -r .install_path "$NEW/antenna-config.json")" = "$NEW"
check "legacy peer record is preserved exactly" cmp -s "$OLD/antenna-peers.json" "$NEW/antenna-peers.json"
check "legacy auth is not silently invented" jq -e '.["legacy-peer"] | has("auth_mode") | not' "$NEW/antenna-peers.json"
check "lists, routes, replay state, secrets, keys, and logs migrate" test \
  "$(cat "$NEW/antenna-lists.json" "$NEW/antenna-public-groups.json" "$NEW/state/antenna-replay.json" "$NEW/secrets/peer.secret" "$NEW/keys/legacy.pem" "$NEW/antenna.log.1" | wc -c)" -gt 20
check "agent-local auth and memory state migrate" test \
  "$(cat "$NEW/agent/auth-profiles.json" "$NEW/agent/memory/local.txt" | wc -c)" -gt 20
check "7.x upgrade retains legacy HEARTBEAT.md" cmp -s \
  "$OLD/agent/HEARTBEAT.md" "$NEW/agent/HEARTBEAT.md"
check "private runtime permissions remain private" test "$(stat -c %a "$NEW/secrets/peer.secret")" = 600
check "copied private runtime directories are hardened" test "$(stat -c %a "$NEW/secrets")" = 700
check "gateway separates new workspace from stable agent state" jq -e --arg workspace "$NEW/agent" --arg state "$HOME_DIR/.openclaw/agents/antenna/agent" \
  '.agents.list[] | select(.id=="antenna") | .agentDir==$state and .workspace==$workspace' "$GATEWAY"
check "gateway custom agent tools and unrelated config survive" jq -e \
  '.hooks.token=="keep-me" and (.agents.list[] | select(.id=="antenna") | .tools.exec.security)=="allowlist" and (.agents.list[] | select(.id=="betty") | .workspace)=="/keep/betty"' "$GATEWAY"
check "gateway backup is private and present" bash -c 'f=("$1".antenna-upgrade-backup-*); [[ -f "${f[0]}" && "$(stat -c %a "${f[0]}")" == 600 ]]' _ "$GATEWAY"
check "existing CLI symlink is repointed" test "$(readlink -f "$HOME_DIR/.local/bin/antenna")" = "$NEW/bin/antenna.sh"
cli_backup="$(find "$HOME_DIR/.local/bin" -mindepth 2 -maxdepth 2 \
  -path '*/antenna.antenna-backup-*/displaced' -print -quit)"
check "repointed CLI link keeps a private rollback backup" bash -c \
  '[[ -L "$1" && "$(readlink -f "$1")" == "$2" && "$(stat -c %a "$(dirname "$1")")" == 700 ]]' \
  _ "$cli_backup" "$OLD/bin/antenna.sh"
check "explicit upgrade replacement installs the new dispatcher" test \
  "$(readlink -f "$HOME_DIR/custom/antenna")" = "$NEW/bin/antenna.sh"
custom_backup="$(find "$HOME_DIR/custom" -mindepth 2 -maxdepth 2 \
  -path '*/antenna.antenna-backup-*/displaced' -print -quit)"
check "explicit upgrade replacement preserves foreign command" grep -qx 'foreign-cli' "$custom_backup"
check "operator receives explicit re-pair warning" grep -q "fresh encrypted Ed25519 re-pair" <<<"$output"

if PATH="$HOME_DIR/bin:$PATH" HOME="$HOME_DIR" USER=tester bash "$NEW/scripts/antenna-upgrade.sh" --from "$OLD" --gateway "$GATEWAY" >/dev/null 2>&1; then
  no "rerun refuses to overwrite destination runtime state"
else
  ok "rerun refuses to overwrite destination runtime state"
fi

echo "SUMMARY $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
