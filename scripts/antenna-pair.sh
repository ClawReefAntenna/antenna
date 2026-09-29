#!/usr/bin/env bash
# Retired legacy operation in an explicitly migrated installation.
_antenna_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$_antenna_root/antenna-config.json" ]] && jq -e 'has("transport_profile")' "$_antenna_root/antenna-config.json" >/dev/null 2>&1; then
  echo 'Legacy operation disabled: use the plugin operator commands and migration runbook.' >&2
  exit 1
fi
unset _antenna_root
# antenna-pair.sh — Interactive pairing wizard for connecting to a remote peer.
# Can be launched standalone (antenna pair) or auto-offered at end of setup.
#
# Usage:
#   antenna-pair.sh                    Interactive wizard
#   antenna-pair.sh --peer-id <id>     Pre-fill peer ID (still interactive)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$SKILL_DIR/bin"
ANTENNA="$BIN_DIR/antenna.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

info()   { echo -e "${CYAN}ℹ${NC}  $*"; }
ok()     { echo -e "${GREEN}✓${NC}  $*"; }
warn()   { echo -e "${YELLOW}⚠${NC}  $*"; }
err()    { echo -e "${RED}✗${NC}  $*" >&2; }
header() { echo -e "\n${BOLD}═══ $* ═══${NC}\n"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt_value() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "  ${CYAN}?${NC}  ${prompt_text} [${default}]: ")" value
    value="${value:-$default}"
  else
    read -rp "$(echo -e "  ${CYAN}?${NC}  ${prompt_text}: ")" value
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_yn() {
  local prompt_text="$1" default="${2:-n}" yn
  read -rp "$(echo -e "  ${CYAN}?${NC}  ${prompt_text} [${default}]: ")" yn
  yn="${yn:-$default}"
  [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
}

wait_for_enter() {
  local msg="${1:-Press Enter when ready}" _discard
  read -rp "$(echo -e "  ${CYAN}▸${NC} ${msg}... ")" _discard
}

wizard_prompt() {
  local step_num="$1" total="$2" label="$3" can_skip="${4:-true}"
  echo ""
  echo -e "  ${DIM}Step ${step_num}/${total}${NC}  ${BOLD}${label}${NC}"
  echo ""
  if [[ "$can_skip" == "true" ]]; then
    local choice
    read -rp "$(echo -e "  ${CYAN}▸${NC} [${BOLD}N${NC}]ext  [${BOLD}S${NC}]kip  [${BOLD}Q${NC}]uit: ")" choice
    case "${choice,,}" in
      n|next|"") return 0 ;;
      s|skip)    return 1 ;;
      q|quit)
        echo ""
        info "No worries — pick up where you left off anytime:  ${BOLD}antenna pair${NC}"
        exit 0
        ;;
      *) return 0 ;;
    esac
  else
    local choice
    read -rp "$(echo -e "  ${CYAN}▸${NC} [${BOLD}N${NC}]ext  [${BOLD}Q${NC}]uit: ")" choice
    case "${choice,,}" in
      q|quit)
        echo ""
        info "No worries — pick up where you left off anytime:  ${BOLD}antenna pair${NC}"
        exit 0
        ;;
      *) return 0 ;;
    esac
  fi
}

prompt_limited_value() {
  local var_name="$1" prompt_text="$2" max_len="$3" default="${4:-}"
  local limited_value="" len
  while true; do
    prompt_value limited_value "$prompt_text" "$default"
    len=${#limited_value}
    if (( len < max_len )); then
      printf -v "$var_name" '%s' "$limited_value"
      return 0
    fi
    err "${prompt_text} must be fewer than ${max_len} characters (got ${len})."
  done
}

ensure_email_tool() {
  if have_cmd gog || have_cmd himalaya; then
    return 0
  fi
  err "Email pairing needs gog or himalaya installed/configured."
  echo ""
  info "Use ClawReef or Manual pairing for now, or install/configure one of those mail tools."
  return 1
}

himalaya_config_path() {
  if [[ -n "${HIMALAYA_CONFIG:-}" && -f "${HIMALAYA_CONFIG}" ]]; then
    printf '%s\n' "$HIMALAYA_CONFIG"
    return 0
  fi
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/himalaya/config.toml"
  [[ -f "$cfg" ]] && printf '%s\n' "$cfg"
}

himalaya_accounts_list() {
  local cfg
  cfg="$(himalaya_config_path)"
  [[ -n "$cfg" ]] || return 0
  awk '
    /^\[accounts\.[^]]+\]/ {
      name=$0
      sub(/^\[accounts\./, "", name)
      sub(/\]$/, "", name)
      print name
    }
  ' "$cfg"
}

