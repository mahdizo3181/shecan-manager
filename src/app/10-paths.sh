# shellcheck shell=bash
# 10-paths.sh - constants, paths, persisted role, small state store, tool checks.
#
# GM_ROOT prefixes every path this tool writes. It is empty on a real server; the test-suite points
# it at a sandbox directory (tests/iran_test.sh) together with stub commands.

GM_ROOT=${GM_ROOT:-}

# The seed list. Once installed, the relay's config.json is the source of truth.
GEMINI_DOMAINS=(
  gemini.google.com
  bard.google.com
  aistudio.google.com
  makersuite.google.com
  alkalimakersuite-pa.clients6.google.com
  waa-pa.clients6.google.com
  proactivebackend-pa.googleapis.com
  robinfrontend-pa.googleapis.com
  generativelanguage.googleapis.com
)
# GM_SHECAN_DNS / GM_NEUTRAL_DNS are test hooks (let a test rig answer through other resolvers).
read -r -a SHECAN_DNS <<<"${GM_SHECAN_DNS:-178.22.122.101 185.51.200.1}"
NEUTRAL_DNS=${GM_NEUTRAL_DNS:-1.1.1.1 8.8.8.8 9.9.9.9}
DNS_PROBE_HOST=gemini.google.com
SS_METHOD=2022-blake3-aes-128-gcm

SVC=xray-gemini
BIN=$GM_ROOT/usr/local/bin/xray-gemini
CONF_DIR=$GM_ROOT/usr/local/etc/xray-gemini
CONF=$CONF_DIR/config.json
SYSTEMD_DIR=$GM_ROOT/etc/systemd/system
UNIT=$SYSTEMD_DIR/$SVC.service
STATE_DIR=$GM_ROOT/etc/gemini-shecan
ROLE_FILE=$STATE_DIR/role                 # persisted role: asked/detected once, then remembered
URL_FILE=$STATE_DIR/shecan-url            # Shecan registration URL (secret, mode 600)
WATCH_CONF=$STATE_DIR/watch.conf          # non-secret settings for the health timer
WATCH_ENV=$STATE_DIR/watch.env            # TG_BOT / TG_CHAT (secret, mode 600)
WATCH_SVC=gemini-shecan-watch
REVERT_UNIT=gemini-access-revert
LEGACY_WATCH_BIN=$GM_ROOT/usr/local/sbin/gemini-shecan-watch   # old layout: a second copy of the script
DEFAULT_KEY_FILE=$GM_ROOT/root/gemini-shecan/ss.key
BACKUP_ROOT=${BACKUP_ROOT:-$GM_ROOT/root/gemini-shecan-backup}
FW_COMMENT=gemini-shecan
WATCH_STATE=$GM_ROOT/run/gemini-shecan-watch.state
LOG_FILE=$GM_ROOT/var/log/gemini-menu.log
MENU_STATE=$GM_ROOT/var/lib/gemini-menu/state       # small key=value cache; never secrets
# The ONE installed copy. The health timer and the access-log auto-off run this very file, so
# the menu and the timer can never drift apart.
INSTALL_PATH=$GM_ROOT/usr/local/bin/gemini-menu
MANIFEST=iran.manifest

# ---- settings (flags / environment) -------------------------------------------------------------
FOREIGN_IP=${FOREIGN_IP:-}
SS_PORT_EXPLICIT=0                        # 1 when the port came from --ss-port / $SS_PORT (beats the installed value)
if [[ -n ${SS_PORT:-} ]]; then SS_PORT_EXPLICIT=1; fi
SS_PORT=${SS_PORT:-20443}
KEY_FILE_ARG=""
SHECAN_URL_FILE_ARG=""
XRAY_VERSION=latest
XRAY_BIN_SRC=""
BACKUP_DIR_ARG=""
VERBOSE=0
FW_KIND=none
GM_SELF=""                # absolute path of this script when it runs from a file (empty when piped)

