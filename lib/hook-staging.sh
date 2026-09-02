#!/usr/bin/env bash
# Shared v1.6.3 deterministic hook-staging contract.

[[ -n "${_ANTENNA_HOOK_STAGING_SH_LOADED:-}" ]] && return 0
_ANTENNA_HOOK_STAGING_SH_LOADED=1

HOOK_STAGING_ID="antenna-deterministic-staging"
HOOK_STAGING_PATH="antenna"
HOOK_STAGING_MODULE="antenna-stage.mjs"
HOOK_STAGING_RELNAME="hooks/antenna-stage.mjs"
HOOK_STAGING_SESSION_PREFIX="hook:antenna:"

hook_staging_packaged_file() { printf '%s/%s\n' "$SKILL_DIR" "$HOOK_STAGING_RELNAME"; }

hook_staging_mapping_filter='{
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

hook_staging_mapping_audit() {
  local gateway="$1"
  jq -r --arg id "$HOOK_STAGING_ID" --arg path "$HOOK_STAGING_PATH" \
    --arg module "$HOOK_STAGING_MODULE" --argjson canonical "$hook_staging_mapping_filter" '
      (.hooks.mappings // []) as $m
      | if ($m|type)!="array" then "fail|hooks.mappings is not an array"
        elif ([$m[]|select(.id==$id)]|length)>1 then "fail|duplicate Antenna mapping id"
        elif ([$m[]|select((((.match.path // "") | sub("^/+";"") | sub("/+$";"")) == $path))]|length)>1 then "fail|duplicate /hooks/antenna path mappings"
        elif ([$m[]|select(.transform.module?==$module and .id!=$id)]|length)>0 then "fail|foreign mapping uses Antenna transform module"
        elif ([$m[]|select((.id==$id) or (((.match.path // "") | sub("^/+";"") | sub("/+$";"")) == $path))]|length)==0 then "missing|mapping absent"
        elif ([$m[]|select(.id==$id and .==$canonical)]|length)==1 then "pass|canonical"
        else "fail|conflicting Antenna mapping id or path" end
    ' "$gateway"
}

hook_staging_write_gateway_candidate() {
  local source="$1" destination="$2" audit rc
  audit="$(hook_staging_mapping_audit "$source")"; rc=$?
  [[ $rc -eq 0 ]] || return 1
  case "$audit" in fail\|*) printf '%s\n' "${audit#fail|}" >&2; return 1 ;; esac
  jq --argjson canonical "$hook_staging_mapping_filter" \
    --arg antenna_prefix "$HOOK_STAGING_SESSION_PREFIX" '
    .hooks = (if (.hooks|type)=="object" then .hooks else {} end)
    | .hooks.allowedSessionKeyPrefixes = ((.hooks.allowedSessionKeyPrefixes // [])
        | if any(.[]; . as $prefix | ($antenna_prefix + "probe") | startswith($prefix))
          then . else . + [$antenna_prefix] end)
    | .hooks.mappings = (if (.hooks.mappings|type)=="array" then .hooks.mappings else [] end)
    | if any(.hooks.mappings[]; .id==$canonical.id) then
        .hooks.mappings = [.hooks.mappings[] | if .id==$canonical.id then $canonical else . end]
      else .hooks.mappings += [$canonical] end
  ' "$source" > "$destination"
}

hook_staging_session_prefix_audit() {
  local gateway="$1"
  jq -r --arg antenna_prefix "$HOOK_STAGING_SESSION_PREFIX" '
    if (.hooks.allowedSessionKeyPrefixes? == null) then
      "pass|prefix allowlist is not configured (static mapping is allowed)"
    elif ((.hooks.allowedSessionKeyPrefixes | type) != "array") then
      "fail|hooks.allowedSessionKeyPrefixes is not an array"
    elif any(.hooks.allowedSessionKeyPrefixes[];
             . as $prefix | ($antenna_prefix + "probe") | startswith($prefix)) then
      "pass|Antenna hook-session namespace is allowed"
    else
      "fail|hooks.allowedSessionKeyPrefixes excludes hook:antenna:*"
    end
  ' "$gateway"
}

hook_staging_resolve_transforms_dir() {
  local gateway="$1" outvar="$2" configured raw_base raw_candidate base resolved cur
  raw_base="$(dirname "$gateway")/hooks/transforms"
  _hook_staging_no_symlink_ancestors "$(dirname "$gateway")" || return 1
  _hook_staging_no_symlink_ancestors "$raw_base" || return 1
  base="$(realpath -m "$raw_base")" || return 1
  configured="$(jq -r '.hooks.transformsDir // empty' "$gateway" 2>/dev/null)" || return 1
  if [[ -z "$configured" ]]; then resolved="$base"
  else
    [[ "$configured" != *$'\n'* ]] || return 1
    [[ "$configured" == "~" || "$configured" == "~/"* ]] && configured="$HOME${configured:1}"
    if [[ "$configured" != /* ]]; then raw_candidate="$raw_base/$configured"; else raw_candidate="$configured"; fi
    _hook_staging_no_symlink_ancestors "$raw_candidate" || return 1
    resolved="$(realpath -m "$raw_candidate")" || return 1
  fi
  [[ "$resolved" == "$base" || "$resolved" == "$base/"* ]] || return 1
  cur="$base"
  [[ ! -L "$cur" ]] || return 1
  if [[ "$resolved" != "$base" ]]; then
    local suffix="${resolved#"$base"/}" part
    IFS=/ read -r -a _hook_parts <<<"$suffix"
    for part in "${_hook_parts[@]}"; do cur="$cur/$part"; [[ ! -L "$cur" ]] || return 1; done
  fi
  printf -v "$outvar" '%s' "$resolved"
}

_hook_staging_no_symlink_ancestors() {
  local input="$1" normalized cur="/" part
  # -s is lexical: do not resolve away the symlink we are trying to detect.
  normalized="$(realpath -ms "$input")" || return 1
  IFS=/ read -r -a _hook_ancestor_parts <<<"${normalized#/}"
  for part in "${_hook_ancestor_parts[@]}"; do
    [[ -n "$part" ]] || continue
    cur="${cur%/}/$part"
    [[ ! -L "$cur" ]] || return 1
  done
}

hook_staging_transform_audit() {
  local file="$1" expected actual
  expected="$(relay_policy_expected_hash "$HOOK_STAGING_RELNAME")" || { printf 'fail|manifest entry missing\n'; return 0; }
  if [[ -L "$file" ]]; then printf 'fail|transform is a symlink\n'; return 0; fi
  if [[ ! -e "$file" ]]; then printf 'missing|transform absent\n'; return 0; fi
  if [[ ! -f "$file" ]]; then printf 'fail|transform is not a regular file\n'; return 0; fi
  actual="$(relay_policy_sha256 "$file")" || { printf 'fail|cannot hash transform\n'; return 0; }
  [[ "$actual" == "$expected" ]] && printf 'pass|%s\n' "$actual" || printf 'fail|transform hash mismatch (%s)\n' "$actual"
}

hook_staging_install_transform() {
  local gateway="$1" outvar="${2:-}" dir live packaged tmp tmp_identity live_identity audit
  hook_staging_resolve_transforms_dir "$gateway" dir || return 1
  live="$dir/$HOOK_STAGING_MODULE"; packaged="$(hook_staging_packaged_file)"
  relay_policy_default_ok "$HOOK_STAGING_RELNAME" || return 1
  audit="$(hook_staging_transform_audit "$live")"
  case "$audit" in pass\|*) [[ -n "$outvar" ]] && printf -v "$outvar" '%s' existing; return 0;; fail\|*) return 1;; esac
  mkdir -p -- "$dir" || return 1
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  tmp="$(mktemp "$dir/.antenna-stage.XXXXXX")" || return 1
  if ! cp -- "$packaged" "$tmp" || ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  tmp_identity="$(stat -Lc '%d:%i' -- "$tmp" 2>/dev/null)" || { rm -f -- "$tmp"; return 1; }
  if ! ln -- "$tmp" "$live"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  audit="$(hook_staging_transform_audit "$live")"
  if [[ "$audit" != pass\|* ]]; then
    # We created the live hard link. If verification fails, remove only that
    # exact inode; never unlink a path another same-user process replaced.
    live_identity="$(stat -Lc '%d:%i' -- "$live" 2>/dev/null || true)"
    if [[ -n "$live_identity" && "$live_identity" == "$tmp_identity" && ! -L "$live" ]]; then
      rm -f -- "$live"
    fi
    return 1
  fi
  [[ -n "$outvar" ]] && printf -v "$outvar" '%s' installed
}

hook_staging_remove_if_canonical() {
  local file="$1" audit
  audit="$(hook_staging_transform_audit "$file")"
  [[ "$audit" == pass\|* ]] || return 1
  rm -f -- "$file"
}
