# lib/secret-file.sh — Private on-disk generation for reusable Antenna secrets.
#
# SOURCE, don't execute. Secret values are written directly to a private file;
# callers receive only success/failure and must not capture the value in a shell
# variable or print it during ordinary operation.

if [[ -n "${_ANTENNA_LIB_SECRET_FILE_LOADED:-}" ]]; then
  return 0
fi
_ANTENNA_LIB_SECRET_FILE_LOADED=1

# antenna_secret_peer_id_ok <peer-id>
#   Restrict peer IDs used in secret filenames to one safe path component.
antenna_secret_peer_id_ok() {
  local peer_id="${1:-}"
  [[ "$peer_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# antenna_secret_generate_hex_file <absolute-path>
#   Atomically writes a fresh 256-bit lowercase-hex secret. The containing
#   directory is mode 0700 and the final file is mode 0600. Existing files are
#   replaced atomically, preserving the historical generate-secret behavior.
antenna_secret_generate_hex_file() (
  set -o pipefail
  umask 077

  local destination="${1:-}" directory scratch=""
  [[ -n "$destination" && "$destination" == /* ]] || {
    echo "secret destination must be an absolute path" >&2
    return 1
  }
  command -v openssl >/dev/null 2>&1 || {
    echo "openssl not found — required for secret generation" >&2
    return 1
  }

  directory="$(dirname -- "$destination")"
  install -d -m 700 -- "$directory" || return 1
  scratch="$(mktemp "$directory/.antenna-secret.XXXXXX")" || return 1
  cleanup_antenna_secret_scratch() {
    [[ -z "$scratch" ]] || rm -f -- "$scratch"
  }
  trap cleanup_antenna_secret_scratch EXIT HUP INT TERM

  chmod 600 -- "$scratch" || return 1
  openssl rand -hex 32 >"$scratch" || return 1
  [[ "$(tr -d '[:space:]' <"$scratch")" =~ ^[0-9a-f]{64}$ ]] || {
    echo "openssl returned an invalid secret" >&2
    return 1
  }

  # -T makes the destination an exact filename. Without it, an unexpected
  # directory at that path would receive the temp file as a child.
  mv -fT -- "$scratch" "$destination" || return 1
  scratch=""
  [[ -f "$destination" && ! -L "$destination" ]] || return 1
  chmod 600 -- "$destination"
)