choose_mail_account() {
  local selected_var="$1"
  printf -v "$selected_var" '%s' ""
  have_cmd himalaya || return 0

  local accounts=()
  while IFS= read -r account; do
    [[ -n "$account" ]] && accounts+=("$account")
  done < <(himalaya_accounts_list)

  [[ ${#accounts[@]} -gt 0 ]] || return 0

  echo ""
  echo -e "  ${BOLD}Mail account${NC}"
  echo -e "    0) Use default mail tool/account"
  local i
  for i in "${!accounts[@]}"; do
    echo -e "    $((i + 1))) ${accounts[$i]}"
  done

  local choice
  while true; do
    prompt_value choice "Send from which account?" "0"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= ${#accounts[@]} )); then
      if (( choice > 0 )); then
        printf -v "$selected_var" '%s' "${accounts[$((choice - 1))]}"
      fi
      return 0
    fi
    warn "Choose a number from the list."
  done
}

show_email_preview() {
  local to="$1" account="$2" cc_self="$3" subject="$4" body="$5" attachment="${6:-}"
  echo ""
  echo -e "  ${BOLD}Email preview${NC}"
  echo -e "  ${DIM}From:${NC}    ${account:-default configured mail account}"
  echo -e "  ${DIM}To:${NC}      ${to}"
  if [[ "$cc_self" == "true" ]]; then
    echo -e "  ${DIM}Cc:${NC}      resolved sender address"
  fi
  echo -e "  ${DIM}Subject:${NC} ${subject}"
  echo -e "  ${DIM}Body:${NC}"
  sed 's/^/    /' <<<"$body"
  if [[ -n "$attachment" ]]; then
    echo -e "  ${DIM}Attachment:${NC} ${attachment}"
  fi
  echo ""
}

extract_bundle_file() {
  grep -oE 'Bundle file: .*$' | sed 's/^Bundle file: //'
}

open_clawreef_invites() {
  if have_cmd xdg-open; then
    xdg-open "https://clawreef.io/registry/dashboard/invites" 2>/dev/null &
  elif have_cmd open; then
    open "https://clawreef.io/registry/dashboard/invites" 2>/dev/null &
  else
    echo -e "  ${CYAN}→${NC} https://clawreef.io/registry/dashboard/invites"
  fi
}

build_email_args() {
  local -n _args_ref="$1"
  local email="$2" account="$3" subject="$4" message="$5" cc_self="$6"
  _args_ref+=(--email "$email" --subject "$subject" --message "$message" --send-email)
  [[ -n "$account" ]] && _args_ref+=(--account "$account")
  if [[ "$cc_self" == "true" ]]; then
    _args_ref+=(--cc-self)
  fi
}

import_reply_bundle() {
  local import_file
  prompt_value import_file "Path to the reply bundle you received" ""
  import_file="${import_file/#\~/$HOME}"
  if [[ -z "$import_file" ]]; then
    err "No file path provided."
  elif [[ ! -f "$import_file" ]]; then
    err "Can't find that file: $import_file — double-check the path?"
  else
    echo ""
    bash "$ANTENNA" peers exchange import "$import_file" || true
    echo ""
  fi
}

test_connection() {
  if [[ -z "${PEER_ID:-}" ]]; then
    prompt_value PEER_ID "Peer ID to test"
  fi
  if [[ -n "${PEER_ID:-}" ]]; then
    info "Pinging ${BOLD}${PEER_ID}${NC} — let's see if anyone's home..."
    echo ""
    bash "$ANTENNA" peers test "$PEER_ID" || true
    echo ""
  else
    err "No peer ID provided."
  fi
}

send_first_message() {
  if [[ -z "${PEER_ID:-}" ]]; then
    prompt_value PEER_ID "Peer ID to message"
  fi
  if [[ -n "${PEER_ID:-}" ]]; then
    local first_msg
    prompt_value first_msg "Message to send" "Hello from the other side of the reef! 🦞"
    echo ""
    info "Releasing the lobster to ${BOLD}${PEER_ID}${NC}... 🦞"
    echo ""
    bash "$ANTENNA" msg "$PEER_ID" "$first_msg" || true
    echo ""
  else
    err "No peer ID provided."
  fi
}

finish_cheat_sheet() {
  header "🦞 You're Claw-nected!"
  echo -e "  Welcome to the reef. Here's your cheat sheet:"
  echo ""
  echo -e "  ${BOLD}Send a message:${NC}     antenna msg ${PEER_ID:-<peer>} \"Your message\""
  echo -e "  ${BOLD}Target a session:${NC}   antenna msg ${PEER_ID:-<peer>} --session agent:main:test \"Hi\""
  echo -e "  ${BOLD}Check status:${NC}       antenna peers test ${PEER_ID:-<peer>}"
  echo -e "  ${BOLD}List peers:${NC}         antenna peers list"
  echo -e "  ${BOLD}Run diagnostics:${NC}    antenna doctor"
  echo ""
  ok "Happy messaging! The ocean just got smaller. 🦞 📡"
  echo ""
}

# ── Parse args ───────────────────────────────────────────────────────────────

PEER_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer-id) PEER_ID="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: antenna pair [--peer-id <id>]"
      echo "  Interactive wizard for pairing with a remote Antenna peer."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Pairing branches ─────────────────────────────────────────────────────────

run_clawreef_pairing() {
  header "ClawReef.io Invite"

  echo -e "  If your peer is on ${BOLD}clawreef.io${NC}, you can send them an invite"
  echo -e "  through the registry instead of exchanging bundles manually."
  echo ""
  echo -e "  ${BOLD}How it works:${NC}"
  echo -e "    1. Log in at ${CYAN}https://clawreef.io${NC}"
  echo -e "    2. Go to ${BOLD}Invites${NC} → search for your peer by name"
  echo -e "    3. Send the invite — ClawReef delivers it via Antenna"
  echo -e "    4. When they accept, you both finish pairing locally"
  echo ""

  if prompt_yn "Open clawreef.io/registry/dashboard/invites in your browser?" "n"; then
    open_clawreef_invites
  else
    echo -e "  ${CYAN}→${NC} https://clawreef.io/registry/dashboard/invites"
  fi

  echo ""
  wait_for_enter "Press Enter once you've sent your invite, or to return later"
  echo ""
  info "If the invite completes pairing, test it with:  ${BOLD}antenna peers test <peer>${NC}"
}

run_email_pubkey_request() {
  local recipient_email="$1" account="$2"
  local subject message cc_self=false pubkey body_text send_args=()

  bash "$ANTENNA" peers exchange keygen >/dev/null

  prompt_limited_value subject "Subject (< 50 characters)" 50 "Antenna Pairing Invite PubKey Request"
  prompt_limited_value message "Any message to include (< 100 characters)" 100 ""
  if prompt_yn "CC yourself for confirmation?" "n"; then
    cc_self=true
  fi

  pubkey="$(bash "$ANTENNA" peers exchange pubkey --bare 2>/dev/null || true)"
  body_text="${message:+$message\n\n}Antenna exchange public key:\n\n${pubkey}\n\nWhen you reply with your public key, I can send the encrypted exchange bundle."

  show_email_preview "$recipient_email" "$account" "$cc_self" "$subject" "$(printf '%b' "$body_text")" "<self>.agepub"

  if ! prompt_yn "Send this email?" "n"; then
    info "Email not sent. Your public key is:"
    echo ""
    echo -e "  ${GREEN}${pubkey}${NC}"
    return 0
  fi

  send_args=(peers exchange pubkey)
  build_email_args send_args "$recipient_email" "$account" "$subject" "$message" "$cc_self"

  echo ""
  set +e
  local email_output email_exit
  email_output=$(bash "$ANTENNA" "${send_args[@]}" 2>&1)
  email_exit=$?
  set -e
  echo "$email_output"

  if [[ $email_exit -eq 0 ]]; then
    ok "Public-key request sent."
    echo ""
    info "When they reply with their public key, run ${BOLD}antenna pair${NC} again and choose Email → I already have their public key."
  else
    err "Email delivery failed — public-key request was NOT sent."
    echo ""
    info "Share this public key manually if needed:"
    echo -e "  ${GREEN}${pubkey}${NC}"
  fi
}

run_email_bundle_invite() {
  local recipient_email="$1" account="$2"
  local subject message cc_self=false peer_pubkey bundle_output bundle_file body_text
  local bundle_args=() email_args=()

  if [[ -z "$PEER_ID" ]]; then
    prompt_value PEER_ID "Peer ID (a short name for the remote host, e.g. 'myserver')" ""
  else
    echo -e "  ${CYAN}ℹ${NC}  Peer ID: ${BOLD}${PEER_ID}${NC}"
  fi
  [[ -n "$PEER_ID" ]] || { err "Need a peer ID to build the bundle."; return 1; }

  prompt_value peer_pubkey "Recipient PubKey (starts with age1...)" ""
  [[ -n "$peer_pubkey" ]] || { err "Can't build a bundle without their public key."; return 1; }

  prompt_limited_value subject "Subject (< 50 characters)" 50 "Antenna Pairing Invite Exchange Bundle"
  prompt_limited_value message "Any message to include (< 100 characters)" 100 ""
  if prompt_yn "CC yourself for confirmation?" "n"; then
    cc_self=true
  fi

  echo ""
  info "Building your encrypted bootstrap bundle..."
  echo ""
  set +e
  bundle_output=$(bash "$ANTENNA" peers exchange initiate "$PEER_ID" --pubkey "$peer_pubkey" 2>&1)
  local bundle_exit=$?
  set -e
  echo "$bundle_output"
  [[ $bundle_exit -eq 0 ]] || return "$bundle_exit"

  bundle_file="$(printf '%s\n' "$bundle_output" | extract_bundle_file)"
  [[ -n "$bundle_file" ]] || { err "Could not determine bundle path from exchange output."; return 1; }

  body_text="${message:+$message\n\n}Encrypted Antenna pairing exchange bundle attached. Import the attached .age.txt file directly; do not copy-paste the bundle text."
  show_email_preview "$recipient_email" "$account" "$cc_self" "$subject" "$(printf '%b' "$body_text")" "$bundle_file"

  if ! prompt_yn "Send this email?" "n"; then
    info "Email not sent. Transfer this bundle manually:"
    echo -e "  ${CYAN}${bundle_file}${NC}"
    return 0
  fi

  email_args=(peers exchange initiate "$PEER_ID" --pubkey "$peer_pubkey" --output "$bundle_file")
  build_email_args email_args "$recipient_email" "$account" "$subject" "$message" "$cc_self"

  echo ""
  info "Sending encrypted bundle email..."
  echo ""

  BUNDLE_EMAIL_ATTEMPTED="y"
  BUNDLE_EMAIL_DELIVERED="n"
  set +e
  EMAIL_OUTPUT=$(bash "$ANTENNA" "${email_args[@]}" 2>&1)
  EMAIL_EXIT=$?
  set -e
  echo "$EMAIL_OUTPUT"
  if [[ $EMAIL_EXIT -eq 0 ]]; then
    BUNDLE_EMAIL_DELIVERED="y"
  fi

  if [[ "${BUNDLE_EMAIL_ATTEMPTED:-n}" == "y" && "${BUNDLE_EMAIL_DELIVERED:-n}" == "y" ]]; then
    ok "Bundle emailed. Waiting for your peer to import it and reply."
    echo ""
    if prompt_yn "Wait now and import their reply bundle?" "n"; then
      import_reply_bundle
      test_connection
      if prompt_yn "Send a first message?" "n"; then
        send_first_message
      fi
    else
      info "When their reply arrives, run ${BOLD}antenna pair${NC} again and choose Manual to import/test, or run:"
      echo -e "  ${DIM}antenna peers exchange import <reply-bundle>${NC}"
    fi
  elif [[ "${BUNDLE_EMAIL_ATTEMPTED:-n}" == "y" ]]; then
    err "Email delivery failed — bundle was NOT sent."
    echo -e "  ${DIM}Transfer this file manually (scp, USB, encrypted drop):${NC}"
    echo -e "  ${CYAN}${bundle_file}${NC}"
    echo ""
    prompt_value BUNDLE_DELIVERED_MANUALLY "Did you deliver it out of band? (y/N)" "n"
    if [[ "${BUNDLE_DELIVERED_MANUALLY,,}" != "y" && "${BUNDLE_DELIVERED_MANUALLY,,}" != "yes" ]]; then
      warn "Holding here. Re-run the wizard after you've delivered the bundle, or rerun with the bundle file path."
      exit 0
    fi
  fi
}

run_email_pairing() {
  local recipient_email account="" email_choice

  header "Email Pairing"

  if ! ensure_email_tool; then
    return 2
  fi

  prompt_value recipient_email "What email should I send to?" ""
  [[ -n "$recipient_email" ]] || { err "Need a recipient email address."; return 1; }

  choose_mail_account account

  echo ""
  echo -e "  ${BOLD}Choose from the following:${NC}"
  echo -e "    a) Enter recipient PubKey"
  echo -e "    b) Send PubKey Request Email"
  echo -e "    c) Quit"
  echo ""

  prompt_value email_choice "Choice" "a"
  case "${email_choice,,}" in
    a|1)
      run_email_bundle_invite "$recipient_email" "$account"
      ;;
    b|2)
      run_email_pubkey_request "$recipient_email" "$account"
      ;;
    c|q|quit)
      info "No changes made."
      ;;
    *)
      warn "Unknown choice."
      ;;
  esac
}

