#!/usr/bin/env bash
# lib/v163-staging-cleanup.sh — Bounded removal helpers for the superseded
# v1.6.3 deterministic hook mapping and transform. This library never installs
# or repairs staging. It removes only the exact Antenna-owned v1.6.3 artifacts
# and fails closed around customized or foreign content.

[[ -n "${_ANTENNA_V163_STAGING_CLEANUP_SH_LOADED:-}" ]] && return 0
_ANTENNA_V163_STAGING_CLEANUP_SH_LOADED=1

V163_STAGING_MAPPING_ID="antenna-deterministic-staging"
V163_STAGING_PATH="antenna"
V163_STAGING_MODULE="antenna-stage.mjs"
V163_STAGING_TRANSFORM_SHA256="b38306400676a91ec6513be8f0373e3a8a22ff197c2bc50a1f007a093c117d3a"

v163_staging_mapping_filter='{
  "id":"antenna-deterministic-staging",
  "match":{"path":"antenna"},
  "action":"agent",
  "agentId":"antenna",
  "wakeMode":"now",
  "name":"Antenna",
  "sessionKey":"hook:antenna",
  "deliver":false,
  "allowUnsafeExternalContent":false,
  "transform":{"module":"antenna-stage.mjs","export":"default"}
}'

# Prints pass|canonical, missing|absent, or fail|reason.
v163_staging_mapping_audit() {
  local gateway="$1"
  jq -r --arg id "$V163_STAGING_MAPPING_ID" --arg path "$V163_STAGING_PATH" \
    --arg module "$V163_STAGING_MODULE" --argjson canonical "$v163_staging_mapping_filter" '
      (.hooks.mappings // []) as $m
      | if ($m | type) != "array" then "fail|hooks.mappings is not an array"
        elif ([$m[] | select(.id == $id)] | length) > 1 then "fail|duplicate Antenna v1.6.3 mapping id"
        elif ([$m[] | select((((.match.path // "") | sub("^/+";"") | sub("/+$";"")) == $path))] | length) > 1
          then "fail|duplicate /hooks/antenna path mappings"
        elif ([$m[] | select(.transform.module? == $module and .id != $id)] | length) > 0
          then "fail|foreign mapping uses the v1.6.3 transform module"
        elif ([$m[] | select((.id == $id) or (((.match.path // "") | sub("^/+";"") | sub("/+$";"")) == $path))] | length) == 0
          then "missing|mapping absent"
        elif ([$m[] | select(.id == $id and . == $canonical)] | length) == 1
          then "pass|canonical"
        else "fail|customized or conflicting v1.6.3 mapping" end
    ' "$gateway"
}

# Writes a candidate with only the exact canonical v1.6.3 mapping removed.
v163_staging_write_cleanup_candidate() {
  local source="$1" destination="$2" audit
  audit="$(v163_staging_mapping_audit "$source")" || return 1
  case "$audit" in
    pass\|*)
      jq --arg id "$V163_STAGING_MAPPING_ID" '
        .hooks.mappings |= map(select(.id != $id))
      ' "$source" >"$destination"
      ;;
    missing\|*) cp -- "$source" "$destination" ;;
    *) printf '%s\n' "${audit#fail|}" >&2; return 1 ;;
  esac
}

_v163_no_symlink_ancestors() {
  local input="$1" normalized cur="/" part
  normalized="$(realpath -ms "$input")" || return 1
  IFS=/ read -r -a _v163_parts <<<"${normalized#/}"
  for part in "${_v163_parts[@]}"; do
    [[ -n "$part" ]] || continue
    cur="${cur%/}/$part"
    [[ ! -L "$cur" ]] || return 1
  done
}

v163_staging_resolve_transforms_dir() {
  local gateway="$1" outvar="$2" configured raw_base raw_candidate base resolved cur
  raw_base="$(dirname "$gateway")/hooks/transforms"
  _v163_no_symlink_ancestors "$(dirname "$gateway")" || return 1
  _v163_no_symlink_ancestors "$raw_base" || return 1
  base="$(realpath -m "$raw_base")" || return 1
  configured="$(jq -r '.hooks.transformsDir // empty' "$gateway" 2>/dev/null)" || return 1
  if [[ -z "$configured" ]]; then
    resolved="$base"
  else
    [[ "$configured" != *$'\n'* ]] || return 1
    [[ "$configured" == "~" || "$configured" == "~/"* ]] && configured="$HOME${configured:1}"
    if [[ "$configured" != /* ]]; then raw_candidate="$raw_base/$configured"; else raw_candidate="$configured"; fi
    _v163_no_symlink_ancestors "$raw_candidate" || return 1
    resolved="$(realpath -m "$raw_candidate")" || return 1
  fi
  [[ "$resolved" == "$base" || "$resolved" == "$base/"* ]] || return 1
  cur="$base"
  [[ ! -L "$cur" ]] || return 1
  if [[ "$resolved" != "$base" ]]; then
    local suffix="${resolved#"$base"/}" part
    IFS=/ read -r -a _v163_parts <<<"$suffix"
    for part in "${_v163_parts[@]}"; do
      cur="$cur/$part"
      [[ ! -L "$cur" ]] || return 1
    done
  fi
  printf -v "$outvar" '%s' "$resolved"
}

_v163_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Prints pass|hash, missing|absent, or fail|reason.
v163_staging_transform_audit() {
  local file="$1" actual
  if [[ -L "$file" ]]; then printf 'fail|transform is a symlink\n'; return 0; fi
  if [[ ! -e "$file" ]]; then printf 'missing|transform absent\n'; return 0; fi
  if [[ ! -f "$file" ]]; then printf 'fail|transform is not a regular file\n'; return 0; fi
  actual="$(_v163_sha256 "$file")" || { printf 'fail|cannot hash transform\n'; return 0; }
  if [[ "$actual" == "$V163_STAGING_TRANSFORM_SHA256" ]]; then
    printf 'pass|%s\n' "$actual"
  else
    printf 'fail|transform hash mismatch (%s)\n' "$actual"
  fi
}

v163_staging_remove_transform_if_canonical() {
  local file="$1" audit
  audit="$(v163_staging_transform_audit "$file")"
  [[ "$audit" == pass\|* ]] || return 1
  rm -f -- "$file"
}
