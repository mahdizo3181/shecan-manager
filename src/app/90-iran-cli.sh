# shellcheck shell=bash
# 90-iran-cli.sh - gemini-menu iran <command> ...   (the canonical command line)
#
# iran_cli returns the exit code; call it as its own statement (see act_run).
#   0 ok | 1 health: warnings | 2 health: broken / usage | 10 cancelled | 130 interrupted | other: failed

iran_usage() {
  cat <<EOF2
gemini-menu iran <command> [flags]

  (no command)            interactive menu
  status                  health check (exit 0 healthy, 1 warnings, 2 broken)
  setup                   install / repair the relay end to end
  repair [all|firewall|config|timer|register]
  register                register this IP with Shecan now, with a live check
  info [reveal]           IP, port, method, masked key, commands for the foreign side
  foreign-ip [IPv4]       change / re-check which IP may reach the relay (idempotent)
  domain list|add H|remove H|set H...
  logs [relay|timer|follow]     access-on [MIN]     access-off
  service start|stop|restart    timer on|off        telegram set|off
  backups [list|diff N|restore N|undo N]
  rollback [--backup-dir D]     undo the newest run that changed something
  uninstall               remove only what this tool created
  install-self            install this file as /usr/local/bin/gemini-menu (the timer runs it)
  watch                   one health-timer run (used by systemd)

Flags: --dry-run  --yes  --foreign-ip IP  --ss-port N  --key-file F  --shecan-url-file F
       --xray-version X.Y.Z  --xray-bin PATH  --backup-dir D  --verbose
EOF2
}

iran_cli_backup_dir() {  # the N-th newest backup directory (prints it)
  local n=${1:-} d
  v_int_range "$n" 1 999 || { ui_err "backup number: $IN_ERR"; return 2; }
  d=$(bk_dirs | sed -n "${n}p")
  if [[ -z $d ]]; then ui_err "no backup number $n (see: backups list)"; return 2; fi
  printf '%s' "$d"
}

iran_cli() {
  local c=${1:-status} d i=0
  shift || true
  case $c in
    status | health) iran_cli_status; return $? ;;
    setup | apply)   act_run "Setup" iran_act_setup; return $? ;;
    repair)          act_run "Repair ${1:-all}" iran_act_repair "${1:-all}"; return $? ;;
    register)        act_run "Register IP with Shecan" iran_act_register; return $? ;;
    info)
      if [[ ${1:-} == reveal ]]; then act_run "Reveal key" iran_act_reveal_key; else ACT_QUIET_OK=1 act_run "Connection info" iran_act_info; fi
      return $? ;;
    foreign-ip)      act_run "Allowed foreign IP" iran_act_change_ip "${1:-}"; return $? ;;
    domain | domains)
      case ${1:-list} in
        list)   ACT_QUIET_OK=1 act_run "Domain list" iran_act_domains_list ;;
        add)    act_run "Add domain" iran_act_domain_add "${2:-}" ;;
        remove) act_run "Remove domain" iran_act_domain_remove "${2:-}" ;;
        set)    shift; act_run "Set domain list" iran_act_domain_set "$@" ;;
        *)      ui_err "domain: use list | add H | remove H | set H..."; return 2 ;;
      esac
      return $? ;;
    logs)
      case ${1:-relay} in
        relay | last) ACT_QUIET_OK=1 act_run "Relay log" iran_act_logs relay ;;
        timer)        ACT_QUIET_OK=1 act_run "Timer log" iran_act_logs timer ;;
        follow)       iran_logs_follow ;;
        access)       act_run "Access log on" iran_act_access_on "${2:-}" ;;
        *)            ui_err "logs: use relay | timer | follow"; return 2 ;;
      esac
      return $? ;;
    access-on)       act_run "Access log on" iran_act_access_on "${1:-}"; return $? ;;
    access-off)      act_run "Access log off" iran_act_access_off; return $? ;;
    service)         act_run "Service ${1:-}" iran_act_service "${1:-}"; return $? ;;
    timer)           act_run "Health timer ${1:-}" iran_act_timer "${1:-}"; return $? ;;
    telegram)
      case ${1:-set} in
        set) act_run "Telegram alerts" iran_act_tg_set ;;
        off) act_run "Remove Telegram alerts" iran_act_tg_off ;;
        *)   ui_err "telegram: use set | off"; return 2 ;;
      esac
      return $? ;;
    backups)
      case ${1:-list} in
        list)
          bk_dirs | while IFS= read -r d; do i=$((i + 1)); printf '  %d) %s  %s\n' "$i" "$(basename "$d")" "$(iran_bk_summary "$d")"; done
          if [[ -z $(bk_dirs) ]]; then ui_note "(no backups yet)"; fi
          return 0 ;;
        diff)    d=$(iran_cli_backup_dir "${2:-}") || return $?; ACT_QUIET_OK=1 act_run "Backup diff" iran_act_backup_diff "$d"; return $? ;;
        restore) d=$(iran_cli_backup_dir "${2:-}") || return $?; act_run "Restore backup" iran_act_backup_restore "$d"; return $? ;;
        undo)    d=$(iran_cli_backup_dir "${2:-}") || return $?; act_run "Undo run" iran_act_rollback "$d"; return $? ;;
        *)       ui_err "backups: use list | diff N | restore N | undo N"; return 2 ;;
      esac ;;
    rollback)        act_run "Rollback" iran_act_rollback; return $? ;;
    uninstall)       act_run "Uninstall the Iran relay" iran_act_uninstall; return $? ;;
    install-self)    act_run "Install this tool" iran_act_install_self; return $? ;;
    watch)           act_run "Health timer run" iran_act_watch; return $? ;;
    help)            iran_usage; return 0 ;;
    *)               ui_err "unknown iran command: $c"; iran_usage >&2; return 2 ;;
  esac
}
