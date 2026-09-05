#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
UNINSTALL_SCRIPT="$SKILL_DIR/scripts/antenna-uninstall.sh"
ANTENNA_CLI="$SKILL_DIR/bin/antenna.sh"

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

cli_output="$(bash "$ANTENNA_CLI" uninstall --yes --dry-run --keep-gateway-config)"
grep -q 'Antenna Uninstall' <<<"$cli_output" || fail "CLI allows uninstall after config removal"
pass "CLI allows uninstall after config removal"

assert_no_antenna() {
  local file="$1" label="$2"
  local remaining
  remaining="$(jq '[
    (if (.agents | type) == "array" then .agents[] else empty end),
    (if (.agents | type) == "object" then (if (.agents.list | type) == "array" then .agents.list[] else empty end) else empty end),
    (if (.agents | type) == "object" then (if (.agents.entries | type) == "object" then .agents.entries[] else empty end) else empty end),
    (if (.agents | type) == "object" then (.agents[] | select(type == "object" and .id? != null)) else empty end)
  ] | map(select((.id // "") == "antenna" or ((.name // "") | ascii_downcase) == "antenna relay")) | length' "$file")"
  [[ "$remaining" == "0" ]] || fail "$label: antenna agent still present"
}

assert_hooks_clean() {
  local file="$1" label="$2"
  jq -e '
    ((.hooks.allowedAgentIds // []) | index("antenna")) == null and
    ((.hooks.allowedSessionKeyPrefixes // []) | index("hook:antenna")) == null and
    ((.hooks.allowedSessionKeyPrefixes // []) | index("hook:antenna:")) == null and
    ([.hooks.mappings[]? | select(.id == "antenna-deterministic-staging")] | length) == 0
  ' "$file" >/dev/null || fail "$label: hooks entries still present"
}

run_case() {
  local name="$1" json="$2"
  local tmpdir gateway skill
  tmpdir="$(mktemp -d /tmp/ref1200-XXXXXX)"
  skill="$tmpdir/skill"
  gateway="$tmpdir/openclaw.json"
  mkdir -p "$skill/scripts" "$skill/lib" "$skill/bin" "$skill/secrets" "$skill/keys" \
    "$skill/state" "$skill/test-results" "$tmpdir/hooks/transforms" "$tmpdir/home/.local/bin"
  cp "$UNINSTALL_SCRIPT" "$skill/scripts/antenna-uninstall.sh"
  cp "$SKILL_DIR/lib/v163-staging-cleanup.sh" "$SKILL_DIR/lib/cli-link.sh" "$skill/lib/"
  printf '#!/usr/bin/env bash\n' >"$skill/bin/antenna.sh"
  ln -s "$skill/bin/antenna.sh" "$tmpdir/home/.local/bin/antenna"
  printf '{}\n' > "$skill/antenna-config.json"
  printf '{}\n' > "$skill/antenna-peers.json"
  printf '[]\n' > "$skill/antenna-inbox.json"
  printf '{}\n' > "$skill/antenna-lists.json"
  printf '{}\n' > "$skill/antenna-public-groups.json"
  printf 'log\n' > "$skill/antenna.log"
  printf '{}\n' > "$skill/antenna-ratelimit.json"
  printf 'secret\n' > "$skill/secrets/token"
  printf 'public-key\n' > "$skill/keys/peer.pem"
  printf 'state\n' > "$skill/state/replay"
  printf 'result\n' > "$skill/test-results/result"
  printf '%s\n' "$json" > "$gateway"
  HOME="$tmpdir/home" USER=tester bash "$skill/scripts/antenna-uninstall.sh" --yes --dry-run --gateway "$gateway" >/dev/null
  HOME="$tmpdir/home" USER=tester bash "$skill/scripts/antenna-uninstall.sh" --yes --gateway "$gateway" >/dev/null
  for removed in \
    antenna-config.json antenna-peers.json antenna-inbox.json antenna-lists.json \
    antenna-public-groups.json antenna.log antenna-ratelimit.json secrets keys state test-results; do
    [[ ! -e "$skill/$removed" ]] || fail "$name: runtime artifact still present: $removed"
  done
  assert_no_antenna "$gateway" "$name"
  assert_hooks_clean "$gateway" "$name"
  [[ ! -e "$tmpdir/home/.local/bin/antenna" && ! -L "$tmpdir/home/.local/bin/antenna" ]] \
    || fail "$name: owned CLI symlink still present"
  [[ ! -e "$tmpdir/hooks/transforms/antenna-stage.mjs" ]] || fail "$name: staging transform still present"
  rm -rf "$tmpdir"
  pass "$name"
}

run_case "agents.list shape" '{
  "agents": {
    "defaults": {"model": "x"},
    "list": [
      {"id": "main", "name": "Main Agent"},
      {"id": "antenna", "name": "Antenna Relay"}
    ]
  },
  "hooks": {
    "allowedAgentIds": ["main", "antenna"],
    "allowedSessionKeyPrefixes": ["hook:antenna", "hook:other"]
  }
}'

run_case "agents array shape" '{
  "agents": [
    {"id": "main", "name": "Main Agent"},
    {"id": "antenna", "name": "Antenna Relay"}
  ],
  "hooks": {
    "allowedAgentIds": ["antenna"],
    "allowedSessionKeyPrefixes": ["hook:antenna"]
  }
}'

run_case "agents.entries shape" '{
  "agents": {
    "entries": {
      "main": {"id": "main", "name": "Main Agent"},
      "antenna": {"id": "antenna", "name": "Antenna Relay"}
    }
  },
  "hooks": {
    "allowedAgentIds": ["antenna", "main"],
    "allowedSessionKeyPrefixes": ["hook:antenna", "hook:main"]
  }
}'

run_case "v1.6.3 canonical hook shape" '{
  "agents": {
    "entries": {
      "main": {"id": "main", "name": "Main Agent"},
      "antenna": {"id": "antenna", "name": "Antenna Relay"}
    }
  },
  "hooks": {
    "allowedAgentIds": ["antenna", "main"],
    "allowedSessionKeyPrefixes": ["hook:antenna:", "hook:other"],
    "mappings": [{
      "id": "antenna-deterministic-staging",
      "match": {"path": "antenna"},
      "action": "agent",
      "agentId": "antenna",
      "wakeMode": "now",
      "name": "Antenna",
      "sessionKey": "hook:antenna",
      "deliver": false,
      "allowUnsafeExternalContent": false,
      "transform": {"module": "antenna-stage.mjs", "export": "default"}
    }]
  }
}'

purge_tmp="$(mktemp -d /tmp/ref1200-purge-XXXXXX)"
purge_skill="$purge_tmp/skill"
cp -a "$SKILL_DIR" "$purge_skill"
rm -f "$purge_skill/antenna-config.json"
HOME="$purge_tmp/home" USER=tester bash "$purge_skill/bin/antenna.sh" \
  uninstall --yes --purge-skill-dir --keep-gateway-config >/dev/null
[[ ! -e "$purge_skill" ]] || fail "follow-up purge after config removal"
rm -rf "$purge_tmp"
pass "follow-up purge after config removal"

echo "All REF-1200 uninstall cleanup tests passed."
