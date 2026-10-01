# shellcheck shell=bash
# 80-iran-screens.sh - the Iran menu, as data. Every screen is a menu_screen + menu_item table;
# the engine (src/lib/60-menu.sh) supplies input, navigation, errors, dry-run toggle and help.

iran_en_installed() {
  if iran_installed; then return 0; fi
  MENU_WHY="the relay is not installed - press s for the setup"
  return 1
}

# ---- small status cards for the sub-screens ----------------------------------------------------------
iran_domains_card() {
  local i=0 d
  ui_box_top "Routed hosts (Shecan DNS + routing)"
  if iran_installed; then
    while IFS= read -r d; do
      i=$((i + 1))
      ui_safe d "$d" $((UI_W - 12))
      ui_box_row "${C_DIM}$(printf '%2d.' "$i")${C_0} $d"
    done < <(cfg_py domains 2>/dev/null || true)
  fi
  if ((i == 0)); then ui_box_row "${C_DIM}(none: the relay is not installed)${C_0}"; fi
  ui_box_row "${C_DIM}the foreign server must route the same hosts${C_0}"
  ui_box_bottom
}

iran_service_card() {
  local s t tg badge
  s=$(systemctl is-active "$SVC" 2>/dev/null || echo unknown)
  t=$(systemctl is-active "$WATCH_SVC.timer" 2>/dev/null || echo unknown)
  ui_box_top "Service, timer, alerts"
  if [[ $s == active ]]; then ui_badge badge ok ACTIVE; else ui_badge badge fail "${s^^}"; fi
  ui_box_kv "Relay" "$badge $SVC"
  if [[ $t == active ]]; then ui_badge badge ok ACTIVE; else ui_badge badge warn "${t^^}"; fi
  ui_box_kv "Timer" "$badge $WATCH_SVC.timer (every 5 min)"
  if [[ -f $WATCH_ENV ]]; then ui_badge badge ok CONFIGURED; else ui_badge badge off "NOT SET"; fi
  tg=$badge
  ui_box_kv "Telegram" "$tg alerts on problems / recovery"
  ui_box_bottom
}

iran_logs_card() {
  local until
  until=$(state_get access_until)
  ui_box_top "Logs"
  if iran_installed && [[ $(cfg_py access 2>/dev/null) == on ]]; then
    ui_box_row "${C_WARN}[ON]${C_0}  access log is recording${until:+ (auto-off in $(((until - $(now)) / 60 + 1)) min)}"
  else
    ui_box_row "${C_DIM}[OFF]${C_0} access log is off (normal: connections are not recorded)"
  fi
  ui_box_bottom
}

# ---- backups (dynamic) --------------------------------------------------------------------------------
IRAN_SEL_BK=""
iran_bk_open() {  # call: handler - remember which backup, then push its screen
  IRAN_SEL_BK=$1
  MENU_STACK+=(bkdetail)
}

iran_backups_build() {
  local i=0 d
  menu_reset backups
  while IFS= read -r d; do
    i=$((i + 1))
    if ((i > 20)); then break; fi
    menu_item backups "$i" "$(basename "$d")" "$(iran_bk_summary "$d")" "call:iran_bk_open $d"
  done < <(bk_dirs)
}
iran_backups_card() {
  ui_box_top "Backups ($BACKUP_ROOT)"
  if [[ -z $(bk_dirs) ]]; then ui_box_row "${C_DIM}no backups yet: they are created the first time something changes${C_0}"; fi
  ui_box_row "${C_DIM}pick one to diff it, restore its config, or undo the whole run${C_0}"
  ui_box_bottom
}

iran_bkdetail_build() {
  menu_reset bkdetail
  menu_item bkdetail 1 "Diff against the current config" "key line hidden"  "view:iran_act_backup_diff $IRAN_SEL_BK"
  menu_item bkdetail 2 "Restore this backup's config"    "restarts the relay" "action:iran_act_backup_restore $IRAN_SEL_BK"
  menu_item bkdetail 3 "Undo the whole run it belongs to" "firewall, files, service" "action:iran_act_rollback $IRAN_SEL_BK"
}
iran_bkdetail_card() {
  ui_box_top "Backup $(basename "$IRAN_SEL_BK")"
  ui_box_kv "Contains" "$(iran_bk_summary "$IRAN_SEL_BK")"
  ui_box_bottom
}

