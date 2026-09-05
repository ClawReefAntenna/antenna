#!/usr/bin/env bash
# lib/relay-policy.sh — Shared integrity helpers for Antenna-owned relay-agent
# policy files (agent/AGENTS.md today; future Antenna-supplied agent files via
# the same manifest). Used by both `antenna upgrade` (fail-closed preflight) and
# `antenna doctor` (read-only audit + explicit, backup-first restore).
#
# Design:
#   * A pristine packaged default of every Antenna-owned agent file lives OUTSIDE
#     the live agent workspace, under lib/relay-policy/, so OpenClaw-created
#     workspace state is never confused with Antenna content and a clean local
#     copy is always available for restore (never fetched over the network).
#   * A SHA-256 manifest (lib/relay-policy/manifest.txt) pins the expected hash
#     of each owned file. The .txt name is included by ClawHub. A legacy
#     manifest.sha256 is accepted only when it is the sole manifest present.
#     File size is never used as an integrity signal.
#   * Each Antenna policy file carries a stable identity marker so a missing,
#     symlinked, OpenClaw-generic-template, or otherwise foreign file fails
#     closed independently of the exact hash.
#
# Every check fails closed. Nothing here reaches the network or mutates live
# state; restore is performed by the caller using the accessors below.

# Resolve the packaged default location relative to this library's own path so
# the helpers work regardless of the caller's working directory.
RELAY_POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relay-policy"
RELAY_POLICY_MANIFEST_CANONICAL="$RELAY_POLICY_DIR/manifest.txt"
RELAY_POLICY_MANIFEST_LEGACY="$RELAY_POLICY_DIR/manifest.sha256"

# The stable identity marker every Antenna-owned relay policy file must contain.
# Unique to Antenna and absent from OpenClaw's generic workspace AGENTS.md
# template, so identity holds even when a file has been legitimately edited.
RELAY_POLICY_MARKER='antenna-relay-policy: id=antenna-relay-agent'

# relay_policy_sha256 <file> — print lowercase hex SHA-256, or fail.
relay_policy_sha256() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$f" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# relay_policy_manifest_file — print the sole usable manifest path.
# Canonical v1.6.5 packages ship manifest.txt. The legacy name remains a
# bounded compatibility fallback for older layouts. Both present is ambiguous
# and fails closed; symlinks and non-regular files are never accepted.
relay_policy_manifest_file() {
  local canonical_present=false legacy_present=false
  [[ -e "$RELAY_POLICY_MANIFEST_CANONICAL" || -L "$RELAY_POLICY_MANIFEST_CANONICAL" ]] && canonical_present=true
  [[ -e "$RELAY_POLICY_MANIFEST_LEGACY" || -L "$RELAY_POLICY_MANIFEST_LEGACY" ]] && legacy_present=true

  if [[ "$canonical_present" == true && "$legacy_present" == true ]]; then
    return 1
  fi
  if [[ "$canonical_present" == true ]]; then
    [[ -f "$RELAY_POLICY_MANIFEST_CANONICAL" && ! -L "$RELAY_POLICY_MANIFEST_CANONICAL" ]] || return 1
    printf '%s\n' "$RELAY_POLICY_MANIFEST_CANONICAL"
    return 0
  fi
  if [[ "$legacy_present" == true ]]; then
    [[ -f "$RELAY_POLICY_MANIFEST_LEGACY" && ! -L "$RELAY_POLICY_MANIFEST_LEGACY" ]] || return 1
    printf '%s\n' "$RELAY_POLICY_MANIFEST_LEGACY"
    return 0
  fi
  return 1
}

