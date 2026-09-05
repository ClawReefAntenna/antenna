# lib/cli-link.sh — Ownership-safe Antenna CLI symlink handling.
#
# SOURCE, don't execute. Callers provide user-facing messages and decide
# whether a refused link is fatal. This library never follows a foreign target
# for mutation and never removes a displaced command without preserving it.

if [[ -n "${_ANTENNA_LIB_CLI_LINK_LOADED:-}" ]]; then
  return 0
fi
_ANTENNA_LIB_CLI_LINK_LOADED=1

CLI_LINK_STATE=""
CLI_LINK_TARGET=""
CLI_LINK_ACTION=""
CLI_LINK_BACKUP=""

_cli_link_normalize() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$path" 2>/dev/null
  else
    readlink -m -- "$path" 2>/dev/null
  fi
}

_cli_link_resolve_target() {
  local link="${1:-}" raw="" resolved=""
  [[ -L "$link" ]] || return 1

  # Prefer the fully resolved target when it exists, including a short chain
  # of symlinks. For a dangling link, normalize its literal destination so an
  # uninstaller can still distinguish its own exact command from a foreign one.
  if resolved="$(readlink -f -- "$link" 2>/dev/null)" && [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  raw="$(readlink -- "$link" 2>/dev/null)" || return 1
  if [[ "$raw" == /* ]]; then
    _cli_link_normalize "$raw"
  else
    _cli_link_normalize "$(dirname -- "$link")/$raw"
  fi
}

# cli_link_classify <link> <desired-target> [owned-old-target]
#
# Sets CLI_LINK_STATE to one of:
#   missing, correct, owned_old, foreign_symlink, regular_file, directory,
#   other, ambiguous
# and records a normalized symlink destination in CLI_LINK_TARGET when one is
# available. Returns 0 when classification is reliable, 2 when it is not.
cli_link_classify() {
  local link="${1:-}" desired="${2:-}" owned_old="${3:-}"
  local desired_norm="" owned_norm="" target_norm=""
  CLI_LINK_STATE=""
  CLI_LINK_TARGET=""

  desired_norm="$(_cli_link_normalize "$desired")" || {
    CLI_LINK_STATE="ambiguous"
    return 2
  }
  if [[ -n "$owned_old" ]]; then
    owned_norm="$(_cli_link_normalize "$owned_old")" || {
      CLI_LINK_STATE="ambiguous"
      return 2
    }
  fi

  if [[ -L "$link" ]]; then
    target_norm="$(_cli_link_resolve_target "$link")" || {
      CLI_LINK_STATE="ambiguous"
      return 2
    }
    CLI_LINK_TARGET="$target_norm"
    if [[ "$target_norm" == "$desired_norm" ]]; then
      CLI_LINK_STATE="correct"
    elif [[ -n "$owned_norm" && "$target_norm" == "$owned_norm" ]]; then
      CLI_LINK_STATE="owned_old"
    else
      CLI_LINK_STATE="foreign_symlink"
    fi
  elif [[ ! -e "$link" ]]; then
    CLI_LINK_STATE="missing"
  elif [[ -f "$link" ]]; then
    CLI_LINK_STATE="regular_file"
  elif [[ -d "$link" ]]; then
    CLI_LINK_STATE="directory"
  else
    CLI_LINK_STATE="other"
  fi
  return 0
}

_cli_link_replace_with_backup() {
  local link="$1" desired="$2"
  local parent base stamp backup_dir displaced
  parent="$(dirname -- "$link")"
  base="$(basename -- "$link")"
  stamp="$(date +%Y%m%d-%H%M%S)"

  backup_dir="$(mktemp -d "$parent/${base}.antenna-backup-${stamp}.XXXXXX")" || return 2
  chmod 700 "$backup_dir" || {
    rmdir -- "$backup_dir" 2>/dev/null || true
    return 2
  }
  displaced="$backup_dir/displaced"
  if ! mv -- "$link" "$displaced"; then
    rmdir -- "$backup_dir" 2>/dev/null || true
    return 2
  fi

  if ! ln -s -- "$desired" "$link"; then
    # Roll back transactionally. If an external writer raced us and occupied
    # the pathname, preserve the displaced command in the private backup and
    # report the stronger failure instead of deleting the new occupant.
    if [[ ! -e "$link" && ! -L "$link" ]] && mv -- "$displaced" "$link"; then
      rmdir -- "$backup_dir" 2>/dev/null || true
      CLI_LINK_ACTION="rolled_back"
      CLI_LINK_BACKUP=""
      return 2
    fi
    CLI_LINK_ACTION="rollback_failed"
    CLI_LINK_BACKUP="$displaced"
    return 3
  fi

  CLI_LINK_BACKUP="$displaced"
  return 0
}

# cli_link_apply <link> <desired-target> [owned-old-target] [replace-foreign]
#
# Safe default behavior:
#   - missing: install
#   - correct: no-op
#   - owned_old: repoint, preserving the old link in a private backup
#   - foreign symlink / regular file: refuse unless replace-foreign == true;
#     an explicit replacement is preserved in a private backup
#   - directory / other / ambiguous: always refuse
#
# Returns 0 on success/no-op, 10 on a policy refusal, 2 on an ordinary
# filesystem failure, and 3 if transactional rollback could not be completed.
cli_link_apply() {
  local link="${1:-}" desired="${2:-}" owned_old="${3:-}" replace_foreign="${4:-false}"
  local parent
  CLI_LINK_ACTION=""
  CLI_LINK_BACKUP=""

  [[ "$link" == /* && -n "$desired" ]] || {
    CLI_LINK_STATE="ambiguous"
    CLI_LINK_ACTION="refused"
    return 10
  }
  [[ -f "$desired" && ! -L "$desired" ]] || {
    CLI_LINK_STATE="ambiguous"
    CLI_LINK_ACTION="refused"
    return 10
  }
  parent="$(dirname -- "$link")"
  [[ -d "$parent" ]] || {
    CLI_LINK_STATE="ambiguous"
    CLI_LINK_ACTION="refused"
    return 10
  }
  cli_link_classify "$link" "$desired" "$owned_old" || {
    CLI_LINK_ACTION="refused"
    return 10
  }

  case "$CLI_LINK_STATE" in
    missing)
      if ln -s -- "$desired" "$link"; then
        CLI_LINK_ACTION="installed"
        return 0
      fi
      CLI_LINK_ACTION="failed"
      return 2
      ;;
    correct)
      CLI_LINK_ACTION="unchanged"
      return 0
      ;;
    owned_old)
      if _cli_link_replace_with_backup "$link" "$desired"; then
        CLI_LINK_ACTION="repointed"
        return 0
      else
        return $?
      fi
      ;;
    foreign_symlink|regular_file)
      if [[ "$replace_foreign" != "true" ]]; then
        CLI_LINK_ACTION="refused"
        return 10
      fi
      if _cli_link_replace_with_backup "$link" "$desired"; then
        CLI_LINK_ACTION="replaced"
        return 0
      else
        return $?
      fi
      ;;
    directory|other|ambiguous)
      CLI_LINK_ACTION="refused"
      return 10
      ;;
    *)
      CLI_LINK_STATE="ambiguous"
      CLI_LINK_ACTION="refused"
      return 10
      ;;
  esac
}

# cli_link_remove_if_owned <link> <owned-target> [dry-run]
#
# Removes only an exact Antenna-owned symlink. Foreign, regular, directory, and
# ambiguous paths are preserved. Returns 0 for removed/would-remove/missing,
# 10 when a present path is not owned, and 2 on a filesystem error.
cli_link_remove_if_owned() {
  local link="${1:-}" owned_target="${2:-}" dry_run="${3:-false}"
  CLI_LINK_ACTION=""
  CLI_LINK_BACKUP=""

  if [[ ! -e "$link" && ! -L "$link" ]]; then
    CLI_LINK_STATE="missing"
    CLI_LINK_ACTION="unchanged"
    return 0
  fi
  cli_link_classify "$link" "$owned_target" "" || {
    CLI_LINK_ACTION="preserved"
    return 10
  }
  if [[ "$CLI_LINK_STATE" != "correct" ]]; then
    CLI_LINK_ACTION="preserved"
    return 10
  fi
  if [[ "$dry_run" == "true" ]]; then
    CLI_LINK_ACTION="would_remove"
    return 0
  fi
  if rm -- "$link"; then
    CLI_LINK_ACTION="removed"
    return 0
  fi
  CLI_LINK_ACTION="failed"
  return 2
}
