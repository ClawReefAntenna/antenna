#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
pass=0 fail=0
ok(){ printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

setup="$ROOT/scripts/antenna-setup.sh"
status_block=$(awk '/# Check the credential selected/,/local xpk/' "$ROOT/bin/antenna.sh")
path_block=$(awk '/# ── PATH symlink/,/if \[\[ "\$AUTO_REGISTERED"/' "$setup")
model_block=$(awk '/# Prefer the host.s configured default/,/# Inbox settings/' "$setup")

grep -q 'auth_mode.*ed25519-v1' <<<"$status_block" \
  && grep -q 'signature_public_key_ok' <<<"$status_block" \
  && ok "status audits Ed25519 pinned keys instead of legacy secrets" \
  || no "status audits Ed25519 pinned keys instead of legacy secrets"

grep -q '\-w "\$candidate"' <<<"$path_block" \
  && grep -q '\$HOME/.local/bin/antenna' <<<"$path_block" \
  && ok "setup skips unwritable PATH directories and retains user-local fallback" \
  || no "setup skips unwritable PATH directories and retains user-local fallback"

grep -q 'agents.defaults.model.primary' <<<"$model_block" \
  && grep -q 'models status --json' <<<"$model_block" \
  && grep -q 'Relay model is not available on this host' <<<"$model_block" \
  && ok "non-interactive setup uses host default and rejects unavailable models" \
  || no "non-interactive setup uses host default and rejects unavailable models"

for forbidden in AGENTS.md IDENTITY.md SOUL.md USER.md openclaw-workspace-state.json references/VAL-001-VALIDATION-REPORT-2026-08-15.md; do
  node --input-type=module -e \
    "import { listTextFiles } from '/home/corey/.npm-global/lib/node_modules/clawhub/dist/skills.js'; const f=await listTextFiles(process.argv[1]); process.exit(f.some(x=>x.relPath===process.argv[2])?1:0)" \
    "$ROOT" "$forbidden" || { no "ClawHub excludes $forbidden"; continue; }
  ok "ClawHub excludes $forbidden"
done

printf 'RESULT: pass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
