# shellcheck shell=bash
# 95-foreign-screens.sh - the foreign menu, as data.

foreign_en_panel() {
  if [[ -n $DB ]]; then return 0; fi
  MENU_WHY="the 3X-UI database was not found - pass --db, or open the panel > Xray Configs and press Save once"
  return 1
}

foreign_routing_card() {
  local badge
  foreign_facts >/dev/null 2>&1 || true
  case $T_STATE in
    on)      ui_badge badge ok ON ;;
    off)     ui_badge badge warn OFF ;;
    partial) ui_badge badge warn INCONSISTENT ;;
    *)       ui_badge badge fail MISSING ;;
  esac
  ui_box_top "Gemini routing"
  ui_box_kv "State" "$badge  scope: $T_SCOPE, $T_NDOM hosts"
  ui_box_row "${C_DIM}OFF keeps both rules but makes them match nothing: Gemini goes out the normal way.${C_0}"
  ui_box_row "${C_DIM}Each switch restarts the panel (users are dropped for a few seconds).${C_0}"
  ui_box_bottom
}

foreign_domains_card() {
  local d i=0
  ui_box_top "Routed hosts"
  while IFS= read -r d; do
    i=$((i + 1))
    ui_safe d "$d" $((UI_W - 12))
    ui_box_row "${C_DIM}$(printf '%2d.' "$i")${C_0} $d"
  done < <(foreign_domain_list 2>/dev/null || true)
  ui_box_row "${C_DIM}the Iran relay must accept the same hosts (Push list to Iran)${C_0}"
  ui_box_bottom
}

foreign_sniffing_card() {
  ui_box_top "Sniffing"
  ui_box_row "${C_DIM}domain rules only work if the inbound sniffs tls/http and routeOnly is off${C_0}"
  ui_box_bottom
  if [[ -n $DB ]]; then panel_py audit "$DB" "$GM_TMP/sniff.count" 2>/dev/null || true; fi
}

# ---- backups (dynamic) ------------------------------------------------------------------------------------
FOREIGN_SEL_BK=""
foreign_bk_open() { FOREIGN_SEL_BK=$1; MENU_STACK+=(f_bkdetail); }
foreign_backups_build() {
  local i=0 d
  menu_reset f_backups
  while IFS= read -r d; do
    i=$((i + 1))
    if ((i > 20)); then break; fi
    menu_item f_backups "$i" "$(basename "$d")" "$(foreign_bk_summary "$d")" "call:foreign_bk_open $d"
  done < <(bk_dirs)
}
foreign_backups_card() {
  ui_box_top "Backups ($BACKUP_ROOT)"
  if [[ -z $(bk_dirs) ]]; then ui_box_row "${C_DIM}no backups yet: created the first time something changes${C_0}"; fi
  ui_box_row "${C_DIM}the OLDEST backup is the template from before this tool first ran${C_0}"
  ui_box_bottom
}
foreign_bkdetail_build() {
  menu_reset f_bkdetail
  menu_item f_bkdetail 1 "Diff against the current template" "what restoring would change" "view:foreign_act_backup_diff $FOREIGN_SEL_BK"
  menu_item f_bkdetail 2 "Restore it" "typed confirmation, panel restarts" "action:foreign_act_backup_restore $FOREIGN_SEL_BK"
}
foreign_bkdetail_card() {
  ui_box_top "Backup $(basename "$FOREIGN_SEL_BK")"
  ui_box_kv "Contains" "$(foreign_bk_summary "$FOREIGN_SEL_BK")  (the state BEFORE that run)"
  ui_box_bottom
}

foreign_screens() {
  menu_screen main "Foreign server" foreign_status
  menu_item main 1 "Health check"          "live checks, what to do"      call:foreign_act_health
  menu_item main 2 "End-to-end test"       "foreign > Iran > Shecan > Google" action:foreign_act_test foreign_en_panel
  menu_item main 3 "Gemini routing"        "switch ON / OFF"              screen:f_routing foreign_en_panel
  menu_item main 4 "Scope: which inbounds" "who uses the relay"           action:foreign_act_scope foreign_en_panel
  menu_item main 5 "Domains"               "hosts routed to Iran"         screen:f_domains foreign_en_panel
  menu_item main 6 "Learn mode (phone app)" "find hosts the app uses"     action:foreign_act_learn foreign_en_panel
  menu_item main 7 "Sniffing"              "audit / fix inbounds"         screen:f_sniffing foreign_en_panel
  menu_item main 8 "Backups"               "diff, restore"                screen:f_backups foreign_en_panel
  menu_item main 9 "Revert everything"     "remove ir-gemini + its rules" action:foreign_act_revert foreign_en_panel
  menu_item main s "Setup / re-run setup"  "patch the panel template"     action:foreign_act_setup

  menu_screen f_routing "Routing" foreign_routing_card
  menu_item f_routing 1 "Switch ON"  "" "action:foreign_act_routing on"
  menu_item f_routing 2 "Switch OFF" "" "action:foreign_act_routing off"

  menu_screen f_domains "Domains" foreign_domains_card
  menu_item f_domains 1 "Add a hostname"       "offers to sync Iran"       action:foreign_act_domain_add
  menu_item f_domains 2 "Remove a hostname"    "pick by number or name"    action:foreign_act_domain_remove
  menu_item f_domains 3 "Push the list to Iran" "ssh, or prints the command" action:foreign_act_sync_iran

  menu_screen f_sniffing "Sniffing" foreign_sniffing_card
  menu_item f_sniffing 1 "Fix selected inbounds" "old values are saved in the backup" action:foreign_act_sniff_fix
  menu_item f_sniffing 2 "Run the audit again"   "" view:foreign_act_sniff_audit

  menu_screen f_backups "Backups" foreign_backups_card foreign_backups_build
  menu_screen f_bkdetail "Backup" foreign_bkdetail_card foreign_bkdetail_build
}
