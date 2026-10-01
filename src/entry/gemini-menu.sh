#!/usr/bin/env bash
# build: app
# gemini-menu - menu and command line for "Gemini via Iran-side Shecan".
#
#   gemini-menu                          interactive menu (the role is remembered)
#   gemini-menu [flags] iran <command>   canonical command line (see: gemini-menu iran help)
#   gemini-menu role [iran|foreign]      show / set the remembered role
#   gemini-menu install-self             install this file as /usr/local/bin/gemini-menu
#
# Both roles live in this engine: IRAN (the relay) and FOREIGN (the 3X-UI panel patcher).

set -uo pipefail
umask 077

ROLE=""
ROLE_FLAG=""
POS=()
ORIG_ARGS=()
FLAG_CMD=""

usage() {
  cat <<EOF
gemini-menu $GM_VERSION - menu and commands for "Gemini via Iran-side Shecan"

  gemini-menu                         interactive menu
  gemini-menu [flags] iran|foreign <command>   run one command (gemini-menu iran help / foreign help)
  gemini-menu role [iran|foreign]     show / set which server this is (remembered in $ROLE_FILE)
  gemini-menu install-self            install this file as $INSTALL_PATH

Global flags: --role iran|foreign  --dry-run  --yes  --no-color  --ascii  --verbose  -h  --version
Iran flags:   --foreign-ip IP  --ss-port N  --key-file F  --shecan-url-file F  --xray-version X.Y.Z
              --xray-bin PATH  --backup-dir D  --rollback
Foreign flags: --iran-ip IP  --key-file F  --ss-port N  --db PATH  --xray-bin PATH  --restart-cmd CMD
              --fix-sniffing  --all-domains  --restore-full-db  --quick  --backup-dir D
Flags may appear before or after the command: 'gemini-menu --yes iran status' = 'gemini-menu iran status --yes'.
EOF
}

# parse_args: flags anywhere, everything else is a positional word. Returns 2 on a usage error.
parse_args() {
  POS=()
  while (($#)); do
    case $1 in
      --role | --foreign-ip | --iran-ip | --ss-port | --key-file | --shecan-url-file | --xray-version | --xray-bin | --backup-dir | --db | --restart-cmd)
        if (($# < 2)); then echo "flag $1 needs a value (see: gemini-menu --help)" >&2; return 2; fi
        case $1 in
          --role)            ROLE_FLAG=$2 ;;
          --foreign-ip)      FOREIGN_IP=$2 ;;
          --iran-ip)         IRAN_IP=$2 ;;
          --db)              DB=$2 ;;
          --restart-cmd)     RESTART_CMD=$2 ;;
          --ss-port)         SS_PORT=$2; SS_PORT_EXPLICIT=1 ;;
          --key-file)        KEY_FILE_ARG=$2 ;;
          --shecan-url-file) SHECAN_URL_FILE_ARG=$2 ;;
          --xray-version)    XRAY_VERSION=$2; XRAY_VERSION_SET=1 ;;
          --xray-bin)        XRAY_BIN_SRC=$2 ;;
          --backup-dir)      BACKUP_DIR_ARG=$2 ;;
          *) ;;
        esac
        shift
        ;;
      --dry-run)  GM_DRY=1 ;;
      --yes | -y) GM_YES=1 ;;
      --no-color) GM_COLOR=0 ;;
      --ascii)    GM_ASCII=1 ;;
      --verbose)  VERBOSE=1 ;;
      --rollback) FLAG_CMD=rollback ;;
      --legacy | --quick) QUICK=1 ;;
      --fix-sniffing)     FIX_SNIFFING=1 ;;
      --all-domains)      ALL_DOMAINS=1 ;;
      --restore-full-db)  RESTORE_FULL_DB=1 ;;
      -h | --help) FLAG_CMD=help ;;
      --version)  FLAG_CMD=version ;;
      --*) echo "unknown flag: $1 (see: gemini-menu --help)" >&2; return 2 ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
}

# Role: --role / $GM_ROLE, else the remembered one, else "the relay is installed here" => iran,
# else ASK ONCE and remember the answer. It is never guessed from other software: an Iran server
# often runs a 3X-UI panel too, and a wrong guess used to be repeated on every start.
resolve_role() {
  local r=${ROLE_FLAG:-${GM_ROLE:-}} pick
  if [[ -z $r ]]; then r=$(role_get); fi
  if [[ -z $r ]] && iran_installed; then r=iran; if ! is_dry; then role_set iran; fi; fi
  if [[ -z $r ]]; then
    if ((!IN_OK)); then
      ui_err "cannot tell which server this is - pass --role iran|foreign (it is remembered after 'setup')"
      return 2
    fi
    ui_blank
    ui_say "First run: which server is this? (asked once, then remembered in $ROLE_FILE)"
    prompt_choice pick "This server is the" "" "Iran server (runs the relay)" "Foreign server (runs the 3X-UI panel)" || return 1
    case $pick in Iran*) r=iran ;; *) r=foreign ;; esac
    if ! is_dry; then role_set "$r"; fi
  fi
  case $r in
    iran | foreign) ROLE=$r ;;
    *) ui_err "role must be iran or foreign (got '$r')"; return 2 ;;
  esac
}

