#!/usr/bin/env bash
# demo.sh - a small fake "relay manager" that exercises every part of the Phase 1 foundation.
# It doubles as the reference for how Phase 2 plugs the real Iran / foreign logic in:
#
#   1. register probes      probe_register id fn "Label"      (fast, parallel, cached status)
#   2. write a status card  ui_box_* + ui_box_probe           (the dashboard header)
#   3. write actions        plain functions; prompts + act_* helpers; state goes to disk
#   4. declare screens      menu_screen / menu_item           (data, not loops)
#   5. menu_run main
#
# Nothing here touches the machine: the "service" is a file in a temp directory.

set -uo pipefail
umask 077

DEMO_DIR=""

# ---------------------------------------------------------------- fake backend ------------------
demo_seed() {
  DEMO_DIR=$GM_TMP/demo
  mkdir -p "$DEMO_DIR"
  echo running >"$DEMO_DIR/service"
  printf '%s\n' gemini.google.com aistudio.google.com generativelanguage.googleapis.com \
    proactivebackend-pa.googleapis.com >"$DEMO_DIR/domains"
}

demo_domains_without() {  # rewrite the list without $1 (grep -v exits 1 on an empty result)
  { grep -vxF -- "$1" "$DEMO_DIR/domains" || true; } >"$DEMO_DIR/domains.new"
  mv -f "$DEMO_DIR/domains.new" "$DEMO_DIR/domains"
}

# ---------------------------------------------------------------- probes -----------------------
# Each prints: LEVEL <TAB> BADGE <TAB> detail [<TAB> hint]
probe_relay() {
  if [[ $(<"$DEMO_DIR/service") == running ]]; then
    printf 'ok\tACTIVE\txray-gemini %s listening on :20443\n' "$G_DOT"
  else
    printf 'fail\tSTOPPED\txray-gemini is not running\tService > Start\n'
  fi
}
probe_routing() { printf 'ok\tON\t%s hosts routed to Iran\n' "$(wc -l <"$DEMO_DIR/domains")"; }
probe_dns() {
  sleep "${DEMO_DNS_DELAY:-1.5}"          # a slow live check: costs one spinner, not a frozen screen
  printf 'ok\tOK\tShecan answers differ from a neutral resolver\n'
}
probe_fw() { printf 'warn\tNO RULE\tnothing allows 198.51.100.7 to reach :20443\tService > Repair firewall\n'; }

# ---------------------------------------------------------------- status cards ------------------
demo_status() {
  probe_refresh
  ui_box_top "GEMINI $G_DOT SHECAN"
  ui_box_kv "Role" "${C_B}IRAN relay${C_0} ${C_DIM}(demo)${C_0}"
  ui_box_probe "Relay" relay
  ui_box_probe "Routing" routing
  ui_box_probe "Shecan DNS" dns
  ui_box_probe "Firewall" fw
  ui_box_kv "Addresses" "203.0.113.10 ${C_DIM}$G_SEP foreign${C_0} 198.51.100.7"
  ui_box_bottom
}

demo_domains_status() {
  local d n=0
  ui_box_top "Routed hosts"
  while IFS= read -r d; do
    n=$((n + 1))
    ui_safe d "$d" $((UI_W - 12))
    ui_box_row "${C_DIM}$n.${C_0} $d"
  done <"$DEMO_DIR/domains"
  if ((n == 0)); then ui_box_row "${C_DIM}(empty)${C_0}"; fi
  ui_box_bottom
}

# ---------------------------------------------------------------- actions ----------------------
demo_health() {  # runs in the main shell (call:) so it can refresh the probe cache
  ui_blank
  probe_refresh 1
  ui_rule "Health check"
  probe_report
  ui_blank
}

demo_domain_add() {
  local h
  prompt_hostname h "Hostname to add (e.g. bard.google.com)" || act_cancel
  if grep -qxF -- "$h" "$DEMO_DIR/domains"; then
    ui_ok "$h is already in the list"
    return 0
  fi
  confirm "Add $h?" || act_cancel
  act_step "Updating the list"
  act_do "add $h to the list" bash -c 'printf "%s\n" "$1" >>"$2"' _ "$h" "$DEMO_DIR/domains"
}