# ---- values produced inside one action (they live and die with the action's subshell) ----------
BK="" CHANGED=0 RESTART_NEEDED=0
FKEY_FILE=${KEY_FILE:-}            # foreign: $KEY_FILE from the environment (the key file the Iran setup wrote)
SS_KEY_VAL="" KEY_SRC="" KEY_FILE="" NEW_URL="" SHECAN_URL_SRC="" XRAY_CHECK_BIN=""
REG_RC=0 VERIFY_MSG="" FORM_OK=""

# ---- log, state ------------------------------------------------------------------------------------
# One line per action in the tool's own log. Never pass secrets to it.
gm_audit() {
  {
    mkdir -p "$(dirname "$LOG_FILE")" \
      && printf '%s %s %s %s\n' "$(date '+%F %T')" "${ROLE:-?}" "${SUDO_USER:-${USER:-root}}" "$*" >>"$LOG_FILE" \
      && chmod 600 "$LOG_FILE"
  } 2>/dev/null || true
}

state_get() { if [[ -r $MENU_STATE ]]; then sed -n "s/^$1=//p" "$MENU_STATE" | tail -n 1; fi; }
state_set() {
  mkdir -p "$(dirname "$MENU_STATE")" 2>/dev/null || return 0
  {
    if [[ -f $MENU_STATE ]]; then grep -v "^$1=" "$MENU_STATE" || true; fi
    printf '%s=%s\n' "$1" "$2"
  } >"$MENU_STATE.tmp" 2>/dev/null && mv -f "$MENU_STATE.tmp" "$MENU_STATE" 2>/dev/null || true
}

fmt_age() {  # seconds -> "5 min ago"
  local s=$1
  if ((s < 90)); then echo "${s}s ago"
  elif ((s < 5400)); then echo "$((s / 60)) min ago"
  elif ((s < 172800)); then echo "$((s / 3600)) h ago"
  else echo "$((s / 86400)) days ago"; fi
}
now() { date +%s; }

mask_key() {  # last 4 characters only (base64 '=' padding ignored)
  local k=${1%%=*}
  if ((${#k} < 8)); then echo "****"; else echo "************${k: -4}"; fi
}

dry_say() { ui_info "${C_WARN}dry-run${C_0}: $*"; }

# ---- role: detect or ask ONCE, then remember -------------------------------------------------------
role_get() { if [[ -r $ROLE_FILE ]]; then tr -d '[:space:]' <"$ROLE_FILE"; fi; }
role_set() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" >"$ROLE_FILE" 2>/dev/null || true
}

# ---- privileges and tools ----------------------------------------------------------------------------
iran_require_root() {
  if is_dry || [[ $EUID -eq 0 || ${GM_ASSUME_ROOT:-0} == 1 ]]; then return 0; fi
  act_fail "run as root (or use --dry-run)"
}

pkg_of() {
  case $1 in
    dig) echo dnsutils ;; ss) echo iproute2 ;; nc) echo netcat-openbsd ;; systemctl) echo systemd ;;
    base64 | sha256sum | stat | tac | mktemp) echo coreutils ;; *) echo "$1" ;;
  esac
}

# need_cmds cmd...   (inside an action) offers apt-get for what is missing, otherwise fails clearly
need_cmds() {
  local c missing=() pkgs=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]} == 0)); then return 0; fi
  for c in "${missing[@]}"; do pkgs+=("$(pkg_of "$c")"); done
  ui_warn "missing commands: ${missing[*]}"
  if is_dry; then dry_say "would offer: apt-get install -y ${pkgs[*]}"; return 0; fi
  if command -v apt-get >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
    confirm "Install the missing packages now (apt-get install -y ${pkgs[*]})?" \
      || act_fail "missing commands: ${missing[*]}"
    must apt-get install -y "${pkgs[@]}"
    for c in "${missing[@]}"; do command -v "$c" >/dev/null 2>&1 || act_fail "$c is still missing after installing"; done
    return 0
  fi
  act_fail "missing commands: ${missing[*]} - install with: apt-get install -y ${pkgs[*]}"
}

valid_ipv4() { v_ipv4 "$1" >/dev/null 2>&1; }