# relay_policy_expected_hash <relname> — print the manifest's expected hash.
# Every manifest line must be exactly sha256sum-compatible:
# "<64 lowercase hex characters>  <relative path>". The requested path must
# appear exactly once; malformed or duplicate records fail the whole manifest.
relay_policy_expected_hash() {
  local relname="$1" manifest
  manifest="$(relay_policy_manifest_file)" || return 1
  awk -v want="$relname" '
    {
      hash=substr($0,1,64)
      separator=substr($0,65,2)
      name=substr($0,67)
      if (length(hash) != 64 || hash !~ /^[0-9a-f]+$/ ||
          separator != "  " || name == "" || name ~ /^[[:space:]]/ ||
          name ~ /[[:space:]]$/ || name ~ /^\// ||
          name ~ /(^|\/)\.\.(\/|$)/ || seen[name]++) {
        invalid=1
        next
      }
      if (name == want) {
        expected=hash
        found++
      }
    }
    END {
      if (invalid || found != 1) exit 1
      print expected
    }
  ' "$manifest"
}

# relay_policy_default_file <relname> — absolute path to the packaged default.
relay_policy_default_file() {
  printf '%s\n' "$RELAY_POLICY_DIR/$1"
}

# relay_policy_has_marker <file> — 0 if the file carries the identity marker.
relay_policy_has_marker() {
  local f="$1" marker="$RELAY_POLICY_MARKER"
  [[ -f "$f" ]] || return 1
  grep -Fq -- "$marker" "$f"
}

# relay_policy_default_ok <relname>
#   Verify the packaged pristine default itself is trustworthy before it is used
#   either as a comparison baseline or as a restore source. Fails closed if the
#   default is missing, a symlink, marker-free, or does not match its own
#   manifest hash. Prevents "restoring" from a tampered package.
relay_policy_default_ok() {
  local relname="$1" def want have
  def="$(relay_policy_default_file "$relname")"
  [[ -f "$def" && ! -L "$def" ]] || return 1
  relay_policy_has_marker "$def" "$relname" || return 1
  want="$(relay_policy_expected_hash "$relname")" || return 1
  have="$(relay_policy_sha256 "$def")" || return 1
  [[ -n "$want" && "$want" == "$have" ]]
}

# relay_policy_audit <live_path> <relname>
#   Read-only classification of a live Antenna-owned policy file. Prints:
#       pass|<hash>
#       warn|<reason>|<hash>
#       fail|<reason>
#   and returns 0 (pass), 10 (warn), or 20 (fail). Never writes anything and
#   never follows the path as anything other than the file it names.
relay_policy_audit() {
  local live="$1" relname="$2" want have
  if [[ -L "$live" ]]; then
    printf 'fail|symlinked policy file (Antenna never installs a symlink here)\n'; return 20
  fi
  if [[ ! -e "$live" ]]; then
    printf 'fail|missing policy file\n'; return 20
  fi
  if [[ ! -f "$live" ]]; then
    printf 'fail|not a regular file\n'; return 20
  fi
  if ! relay_policy_has_marker "$live" "$relname"; then
    printf 'fail|no Antenna relay-policy identity marker (generic OpenClaw template or foreign content)\n'; return 20
  fi
  want="$(relay_policy_expected_hash "$relname" 2>/dev/null || true)"
  have="$(relay_policy_sha256 "$live" 2>/dev/null || true)"
  if [[ -z "$have" ]]; then
    printf 'fail|could not hash policy file\n'; return 20
  fi
  if [[ -n "$want" && "$want" == "$have" ]]; then
    printf 'pass|%s\n' "$have"; return 0
  fi
  printf 'warn|differs from packaged default (possible intentional customization)|%s\n' "$have"
  return 10
}

# relay_policy_require_canonical <live_path> <relname> [reason_var]
#   Fail-closed gate for the upgrade preflight. Returns 0 only when the live
#   destination release file exactly matches the package manifest. Doctor may
#   warn for intentional live customization; a pristine upgrade destination may
#   not, because truncated marker-bearing policy would become active code.
#   On failure returns non-zero and, when reason_var is given, stores a reason.
relay_policy_require_canonical() {
  local live="$1" relname="$2" __rv="${3:-}" out rc
  out="$(relay_policy_audit "$live" "$relname")"; rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi
  [[ -n "$__rv" ]] && printf -v "$__rv" '%s' "${out#*|}"
  return 1
}