demo_domain_remove() {
  local -a list=()
  local pick
  mapfile -t list <"$DEMO_DIR/domains"
  if ((${#list[@]} == 0)); then act_cancel "the list is empty"; fi
  prompt_choice pick "Remove which host (number or name)" "" "${list[@]}" || act_cancel
  confirm "Remove $pick?" || act_cancel
  act_step "Updating the list"
  act_do "remove $pick from the list" demo_domains_without "$pick"
}

demo_service_start() {
  act_step "Starting xray-gemini"
  act_do "start the relay" bash -c 'sleep 0.4; echo running >"$1"' _ "$DEMO_DIR/service"
}
demo_service_stop() {
  confirm "Stop the relay? Gemini requests pause while it is down." || act_cancel
  act_step "Stopping xray-gemini"
  act_do "stop the relay" bash -c 'sleep 0.4; echo stopped >"$1"' _ "$DEMO_DIR/service"
}
demo_can_start() { [[ $(<"$DEMO_DIR/service") == stopped ]] || { MENU_WHY="already running"; return 1; }; }
demo_can_stop()  { [[ $(<"$DEMO_DIR/service") == running ]] || { MENU_WHY="not running"; return 1; }; }

demo_setup() {  # a wizard: every prompt re-asks on a typo and b cancels cleanly
  local fip port ver url
  ui_say "This walks through the prompts a real setup needs. Try typing nonsense, or just Enter."
  prompt_ipv4 fip "Foreign server IPv4" || act_cancel
  prompt_port port "Relay port" 20443 || act_cancel
  prompt_choice ver "Xray version" latest latest 26.3.27 25.12.1 || act_cancel
  prompt_text url "Shecan registration URL" || act_cancel
  ui_info "foreign=$fip  port=$port  xray=$ver  url=(${#url} characters)"
  confirm "Apply this configuration?" || act_cancel
  act_step "Writing the configuration"
  act_do "write the config for $fip:$port" sleep 0.4
  act_commit                                   # step 1 is durable from here on
  act_step "Starting the relay"
  act_do "start the relay" sleep 0.4
  if [[ $port == 666 ]]; then                  # simulated failure: shows the PARTIAL report
    act_partial "configuration written for $fip:$port"
    act_fail "port 666 is refused by this demo"
  fi
}

demo_scope() {  # pick_many: b cancels and leaves the selection untouched
  local -a labels=("in-8443  :8443  Phone (vless)" "in-2053  :2053  Laptop (trojan)" "in-443  :443  Family (vless)")
  local -a sel=(1 1 0) chosen=()
  pick_many chosen "Which inbounds use the relay" labels sel || act_cancel
  ui_ok "selected: ${chosen[*]:-none}  (0-based indexes)"
}

demo_slow() {
  act_defer ui_note "cleanup ran (deferred)"
  act_step "A long operation - press Ctrl-C to stop it"
  ui_task "Waiting for a slow server" sleep 6
}

demo_fail() {
  act_step "Step one (will be rolled back)"
  act_on_fail ui_note "rollback: step one undone"
  ui_ok "step one done"
  act_step "Step two (fails)"
  must ls /nonexistent-directory-for-the-demo
  ui_ok "never reached: a failing step stops the operation"
}

demo_danger() {
  confirm_typed_force "This would delete everything the demo manages." yes || act_cancel
  act_step "Deleting"
  act_do "delete everything (pretend)" sleep 0.4
}

# ---------------------------------------------------------------- screens ----------------------
demo_screens() {
  menu_screen main "Demo relay" demo_status
  menu_item main 1 "Health check"      "live checks with what to do"  call:demo_health
  menu_item main 2 "Domains"           "edit the routed hosts"        screen:domains
  menu_item main 3 "Service"           "start / stop the relay"       screen:service
  menu_item main 4 "Setup wizard"      "validated prompts"            action:demo_setup
  menu_item main 5 "Choose inbounds"   "multi-select"                 action:demo_scope
  menu_item main 6 "Slow operation"    "try Ctrl-C while it runs"     action:demo_slow
  menu_item main 7 "Failing operation" "rollback + FAILED result"     action:demo_fail

  menu_screen domains "Domains" demo_domains_status
  menu_item domains 1 "Add a hostname"    "" action:demo_domain_add
  menu_item domains 2 "Remove a hostname" "" action:demo_domain_remove

  menu_screen service "Service"
  menu_item service 1 "Start relay" "" action:demo_service_start demo_can_start
  menu_item service 2 "Stop relay"  "" action:demo_service_stop demo_can_stop
  menu_item service 3 "Danger zone" "typed confirmation" action:demo_danger
}

demo_usage() {
  cat <<EOF
$GM_APP demo (Phase 1 foundation)   version $GM_VERSION
  --dry-run     actions only describe what they would do
  --yes         auto-accept plain y/n confirmations
  --ascii       plain ASCII frames      --no-color   no colours
  --status      print the status card once and exit
  -h, --help    this text
EOF
}

main() {
  local status_only=0
  while (($#)); do
    case $1 in
      --dry-run) GM_DRY=1 ;;
      --yes | -y) GM_YES=1 ;;
      --ascii) GM_ASCII=1 ;;
      --no-color) GM_COLOR=0 ;;
      --status) status_only=1 ;;
      -h | --help) demo_usage; return 0 ;;
      *) echo "unknown option: $1 (see --help)" >&2; return 2 ;;
    esac
    shift
  done
  gm_tmp_init
  gm_install_traps
  ui_detect
  in_init
  demo_seed
  probe_register relay probe_relay "Relay service"
  probe_register routing probe_routing "Gemini routing"
  probe_register dns probe_dns "Shecan DNS hijack"
  probe_register fw probe_fw "Firewall rule"
  demo_screens

  if ((status_only)); then
    demo_status
    return 0
  fi
  if ((!IN_OK)); then
    ui_err "no terminal available: run this from an interactive shell"
    return 1
  fi
  ui_banner "GEMINI $G_DOT SHECAN" "Phase 1 foundation demo $G_DOT v$GM_VERSION"
  menu_run main        # its own statement (never after || / if): see 40-action.sh
  ui_blank
  ui_note "bye"
  return 0
}

# Run when executed, or when piped into bash (curl ... | bash); stay quiet when sourced by tests.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi
