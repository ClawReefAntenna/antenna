#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/antenna-public-group-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/scripts"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/antenna-public-group.sh" "$ROOT/scripts/"
cat >"$ROOT/antenna-public-groups.json" <<'JSON'
{
  "reef-news": {
    "group_id": "11111111-1111-4111-8111-111111111111",
    "name": "Reef News",
    "relay_peer": "clawreef"
  }
}
JSON
cat >"$ROOT/scripts/antenna-send.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${ANTENNA_TEST_ARGS:?}"
cat >"${ANTENNA_TEST_BODY:?}"
SH
chmod 700 "$ROOT/scripts/antenna-send.sh"
export ANTENNA_TEST_ARGS="$ROOT/args" ANTENNA_TEST_BODY="$ROOT/body"

list=$(bash "$ROOT/scripts/antenna-public-group.sh" list)
[[ "$list" == $'@reef-news\tReef News\t11111111-1111-4111-8111-111111111111\trelay=clawreef' ]]
bash "$ROOT/scripts/antenna-public-group.sh" send @reef-news "hello reef" --subject "Notice"
[[ "$(sed -n '1p' "$ROOT/args")" == "clawreef" ]]
grep -qx -- '--subject' "$ROOT/args"
grep -qx -- '--stdin' "$ROOT/args"
grep -q '^group_id: 11111111-1111-4111-8111-111111111111$' "$ROOT/body"
[[ "$(tail -n 1 "$ROOT/body")" == "hello reef" ]]

printf 'PASS: Public Group routes contain only group identity and ClawReef peer\n'
printf 'PASS: Public Group sends reuse ordinary antenna-send.sh signing and HTTPS path\n'
