#!/usr/bin/env bash
# ANT-162-006 — Side-by-side upgrade refuses an invalid destination relay policy
# BEFORE any mutation, across both supported OpenClaw generations (7.x list and
# 8.1 entries rosters).
#
# Proves for missing / symlinked / generic-template / marker-free / hash-tampered
# destination agent/AGENTS.md: (a) upgrade exits non-zero, (b) the message names
# agent/AGENTS.md and the safe recovery action, and (c) no source, destination
# runtime, gateway, gateway-backup, or CLI-symlink byte changed. Also proves a
# valid packaged relay policy passes the gate.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# Build a self-contained fixture: a new (destination) release tree, an old
# (source) install, a home with a gateway config of the requested generation,
# and a CLI symlink pointing at the old install.
make_case() {
  local name="$1" generation="$2"
  local root="$TMP/$name"
  local old="$root/old" new="$root/new" home="$root/home"
  mkdir -p "$old/agent" "$old/bin" \
           "$new/scripts" "$new/lib/relay-policy/agent" "$new/bin" "$new/agent" \
           "$home/.openclaw" "$home/bin"

  cp "$ROOT/scripts/antenna-upgrade.sh" "$new/scripts/"
  cp "$ROOT/lib/gateway-roster.sh" "$ROOT/lib/relay-policy.sh" \
    "$ROOT/lib/v163-staging-cleanup.sh" "$new/lib/"
  cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$new/lib/relay-policy/agent/"
  cp "$ROOT/lib/relay-policy/manifest.sha256" "$new/lib/relay-policy/"
  cp "$ROOT/bin/antenna.sh" "$new/bin/"
  # Destination ships a valid relay policy by default; individual cases tamper it.
  cp "$ROOT/lib/relay-policy/agent/AGENTS.md" "$new/agent/AGENTS.md"
  chmod +x "$new/scripts/antenna-upgrade.sh" "$new/bin/antenna.sh"

  printf '#!/usr/bin/env bash\n' > "$old/bin/antenna.sh"
  jq -n --arg old "$old" '{install_path:$old}' > "$old/antenna-config.json"
  printf '%s\n' '{"self":{"self":true,"url":"https://self.example"}}' > "$old/antenna-peers.json"

  if [[ "$generation" == "entries" ]]; then
    cat > "$home/.openclaw/openclaw.json" <<JSON
{
  "agents": {
    "ownership": "explicit",
    "entries": {
      "main": {"workspace": "$home/workspace"},
      "antenna": {"agentDir": "$old/agent", "workspace": "$old/agent"}
    }
  }
}
JSON
  else
    cat > "$home/.openclaw/openclaw.json" <<JSON
{
  "agents": {
    "list": [
      {"id": "main", "workspace": "$home/workspace"},
      {"id": "antenna", "agentDir": "$old/agent", "workspace": "$old/agent"}
    ]
  }
}
JSON
  fi

  # A CLI symlink pointing at the OLD install; a refusal must not repoint it.
  ln -s "$old/bin/antenna.sh" "$home/bin/antenna"

  cat > "$home/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "config" && "${2:-}" == "validate" ]]; then jq empty "${OPENCLAW_CONFIG_PATH:?}"; exit $?; fi
exit 2
STUB
  chmod +x "$home/bin/openclaw"

  printf '%s\n' "$root"
}

dir_fingerprint() { find "$1" -printf '%p %s %y\n' 2>/dev/null | LC_ALL=C sort; }

# Drive each tamper case; each builds its own fresh tree, tampers the
# destination policy, then runs the refusal + no-mutation assertions.
run_tamper() {
  local name="$1" generation="$2" tamper="$3"
  local root; root="$(make_case "$name-$generation" "$generation")"
  local new="$root/new"
  case "$tamper" in
    missing) rm -f "$new/agent/AGENTS.md" ;;
    symlink) rm -f "$new/agent/AGENTS.md"; ln -s "$new/lib/relay-policy/agent/AGENTS.md" "$new/agent/AGENTS.md" ;;
    generic) printf '# AGENTS.md - Your Workspace\n\nWelcome.\n' > "$new/agent/AGENTS.md" ;;
    markerfree) printf 'not the relay policy\n' > "$new/agent/AGENTS.md" ;;
    hashmismatch)
      # Keep the identity marker and byte length intact while changing content.
      sed -i '0,/mechanical/{s/mechanical/mechanicxl/}' "$new/agent/AGENTS.md"
      ;;
  esac
  # Re-run the refusal assertions against this prepared tree.
  local old="$root/old" home="$root/home" gateway="$root/home/.openclaw/openclaw.json"
  local gw_before src_before link_before output rc
  gw_before="$(sha256sum "$gateway" | awk '{print $1}')"
  src_before="$(dir_fingerprint "$old")"
  link_before="$(readlink "$home/bin/antenna")"
  output="$(PATH="$home/bin:$PATH" HOME="$home" USER=fixture \
    bash "$new/scripts/antenna-upgrade.sh" --from "$old" --gateway "$gateway" 2>&1)"
  rc=$?
  check "$name/$generation refuses (nonzero)" test "$rc" -ne 0
  check "$name/$generation names agent/AGENTS.md" grep -Fq "agent/AGENTS.md" <<<"$output"
  check "$name/$generation names canonical-contract failure" \
    grep -Fq "is not a canonical Antenna relay contract" <<<"$output"
  check "$name/$generation gives recovery action" grep -Fq "Restore this release package" <<<"$output"
  check "$name/$generation preserves gateway bytes" test \
    "$gw_before" = "$(sha256sum "$gateway" | awk '{print $1}')"
  check "$name/$generation writes no gateway backup" test \
    -z "$(find "$home/.openclaw" -maxdepth 1 -name 'openclaw.json.antenna-upgrade-backup-*' -print -quit)"
  check "$name/$generation installs no destination runtime state" test ! -e "$new/antenna-config.json"
  check "$name/$generation leaves no staging dir" test \
    -z "$(find "$new" -maxdepth 1 -name '.antenna-upgrade.*' -print -quit)"
  check "$name/$generation does not touch the source install" test \
    "$src_before" = "$(dir_fingerprint "$old")"
  check "$name/$generation does not repoint the CLI symlink" test \
    "$link_before" = "$(readlink "$home/bin/antenna")"
}

for generation in list entries; do
  run_tamper missing "$generation" missing
  run_tamper symlink "$generation" symlink
  run_tamper generic "$generation" generic
  run_tamper markerfree "$generation" markerfree
  run_tamper hashmismatch "$generation" hashmismatch
done

# ── Positive control: a valid packaged relay policy passes the gate ─────────
for generation in list entries; do
  root="$(make_case "valid-$generation" "$generation")"
  new="$root/new"; old="$root/old"; gateway="$root/home/.openclaw/openclaw.json"
  output="$(PATH="$root/home/bin:$PATH" HOME="$root/home" USER=fixture \
    bash "$new/scripts/antenna-upgrade.sh" --from "$old" --gateway "$gateway" 2>&1)" || true
  check "valid/$generation policy passes the relay-policy gate" \
    bash -c '! grep -Fq "is not a canonical Antenna relay contract" <<<"$1"' _ "$output"
done

printf 'SUMMARY %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