# ---- the screen tree ------------------------------------------------------------------------------------
iran_screens() {
  menu_screen main "Iran relay" iran_status
  menu_item main 1 "Health check"          "live checks, what to do"      call:iran_act_health
  menu_item main 2 "Repair"                "fix what the checks flag"     screen:repair iran_en_installed
  menu_item main 3 "Register IP (Shecan)"  "re-register + verify DNS"    action:iran_act_register iran_en_installed
  menu_item main 4 "Connection info"       "what the foreign side needs"  screen:connection iran_en_installed
  menu_item main 5 "Allowed foreign IP"    "change / re-check the rule"   action:iran_act_change_ip iran_en_installed
  menu_item main 6 "Domains"               "hosts routed through Shecan"  screen:domains iran_en_installed
  menu_item main 7 "Logs"                  "relay, timer, access log"     screen:logs iran_en_installed
  menu_item main 8 "Service, timer, alerts" "start/stop, Telegram"        screen:service iran_en_installed
  menu_item main 9 "Backups"               "diff, restore, undo a run"    screen:backups iran_en_installed
  menu_item main s "Setup / re-run setup"  "install or repair end to end" action:iran_act_setup
  menu_item main u "Uninstall"             "remove only what we created"  action:iran_act_uninstall

  menu_screen repair "Repair" iran_status
  menu_item repair 1 "Fix everything that is wrong" "runs 2-5, each is idempotent" "action:iran_act_repair all"
  menu_item repair 2 "Firewall rule"               "re-add the allow rule"         "action:iran_act_repair firewall"
  menu_item repair 3 "Relay config"                "catch-all guard + domain list" "action:iran_act_repair config"
  menu_item repair 4 "Health timer"                "single installed copy"         "action:iran_act_repair timer"
  menu_item repair 5 "Shecan registration"         "register + verify DNS"         "action:iran_act_repair register"

  menu_screen connection "Connection info"
  menu_item connection 1 "Show connection info" "IP, port, masked key, commands" action:iran_act_info
  menu_item connection 2 "Reveal the key once"  "typed confirmation required"    action:iran_act_reveal_key

  menu_screen domains "Domains" iran_domains_card
  menu_item domains 1 "Add a hostname"    "checked with xray -test first" action:iran_act_domain_add
  menu_item domains 2 "Remove a hostname" "pick by number or name"        action:iran_act_domain_remove

  menu_screen logs "Logs" iran_logs_card
  menu_item logs 1 "Last 50 lines: relay"        "" "view:iran_act_logs relay"
  menu_item logs 2 "Last 50 lines: health timer" "" "view:iran_act_logs timer"
  menu_item logs 3 "Live tail"                   "Ctrl-C stops the tail only" call:iran_logs_follow
  menu_item logs 4 "Access log ON for N minutes" "switches itself off" action:iran_act_access_on
  menu_item logs 5 "Access log OFF now"          "" action:iran_act_access_off

  menu_screen service "Service" iran_service_card
  menu_item service 1 "Start relay"   "" "action:iran_act_service start"
  menu_item service 2 "Restart relay" "" "action:iran_act_service restart"
  menu_item service 3 "Stop relay"    "Gemini pauses while it is down" "action:iran_act_service stop"
  menu_item service 4 "Health timer ON"  "" "action:iran_act_timer on"
  menu_item service 5 "Health timer OFF" "" "action:iran_act_timer off"
  menu_item service 6 "Telegram alerts: set / change" "" action:iran_act_tg_set
  menu_item service 7 "Telegram alerts: remove"       "" action:iran_act_tg_off
  menu_item service 8 "Install / update this tool's copy" "the timer runs it" action:iran_act_install_self

  menu_screen backups "Backups" iran_backups_card iran_backups_build
  menu_screen bkdetail "Backup" iran_bkdetail_card iran_bkdetail_build
}
