# shellcheck shell=bash
# 96-foreign-cli.sh - gemini-menu foreign <command> ...   (call foreign_cli as its own statement)
#   0 ok | 1 health: warnings | 2 health: broken / usage | 10 cancelled | 130 interrupted | other: failed

foreign_usage() {
  cat <<EOF2
gemini-menu foreign <command> [flags]

  (no command)            interactive menu
  status                  health check (exit 0 healthy, 1 warnings, 2 broken)
  setup | apply           patch the 3X-UI template (--iran-ip --key-file --ss-port --db --xray-bin --fix-sniffing)
  test [--quick]          end-to-end test, one row per host (--all-domains probes every host)
  routing on|off|status   switch the two Gemini rules without deleting them
  scope all | set TAG... | pick | list     (pick = choose the inbounds interactively)
  domain list|add H|remove H|set H...    (offers to sync the Iran relay)
  sync-iran               push the current host list to the Iran relay
  learn                   capture hostnames used by the phone app      learn-restore   undo its access-log switch
  sniffing audit|fix [IDS|all]            audit  = alias for 'sniffing audit'
  backups [list|diff N|restore N]
  revert                  remove ir-gemini + its rules (restores the pre-tool template)
  rollback [--backup-dir D] [--restore-full-db]    undo the newest run that changed something
  install                 install this file as /usr/local/bin/gemini-menu + the command  gemini
EOF2
}

foreign_cli_backup_dir() {
  local n=${1:-} d
  v_int_range "$n" 1 999 || { ui_err "backup number: $IN_ERR"; return 2; }
  d=$(bk_dirs | sed -n "${n}p")
  if [[ -z $d ]]; then ui_err "no backup number $n (see: backups list)"; return 2; fi
  printf '%s' "$d"
}

foreign_cli() {
  local c=${1:-status} d i=0
  shift || true
  case $c in
    status | health) foreign_cli_status; return $? ;;
    setup | apply)   act_run "Setup" foreign_act_setup; return $? ;;
    test)
      if [[ ${1:-} == --quick ]]; then QUICK=1; fi
      act_run "End-to-end test" foreign_act_test; return $? ;;
    routing)
      case ${1:-status} in
        on | off) act_run "Gemini routing $1" foreign_act_routing "$1" ;;
        status)
          if foreign_facts; then ui_say "Gemini routing: $T_STATE (scope: $T_SCOPE, $T_NDOM hosts)"; else ui_err "cannot read the template"; return 1; fi ;;
        *) ui_err "routing: use on | off | status"; return 2 ;;
      esac
      return $? ;;
    scope)
      case ${1:-list} in
        all)  act_run "Scope: all inbounds" foreign_act_scope all ;;
        pick) act_run "Scope" foreign_act_scope ;;
        set)  shift; act_run "Scope" foreign_act_scope "$@" ;;
        list)
          if foreign_facts; then
            ui_say "scope: $T_SCOPE"
            panel_py inbounds "$DB" | awk -F'\x1f' '{printf "  %s  :%s  %s [%s]\n",$1,$2,$3,$4}'
          else ui_err "cannot read the template"; return 1; fi ;;
        *) ui_err "scope: use all | set TAG... | pick | list"; return 2 ;;
      esac
      return $? ;;
    domain | domains)
      case ${1:-list} in
        list)   ACT_QUIET_OK=1 act_run "Domain list" foreign_act_domains_list ;;
        add)    act_run "Add domain" foreign_act_domain_add "${2:-}" ;;
        remove) act_run "Remove domain" foreign_act_domain_remove "${2:-}" ;;
        set)    shift; act_run "Set domain list" foreign_act_domain_set "$@" ;;
        *)      ui_err "domain: use list | add H | remove H | set H..."; return 2 ;;
      esac
      return $? ;;
    sync-iran)    act_run "Sync the Iran relay" foreign_act_sync_iran; return $? ;;
    learn)        act_run "Learn mode" foreign_act_learn; return $? ;;
    learn-restore) act_run "Restore the access log" foreign_act_learn_restore; return $? ;;
    sniffing | audit)
      if [[ $c == audit ]]; then set -- audit "$@"; fi
      case ${1:-audit} in
        audit) act_run "Sniffing audit" foreign_act_sniff_audit ;;
        fix)   act_run "Fix sniffing" foreign_act_sniff_fix "${2:-}" ;;
        *)     ui_err "sniffing: use audit | fix [IDS|all]"; return 2 ;;
      esac
      return $? ;;
    backups)
      case ${1:-list} in
        list)
          while IFS= read -r d; do i=$((i + 1)); printf '  %d) %s  %s\n' "$i" "$(basename "$d")" "$(foreign_bk_summary "$d")"; done < <(bk_dirs)
          if ((i == 0)); then ui_note "(no backups yet)"; fi
          return 0 ;;
        diff)    d=$(foreign_cli_backup_dir "${2:-}") || return $?; ACT_QUIET_OK=1 act_run "Backup diff" foreign_act_backup_diff "$d"; return $? ;;
        restore) d=$(foreign_cli_backup_dir "${2:-}") || return $?; act_run "Restore backup" foreign_act_backup_restore "$d"; return $? ;;
        *)       ui_err "backups: use list | diff N | restore N"; return 2 ;;
      esac ;;
    revert)       act_run "Revert everything" foreign_act_revert; return $? ;;
    rollback)     act_run "Rollback" foreign_act_rollback; return $? ;;
    install | install-self) act_run "Install the gemini command" gm_act_install; return $? ;;
    help)         foreign_usage; return 0 ;;
    *)            ui_err "unknown foreign command: $c"; foreign_usage >&2; return 2 ;;
  esac
}
