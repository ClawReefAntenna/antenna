#!/usr/bin/env bash
# ANT-164-001/002 regression: v1.6.4 carries removal-only migration helpers
# for exact v1.6.3 staging residue and preserves customized/foreign content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d /tmp/antenna-ant164-cleanup-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# shellcheck source=../lib/v163-staging-cleanup.sh
source "$ROOT/lib/v163-staging-cleanup.sh"

check 'migration pins the released v1.6.3 transform hash' \
  test "$V163_STAGING_TRANSFORM_SHA256" = \
  b38306400676a91ec6513be8f0373e3a8a22ff197c2bc50a1f007a093c117d3a

cat >"$TMP/canonical.json" <<JSON
{
  "hooks": {
    "mappings": [
      {"id":"unrelated","match":{"path":"other"},"action":"agent"},
      $v163_staging_mapping_filter
    ]
  }
}
JSON

check 'exact v1.6.3 mapping is recognized' \
  test "$(v163_staging_mapping_audit "$TMP/canonical.json")" = 'pass|canonical'
check 'cleanup candidate is produced' \
  v163_staging_write_cleanup_candidate "$TMP/canonical.json" "$TMP/clean.json"
check 'cleanup removes only the exact v1.6.3 mapping' \
  jq -e '.hooks.mappings == [{"id":"unrelated","match":{"path":"other"},"action":"agent"}]' \
  "$TMP/clean.json"

jq '.hooks.mappings[1].name = "Customized Antenna"' \
  "$TMP/canonical.json" >"$TMP/customized.json"
check 'customized v1.6.3 mapping is rejected' \
  grep -q '^fail|' < <(v163_staging_mapping_audit "$TMP/customized.json")
if v163_staging_write_cleanup_candidate "$TMP/customized.json" "$TMP/should-not-exist" 2>/dev/null; then
  fail 'customized mapping is never rewritten'
else
  pass 'customized mapping is never rewritten'
fi

mkdir -p "$TMP/hooks/transforms"
printf '%s\n' 'test canonical transform' >"$TMP/hooks/transforms/antenna-stage.mjs"
V163_STAGING_TRANSFORM_SHA256="$(_v163_sha256 "$TMP/hooks/transforms/antenna-stage.mjs")"
check 'exact-hash transform is recognized' \
  grep -q '^pass|' < <(v163_staging_transform_audit "$TMP/hooks/transforms/antenna-stage.mjs")
check 'exact-hash transform is removed' \
  v163_staging_remove_transform_if_canonical "$TMP/hooks/transforms/antenna-stage.mjs"
check 'exact-hash transform path is gone' \
  test ! -e "$TMP/hooks/transforms/antenna-stage.mjs"

printf '%s\n' 'operator customization' >"$TMP/hooks/transforms/antenna-stage.mjs"
if v163_staging_remove_transform_if_canonical "$TMP/hooks/transforms/antenna-stage.mjs"; then
  fail 'customized transform is never removed'
else
  pass 'customized transform is never removed'
fi
check 'customized transform remains present' \
  test -f "$TMP/hooks/transforms/antenna-stage.mjs"

printf 'RESULT pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
