# lib/change-plan.sh — Shared preview and consent for administrative changes.
#
# SOURCE, don't execute. Callers assemble a concise command-specific plan,
# display it before their first persistent mutation, then request one consent.

if [[ -n "${_ANTENNA_LIB_CHANGE_PLAN_LOADED:-}" ]]; then
  return 0
fi
_ANTENNA_LIB_CHANGE_PLAN_LOADED=1

ANTENNA_CHANGE_PLAN_TITLE=""
ANTENNA_CHANGE_PLAN_ITEMS=()

antenna_change_plan_reset() {
  ANTENNA_CHANGE_PLAN_TITLE="${1:-Antenna administrative change}"
  ANTENNA_CHANGE_PLAN_ITEMS=()
}

antenna_change_plan_add() {
  [[ -n "${1:-}" ]] || return 0
  ANTENNA_CHANGE_PLAN_ITEMS+=("$1")
}

antenna_change_plan_show() {
  local item
  printf '\n%s\n\n' "$ANTENNA_CHANGE_PLAN_TITLE"
  printf 'Planned changes:\n'
  for item in "${ANTENNA_CHANGE_PLAN_ITEMS[@]}"; do
    printf '  - %s\n' "$item"
  done
  printf '\n'
}

# antenna_change_plan_confirm <assume-yes> [prompt]
# Returns 0 when authorized, 1 when declined, and 2 when a non-interactive
# caller omitted --yes. The plan is always displayed separately by the caller.
antenna_change_plan_confirm() {
  local assume_yes="${1:-false}"
  local prompt_text="${2:-Proceed with these changes?}"
  local answer=""

  if [[ "$assume_yes" == "true" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    printf 'Refusing administrative changes without confirmation. Re-run with --yes for authorized non-interactive use.\n' >&2
    return 2
  fi

  read -rp "$prompt_text [y/N]: " answer
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}