run_manual_pairing() {
  local total_steps=7

  header "Manual Pairing"

  echo -e "  This is the direct exchange flow: public keys, encrypted bundles,"
  echo -e "  reply bundle, import, test, then first message."
  echo ""

  if wizard_prompt 1 $total_steps "Generate your exchange keypair"; then
    local exchange_key_dir="$SKILL_DIR/secrets"
    if [[ -f "$exchange_key_dir/antenna-exchange.agekey" ]]; then
      warn "You've already got a keypair — no need to generate a new one unless you want a fresh start."
      if prompt_yn "Regenerate?" "n"; then
        bash "$ANTENNA" peers exchange keygen --force
      else
        ok "Keeping existing keypair."
      fi
    else
      bash "$ANTENNA" peers exchange keygen
    fi
  fi

  if wizard_prompt 2 $total_steps "Share your public key" false; then
    echo ""
    echo -e "  Here's your public key — share it with your peer."
    echo -e "  It's safe to post openly; it's a lock, not a key."
    echo ""
    local pubkey
    pubkey=$(bash "$ANTENNA" peers exchange pubkey --bare 2>/dev/null || echo "")
    if [[ -n "$pubkey" ]]; then
      echo -e "  ${GREEN}${pubkey}${NC}"
      echo ""
      info "Your peer needs this to encrypt a bootstrap bundle that only you can open."
    else
      err "No public key found — run: antenna peers exchange keygen"
    fi
    echo ""
    wait_for_enter "Press Enter once your peer has your key"
  fi

  if wizard_prompt 3 $total_steps "Build a bootstrap bundle for your peer"; then
    echo ""
    if [[ -z "$PEER_ID" ]]; then
      prompt_value PEER_ID "Peer ID (a short name for the remote host, e.g. 'myserver')" ""
    else
      echo -e "  ${CYAN}ℹ${NC}  Peer ID: ${BOLD}${PEER_ID}${NC}"
    fi

    if [[ -z "$PEER_ID" ]]; then
      err "Need a peer ID to continue — what do you call the other host?"
    else
      local peer_pubkey bundle_output bundle_file
      prompt_value peer_pubkey "Their age public key (starts with age1...)" ""
      if [[ -z "$peer_pubkey" ]]; then
        err "Can't build a bundle without their public key — ask your peer for it."
      else
        echo ""
        info "Building your encrypted bootstrap bundle..."
        echo ""
        bundle_output=$(bash "$ANTENNA" peers exchange initiate "$PEER_ID" --pubkey "$peer_pubkey" 2>&1) || true
        echo "$bundle_output"

        bundle_file=$(printf '%s\n' "$bundle_output" | extract_bundle_file || echo "")
        if [[ -n "$bundle_file" ]]; then
          echo ""
          ok "Bundle created!"
          echo ""
          echo -e "  ${BOLD}Send this file to your peer:${NC}"
          echo -e "  ${CYAN}${bundle_file}${NC}"
          echo ""
          echo -e "  ${DIM}Email attachment, scp, encrypted drop — whatever works.${NC}"
          echo -e "  ${DIM}Just don't paste the contents inline; email clients love to mangle encoded text.${NC}"

          BUNDLE_EMAIL_ATTEMPTED="n"
          BUNDLE_EMAIL_DELIVERED="n"

          if have_cmd gog || have_cmd himalaya; then
            echo ""
            if prompt_yn "Email this bundle to your peer now?" "n"; then
              local bundle_email bundle_email_account="" manual_email_args=()
              prompt_value bundle_email "Recipient email address" ""
              if [[ -n "$bundle_email" ]]; then
                choose_mail_account bundle_email_account
                manual_email_args=(peers exchange initiate "$PEER_ID" --pubkey "$peer_pubkey" --output "$bundle_file")
                build_email_args manual_email_args "$bundle_email" "$bundle_email_account" "Antenna Pairing Invite Exchange Bundle" "" "false"

                echo ""
                info "Sending encrypted bundle email..."
                echo ""

                BUNDLE_EMAIL_ATTEMPTED="y"
                set +e
                EMAIL_OUTPUT=$(bash "$ANTENNA" "${manual_email_args[@]}" 2>&1)
                EMAIL_EXIT=$?
                set -e
                echo "$EMAIL_OUTPUT"
                if [[ $EMAIL_EXIT -eq 0 ]]; then
                  BUNDLE_EMAIL_DELIVERED="y"
                fi
              else
                warn "No email address entered — skipping email send."
              fi
            fi
          fi

          echo ""
          if [[ "${BUNDLE_EMAIL_ATTEMPTED:-n}" == "y" && "${BUNDLE_EMAIL_DELIVERED:-n}" == "y" ]]; then
            ok "Bundle emailed. Waiting for your peer to import it and reply."
          elif [[ "${BUNDLE_EMAIL_ATTEMPTED:-n}" == "y" ]]; then
            err "Email delivery failed — bundle was NOT sent."
            echo -e "  ${DIM}Transfer this file manually (scp, USB, encrypted drop):${NC}"
            echo -e "  ${CYAN}${bundle_file}${NC}"
            echo ""
            prompt_value BUNDLE_DELIVERED_MANUALLY "Did you deliver it out of band? (y/N)" "n"
            if [[ "${BUNDLE_DELIVERED_MANUALLY,,}" != "y" && "${BUNDLE_DELIVERED_MANUALLY,,}" != "yes" ]]; then
              warn "Holding here. Re-run the wizard after you've delivered the bundle, or rerun with the bundle file path."
              exit 0
            fi
          else
            wait_for_enter "Press Enter once you've sent it off"
          fi
        fi
      fi
    fi
  fi

  if wizard_prompt 4 $total_steps "Wait for their reply"; then
    echo ""
    echo -e "  Ball's in their court. They need to:"
    echo -e "    1. Import your bundle:  ${DIM}antenna peers exchange import <your-bundle>${NC}"
    echo -e "    2. Create a reply:      ${DIM}antenna peers exchange reply ${PEER_ID:-<your-host-id>}${NC}"
    echo -e "    3. Send you the reply file"
    echo ""
    echo -e "  This is a good time to grab coffee. ☕"
    echo ""
    wait_for_enter "Press Enter once you have their reply bundle"
  fi

  if wizard_prompt 5 $total_steps "Import their bundle"; then
    echo ""
    import_reply_bundle
  fi

  if wizard_prompt 6 $total_steps "Test the connection"; then
    echo ""
    test_connection
  fi

  if wizard_prompt 7 $total_steps "Send your first message! 🦞"; then
    echo ""
    send_first_message
  fi

  finish_cheat_sheet
}

run_transport_menu() {
  local choice
  while true; do
    header "🦞 Antenna Pairing Wizard"

    echo -e "  Let's connect you to another host on the reef."
    echo -e "  Choose the pairing path first, then the wizard will only ask for what that path needs."
    echo ""
    echo -e "  ${BOLD}How would you like to pair?${NC}"
    echo -e "    1) Email (requires Himalaya or gog)"
    echo -e "    2) ClawReef.io invite"
    echo -e "    3) Manually"
    echo -e "    4) Quit"
    echo ""

    prompt_value choice "Choice" "1"
    case "${choice,,}" in
      1|email|e)
        if run_email_pairing; then
          return 0
        else
          local email_status=$?
          if [[ $email_status -eq 2 ]]; then
            continue
          fi
          return "$email_status"
        fi
        ;;
      2|clawreef|clawreef.io|c)
        run_clawreef_pairing
        return 0
        ;;
      3|manual|manually|m)
        run_manual_pairing
        return 0
        ;;
      4|q|quit)
        info "No changes made."
        return 0
        ;;
      *)
        warn "Choose 1, 2, 3, or 4."
        ;;
    esac
  done
}

run_transport_menu
