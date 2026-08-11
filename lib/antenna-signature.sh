#!/usr/bin/env bash
# Ed25519 primitives and canonical-byte construction for antenna-ed25519-v1.

signature_uuid_v4() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then tr 'A-F' 'a-f' </proc/sys/kernel/random/uuid
  else
    local h
    h=$(openssl rand -hex 16) || return 1
    printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$((0x${h:16:1} % 4 + 8))" "${h:17:3}" "${h:20:12}"
  fi
}

signature_public_key_ok() {
  local key="$1"
  [[ -f "$key" && ! -L "$key" ]] || return 1
  openssl pkey -pubin -in "$key" -text_pub -noout 2>/dev/null | head -n1 | grep -q '^ED25519 Public-Key:'
}

signature_private_key_ok() {
  local key="$1" mode owner
  [[ -f "$key" && ! -L "$key" ]] || return 1
  mode=$(stat -c '%a' "$key" 2>/dev/null) || return 1
  owner=$(stat -c '%u' "$key" 2>/dev/null) || return 1
  [[ "$owner" -eq "$(id -u)" ]] || return 1
  (( (8#$mode & 077) == 0 )) || return 1
  openssl pkey -in "$key" -text -noout 2>/dev/null | head -n1 | grep -q '^ED25519 Private-Key:'
}

signature_keygen() {
  local private="$1" public="$2" dir
  dir=$(dirname "$private")
  [[ "$dir" == "$(dirname "$public")" ]] || return 1
  [[ ! -e "$private" && ! -e "$public" ]] || return 1
  mkdir -p "$dir" && chmod 0700 "$dir" || return 1
  if ! (
    umask 077
    openssl genpkey -algorithm ED25519 -out "$private" >/dev/null 2>&1 &&
      openssl pkey -in "$private" -pubout -out "$public" >/dev/null 2>&1 &&
      chmod 0600 "$private" && chmod 0644 "$public"
  ); then
    rm -f "$private" "$public"
    return 1
  fi
}

signature_public_fingerprint() {
  local key="$1"
  signature_public_key_ok "$key" || return 1
  openssl pkey -pubin -in "$key" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

_signature_field() {
  local name="$1" value="$2"
  printf '%s:%s:' "$name" "$(printf '%s' "$value" | wc -c | tr -d ' ')"
  printf '%s\n' "$value"
}

# signature_canonical_file out protocol from timestamp id target user reply subject body-file
signature_canonical_file() {
  local out="$1" protocol="$2" from="$3" timestamp="$4" id="$5"
  local target="$6" user="$7" reply="$8" subject="$9" body="${10}"
  [[ -f "$body" && ! -L "$body" ]] || return 1
  {
    _signature_field protocol "$protocol"
    _signature_field from "$from"
    _signature_field timestamp "$timestamp"
    _signature_field message_id "$id"
    _signature_field target_session "$target"
    _signature_field user "$user"
    _signature_field reply_to "$reply"
    _signature_field subject "$subject"
    printf 'body:%s:' "$(wc -c <"$body" | tr -d ' ')"
    cat "$body"
    printf '\n'
  } >"$out"
}

signature_sign() {
  local key="$1" canonical="$2" sig
  signature_private_key_ok "$key" || return 1
  sig=$(mktemp "${TMPDIR:-/tmp}/antenna-signature.XXXXXX") || return 1
  chmod 0600 "$sig"
  openssl pkeyutl -sign -rawin -inkey "$key" -in "$canonical" -out "$sig" 2>/dev/null || { rm -f "$sig"; return 1; }
  [[ $(wc -c <"$sig") -eq 64 ]] || { rm -f "$sig"; return 1; }
  openssl base64 -A -in "$sig"
  rm -f "$sig"
}

signature_verify() {
  local key="$1" canonical="$2" encoded="$3" sig
  signature_public_key_ok "$key" || return 1
  [[ "$encoded" =~ ^[A-Za-z0-9+/]{86}==$ ]] || return 1
  sig=$(mktemp "${TMPDIR:-/tmp}/antenna-signature.XXXXXX") || return 1
  chmod 0600 "$sig"
  printf '%s' "$encoded" | openssl base64 -A -d >"$sig" 2>/dev/null || { rm -f "$sig"; return 1; }
  [[ $(wc -c <"$sig") -eq 64 ]] || { rm -f "$sig"; return 1; }
  openssl pkeyutl -verify -rawin -pubin -inkey "$key" -in "$canonical" -sigfile "$sig" >/dev/null 2>&1
  local rc=$?
  rm -f "$sig"
  return "$rc"
}
