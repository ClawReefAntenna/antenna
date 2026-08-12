#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1" >&2; fail=$((fail+1)); }

for host in alpha beta; do
  mkdir -p "$TMP/$host"; cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/scripts" "$TMP/$host/"
  mkdir -m 0700 "$TMP/$host/secrets"
  printf token >"$TMP/$host/secrets/hooks_token_$host"; chmod 0600 "$TMP/$host/secrets/hooks_token_$host"
  cat >"$TMP/$host/antenna-config.json" <<EOF
{"allowed_inbound_peers":["alpha","beta"],"allowed_outbound_peers":["alpha","beta"],"log_enabled":false}
EOF
  cat >"$TMP/$host/antenna-peers.json" <<EOF
{"$host":{"url":"https://$host.example.test","token_file":"secrets/hooks_token_$host","agentId":"antenna","self":true}}
EOF
done
age-keygen -o "$TMP/beta/secrets/antenna-exchange.agekey" >/dev/null 2>&1
age-keygen -y "$TMP/beta/secrets/antenna-exchange.agekey" >"$TMP/beta/secrets/antenna-exchange.agepub"
beta_pub=$(cat "$TMP/beta/secrets/antenna-exchange.agepub")

(cd "$TMP/alpha" && bash bin/antenna.sh peers exchange initiate beta --pubkey "$beta_pub" --output "$TMP/ed.age" --yes) >/dev/null
age -d -i "$TMP/beta/secrets/antenna-exchange.agekey" "$TMP/ed.age" >"$TMP/ed.json"
jq -e '.schema_version==2 and .from_auth_mode=="ed25519-v1" and .from_identity_secret==null and (.from_signing_public_key|startswith("-----BEGIN PUBLIC KEY-----"))' "$TMP/ed.json" >/dev/null \
  && ok "v2 Ed25519 bundle fields are mutually exclusive" || no "v2 Ed25519 bundle shape"
(cd "$TMP/beta" && bash bin/antenna.sh peers exchange import "$TMP/ed.age" --yes) >/dev/null
jq -e '.alpha.auth_mode=="ed25519-v1" and (.alpha|has("peer_secret_file")|not) and (.alpha.signing_public_key_file|startswith("keys/"))' "$TMP/beta/antenna-peers.json" >/dev/null \
  && ok "Ed25519 import pins only public key" || no "Ed25519 import registry"

(cd "$TMP/alpha" && bash bin/antenna.sh peers exchange initiate beta --pubkey "$beta_pub" --output "$TMP/legacy.age" --yes --auth-mode plaintext-legacy) >/dev/null
age -d -i "$TMP/beta/secrets/antenna-exchange.agekey" "$TMP/legacy.age" >"$TMP/legacy.json"
jq -e '.schema_version==2 and .from_auth_mode=="plaintext-legacy" and (.from_identity_secret|test("^[0-9a-f]{64}$")) and .from_signing_public_key==null' "$TMP/legacy.json" >/dev/null \
  && ok "v2 legacy bundle fields are mutually exclusive" || no "v2 legacy bundle shape"
(cd "$TMP/beta" && bash bin/antenna.sh peers exchange import "$TMP/legacy.age" --yes) >"$TMP/import.out" 2>&1
jq -e '.alpha.auth_mode=="plaintext-legacy" and (.alpha.peer_secret_file|startswith("secrets/")) and (.alpha|has("signing_public_key_file")|not)' "$TMP/beta/antenna-peers.json" >/dev/null \
  && grep -q 'reusable identity secret' "$TMP/import.out" \
  && ok "legacy import selects only secret and warns" || no "legacy import policy"

jq '.from_signing_public_key="-----BEGIN PUBLIC KEY-----\nbogus\n-----END PUBLIC KEY-----"' "$TMP/legacy.json" >"$TMP/mixed.json"
source "$ROOT/lib/peers.sh"; source "$ROOT/lib/bundles.sh"
bundle_shape_reason "$TMP/mixed.json" >/dev/null 2>&1 && no "mixed v2 credentials rejected" || ok "mixed v2 credentials rejected"

jq '.schema_version=1 | del(.from_auth_mode,.from_signing_public_key)' "$TMP/legacy.json" >"$TMP/v1.json"
bundle_shape_reason "$TMP/v1.json" >/dev/null 2>&1 && age -a -r "$beta_pub" -o "$TMP/v1.age" "$TMP/v1.json"
(cd "$TMP/beta" && bash bin/antenna.sh peers exchange import "$TMP/v1.age" --yes) >/dev/null 2>&1
jq -e '.alpha.auth_mode=="plaintext-legacy"' "$TMP/beta/antenna-peers.json" >/dev/null \
  && ok "schema v1 import maps explicitly to legacy" || no "schema v1 legacy mapping"

jq '.from_signing_public_key="-----BEGIN PUBLIC KEY-----\nbogus\n-----END PUBLIC KEY-----"' "$TMP/ed.json" >"$TMP/bad-key.json"
age -a -r "$beta_pub" -o "$TMP/bad-key.age" "$TMP/bad-key.json"
before_peers=$(sha256sum "$TMP/beta/antenna-peers.json" | awk '{print $1}')
before_token=$(sha256sum "$TMP/beta/secrets/hooks_token_alpha" | awk '{print $1}')
(cd "$TMP/beta" && bash bin/antenna.sh peers exchange import "$TMP/bad-key.age" --yes) >/dev/null 2>&1 \
  && no "invalid PEM import fails before mutation" || ok "invalid PEM import fails before mutation"
after_peers=$(sha256sum "$TMP/beta/antenna-peers.json" | awk '{print $1}')
after_token=$(sha256sum "$TMP/beta/secrets/hooks_token_alpha" | awk '{print $1}')
[[ "$before_peers" == "$after_peers" && "$before_token" == "$after_token" ]] \
  && ok "invalid PEM leaves peer and token state unchanged" || no "invalid PEM partial mutation"

echo "RESULT: pass=$pass fail=$fail"; ((fail==0))
