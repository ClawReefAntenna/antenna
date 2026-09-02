#!/usr/bin/env bash
# lib/gateway-roster.sh — Cross-version OpenClaw agent-roster helpers.
#
# OpenClaw through 2026.7.x persists agents.list. OpenClaw 2026.8.1+
# persists agents.entries. Mutating callers must preserve the host's native
# generation and must never create both shapes.

if [[ -n "${_ANTENNA_GATEWAY_ROSTER_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_ANTENNA_GATEWAY_ROSTER_SH_LOADED=1

GATEWAY_ROSTER_KIND=""
GATEWAY_OPENCLAW_VERSION=""
GATEWAY_OPENCLAW_GENERATION=""
GATEWAY_CONFIG_LAST_BACKUP=""

gateway_roster_error() {
  printf 'antenna: gateway roster: %s\n' "$*" >&2
}

gateway_openclaw_generation() {
  GATEWAY_OPENCLAW_GENERATION=""
  command -v openclaw >/dev/null 2>&1 || {
    gateway_roster_error "openclaw is required to identify and validate the gateway config generation"
    return 1
  }

  local raw year month patch
  raw="$(openclaw --version 2>/dev/null || true)"
  if [[ ! "$raw" =~ ([0-9]{4})\.([0-9]+)\.([0-9]+) ]]; then
    gateway_roster_error "could not parse the installed OpenClaw version"
    return 1
  fi
  year="${BASH_REMATCH[1]}"
  month="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  GATEWAY_OPENCLAW_VERSION="${year}.${month}.${patch}"

  if (( 10#$year > 2026 )) \
    || (( 10#$year == 2026 && 10#$month > 8 )) \
    || (( 10#$year == 2026 && 10#$month == 8 && 10#$patch >= 1 )); then
    GATEWAY_OPENCLAW_GENERATION="entries"
  else
    GATEWAY_OPENCLAW_GENERATION="list"
  fi
}

gateway_roster_has_unsafe_include() {
  local file="$1"
  jq -e '
    (type == "object") and (
      has("$include")
      or (
        (.agents? | type) == "object" and (
          (.agents | has("$include"))
          or (
            (.agents.entries? | type) == "object" and (
              (.agents.entries | has("$include"))
              or any(.agents.entries | to_entries[];
                ((.value | type) == "object") and (
                  (.value | has("$include"))
                  or (((.value.default? | type) == "object") and (.value.default | has("$include")))
                )
              )
            )
          )
          or (
            (.agents.list? | type) == "array" and any(.agents.list[];
              ((. | type) == "object") and (
                has("$include")
                or (((.id? | type) == "object") and (.id | has("$include")))
                or (((.default? | type) == "object") and (.default | has("$include")))
              )
            )
          )
        )
      )
    )
  ' "$file" >/dev/null 2>&1
}

gateway_roster_validate_ids() {
  local file="$1" kind="$2"
  case "$kind" in
    list)
      jq -e '
        def valid_id:
          (type == "string") and test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$");
        (.agents.list | type) == "array"
        and all(.agents.list[]; (type == "object") and (.id | valid_id))
        and (([.agents.list[].id | ascii_downcase] | length)
          == ([.agents.list[].id | ascii_downcase] | unique | length))
      ' "$file" >/dev/null 2>&1
      ;;
    entries)
      jq -e '
        def valid_id:
          (type == "string") and test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$");
        (.agents.entries | type) == "object"
        and all(.agents.entries | to_entries[];
          (.key | valid_id) and ((.value | type) == "object"))
        and (([.agents.entries | keys[] | ascii_downcase] | length)
          == ([.agents.entries | keys[] | ascii_downcase] | unique | length))
      ' "$file" >/dev/null 2>&1
      ;;
    absent) return 0 ;;
    *) return 1 ;;
  esac
}

gateway_config_validate_with_openclaw() {
  local file="$1"
  command -v openclaw >/dev/null 2>&1 || {
    gateway_roster_error "openclaw is required to validate gateway config changes"
    return 1
  }
  if ! OPENCLAW_CONFIG_PATH="$file" openclaw config validate >/dev/null 2>&1; then
    gateway_roster_error "OpenClaw rejected the gateway config: $file"
    return 1
  fi
}

# gateway_roster_prepare_mutation <gateway-file>
# Validates the authored config and exports GATEWAY_ROSTER_KIND=list|entries.
gateway_roster_prepare_mutation() {
  local file="$1" has_list has_entries detected_generation
  GATEWAY_ROSTER_KIND=""

  [[ -f "$file" && ! -L "$file" ]] || {
    gateway_roster_error "gateway config must be a regular, non-symlink file: $file"
    return 1
  }
  jq empty "$file" >/dev/null 2>&1 || {
    gateway_roster_error "gateway config is not valid JSON: $file"
    return 1
  }
  jq -e '(.agents == null) or ((.agents | type) == "object")' "$file" >/dev/null 2>&1 || {
    gateway_roster_error ".agents must be an object"
    return 1
  }
  if gateway_roster_has_unsafe_include "$file"; then
    gateway_roster_error "the agent roster may be owned by \$include; edit the owning file or use an OpenClaw-native roster command"
    return 1
  fi

  has_list="$(jq -r '((.agents? | type) == "object") and (.agents | has("list"))' "$file")"
  has_entries="$(jq -r '((.agents? | type) == "object") and (.agents | has("entries"))' "$file")"
  if [[ "$has_list" == "true" && "$has_entries" == "true" ]]; then
    gateway_roster_error "gateway config contains both agents.list and agents.entries"
    return 1
  elif [[ "$has_list" == "true" ]]; then
    GATEWAY_ROSTER_KIND="list"
  elif [[ "$has_entries" == "true" ]]; then
    GATEWAY_ROSTER_KIND="entries"
  else
    GATEWAY_ROSTER_KIND="absent"
  fi

  gateway_roster_validate_ids "$file" "$GATEWAY_ROSTER_KIND" || {
    gateway_roster_error "the authored $GATEWAY_ROSTER_KIND roster is malformed or contains duplicate/invalid agent IDs"
    return 1
  }

  gateway_openclaw_generation || return 1
  detected_generation="$GATEWAY_OPENCLAW_GENERATION"
  if [[ "$GATEWAY_ROSTER_KIND" == "list" && "$detected_generation" != "list" ]]; then
    gateway_roster_error "OpenClaw $GATEWAY_OPENCLAW_VERSION uses agents.entries but this config still has agents.list; run 'openclaw doctor --fix' first"
    return 1
  fi
  if [[ "$GATEWAY_ROSTER_KIND" == "entries" && "$detected_generation" != "entries" ]]; then
    gateway_roster_error "OpenClaw $GATEWAY_OPENCLAW_VERSION does not support canonical agents.entries writes"
    return 1
  fi
  if [[ "$GATEWAY_ROSTER_KIND" == "absent" ]]; then
    GATEWAY_ROSTER_KIND="$detected_generation"
  fi

  gateway_config_validate_with_openclaw "$file"
}

gateway_roster_has_agent() {
  local file="$1" id="${2,,}" kind="${3:-$GATEWAY_ROSTER_KIND}"
  case "$kind" in
    list)
      jq -e --arg id "$id" 'any(.agents.list[]?; ((.id // "") | ascii_downcase) == $id)' "$file" >/dev/null 2>&1
      ;;
    entries)
      jq -e --arg id "$id" 'any(.agents.entries | keys[]?; ascii_downcase == $id)' "$file" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

gateway_roster_write_setup_candidate() {
  local source="$1" destination="$2" primary_id="$3" model="$4" workspace_dir="$5" state_root="$6"
  [[ "$primary_id" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$ ]] || {
    gateway_roster_error "invalid primary agent ID: $primary_id"
    return 1
  }
  [[ "${primary_id,,}" != "antenna" ]] || {
    gateway_roster_error "the primary agent ID cannot be 'antenna'"
    return 1
  }
  gateway_roster_prepare_mutation "$source" || return 1

  case "$GATEWAY_ROSTER_KIND" in
    list)
      jq --arg primary "$primary_id" --arg model "$model" --arg workspace "$workspace_dir" --arg state_root "$state_root" '
        .agents = (if (.agents | type) == "object" then .agents else {} end)
        | if ((.agents.list // []) | length) == 0 then
            .agents.list = [{
              id: $primary,
              name: "Main Agent",
              model: (.agents.defaults.model.primary // "openai/gpt-4o-mini"),
              agentDir: ($state_root + "/agents/" + $primary + "/agent"),
              workspace: (.agents.defaults.workspace // "~/clawd")
            }]
          else . end
        | if any(.agents.list[]; ((.id // "") | ascii_downcase) == "antenna") then .
          else .agents.list += [{
            id: "antenna", name: "Antenna Relay", model: $model,
            agentDir: ($state_root + "/agents/antenna/agent"), workspace: $workspace,
            sandbox: {mode: "off"},
            tools: {deny: [
              "group:web", "browser", "image", "image_generate",
              "cron", "memory_search", "memory_get", "web_search", "web_fetch"
            ]}
          }] end
        | .agents.list = [.agents.list[] |
            if ((.id // "") | ascii_downcase) == "antenna" then
              .sandbox = (if (.sandbox | type) == "object" then .sandbox else {} end)
              | .sandbox.mode = "off"
              | .tools = (if (.tools | type) == "object" then .tools else {} end)
              | .tools.deny = (.tools.deny // [
                  "group:web", "browser", "image", "image_generate",
                  "cron", "memory_search", "memory_get", "web_search", "web_fetch"
                ])
            else . end
          ]
      ' "$source" > "$destination"
      ;;
    entries)
      jq --arg primary "$primary_id" --arg model "$model" --arg workspace "$workspace_dir" --arg state_root "$state_root" '
        .agents = (if (.agents | type) == "object" then .agents else {} end)
        | if ((.agents.entries // {}) | length) == 0 then
            .agents.ownership = "explicit"
            | .agents.defaults = (if (.agents.defaults | type) == "object" then .agents.defaults else {} end)
            | .agents.defaults.systemAgent = (if (.agents.defaults.systemAgent | type) == "object" then .agents.defaults.systemAgent else {} end)
            | .agents.defaults.systemAgent.agentId = $primary
            | if $primary != "main" then
                .agents.defaults.authInheritance = (if (.agents.defaults.authInheritance | type) == "object" then .agents.defaults.authInheritance else {} end)
                | .agents.defaults.authInheritance.agentId = (.agents.defaults.authInheritance.agentId // $primary)
              else . end
            | .agents.entries = {
                ($primary): {
                  name: "Main Agent",
                  model: (.agents.defaults.model.primary // "openai/gpt-4o-mini"),
                  agentDir: ($state_root + "/agents/" + $primary + "/agent"),
                  workspace: (.agents.defaults.workspace // "~/clawd")
                }
              }
          else . end
        | if any(.agents.entries | keys[]; ascii_downcase == "antenna") then .
          else
            (.agents.entries | keys) as $prior_ids
            | if (($prior_ids | length) == 1
                  and .agents.ownership != "explicit"
                  and ([.agents.entries[] | select(.default == true)] | length) == 0) then
                $prior_ids[0] as $owner
                | .agents.ownership = "explicit"
                | .agents.defaults = (if (.agents.defaults | type) == "object" then .agents.defaults else {} end)
                | .agents.defaults.systemAgent = (if (.agents.defaults.systemAgent | type) == "object" then .agents.defaults.systemAgent else {} end)
                | .agents.defaults.systemAgent.agentId = (.agents.defaults.systemAgent.agentId // $owner)
                | if $owner != "main" then
                    .agents.defaults.authInheritance = (if (.agents.defaults.authInheritance | type) == "object" then .agents.defaults.authInheritance else {} end)
                    | .agents.defaults.authInheritance.agentId = (.agents.defaults.authInheritance.agentId // $owner)
                  else . end
              else . end
            | .agents.entries.antenna = {
                name: "Antenna Relay", model: $model,
                agentDir: ($state_root + "/agents/antenna/agent"), workspace: $workspace,
                sandbox: {mode: "off"},
                tools: {deny: [
                  "group:web", "browser", "image", "image_generate",
                  "cron", "memory_search", "memory_get", "web_search", "web_fetch"
                ]}
              }
          end
        | (.agents.entries | keys[] | select(ascii_downcase == "antenna")) as $antenna_key
        | .agents.entries[$antenna_key].agentDir = ($state_root + "/agents/antenna/agent")
        | .agents.entries[$antenna_key].workspace = $workspace
        | .agents.entries[$antenna_key].sandbox =
            (if (.agents.entries[$antenna_key].sandbox | type) == "object"
             then .agents.entries[$antenna_key].sandbox else {} end)
        | .agents.entries[$antenna_key].sandbox.mode = "off"
        | .agents.entries[$antenna_key].tools =
            (if (.agents.entries[$antenna_key].tools | type) == "object"
             then .agents.entries[$antenna_key].tools else {} end)
        | .agents.entries[$antenna_key].tools.deny =
            (.agents.entries[$antenna_key].tools.deny // [
              "group:web", "browser", "image", "image_generate",
              "cron", "memory_search", "memory_get", "web_search", "web_fetch"
            ])
      ' "$source" > "$destination"
      ;;
    *) return 1 ;;
  esac
}

gateway_roster_write_agent_paths_candidate() {
  local source="$1" destination="$2" workspace_dir="$3" state_root="$4"
  gateway_roster_prepare_mutation "$source" || return 1
  gateway_roster_has_agent "$source" antenna "$GATEWAY_ROSTER_KIND" || {
    gateway_roster_error "gateway config has no existing Antenna agent"
    return 1
  }
  case "$GATEWAY_ROSTER_KIND" in
    list)
      jq --arg workspace "$workspace_dir" --arg state_root "$state_root" '
        .agents.list = [.agents.list[] |
          if ((.id // "") | ascii_downcase) == "antenna"
          then .agentDir = ($state_root + "/agents/antenna/agent") | .workspace = $workspace else . end]
      ' "$source" > "$destination"
      ;;
    entries)
      jq --arg workspace "$workspace_dir" --arg state_root "$state_root" '
        (.agents.entries | keys[] | select(ascii_downcase == "antenna")) as $key
        | .agents.entries[$key].agentDir = ($state_root + "/agents/antenna/agent")
        | .agents.entries[$key].workspace = $workspace
      ' "$source" > "$destination"
      ;;
  esac
}

gateway_roster_write_model_candidate() {
  local source="$1" destination="$2" model="$3"
  gateway_roster_prepare_mutation "$source" || return 1
  gateway_roster_has_agent "$source" antenna "$GATEWAY_ROSTER_KIND" || {
    gateway_roster_error "gateway config has no existing Antenna agent"
    return 1
  }
  case "$GATEWAY_ROSTER_KIND" in
    list)
      jq --arg model "$model" '
        .agents.list = [.agents.list[] |
          if ((.id // "") | ascii_downcase) == "antenna" then .model = $model else . end]
      ' "$source" > "$destination"
      ;;
    entries)
      jq --arg model "$model" '
        (.agents.entries | keys[] | select(ascii_downcase == "antenna")) as $key
        | .agents.entries[$key].model = $model
      ' "$source" > "$destination"
      ;;
  esac
}

gateway_config_commit_candidate() {
  local original="$1" candidate="$2" backup_label="${3:-antenna-backup}"
  local backup
  gateway_roster_prepare_mutation "$candidate" || return 1
  backup="$(mktemp "${original}.${backup_label}.XXXXXX")" || return 1
  if ! cp -- "$original" "$backup"; then
    rm -f -- "$backup"
    return 1
  fi
  chmod 600 "$backup" 2>/dev/null || true
  chmod --reference="$original" "$candidate" 2>/dev/null || true
  chown --reference="$original" "$candidate" 2>/dev/null || true
  if ! mv -- "$candidate" "$original"; then
    rm -f -- "$backup"
    return 1
  fi
  GATEWAY_CONFIG_LAST_BACKUP="$backup"
}