offer_install_self() {
  local sum rc
  if ((!IN_OK)) || is_dry || [[ $EUID -ne 0 || -z $GM_SELF || $GM_SELF == "$INSTALL_PATH" ]]; then return 0; fi
  if [[ -x $INSTALL_PATH ]] && cmp -s "$GM_SELF" "$INSTALL_PATH"; then return 0; fi
  sum=$(md5sum "$GM_SELF" | cut -d' ' -f1)
  if [[ $(state_get install_declined) == "$sum" ]]; then return 0; fi
  ui_blank
  if [[ -x $INSTALL_PATH ]]; then ui_info "A different version of this tool is installed as $INSTALL_PATH."
  else ui_info "First run. This tool can install itself so you only type: gemini-menu (the health timer runs that copy)."; fi
  confirm "Install / update $INSTALL_PATH now?"
  rc=$?
  if ((rc == 0)); then
    act_run "Install $INSTALL_PATH" iran_act_install_self
  else
    state_set install_declined "$sum"
  fi
}

main() {
  local cmd="" rc=0
  ORIG_ARGS=("$@")
  parse_args "$@" || return $?
  gm_tmp_init
  gm_install_traps
  ui_detect
  in_init
  if [[ -n ${BASH_SOURCE[0]:-} && -r ${BASH_SOURCE[0]} ]]; then GM_SELF=$(readlink -f "${BASH_SOURCE[0]}"); fi

  if [[ $FLAG_CMD == version ]]; then echo "gemini-menu $GM_VERSION (${GM_BUILD:-dev})"; return 0; fi
  if [[ $FLAG_CMD == help || ${POS[0]:-} == help ]]; then usage; return 0; fi

  # `iran` / `foreign` first word selects the role for this one command
  if [[ ${POS[0]:-} == iran || ${POS[0]:-} == foreign ]]; then ROLE_FLAG=${POS[0]}; POS=("${POS[@]:1}"); fi
  cmd=${POS[0]:-}
  if ((${#POS[@]} > 0)); then POS=("${POS[@]:1}"); fi
  if [[ $FLAG_CMD == rollback ]]; then cmd=rollback; fi

  case $cmd in
    role)
      case ${POS[0]:-show} in
        show) echo "role: $(role_get || true)${ROLE_FLAG:+ (this run: $ROLE_FLAG)}"; return 0 ;;
        iran | foreign) if is_dry; then echo "dry-run: would remember role ${POS[0]}"; else role_set "${POS[0]}"; echo "role remembered: ${POS[0]}"; fi; return 0 ;;
        *) ui_err "role: use iran | foreign | show"; return 2 ;;
      esac ;;
    install-self) ROLE=iran; act_run "Install this tool" iran_act_install_self; return $? ;;
  esac

  resolve_role || return $?
  if [[ $ROLE == foreign ]]; then
    MANIFEST=foreign.manifest
    locate_db || true                  # quiet; the dashboard says so when it stays empty
    locate_xray || true
    foreign_register_probes
    foreign_screens
  else
    iran_register_probes
    iran_screens
  fi
  if [[ -n $cmd ]]; then
    if [[ $ROLE == foreign ]]; then foreign_cli "$cmd" "${POS[@]}"; else iran_cli "$cmd" "${POS[@]}"; fi
    return $?
  fi
  if ((!IN_OK)); then
    ui_err "the menu needs a terminal - run a command instead (gemini-menu $ROLE help)"
    return 1
  fi
  offer_install_self
  gm_audit "menu opened"
  ui_banner "GEMINI $G_DOT SHECAN" "$([[ $ROLE == foreign ]] && echo 'Foreign server manager' || echo 'Iran relay manager') $G_DOT v$GM_VERSION"
  menu_run main        # its own statement (never after || / if): see src/lib/40-action.sh
  rc=$?
  ui_blank
  ui_note "bye"
  return "$rc"
}

# Runs when executed or piped into bash (curl ... | bash); stays quiet when sourced by tests.
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi
