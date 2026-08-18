#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/antenna-public-group-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/scripts" "$ROOT/lib" "$ROOT/keys"
chmod 700 "$ROOT/keys"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/antenna-public-group.sh" "$ROOT/scripts/"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/antenna-signature.sh" "$ROOT/lib/"
openssl genpkey -algorithm ED25519 -out "$ROOT/keys/test-private.pem" >/dev/null 2>&1
openssl pkey -in "$ROOT/keys/test-private.pem" -pubout -out "$ROOT/keys/clawreef-signing-public.pem" >/dev/null 2>&1
chmod 600 "$ROOT/keys/test-private.pem"
chmod 644 "$ROOT/keys/clawreef-signing-public.pem"
cat >"$ROOT/antenna-public-groups.json" <<'JSON'
{
  "reef-news": {
    "group_id": "11111111-1111-4111-8111-111111111111",
    "name": "Reef News",
    "relay_peer": "clawreef"
  }
}
JSON
chmod 600 "$ROOT/antenna-public-groups.json"
cat >"$ROOT/antenna-peers.json" <<'JSON'
{
  "clawreef": {
    "auth_mode": "ed25519-v1",
    "signing_public_key_file": "keys/clawreef-signing-public.pem"
  }
}
JSON
cat >"$ROOT/scripts/antenna-send.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${ANTENNA_TEST_ARGS:?}"
cat >"${ANTENNA_TEST_BODY:?}"
if [[ "${ANTENNA_TEST_PARTIAL:-false}" == "true" ]]; then
  printf '%s\n' '{"status":"delivered","response":{"accepted":1,"failed":1,"results":[]}}'
else
  printf '%s\n' '{"status":"delivered","response":{"accepted":2,"failed":0,"results":[]}}'
fi
SH
chmod 700 "$ROOT/scripts/antenna-send.sh"
export ANTENNA_TEST_ARGS="$ROOT/args" ANTENNA_TEST_BODY="$ROOT/body"

list=$(bash "$ROOT/scripts/antenna-public-group.sh" list)
[[ "$list" == $'@reef-news\tReef News\t11111111-1111-4111-8111-111111111111\trelay=clawreef' ]]
bash "$ROOT/scripts/antenna-public-group.sh" send @reef-news "hello reef" --subject "Notice"
[[ "$(sed -n '1p' "$ROOT/args")" == "clawreef" ]]
grep -qx -- '--subject' "$ROOT/args"
grep -qx -- '--stdin' "$ROOT/args"
grep -qx -- '--include-response' "$ROOT/args"
grep -q '^group_id: 11111111-1111-4111-8111-111111111111$' "$ROOT/body"
[[ "$(tail -n 1 "$ROOT/body")" == "hello reef" ]]

export ANTENNA_TEST_PARTIAL=true
if bash "$ROOT/scripts/antenna-public-group.sh" send @reef-news "partial reef" >"$ROOT/partial.out" 2>"$ROOT/partial.err"; then
  echo "FAIL: partial Public Group fan-out returned success" >&2
  exit 1
fi
grep -q '"failed":1' "$ROOT/partial.out"
grep -q 'reported 1 failed delivery attempt' "$ROOT/partial.err"

cat >"$ROOT/download.json" <<'JSON'
{
  "reef-lounge": {
    "group_id": "22222222-2222-4222-8222-222222222222",
    "name": "Reef Lounge",
    "relay_peer": "clawreef"
  }
}
JSON
bash "$ROOT/scripts/antenna-public-group.sh" install "$ROOT/download.json" --alias lounge
[[ "$(stat -c '%a' "$ROOT/antenna-public-groups.json")" == "600" ]]
jq -e '.lounge.name == "Reef Lounge" and .["reef-news"].name == "Reef News"' "$ROOT/antenna-public-groups.json" >/dev/null
if bash "$ROOT/scripts/antenna-public-group.sh" install "$ROOT/download.json" >"$ROOT/duplicate.out" 2>"$ROOT/duplicate.err"; then
  echo "FAIL: duplicate group ID was installed" >&2
  exit 1
fi
grep -q 'already installed as @lounge' "$ROOT/duplicate.err"

cat >"$ROOT/refresh.json" <<'JSON'
{
  "registry-renamed-slug": {
    "group_id": "22222222-2222-4222-8222-222222222222",
    "name": "The Reef Lounge",
    "relay_peer": "clawreef"
  }
}
JSON
bash "$ROOT/scripts/antenna-public-group.sh" refresh "$ROOT/refresh.json"
jq -e '.lounge.name == "The Reef Lounge" and has("registry-renamed-slug") == false and has("reef-news")' "$ROOT/antenna-public-groups.json" >/dev/null

cat >"$ROOT/malformed.json" <<'JSON'
{"bad":{"group_id":"22222222-2222-4222-8222-222222222222","name":"Bad","relay_peer":"clawreef","token":"must-not-appear"}}
JSON
if bash "$ROOT/scripts/antenna-public-group.sh" refresh "$ROOT/malformed.json" >/dev/null 2>&1; then
  echo "FAIL: route with mixed/extra fields was accepted" >&2
  exit 1
fi

bash "$ROOT/scripts/antenna-public-group.sh" remove @lounge
jq -e 'has("lounge") == false and has("reef-news")' "$ROOT/antenna-public-groups.json" >/dev/null

printf 'PASS: Public Group routes contain only group identity and ClawReef peer\n'
printf 'PASS: Public Group sends reuse ordinary antenna-send.sh signing and HTTPS path\n'
printf 'PASS: Public Group sends surface partial-delivery results and fail closed\n'
printf 'PASS: Public Group route install, refresh, and remove preserve aliases and unrelated routes\n'
printf 'PASS: Public Group route lifecycle enforces schema, mode 0600, and pinned relay prerequisites\n'
