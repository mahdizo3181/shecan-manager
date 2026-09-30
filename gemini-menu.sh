#!/usr/bin/env bash
# gemini-menu.sh - interactive menu + CLI for "Gemini via Iran-side Shecan".
#
# One self-contained file for BOTH servers:
#   Iran server     (service xray-gemini)  - the relay that talks to Shecan
#   Foreign server  (3X-UI panel + Xray)   - routes the 9 Gemini hostnames to the relay
# It is also the engine behind setup-iran.sh and setup-foreign.sh (thin wrappers).
#
# Run it with no arguments for the menu, or use a subcommand:
#   gemini-menu.sh [flags] [iran|foreign] <command> [args]
# Run `gemini-menu.sh help` for the list.

set -Euo pipefail        # no -e here: menus must survive failing commands; actions run under run_action (errexit inside)
umask 077
export LC_ALL=C

# ---------------------------------------------------------------- constants --
# The 9 Gemini hostnames. Always used as full: matches. This is only the seed list:
# once installed, the live config (Iran config.json / foreign template rule) is the source of truth.
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
# Background/push hosts that learn mode never offers (exact names); gvt1.com is matched as a suffix.
LEARN_SKIP_HOSTS=(mtalk.google.com android.clients.google.com play.googleapis.com firebaseinstallations.googleapis.com www.googleapis.com accounts.google.com)
LEARN_SKIP_SUFFIX=(gvt1.com)
# GM_SHECAN_DNS is a test hook only (lets a test rig resolve through another server).
read -r -a SHECAN_DNS <<<"${GM_SHECAN_DNS:-178.22.122.101 185.51.200.1}"
PROBE_DOMAIN=gemini.google.com
SS_METHOD=2022-blake3-aes-128-gcm
TAG=ir-gemini                 # foreign: name of the outbound
OFF_MARK=__gemini_off__       # foreign: inboundTag prefix that makes a rule match nothing (= switched off)

# GM_ROOT prefixes every path this tool writes. It is empty on a real server; tests point it at a fixture.
GM_ROOT=${GM_ROOT:-}
SVC=xray-gemini
BIN=$GM_ROOT/usr/local/bin/xray-gemini
CONF_DIR=$GM_ROOT/usr/local/etc/xray-gemini
CONF=$CONF_DIR/config.json
SYSTEMD_DIR=$GM_ROOT/etc/systemd/system
UNIT=$SYSTEMD_DIR/$SVC.service
STATE_DIR=$GM_ROOT/etc/gemini-shecan
URL_FILE=$STATE_DIR/shecan-url          # stored Shecan registration URL (secret, 600)
WATCH_CONF=$STATE_DIR/watch.conf        # non-secret settings for the health timer
WATCH_ENV=$STATE_DIR/watch.env          # TG_BOT / TG_CHAT (secret, 600)
WATCH_BIN=$GM_ROOT/usr/local/sbin/gemini-shecan-watch
WATCH_SVC=gemini-shecan-watch
REVERT_UNIT=gemini-access-revert
DEFAULT_KEY_FILE=$GM_ROOT/root/gemini-shecan/ss.key
BACKUP_ROOT=${BACKUP_ROOT:-$GM_ROOT/root/gemini-shecan-backup}
FW_COMMENT=gemini-shecan
WATCH_STATE=${GM_ROOT:-}/run/gemini-shecan-watch.state
LOG_FILE=$GM_ROOT/var/log/gemini-menu.log
MENU_STATE=$GM_ROOT/var/lib/gemini-menu/state     # small key=value cache (last test, prompts); no secrets
INSTALL_PATH=$GM_ROOT/usr/local/bin/gemini-menu

# ------------------------------------------------------------------- state --
ROLE=""                # iran | foreign
ROLE_LABEL="?"
DRY=0
YES=0
HINTS=1                # Persian hints in menus (toggle with L)
MANIFEST=""            # iran.manifest | foreign.manifest, set from ROLE
BK=""                  # backup dir of this run, created lazily on the first change
STEP_NAME=""
STEP_START=0
CHANGED=0              # set by put_file
RESTART_NEEDED=0
TMP=""
APPLIED=0              # foreign: 1 once the DB has been modified in this run
BACKUP_DIR_ARG=""
# iran
FOREIGN_IP=${FOREIGN_IP:-}
SS_PORT=${SS_PORT:-20443}
KEY_FILE_ARG=""
KEY_SRC=""
SHECAN_URL_FILE_ARG=""
XRAY_VERSION=latest
XRAY_BIN_SRC=""
XRAY_CHECK_BIN=""
SS_KEY_VAL=""
FW_KIND=none
NEW_URL=""
SHECAN_URL_SRC=""
REG_RC=0
VERIFY_MSG=""
FORM_OK=""
# foreign
IRAN_IP=${IRAN_IP:-}
KEY_FILE=${KEY_FILE:-}
KEY_VAL=""
DB=${XUI_DB:-}
XRAY_BIN=""
XRAY_DIR=""
RESTART_CMD="systemctl restart x-ui"
FIX_SNIFFING=0
ALL_DOMAINS=0
QUICK=0
RESTORE_FULL_DB=0
NC_OK=0
SNIFF_FLAGGED=0

# ================================================================ common ====
IS_TTY=0; if [[ -t 1 ]]; then IS_TTY=1; fi
C_R="" C_G="" C_Y="" C_B="" C_D="" C_N=""
ui_colors() {
  if [[ -z ${NO_COLOR:-} && $IS_TTY == 1 && ${TERM:-dumb} != dumb ]]; then
    C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1m' C_D=$'\e[2m' C_N=$'\e[0m'
  else
    C_R="" C_G="" C_Y="" C_B="" C_D="" C_N=""
  fi
}

log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
warn() { printf '[%s] %sWARNING:%s %s\n' "$(date +%T)" "$C_Y" "$C_N" "$*" >&2; }
dry()  { printf '%s[dry-run]%s %s\n' "$C_Y" "$C_N" "$*"; }
now()  { date +%s; }

die() {
  trap - ERR INT
  printf '%sERROR: %s%s\n' "$C_R" "$*" "$C_N" >&2
  if [[ -n $STEP_NAME && -n $BK && $DRY != 1 ]]; then
    warn "rolling back step: $STEP_NAME"
    replay_manifest "$STEP_START" || true
  fi
  if [[ $APPLIED == 1 && -n $BK ]]; then
    warn "rolling back the change made in this run"
    APPLIED=0
    restore_from_backup || warn "automatic rollback failed - restore it from the Backups menu"
  fi
  exit 1
}

cleanup() {
  if [[ $IS_TTY == 1 ]]; then stty sane 2>/dev/null || true; fi
  if [[ -n $TMP ]]; then rm -rf "$TMP"; fi
}
on_int() { trap - INT; printf '\n%sInterrupted - bye.%s\n' "$C_Y" "$C_N"; exit 130; }

# Append one line to the tool's own log. Never pass secrets to it.
audit_log() {
  { mkdir -p "$(dirname "$LOG_FILE")" && printf '%s %s %s %s\n' "$(date '+%F %T')" "${ROLE:-?}" "${SUDO_USER:-${USER:-root}}" "$*" >>"$LOG_FILE" && chmod 600 "$LOG_FILE"; } 2>/dev/null || true
}

# Tiny key=value cache (last test result, one-time prompts). No secrets.
state_get() { if [[ -r $MENU_STATE ]]; then sed -n "s/^$1=//p" "$MENU_STATE" | tail -n 1; fi; }
state_set() {
  mkdir -p "$(dirname "$MENU_STATE")" 2>/dev/null || return 0
  { if [[ -f $MENU_STATE ]]; then grep -v "^$1=" "$MENU_STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$MENU_STATE.tmp" 2>/dev/null \
    && mv -f "$MENU_STATE.tmp" "$MENU_STATE" 2>/dev/null || true
}
fmt_age() {  # seconds -> "5 min ago"
  local s=$1
  if ((s < 90)); then echo "${s}s ago"
  elif ((s < 5400)); then echo "$((s / 60)) min ago"
  elif ((s < 172800)); then echo "$((s / 3600)) h ago"
  else echo "$((s / 86400)) days ago"; fi
}

# ---------------------------------------------------------------- prompts --
need_tty() { [[ -t 0 ]] || die "this needs a terminal for confirmation - run it interactively or pass --yes"; }

ask_yn() {  # ask_yn "Question"  -> 0 = yes
  if [[ $YES == 1 ]]; then return 0; fi
  need_tty
  local a
  printf '%s [y/N] ' "$1"
  IFS= read -rsn1 a || a=n
  printf '%s\n' "$a"
  [[ $a == [yY] ]]
}
confirm() { ask_yn "$1"; }
ask_opt() {  # an optional extra: --yes means "skip it" (only explicit answers at a terminal enable it)
  if [[ $YES == 1 ]]; then return 1; fi
  ask_yn "$1"
}

ask_typed() {  # ask_typed "What happens"  -> the word "yes" must be typed
  if [[ $YES == 1 ]]; then return 0; fi
  need_tty
  local a
  printf '%s\n' "$1"
  IFS= read -r -p "  Type the word yes to continue (anything else cancels): " a || a=""
  [[ $a == yes ]]
}

ask_typed_force() {  # like ask_typed but --yes can NOT skip it (used before printing a secret)
  need_tty
  local a
  printf '%s\n' "$1"
  IFS= read -r -p "  Type the word yes to continue (anything else cancels): " a || a=""
  [[ $a == yes ]]
}

ask_line() {  # ask_line VAR "Prompt" [default]
  local __v d=${3:-}
  need_tty
  if [[ -n $d ]]; then printf '%s [%s]: ' "$2" "$d"; else printf '%s: ' "$2"; fi
  IFS= read -r __v || __v=""
  printf -v "$1" '%s' "${__v:-$d}"
}

read_secret() {  # read_secret VAR "Prompt"   (hidden input, never echoed)
  local __v
  need_tty
  printf '%s (hidden): ' "$2"
  IFS= read -rs __v || __v=""
  printf '\n'
  printf -v "$1" '%s' "$__v"
}

mask_key() {  # show only the last 4 characters of the key (without base64 '=' padding)
  local k=${1%%=*}
  if ((${#k} < 8)); then echo "****"; else echo "************${k: -4}"; fi
}

ui_key() {  # one key, no Enter needed; arrow/escape sequences are swallowed
  local k=""
  IFS= read -rsn1 k || k=q
  if [[ $k == $'\e' ]]; then read -rsn2 -t 0.05 _ || true; k=""; fi
  printf '%s' "$k"
}
ui_pause() { printf '\n  Press any key to go back... '; IFS= read -rsn1 _ || true; printf '\n'; }

# --------------------------------------------------------------- screens --
ui_clear() { if [[ $IS_TTY == 1 ]]; then printf '\e[H\e[2J'; else printf '\n'; fi; }
ui_hr() { printf '%s\n' "------------------------------------------------------------------------------"; }
ui_screen() {  # ui_screen "Title"
  ui_clear
  printf '%s GEMINI-SHECAN | %s | %s%s\n' "$C_B" "$ROLE_LABEL" "$1" "$C_N"
  if [[ $DRY == 1 ]]; then printf '%s *** DRY-RUN: nothing will be changed ***%s\n' "$C_Y" "$C_N"; fi
  ui_hr
}
mi() {  # mi KEY "English label" "persian hint"
  if [[ $HINTS == 1 && -n ${3:-} ]]; then printf ' %s) %-30s (%s)\n' "$1" "$2" "$3"; else printf ' %s) %s\n' "$1" "$2"; fi
}
ui_footer() {  # ui_footer "0 Back" ...
  local dmark="off"; if [[ $DRY == 1 ]]; then dmark="ON"; fi
  printf ' %s\n' "$1   D) Dry-run [$dmark]   L) Hints   r) Refresh"
}

# Status lines: level = ok | warn | fail | info
st_line() {
  case $1 in
    ok)   printf ' %s[OK]  %s %s\n' "$C_G" "$C_N" "$2" ;;
    warn) printf ' %s[WARN]%s %s\n' "$C_Y" "$C_N" "$2" ;;
    fail) printf ' %s[FAIL]%s %s\n' "$C_R" "$C_N" "$2" ;;
    *)    printf ' %s[..]  %s %s\n' "$C_D" "$C_N" "$2" ;;
  esac
}
CHK_LVL=(); CHK_TXT=(); CHK_HINT=()
chk_reset() { CHK_LVL=(); CHK_TXT=(); CHK_HINT=(); }
chk() { CHK_LVL+=("$1"); CHK_TXT+=("$2"); CHK_HINT+=("${3:-}"); }
chk_render() {  # chk_render [verbose]: verbose adds the "what to do" line under every problem
  local i
  for i in "${!CHK_LVL[@]}"; do
    st_line "${CHK_LVL[i]}" "${CHK_TXT[i]:0:68}"
    if [[ ${1:-} == verbose && ${CHK_LVL[i]} != ok && -n ${CHK_HINT[i]} ]]; then printf '          -> %s\n' "${CHK_HINT[i]}"; fi
  done
}
chk_worst() {  # 0 ok, 1 warn, 2 fail
  local l w=0
  for l in "${CHK_LVL[@]}"; do
    if [[ $l == fail ]]; then w=2; elif [[ $l == warn && $w -lt 1 ]]; then w=1; fi
  done
  return "$w"
}

# Multi-select list. Fill MS_LABEL[] and MS_SEL[] (0/1) first; selection comes back in MS_SEL[].
# Returns 0 on "done", 1 on cancel.
ui_multiselect() {  # ui_multiselect "Title" "help line"
  local page=0 per=10 n=${#MS_LABEL[@]} pages line tok i a b
  pages=$(((n + per - 1) / per)); if ((pages < 1)); then pages=1; fi
  while true; do
    ui_screen "$1"
    printf ' %s\n\n' "$2"
    for ((i = page * per; i < n && i < (page + 1) * per; i++)); do
      printf ' %3d [%s] %s\n' "$((i + 1))" "$([[ ${MS_SEL[i]} == 1 ]] && echo x || echo ' ')" "${MS_LABEL[i]:0:66}"
    done
    printf '\n page %d/%d | numbers toggle (1 3 5-7) | a=all z=none f=next b=back d=done 0=cancel\n > ' "$((page + 1))" "$pages"
    IFS= read -r line || return 1
    for tok in $line; do
      case $tok in
        0) return 1 ;;
        d|D) return 0 ;;
        a|A) for i in "${!MS_SEL[@]}"; do MS_SEL[i]=1; done ;;
        z|Z) for i in "${!MS_SEL[@]}"; do MS_SEL[i]=0; done ;;
        f|F) if ((page + 1 < pages)); then page=$((page + 1)); fi ;;
        b|B) if ((page > 0)); then page=$((page - 1)); fi ;;
        [0-9]*-[0-9]*) a=${tok%-*}; b=${tok#*-}
             for ((i = a; i <= b && i <= n; i++)); do if ((i >= 1)); then MS_SEL[i - 1]=$((1 - MS_SEL[i - 1])); fi; done ;;
        [0-9]*) if ((tok >= 1 && tok <= n)); then MS_SEL[tok - 1]=$((1 - MS_SEL[tok - 1])); fi ;;
      esac
    done
  done
}

# ------------------------------------------------------------- validation --
valid_ipv4() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && python3 -c 'import ipaddress,sys;ipaddress.IPv4Address(sys.argv[1])' "$1" 2>/dev/null; }
norm_host() {  # lower-case, strip full:/scheme/path
  local h=${1,,}
  h=${h#full:}; h=${h#https://}; h=${h#http://}; h=${h%%/*}; h=${h%.}
  printf '%s' "$h"
}
valid_host() { [[ ${#1} -le 253 && $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }

# --------------------------------------------------------- dependencies ----
pkg_of() {
  case $1 in
    dig) echo dnsutils ;; ss) echo iproute2 ;; nc) echo netcat-openbsd ;; systemctl) echo systemd ;;
    base64|sha256sum|stat|tac|mktemp) echo coreutils ;; *) echo "$1" ;;
  esac
}
need_cmds() {
  local c missing=() pkgs=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]} == 0)); then return 0; fi
  for c in "${missing[@]}"; do pkgs+=("$(pkg_of "$c")"); done
  warn "missing commands: ${missing[*]}"
  if [[ $DRY == 1 ]]; then dry "would offer: apt-get install -y ${pkgs[*]}"; return 0; fi
  if command -v apt-get >/dev/null 2>&1 && [[ $EUID -eq 0 ]] && ask_yn "Install the missing packages now (apt-get install -y ${pkgs[*]})?"; then
    apt-get install -y "${pkgs[@]}" || die "apt-get failed"
    for c in "${missing[@]}"; do command -v "$c" >/dev/null 2>&1 || die "$c is still missing after installing"; done
    return 0
  fi
  die "missing commands: ${missing[*]} - install with: apt-get install -y ${pkgs[*]}"
}

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# ------------------------------------------------------------ run actions --
# Every action runs in a subshell with errexit + an ERR trap, so a failure (or Ctrl-C) rolls the
# current step back and only ends the action, never the menu.
run_action() {
  (
    set -eE
    trap 'die "unexpected error in: $BASH_COMMAND"' ERR
    trap 'die "interrupted - the step in progress was rolled back"' INT
    "$@"
  )
}
do_action() {  # do_action "label" func [args...]  -> prints exactly one result line
  local label=$1 rc
  shift
  echo
  run_action "$@"
  rc=$?
  echo
  if ((rc == 0)); then
    printf '%sRESULT: OK - %s%s\n' "$C_G" "$label" "$C_N"
  elif ((rc == 10)); then
    printf '%sRESULT: cancelled - %s (nothing was changed)%s\n' "$C_Y" "$label" "$C_N"
  else
    printf '%sRESULT: FAILED - %s (nothing half-applied; details above)%s\n' "$C_R" "$label" "$C_N"
  fi
  audit_log "$label rc=$rc dry=$DRY"
  return "$rc"
}

# ===================================================== iran: engine ====
# iran engine (moved from the original script)

# ---------------------------------------------- backup + rollback manifest --
bk_dir() {
  if [[ -z $BK ]]; then
    BK=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BK/files"
    chmod 700 "$BACKUP_ROOT" "$BK" "$BK/files"
  fi
}

manifest_add() { bk_dir; printf '%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" >>"$BK/$MANIFEST"; }

manifest_lines() { if [[ -n $BK && -f $BK/$MANIFEST ]]; then wc -l <"$BK/$MANIFEST"; else echo 0; fi; }

begin_step() {
  STEP_NAME=$1
  STEP_START=$(manifest_lines)
  log "== $1"
}

end_step() { STEP_NAME=""; }

# Record + back up a file that is about to be created/replaced.
backup_file() {
  local p=$1 safe
  if [[ -e $p ]]; then
    bk_dir
    safe=$BK/files/$(printf '%s' "$p" | tr '/' '_')
    cp -p -- "$p" "$safe"
    manifest_add F_BAK "$p" "$safe"
  else
    manifest_add F_NEW "$p"
  fi
}

# put_file PATH MODE OWNER:GROUP  (content on stdin). Sets CHANGED=1|0.
# Identical content is left alone (idempotent); otherwise the old file is backed up.
put_file() {
  local path=$1 mode=$2 owner=${3:-root:root} t
  CHANGED=0
  if [[ $DRY == 1 ]]; then
    cat >/dev/null
    dry "would write $path (mode $mode)"
    CHANGED=1
    return 0
  fi
  t=$(mktemp -p "$(dirname "$path")" .gs.XXXXXX)
  cat >"$t"
  if [[ -f $path ]] && cmp -s "$t" "$path"; then
    rm -f "$t"
    chmod "$mode" "$path"; chown "$owner" "$path"
    return 0
  fi
  backup_file "$path"
  chmod "$mode" "$t"; chown "$owner" "$t"
  mv -f "$t" "$path"
  CHANGED=1
}

mkdir_tracked() {  # PATH MODE OWNER:GROUP
  if [[ -d $1 ]]; then return 0; fi
  if [[ $DRY == 1 ]]; then dry "would create directory $1"; return 0; fi
  mkdir -p "$1"; chmod "$2" "$1"; chown "${3:-root:root}" "$1"
  manifest_add DIR_NEW "$1"
}

undo_op() {
  case $1 in
    F_NEW)    if [[ $2 != "$DEFAULT_KEY_FILE" && $2 != "${KEY_FILE:-}" ]]; then rm -f -- "$2"; fi ;;
    F_BAK)    cp -p -- "$3" "$2" ;;
    DIR_NEW)  rmdir --ignore-fail-on-non-empty -- "$2" 2>/dev/null || true ;;
    SVC)      systemctl disable --now "$2" >/dev/null 2>&1 || true ;;
    USER_NEW) userdel "$2" >/dev/null 2>&1 || true ;;
    FW)       fw_remove "$2" "${3%%:*}" "${3##*:}" || true ;;
    FW_DEL)   fw_ensure "$2" "${3%%:*}" "${3##*:}" >/dev/null || true ;;
    *)        warn "unknown manifest op: $1" ;;
  esac
}

# Undo everything recorded after the first $1 lines of this run's manifest.
replay_manifest() {
  local from=$1 mf=$BK/$MANIFEST op a b
  [[ -s $mf ]] || return 0
  tail -n +"$((from + 1))" "$mf" | tac | while IFS=$'\t' read -r op a b; do
    log "undo: $op ${a:-}"
    undo_op "$op" "${a:-}" "${b:-}"
  done
  head -n "$from" "$mf" >"$mf.tmp" && mv -f "$mf.tmp" "$mf"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -f $UNIT && -f $CONF ]]; then systemctl restart "$SVC" >/dev/null 2>&1 || true; fi
}

# ---------------------------------------------------------------- firewall --
# All firewall changes are additive: one ACCEPT rule for FOREIGN_IP -> SS_PORT/tcp,
# tagged with a comment so it can be found and removed again. Existing rules are
# never flushed, edited or reordered.
nft_py() {  # nft_py targets|ours   (reads `nft -j list ruleset` from stdin)
  python3 -c '
import json, sys
mode, tag = sys.argv[1], sys.argv[2]
want_ip = sys.argv[3] if len(sys.argv) > 3 else ""
items = json.load(sys.stdin).get("nftables", [])
chains = {}
for it in items:
    if "chain" in it:
        c = it["chain"]; chains[(c["family"], c["table"], c["name"])] = {"c": c, "rules": []}
for it in items:
    if "rule" in it:
        r = it["rule"]; k = (r["family"], r["table"], r["chain"])
        if k in chains: chains[k]["rules"].append(r)
for (fam, tab, name), d in chains.items():
    c, rules = d["c"], d["rules"]
    if mode == "ours":
        for r in rules:
            if r.get("comment") == tag and (not want_ip or ("\"" + want_ip + "\"") in json.dumps(r.get("expr"))):
                print(fam, tab, name, r["handle"])
        continue
    if fam not in ("inet", "ip") or c.get("hook") != "input" or c.get("type") != "filter": continue
    if tab.startswith("f2b"): continue          # fail2ban table, leave alone
    drops = c.get("policy") == "drop"
    if rules:                                   # unconditional final drop/reject
        ex = rules[-1].get("expr", [])
        if not any("match" in e for e in ex) and any(("drop" in e) or ("reject" in e) for e in ex): drops = True
    if drops: print(fam, tab, name)
' "$1" "$FW_COMMENT" "${2:-}"
}

fw_detect() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw; return; fi
  if command -v nft >/dev/null 2>&1; then
    local rs; rs=$(nft list ruleset 2>/dev/null || true)
    if grep -q '^table inet' <<<"$rs" && grep -q 'hook input' <<<"$rs"; then echo nft; return; fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    local n pol
    n=$(iptables -S INPUT 2>/dev/null | wc -l || true)
    pol=$(iptables -S INPUT 2>/dev/null | awk '$1=="-P"{print $3}' || true)
    if [[ $n -gt 1 || $pol == DROP ]]; then echo iptables; return; fi
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then echo nft; return; fi
  echo none
}

# fw_ensure KIND IP PORT -> prints "added" or "present" or "n/a"
fw_ensure() {
  local kind=$1 ip=$2 port=$3
  case $kind in
    ufw)
      if ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW[[:space:]]+${ip//./\\.}([[:space:]]|\$)"; then echo present; return; fi
      ufw allow proto tcp from "$ip" to any port "$port" comment "$FW_COMMENT" >/dev/null
      echo added ;;
    iptables)
      local spec=(-s "$ip" -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT)
      if iptables -C INPUT "${spec[@]}" 2>/dev/null; then echo present; return; fi
      iptables -I INPUT 1 "${spec[@]}"
      echo added ;;
    nft)
      local out t fam tab chain any_added=0 any=0
      out=$(nft -j list ruleset | nft_py targets)
      while read -r fam tab chain; do
        [[ -n ${fam:-} ]] || continue
        any=1
        if nft -j list chain "$fam" "$tab" "$chain" | nft_py ours "$ip" | grep -q .; then continue; fi
        printf 'insert rule %s %s %s ip saddr %s tcp dport %s counter accept comment "%s"\n' \
          "$fam" "$tab" "$chain" "$ip" "$port" "$FW_COMMENT" | nft -f -
        any_added=1
      done <<<"$out"
      if [[ $any == 0 ]]; then echo n/a; elif [[ $any_added == 1 ]]; then echo added; else echo present; fi ;;
    *) echo n/a ;;
  esac
}

fw_remove() {
  local kind=$1 ip=$2 port=$3
  case $kind in
    ufw)      ufw --force delete allow proto tcp from "$ip" to any port "$port" >/dev/null 2>&1 || true ;;
    iptables) while iptables -D INPUT -s "$ip" -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; do :; done ;;
    nft)
      local fam tab chain h
      nft -j list ruleset | nft_py ours "$ip" | while read -r fam tab chain h; do
        nft delete rule "$fam" "$tab" "$chain" handle "$h" || true
      done ;;
  esac
}

# shecan_register FILE - the URL is fed to curl through stdin (-K -) so it never
# shows up in `ps`; output and stderr are discarded so it is never logged.
shecan_register() {
  local url; url=$(<"$1")
  url=${url//[$'\r\n\t ']/}
  url=${url//\\/\\\\}; url=${url//\"/\\\"}
  REG_RC=0
  printf 'url = "%s"\n' "$url" | curl -4 -fsS --max-time 10 -o /dev/null -K - >/dev/null 2>&1 || REG_RC=$?
  return "$REG_RC"
}

dns_a() {  # dns_a RESOLVER NAME -> sorted unique IPv4 answers
  dig +short +time=4 +tries=1 -4 @"$1" A "$2" 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true
}

# The Shecan resolver must return an address that a neutral resolver does not.
verify_hijack() {
  local s n r
  s=$(dns_a "${SHECAN_DNS[0]}" "$PROBE_DOMAIN")
  if [[ -z $s ]]; then VERIFY_MSG="Shecan DNS ${SHECAN_DNS[0]} returned no A record for $PROBE_DOMAIN (IP not registered / not allowed?)"; return 1; fi
  n=""
  for r in ${NEUTRAL_DNS:-1.1.1.1 8.8.8.8 9.9.9.9}; do
    n=$(dns_a "$r" "$PROBE_DOMAIN")
    if [[ -n $n ]]; then break; fi
  done
  if [[ -z $n ]]; then VERIFY_MSG="no neutral resolver answered, cannot compare with Shecan's answer"; return 1; fi
  if [[ -n $(comm -12 <(printf '%s\n' "$s") <(printf '%s\n' "$n")) ]]; then
    VERIFY_MSG="Shecan DNS answered the same address as a neutral resolver - the hijack is NOT active"
    return 1
  fi
  VERIFY_MSG="ok (shecan: $(tr '\n' ' ' <<<"$s")vs neutral: $(tr '\n' ' ' <<<"$n"))"
}

# ---------------------------------------------------------------- xray -----
xray_ver() { "$1" version 2>/dev/null | awk 'NR==1{print $2}'; }

xray_test_bin() {  # xray_test_bin BIN CONFIG -> 0 if accepted; message in $TMP/xtest.out
  "$1" run -test -config "$2" >"$TMP/xtest.out" 2>&1 || "$1" -test -config "$2" >"$TMP/xtest.out" 2>&1
}

# gen_config FORM  (FORM = sockopt | settings: where freedom's domainStrategy lives)
gen_config() {
  GC_FORM=$1 GC_KEY=$SS_KEY_VAL GC_PORT=$SS_PORT GC_METHOD=$SS_METHOD \
  GC_DOMAINS="${GEMINI_DOMAINS[*]}" GC_DNS="${SHECAN_DNS[*]}" python3 - <<'PY'
import json, os
e = os.environ
doms = ["full:" + d for d in e["GC_DOMAINS"].split()]
direct = {"tag": "direct", "protocol": "freedom", "settings": {}}
if e["GC_FORM"] == "sockopt":       # newer Xray
    direct["streamSettings"] = {"sockopt": {"domainStrategy": "UseIPv4"}}
else:                               # older Xray
    direct["settings"] = {"domainStrategy": "UseIPv4"}
cfg = {
  "log": {"loglevel": "warning", "access": "none"},
  "inbounds": [{
    "tag": "from-de", "listen": "0.0.0.0", "port": int(e["GC_PORT"]), "protocol": "shadowsocks",
    "settings": {"method": e["GC_METHOD"], "password": e["GC_KEY"], "network": "tcp"}}],
  "outbounds": [direct, {"tag": "blocked", "protocol": "blackhole", "settings": {}}],
  "dns": {
    "tag": "dns_inbound", "queryStrategy": "UseIPv4", "disableFallbackIfMatch": True,
    "servers": [{"address": a, "port": 53, "domains": doms, "skipFallback": True, "timeoutMs": 4000}
                for a in e["GC_DNS"].split()] + ["localhost"]},
  "routing": {"domainStrategy": "AsIs", "rules": [
    {"type": "field", "inboundTag": ["dns_inbound"], "outboundTag": "direct"},
    {"type": "field", "domain": doms, "outboundTag": "direct"},
    # Catch-all: without it this port is an open proxy. Newer Xray rejects a rule that
    # has no matcher ("this rule has no effective fields"), so it matches every network.
    {"type": "field", "network": "tcp,udp", "outboundTag": "blocked"}]}}
print(json.dumps(cfg, indent=2))
PY
}

# ------------------------------------------------------------------ steps --
resolve_inputs() {
  [[ -n $FOREIGN_IP ]] || die "FOREIGN_IP is required (env or --foreign-ip)"
  python3 -c 'import ipaddress,sys;ipaddress.IPv4Address(sys.argv[1])' "$FOREIGN_IP" 2>/dev/null \
    || die "FOREIGN_IP must be an IPv4 address"
  [[ $SS_PORT =~ ^[0-9]+$ && $SS_PORT -ge 1 && $SS_PORT -le 65535 ]] || die "invalid SS_PORT: $SS_PORT"

  local key_file=${KEY_FILE_ARG:-$DEFAULT_KEY_FILE} src
  if [[ -n ${SS_KEY:-} ]]; then
    SS_KEY_VAL=$SS_KEY; src="env"
  elif [[ -n $KEY_FILE_ARG ]]; then
    [[ -r $KEY_FILE_ARG ]] || die "key file not readable: $KEY_FILE_ARG"
    SS_KEY_VAL=$(<"$KEY_FILE_ARG"); src="file"
  elif [[ -r $DEFAULT_KEY_FILE ]]; then
    SS_KEY_VAL=$(<"$DEFAULT_KEY_FILE"); src="file"
  else
    SS_KEY_VAL=$(openssl rand -base64 16); src=generated
  fi
  unset SS_KEY
  SS_KEY_VAL=${SS_KEY_VAL//[$'\r\n\t ']/}
  # 2022-blake3-aes-128-gcm needs exactly 16 random bytes, base64 encoded.
  [[ $(printf '%s' "$SS_KEY_VAL" | base64 -d 2>/dev/null | wc -c) == 16 ]] \
    || die "SS key is not base64 of 16 bytes (generate one with: openssl rand -base64 16)"
  KEY_FILE=$key_file
  KEY_SRC=$src
}

save_key_file() {
  # Only a generated or env-supplied key needs to be stored; a key read from a file already lives there.
  if [[ $KEY_SRC == file ]]; then return 0; fi
  mkdir_tracked "$(dirname "$KEY_FILE")" 700
  if [[ $DRY == 1 ]]; then dry "would store the SS key in $KEY_FILE (mode 600, key not shown)"; return 0; fi
  put_file "$KEY_FILE" 600 root:root < <(printf '%s\n' "$SS_KEY_VAL")
  log "SS key stored in $KEY_FILE"
}

resolve_shecan_url() {
  # Priority: env > --shecan-url-file > stored copy. Never printed.
  SHECAN_URL_SRC=""
  if [[ -n ${SHECAN_REGISTER_URL:-} ]]; then
    NEW_URL=$SHECAN_REGISTER_URL; SHECAN_URL_SRC="env"
  elif [[ -n $SHECAN_URL_FILE_ARG ]]; then
    [[ -r $SHECAN_URL_FILE_ARG ]] || die "cannot read $SHECAN_URL_FILE_ARG"
    NEW_URL=$(<"$SHECAN_URL_FILE_ARG"); SHECAN_URL_SRC="file"
  elif [[ -r $URL_FILE ]]; then
    NEW_URL=""; SHECAN_URL_SRC=stored
  elif [[ $DRY == 1 ]]; then
    warn "Shecan registration URL not provided (a real run needs SHECAN_REGISTER_URL or --shecan-url-file)"
    NEW_URL=""; SHECAN_URL_SRC=stored
  else
    die "Shecan registration URL missing: set SHECAN_REGISTER_URL or pass --shecan-url-file"
  fi
  unset SHECAN_REGISTER_URL
  NEW_URL=${NEW_URL//[$'\r\n\t ']/}
}

discover() {
  log "== Discovery (read-only)"
  echo "-- listening TCP sockets (ss -tlnp):"
  ss -tlnp 2>/dev/null || true
  echo "-- firewall:"
  local ufw_s=inactive nft_n=0 ipt_n=0
  if command -v ufw >/dev/null 2>&1; then ufw_s=$(ufw status 2>/dev/null | awk '/^Status:/{print $2}' || true); fi
  if command -v nft >/dev/null 2>&1; then nft_n=$(nft list ruleset 2>/dev/null | grep -c 'hook input' || true); fi
  if command -v iptables >/dev/null 2>&1; then ipt_n=$(iptables -S INPUT 2>/dev/null | wc -l || true); fi
  echo "   ufw: ${ufw_s:-not installed} | nftables input hooks: $nft_n | iptables INPUT lines: $ipt_n"
  FW_KIND=$(fw_detect)
  echo "   -> will use: $FW_KIND"
  echo "-- tunnel / proxy software that looks present:"
  local pat='gost|haproxy|socat|nginx|rathole|backhaul|frps|frpc|wstunnel|chisel|brook|sing-box|xray|x-ui|v2ray|hysteria|tuic|stunnel|udp2raw|ssh'
  local found
  found=$( { ss -tlnpH 2>/dev/null | grep -oE "\"($pat)[^\"]*\"" ; systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E "$pat" ; } | sort -u | tr '\n' ' ' || true)
  echo "   ${found:-none identified}"
  if command -v iptables >/dev/null 2>&1 && iptables -t nat -S 2>/dev/null | grep -Eq 'DNAT|REDIRECT'; then
    echo "   iptables NAT DNAT/REDIRECT rules present (possible kernel-level forwarder)"
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -Eq 'dnat|redirect'; then
    echo "   nftables dnat/redirect rules present (possible kernel-level forwarder)"
  fi
  echo "   (nothing above is modified by this script)"
}

check_port_free() {
  local line
  line=$(ss -tlnpH "sport = :$SS_PORT" 2>/dev/null || true)
  if [[ -z $line ]]; then return 0; fi
  if grep -q "\"$SVC\"" <<<"$line" || { systemctl is-active --quiet "$SVC" 2>/dev/null && [[ $(cfg_py port 2>/dev/null) == "$SS_PORT" ]]; }; then
    log "port $SS_PORT is used by our own $SVC (re-run) - ok"
    return 0
  fi
  die "TCP port $SS_PORT is already in use by something else - choose another with --ss-port:
$line"
}

step_install_xray() {
  begin_step "Install Xray as $BIN"
  local want=${XRAY_VERSION#v} cur="" cand="" asset url exp got
  if [[ -x $BIN ]]; then cur=$(xray_ver "$BIN" || true); fi

  if [[ -n $XRAY_BIN_SRC ]]; then
    [[ -x $XRAY_BIN_SRC ]] || die "--xray-bin is not an executable file: $XRAY_BIN_SRC"
    cand=$XRAY_BIN_SRC
  else
    if [[ -n $cur && ( $want == latest || $cur == "$want" ) ]]; then
      log "$BIN $cur already installed - keeping it"
      XRAY_CHECK_BIN=$BIN; end_step; return 0
    fi
    case $(uname -m) in
      x86_64|amd64)  asset=64 ;;
      aarch64|arm64) asset=arm64-v8a ;;
      armv7l)        asset=arm32-v7a ;;
      *) die "unsupported CPU architecture $(uname -m); use --xray-bin" ;;
    esac
    if [[ $want == latest ]]; then
      url=https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$asset.zip
    else
      url=https://github.com/XTLS/Xray-core/releases/download/v$want/Xray-linux-$asset.zip
    fi
    if [[ $DRY == 1 ]]; then
      dry "would download $url and verify its .dgst checksum"
      XRAY_CHECK_BIN=""; [[ -x $BIN ]] && XRAY_CHECK_BIN=$BIN
      end_step; return 0
    fi
    log "downloading $url"
    curl -fL --retry 2 --connect-timeout 10 --max-time 180 -o "$TMP/xray.zip" "$url" \
      || die "download failed (GitHub unreachable from this server?). Copy an Xray binary here and use --xray-bin PATH"
    if curl -fsSL --max-time 30 -o "$TMP/xray.dgst" "$url.dgst" 2>/dev/null; then
      exp=$(grep -i '256' "$TMP/xray.dgst" | grep -oE '[0-9a-f]{64}' | head -1 || true)
      got=$(sha256sum "$TMP/xray.zip" | awk '{print $1}')
      if [[ -z $exp ]]; then warn "could not read a SHA-256 from the .dgst file - archive is NOT checksum-verified"
      elif [[ $exp != "$got" ]]; then die "SHA-256 mismatch for the downloaded archive"
      else log "checksum ok"; fi
    else
      warn "no .dgst checksum file available - archive is NOT checksum-verified"
    fi
    python3 - "$TMP/xray.zip" "$TMP/xray" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
open(sys.argv[2], "wb").write(z.read("xray"))
PY
    chmod 755 "$TMP/xray"
    cand=$TMP/xray
  fi

  local cv; cv=$(xray_ver "$cand" || true)
  [[ -n $cv ]] || die "$cand does not run (wrong architecture?)"
  if [[ $want != latest && $cv != "$want" ]]; then
    die "Xray version mismatch: wanted $want, got $cv (the versions on both servers should match)"
  fi
  log "Xray $cv"
  XRAY_CHECK_BIN=$cand
  if [[ $DRY == 1 ]]; then dry "would install $cand as $BIN"; XRAY_CHECK_BIN=$cand; end_step; return 0; fi
  put_file "$BIN" 755 root:root <"$cand"
  if [[ $CHANGED == 1 ]]; then RESTART_NEEDED=1; fi
  XRAY_CHECK_BIN=$BIN
  end_step
}

step_service_user_and_config() {
  begin_step "Write config $CONF"
  if [[ $DRY == 1 ]]; then
    dry "would create system user $SVC (no login) if missing"
  elif ! id "$SVC" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC"
    manifest_add USER_NEW "$SVC"
  fi
  mkdir_tracked "$CONF_DIR" 750 "root:$SVC"

  gen_validate_config
  put_file "$CONF" 640 "root:$SVC" <"$TMP/config.json"
  if [[ $CHANGED == 1 ]]; then RESTART_NEEDED=1; fi
  end_step
}

step_service() {
  begin_step "systemd service $SVC"
  local unit_existed=0
  if [[ -f $UNIT ]]; then unit_existed=1; fi
  put_file "$UNIT" 644 root:root <<EOF
[Unit]
Description=Xray relay for Gemini via Shecan (gemini-shecan)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC
ExecStart=$BIN run -config $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  if [[ $CHANGED == 1 ]]; then RESTART_NEEDED=1; fi
  if [[ $DRY == 1 ]]; then dry "would enable and (re)start $SVC and wait for it to listen on $SS_PORT"; end_step; return 0; fi
  if [[ $unit_existed == 0 ]]; then manifest_add SVC "$SVC"; fi
  systemctl daemon-reload
  systemctl enable "$SVC" >/dev/null 2>&1
  if [[ $RESTART_NEEDED == 1 ]]; then systemctl restart "$SVC"; else systemctl start "$SVC"; fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$SVC" && [[ -n $(ss -tlnH "sport = :$SS_PORT") ]]; then
      log "$SVC is running and listening on $SS_PORT"; end_step; return 0
    fi
    sleep 1
  done
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null || true
  die "$SVC did not come up on port $SS_PORT"
}

step_firewall() {
  begin_step "Firewall: allow $SS_PORT/tcp from $FOREIGN_IP only ($FW_KIND)"
  if [[ $FW_KIND == none ]]; then
    warn "no active firewall detected - nothing to open. (If the provider has a cloud firewall, allow $SS_PORT/tcp from $FOREIGN_IP there.)"
    end_step; return 0
  fi
  if [[ $DRY == 1 ]]; then dry "would add one ACCEPT rule via $FW_KIND (existing rules untouched)"; end_step; return 0; fi
  local r; r=$(fw_ensure "$FW_KIND" "$FOREIGN_IP" "$SS_PORT")
  case $r in
    added)   manifest_add FW "$FW_KIND" "$FOREIGN_IP:$SS_PORT"; log "firewall rule added" ;;
    present) log "firewall rule already present" ;;
    n/a)     warn "no suitable input chain found for $FW_KIND (nothing drops traffic there?) - no rule added" ;;
  esac
  if [[ $FW_KIND == iptables || $FW_KIND == nft ]]; then
    log "note: this rule is runtime-only; the health timer re-adds it if the tunnel's firewall reload removes it"
  fi
  end_step
}

step_shecan() {
  begin_step "Shecan registration + DNS check"
  mkdir_tracked "$STATE_DIR" 700
  if [[ $DRY == 1 ]]; then
    dry "would store the registration URL in $URL_FILE (mode 600), call it with curl -4, then compare dig @${SHECAN_DNS[0]} $PROBE_DOMAIN with a neutral resolver"
    end_step; return 0
  fi
  if [[ $SHECAN_URL_SRC != stored ]]; then
    put_file "$URL_FILE" 600 root:root < <(printf '%s\n' "$NEW_URL")
    NEW_URL=""
  fi
  shecan_register "$URL_FILE" || die "Shecan registration call failed (curl exit code $REG_RC; URL not shown). Check the URL/token and that this server has IPv4 internet access."
  log "registration call succeeded"
  state_set last_register_ok "$(now)"
  local i
  for i in 1 2 3; do
    if verify_hijack; then log "Shecan DNS check: $VERIFY_MSG"; end_step; return 0; fi
    log "attempt $i/3: $VERIFY_MSG"
    sleep 5
  done
  die "Shecan DNS check failed: $VERIFY_MSG"
}

step_selftest() {
  begin_step "Self-test through $SVC (loopback)"
  if [[ $DRY == 1 ]]; then dry "would run a temporary loopback Xray client: $PROBE_DOMAIN must work, example.com must be refused"; end_step; return 0; fi
  local port pid code rc
  port=$(free_port)
  ST_PORT=$port ST_SS=$SS_PORT ST_KEY=$SS_KEY_VAL ST_METHOD=$SS_METHOD python3 - >"$TMP/client.json" <<'PY'
import json, os
e = os.environ
print(json.dumps({
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": int(e["ST_PORT"]), "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
  "outbounds": [{"tag": "to-relay", "protocol": "shadowsocks", "settings": {"servers": [
    {"address": "127.0.0.1", "port": int(e["ST_SS"]), "method": e["ST_METHOD"], "password": e["ST_KEY"]}]}}]}))
PY
  "$BIN" run -config "$TMP/client.json" >"$TMP/client.log" 2>&1 &
  pid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 "$port" 2>/dev/null && break; sleep 0.5; done
  rc=0
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -x "socks5h://127.0.0.1:$port" "https://$PROBE_DOMAIN/" 2>/dev/null) || rc=$?
  if [[ $rc != 0 || $code == 000 ]]; then
    kill "$pid" 2>/dev/null || true
    die "self-test failed: https://$PROBE_DOMAIN via the relay did not answer (curl exit $rc). DNS check passed, so look at: Shecan registration, outbound access to the Shecan proxy IPs, or $SVC logs (journalctl -u $SVC)"
  fi
  log "self-test: $PROBE_DOMAIN via relay -> HTTP $code (Shecan path works)"
  rc=0
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -x "socks5h://127.0.0.1:$port" "https://example.com/" 2>/dev/null) || rc=$?
  kill "$pid" 2>/dev/null || true
  if [[ $rc == 0 && $code != 000 ]]; then
    systemctl stop "$SVC" || true
    STEP_START=0   # undo this whole run
    die "SECURITY: the relay proxied https://example.com (HTTP $code) - it is an OPEN PROXY. $SVC has been stopped."
  fi
  log "self-test: a non-Gemini destination is refused (catch-all block works)"
  end_step
}

step_watch() {
  begin_step "Health timer $WATCH_SVC.timer (every 5 min)"
  local timer_existed=0
  if [[ -f $SYSTEMD_DIR/$WATCH_SVC.timer ]]; then timer_existed=1; fi
  if [[ $DRY == 1 ]]; then dry "would install $WATCH_BIN, $WATCH_SVC.service and $WATCH_SVC.timer"; end_step; return 0; fi
  mkdir_tracked "$STATE_DIR" 700
  local self; self=$(readlink -f "${BASH_SOURCE[0]}")
  [[ -r $self && -f $self ]] || die "cannot locate this script on disk to install the health timer (run it from a file, not via a pipe)"
  put_file "$WATCH_BIN" 755 root:root <"$self"

  put_file "$WATCH_CONF" 600 root:root < <(printf 'FOREIGN_IP=%q\nSS_PORT=%q\nFW_KIND=%q\n' "$FOREIGN_IP" "$SS_PORT" "$FW_KIND")
  if [[ -n ${TG_BOT:-} && -n ${TG_CHAT:-} ]]; then
    put_file "$WATCH_ENV" 600 root:root < <(printf 'TG_BOT=%q\nTG_CHAT=%q\n' "$TG_BOT" "$TG_CHAT")
    log "Telegram alerts configured (token not shown)"
  fi
  unset TG_BOT TG_CHAT

  put_file "$SYSTEMD_DIR/$WATCH_SVC.service" 644 root:root <<EOF
[Unit]
Description=gemini-shecan health check (re-register Shecan IP, verify DNS, check $SVC)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$WATCH_ENV
ExecStart=$WATCH_BIN watch
EOF
  put_file "$SYSTEMD_DIR/$WATCH_SVC.timer" 644 root:root <<EOF
[Unit]
Description=gemini-shecan health check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
  if [[ $timer_existed == 0 ]]; then manifest_add SVC "$WATCH_SVC.timer"; fi
  systemctl daemon-reload
  systemctl enable --now "$WATCH_SVC.timer" >/dev/null 2>&1
  log "timer active - results: journalctl -u $WATCH_SVC"
  end_step
}

# ------------------------------------------------------------- watch mode --
watch_main() {
  # shellcheck disable=SC1090
  source "$WATCH_CONF"
  local problems=() prev="" cur msg
  if [[ -r $URL_FILE ]]; then
    if shecan_register "$URL_FILE"; then log "shecan re-registration ok"; state_set last_register_ok "$(now)"
    else problems+=("Shecan re-registration failed (curl exit $REG_RC)"); fi
    sleep 2
  else
    problems+=("no stored Shecan URL ($URL_FILE)")
  fi
  if verify_hijack; then log "DNS hijack ok: $VERIFY_MSG"; else problems+=("DNS check: $VERIFY_MSG"); fi
  if systemctl is-active --quiet "$SVC"; then log "$SVC running"; else problems+=("$SVC is not running"); fi
  if [[ $FW_KIND == iptables || $FW_KIND == nft ]]; then
    case $(fw_ensure "$FW_KIND" "$FOREIGN_IP" "$SS_PORT" 2>/dev/null || echo error) in
      added)   log "firewall rule was missing and has been re-added" ;;
      error)   problems+=("firewall rule missing and could not be re-added") ;;
    esac
  fi

  [[ -r $WATCH_STATE ]] && prev=$(<"$WATCH_STATE")
  if ((${#problems[@]})); then
    cur=FAIL
    msg=$(printf '%s; ' "${problems[@]}")
    log "PROBLEM: $msg"
    if [[ $prev != FAIL ]]; then tg_send "gemini-shecan on $(hostname): $msg"; fi
    printf '%s' "$cur" >"$WATCH_STATE"
    exit 1
  fi
  if [[ $prev == FAIL ]]; then tg_send "gemini-shecan on $(hostname): recovered"; fi
  printf 'OK' >"$WATCH_STATE"
  log "all checks ok"
}

# ---------------------------------------------------------------- rollback --
iran_rollback_main() {
  local d mf="" cand
  if [[ -n $BACKUP_DIR_ARG ]]; then
    d=$BACKUP_DIR_ARG
  else
    d=""
    for cand in $(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r); do
      if [[ -s ${cand}$MANIFEST ]]; then d=${cand%/}; break; fi
    done
  fi
  [[ -n $d && -s $d/$MANIFEST ]] || die "no backup with a $MANIFEST found under $BACKUP_ROOT (nothing to roll back)"
  mf=$d/$MANIFEST
  log "rolling back run $(basename "$d")"
  awk -F'\t' '{printf "   %s %s\n", $1, $2}' "$mf"
  if [[ $DRY == 1 ]]; then dry "would undo the actions above (last to first)"; return 0; fi
  confirm "Undo these changes? This stops $SVC and removes the firewall rule it added" || die "aborted"
  BK=$d
  trap - ERR
  replay_manifest 0
  mv -f "$mf" "$mf.rolledback"
  log "rollback done. The SS key file (if any) and this backup dir were kept: $d"
}

tg_post() {  # tg_post TEXT  (TG_BOT / TG_CHAT from the environment) -> 0 if Telegram accepted it
  if [[ -z ${TG_BOT:-} || -z ${TG_CHAT:-} ]]; then return 1; fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' \
    "$TG_BOT" "$TG_CHAT" "$1" | curl -fsS --max-time 10 -o /dev/null -K - >/dev/null 2>&1
}
tg_send() {
  if [[ -z ${TG_BOT:-} || -z ${TG_CHAT:-} ]]; then return 0; fi
  tg_post "$1" || log "telegram alert could not be sent"
}

# ========================================================= iran: new code ====
# Facts about the installed relay, read from its config.json (never prints secrets).
cfg_py() {  # cfg_py port|key|domains|catchall|access
  python3 - "$1" "$CONF" <<'PY'
import json, sys
mode, path = sys.argv[1:3]
c = json.load(open(path))
if mode == "port":
    print(c["inbounds"][0]["port"])
elif mode == "key":
    print(c["inbounds"][0]["settings"]["password"])
elif mode == "domains":
    for r in c["routing"]["rules"]:
        if r.get("outboundTag") == "direct" and r.get("domain"):
            print("\n".join(d[5:] if d.startswith("full:") else d for d in r["domain"]))
            break
elif mode == "catchall":
    r = c["routing"]["rules"][-1]
    print("yes" if r.get("outboundTag") == "blocked" and not r.get("domain") and not r.get("inboundTag") else "no")
elif mode == "access":
    print("none" if c.get("log", {}).get("access") == "none" else "on")
PY
}

cfg_set_access() {  # cfg_set_access VALUE -> $TMP/config.json = installed config with log.access changed
  python3 - "$CONF" "$1" "$TMP/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.setdefault("log", {})["access"] = sys.argv[2]
open(sys.argv[3], "w").write(json.dumps(c, indent=2) + "\n")
PY
}

iran_installed() { [[ -f $UNIT && -f $CONF ]]; }

iran_load_runtime() {  # SS_PORT / FOREIGN_IP / FW_KIND from the installed files
  if [[ -r $WATCH_CONF ]]; then
    # shellcheck disable=SC1090
    . "$WATCH_CONF" || true
  fi
  if [[ -r $CONF ]]; then SS_PORT=$(cfg_py port 2>/dev/null || echo "$SS_PORT"); fi
}
iran_load_key() { SS_KEY_VAL=$(cfg_py key); }
iran_detect_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -n 1 || true; }

fw_present() {  # fw_present KIND IP PORT  (read-only)
  local kind=$1 ip=$2 port=$3
  case $kind in
    ufw)      ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW[[:space:]]+${ip//./\\.}([[:space:]]|\$)" ;;
    iptables) iptables -C INPUT -s "$ip" -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null ;;
    nft)      nft -j list ruleset 2>/dev/null | nft_py ours "$ip" | grep -q . ;;
    *)        return 1 ;;
  esac
}

iran_last_register() {  # epoch of the last successful registration (state file, else journal), or empty
  local t
  t=$(state_get last_register_ok)
  if [[ -z $t ]]; then
    t=$(journalctl -u "$WATCH_SVC" --no-pager -o short-unix 2>/dev/null | grep 're-registration ok' | tail -n 1 | cut -d. -f1 || true)
  fi
  [[ $t =~ ^[0-9]+$ ]] && printf '%s' "$t"
  return 0
}

iran_checks() {
  chk_reset
  if ! iran_installed; then
    chk fail "The relay is not installed on this server" "Press s for the guided setup."
    return 0
  fi
  iran_load_runtime
  local t until
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then chk ok "$SVC is running"
  else chk fail "$SVC is NOT running" "Service > Start. Logs > last 50 lines shows why it stopped."; fi

  if [[ -n $(ss -tlnH "sport = :$SS_PORT" 2>/dev/null) ]]; then chk ok "Port $SS_PORT is listening"
  else chk fail "Port $SS_PORT is NOT listening" "The relay is down, or the port is taken. Service > Restart."; fi

  if [[ $FW_KIND == none ]]; then
    chk warn "No firewall detected: port $SS_PORT is open to everyone" "The SS key is still required. A provider firewall for $FOREIGN_IP only would be safer."
  elif fw_present "$FW_KIND" "$FOREIGN_IP" "$SS_PORT"; then chk ok "Firewall: only $FOREIGN_IP may reach port $SS_PORT"
  else chk fail "Firewall rule for $FOREIGN_IP is missing" "Change allowed foreign IP (enter the same IP again) re-adds it."; fi

  if verify_hijack; then chk ok "Shecan DNS hijack works right now (live check)"
  else chk fail "Shecan DNS: ${VERIFY_MSG%% (*}" "Register this IP now. If it keeps failing, the Shecan URL/token may have expired."; fi

  t=$(iran_last_register)
  if [[ -z $t ]]; then chk warn "No successful Shecan registration recorded yet" "Register this IP now, or wait for the 5-minute timer."
  elif (($(now) - t > 1200)); then chk warn "Last registration: $(fmt_age $(($(now) - t)))" "The timer should do it every 5 min: check the timer line below."
  else chk ok "IP registered with Shecan $(fmt_age $(($(now) - t)))"; fi

  if systemctl is-active --quiet "$WATCH_SVC.timer" 2>/dev/null; then chk ok "Health timer is active (every 5 min)"
  else chk warn "Health timer is not active" "Service > Health timer on."; fi

  if [[ $(cfg_py catchall 2>/dev/null) == yes ]]; then chk ok "Relay refuses everything except the Gemini hosts"
  else chk fail "No catch-all block rule: the relay could be an OPEN PROXY" "Domain list > apply again, which rewrites the config safely."; fi

  until=$(state_get access_until)
  if [[ $(cfg_py access 2>/dev/null) == on ]]; then
    chk warn "Access log is ON${until:+ (auto-off in $(((until - $(now)) / 60 + 1)) min)}" "Logs > turn access log off now."
  fi
}

# Generate + validate the relay config for the current GEMINI_DOMAINS / SS_KEY_VAL / SS_PORT.
# Result: $TMP/config.json and FORM_OK (where this Xray wants freedom.domainStrategy).
gen_validate_config() {
  local form cfgtmp chk_bin=${XRAY_CHECK_BIN:-$BIN}
  FORM_OK=""
  if [[ ! -x $chk_bin ]]; then
    warn "no Xray binary to validate with yet (dry-run?): the config would be tested with 'xray run -test' on a real run"
    gen_config sockopt >"$TMP/config.json"; FORM_OK=sockopt; return 0
  fi
  for form in sockopt settings; do
    cfgtmp=$TMP/config.$form.json
    gen_config "$form" >"$cfgtmp"
    if xray_test_bin "$chk_bin" "$cfgtmp"; then FORM_OK=$form; cp "$cfgtmp" "$TMP/config.json"; break; fi
    warn "Xray rejected the '$form' form of freedom.domainStrategy: $(tail -n 1 "$TMP/xtest.out")"
  done
  [[ -n $FORM_OK ]] || die "Xray rejected every config variant; last error: $(tail -n 3 "$TMP/xtest.out")"
  log "config validated with 'xray run -test' (freedom.domainStrategy under: $FORM_OK)"
}

iran_restart_wait() {  # restart only the relay and wait until it listens again
  local i
  systemctl restart "$SVC"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$SVC" && [[ -n $(ss -tlnH "sport = :$SS_PORT") ]]; then return 0; fi
    sleep 1
  done
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null || true
  return 1
}

cancel() { printf '%sCancelled - nothing was changed.%s\n' "$C_Y" "$C_N"; exit 10; }

# ------------------------------------------------------------- iran actions --
iran_need_installed() {
  need_cmds python3 systemctl
  if [[ $DRY != 1 && $EUID -ne 0 ]]; then die "run as root (or use --dry-run)"; fi
  iran_installed || die "the relay is not installed here - run the guided setup first (menu: s)"
  iran_load_runtime
}

iran_health() { chk_reset; iran_checks; chk_render verbose; chk_worst || true; }

iran_ask_shecan_url() {
  local u=""
  read_secret u "Paste the Shecan registration URL"
  [[ -n $u ]] || die "empty URL"
  mkdir_tracked "$STATE_DIR" 700
  put_file "$URL_FILE" 600 root:root < <(printf '%s\n' "$u")
  u=""
}

iran_register_now() {
  iran_need_installed
  if [[ ! -r $URL_FILE ]]; then
    echo "No registration URL is stored yet."
    if [[ $DRY == 1 ]]; then dry "would ask for the Shecan URL (hidden) and store it in $URL_FILE (mode 600)"; else iran_ask_shecan_url; fi
  fi
  if [[ $DRY == 1 ]]; then dry "would call the registration URL (never shown) with curl -4, then check Shecan DNS against a neutral resolver"; return 0; fi
  ask_yn "Register this server's IP with Shecan now?" || cancel
  shecan_register "$URL_FILE" || die "registration call failed (curl exit $REG_RC; URL not shown). Check the URL/token and IPv4 internet access."
  state_set last_register_ok "$(now)"
  log "registration call succeeded - verifying..."
  local i
  for i in 1 2 3; do
    if verify_hijack; then log "Shecan DNS check: $VERIFY_MSG"; return 0; fi
    log "attempt $i/3: $VERIFY_MSG"
    sleep 5
  done
  die "registered, but the DNS check still fails: $VERIFY_MSG"
}

iran_info() {  # iran_info [reveal]
  iran_need_installed
  local ip keyf=$DEFAULT_KEY_FILE
  ip=$(iran_detect_ip)
  iran_load_key
  echo "  This server's IP : ${ip:-unknown}   (use the public IP that is registered with Shecan)"
  echo "  Relay port       : $SS_PORT/tcp"
  echo "  Method           : $SS_METHOD"
  echo "  Allowed from     : ${FOREIGN_IP:-unknown}"
  echo "  Key              : $(mask_key "$SS_KEY_VAL")   (last 4 characters only)"
  if [[ ! -r $keyf ]]; then
    echo "  Key file         : missing - the foreign server needs a file to read the key from"
    if [[ $DRY == 1 ]]; then dry "would save the key to $keyf (mode 600)"
    elif ask_yn "  Create $keyf from the installed config?"; then
      mkdir_tracked "$(dirname "$keyf")" 700
      put_file "$keyf" 600 root:root < <(printf '%s\n' "$SS_KEY_VAL")
    fi
  else
    echo "  Key file         : $keyf"
  fi
  echo
  echo "  On the FOREIGN server run these two commands:"
  echo "    scp root@${ip:-<IRAN_IP>}:$keyf /root/gemini-ss.key"
  echo "    gemini-menu foreign setup --iran-ip ${ip:-<IRAN_IP>} --key-file /root/gemini-ss.key$([[ $SS_PORT != 20443 ]] && echo " --ss-port $SS_PORT")"
  if [[ ${1:-} == reveal ]]; then iran_reveal_key; fi
}

iran_reveal_key() {  # prints the full key once, after a real typed "yes" (even with --yes)
  iran_need_installed
  iran_load_key
  ask_typed_force "The full key will be printed ONCE on this screen. Anyone looking at it can read it." || cancel
  printf '\n  KEY: %s\n\n  (not logged; it stays in your terminal scrollback - clear it after use)\n' "$SS_KEY_VAL"
  printf '  Press any key to clear the screen... '
  IFS= read -rsn1 _ || true
  ui_clear
}

iran_change_foreign_ip() {  # NEW_IP
  iran_need_installed
  local new=${1:-} old r
  valid_ipv4 "$new" || die "not a valid IPv4 address: ${new:-<empty>}"
  old=$FOREIGN_IP
  if [[ $new == "$old" ]]; then
    echo "Port $SS_PORT is already limited to $old."
    return 0
  fi
  echo "  Firewall ($FW_KIND): allow $SS_PORT/tcp from $new   (instead of $old)"
  echo "  Only the firewall rule changes; the relay config and tunnel are untouched."
  if [[ $DRY == 1 ]]; then dry "would add the rule for $new, remove the rule for $old, update $WATCH_CONF"; return 0; fi
  ask_yn "Apply?" || cancel
  begin_step "Firewall: allow $new instead of $old"
  if [[ $FW_KIND != none ]]; then
    r=$(fw_ensure "$FW_KIND" "$new" "$SS_PORT")
    if [[ $r == added ]]; then manifest_add FW "$FW_KIND" "$new:$SS_PORT"; fi
    manifest_add FW_DEL "$FW_KIND" "$old:$SS_PORT"
    fw_remove "$FW_KIND" "$old" "$SS_PORT"
  else
    warn "no active firewall: only the stored address changes. Update a provider firewall by hand."
  fi
  put_file "$WATCH_CONF" 600 root:root < <(printf 'FOREIGN_IP=%q\nSS_PORT=%q\nFW_KIND=%q\n' "$new" "$SS_PORT" "$FW_KIND")
  end_step
  log "now only $new may reach port $SS_PORT"
}

iran_domains_list() { iran_need_installed; cfg_py domains; }

iran_domains_apply() {  # iran_domains_apply host...   (the complete new list)
  iran_need_installed
  local -a new=("$@") old=()
  local d added=() removed=()
  ((${#new[@]} >= 1)) || die "the list cannot be empty"
  mapfile -t old < <(cfg_py domains)
  for d in "${new[@]}"; do if [[ " ${old[*]} " != *" $d "* ]]; then added+=("$d"); fi; done
  for d in "${old[@]}"; do if [[ " ${new[*]} " != *" $d "* ]]; then removed+=("$d"); fi; done
  if ((${#added[@]} + ${#removed[@]} == 0)); then echo "The list is already exactly this - nothing to change."; return 0; fi
  for d in "${added[@]}"; do echo "  + $d"; done
  for d in "${removed[@]}"; do echo "  - $d"; done
  echo "  Applies to Shecan DNS lookups AND routing in the relay config; only $SVC restarts."
  iran_load_key
  GEMINI_DOMAINS=("${new[@]}")
  gen_validate_config
  if [[ $DRY == 1 ]]; then dry "would write $CONF and restart $SVC"; return 0; fi
  ask_yn "Apply and restart $SVC (Gemini sessions reconnect in a second)?" || cancel
  begin_step "Domain list"
  put_file "$CONF" 640 "root:$SVC" <"$TMP/config.json"
  if [[ $CHANGED == 1 ]]; then iran_restart_wait || die "$SVC did not come back on port $SS_PORT"; fi
  end_step
  log "domain list updated (${#new[@]} hosts). The foreign server must route the same hosts."
}

iran_domain_add() {
  local h cur=() d
  h=$(norm_host "${1:-}")
  valid_host "$h" || die "not a valid hostname: ${1:-<empty>} (example: gemini.google.com)"
  iran_need_installed
  mapfile -t cur < <(cfg_py domains)
  for d in "${cur[@]}"; do if [[ $d == "$h" ]]; then echo "$h is already in the list."; return 0; fi; done
  iran_domains_apply "${cur[@]}" "$h"
}
iran_domain_remove() {
  local h cur=() d keep=()
  h=$(norm_host "${1:-}")
  iran_need_installed
  mapfile -t cur < <(cfg_py domains)
  for d in "${cur[@]}"; do if [[ $d != "$h" ]]; then keep+=("$d"); fi; done
  if ((${#keep[@]} == ${#cur[@]})); then echo "$h is not in the list."; return 0; fi
  iran_domains_apply "${keep[@]}"
}
iran_domain_set() {
  local d h list=()
  for d in "$@"; do h=$(norm_host "$d"); valid_host "$h" || die "not a valid hostname: $d"; list+=("$h"); done
  iran_domains_apply "${list[@]}"
}

iran_service() {  # start|stop|restart
  iran_need_installed
  local a=$1
  echo "  About to $a $SVC (Gemini requests through the relay pause while it is down)."
  if [[ $DRY == 1 ]]; then dry "would run: systemctl $a $SVC"; return 0; fi
  ask_yn "$a $SVC?" || cancel
  audit_log "service $a $SVC"
  if [[ $a == restart ]]; then iran_restart_wait || die "$SVC did not come back"
  else systemctl "$a" "$SVC"; fi
  log "$SVC: $(systemctl is-active "$SVC" 2>/dev/null || true)"
}
iran_timer() {  # on|off
  iran_need_installed
  if [[ $DRY == 1 ]]; then dry "would turn the health timer $1"; return 0; fi
  if [[ $1 == on ]]; then systemctl enable --now "$WATCH_SVC.timer" >/dev/null 2>&1; else systemctl disable --now "$WATCH_SVC.timer" >/dev/null 2>&1; fi
  log "health timer: $(systemctl is-active "$WATCH_SVC.timer" 2>/dev/null || true)"
}

install_watch_copy() {  # the timer (and the access-log auto-off) run a copy of this file
  put_file "$WATCH_BIN" 755 root:root <"$SELF"
}

iran_access_on() {  # minutes
  iran_need_installed
  local m=${1:-10}
  [[ $m =~ ^[0-9]+$ && $m -ge 1 && $m -le 240 ]] || die "minutes must be a number from 1 to 240"
  iran_load_key
  cfg_set_access ""      # empty = Xray writes the access log to stdout, i.e. the journal
  echo "  Turns the relay's access log ON for $m minute(s): every Gemini connection is logged to the journal."
  echo "  It switches itself off afterwards (systemd timer), even if you close this session."
  if [[ $DRY == 1 ]]; then dry "would restart $SVC with access logging, schedule the automatic revert"; return 0; fi
  ask_yn "Continue? ($SVC restarts briefly)" || cancel
  begin_step "Access log on for $m min"
  put_file "$CONF" 640 "root:$SVC" <"$TMP/config.json"
  local conf_changed=$CHANGED
  install_watch_copy          # the automatic switch-off runs this copy (note: put_file resets CHANGED)
  if [[ $conf_changed == 1 ]]; then iran_restart_wait || die "$SVC did not come back"; fi
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  systemd-run --on-active="${m}m" --unit="$REVERT_UNIT" --collect "$WATCH_BIN" --role iran --yes access-off >/dev/null \
    || die "could not schedule the automatic switch-off"
  state_set access_until "$(($(now) + m * 60))"
  end_step
  log "access log is ON until $(date -d "+$m min" +%H:%M) - read it with: Logs > live tail"
}
iran_access_off() {
  iran_need_installed
  cfg_set_access none
  if [[ $DRY == 1 ]]; then dry "would set log.access back to none and restart $SVC"; return 0; fi
  begin_step "Access log off"
  put_file "$CONF" 640 "root:$SVC" <"$TMP/config.json"
  if [[ $CHANGED == 1 ]]; then iran_restart_wait || die "$SVC did not come back"; fi
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  state_set access_until ""
  end_step
  log "access log is OFF"
}

iran_tg_set() {
  iran_need_installed
  local bot=${TG_BOT:-} chat=${TG_CHAT:-}
  if [[ -z $bot ]]; then read_secret bot "Telegram bot token"; fi
  if [[ -z $chat ]]; then ask_line chat "Telegram chat id"; fi
  [[ -n $bot && -n $chat ]] || die "both the bot token and the chat id are needed"
  echo "  Alerts go out only when the health timer finds a problem (and when it recovers)."
  echo "  Token to be stored: $(mask_key "$bot")"
  if [[ $DRY == 1 ]]; then dry "would store the token in $WATCH_ENV (mode 600)"; return 0; fi
  ask_yn "Save these alert settings?" || cancel
  put_file "$WATCH_ENV" 600 root:root < <(printf 'TG_BOT=%q\nTG_CHAT=%q\n' "$bot" "$chat")
  if TG_BOT=$bot TG_CHAT=$chat tg_post "gemini-shecan on $(hostname): test alert" ; then log "test message sent"
  else warn "saved, but the test message could not be sent (Telegram may be blocked from this server)"; fi
}
iran_tg_off() {
  iran_need_installed
  if [[ ! -f $WATCH_ENV ]]; then echo "No alert settings are stored."; return 0; fi
  if [[ $DRY == 1 ]]; then dry "would remove $WATCH_ENV"; return 0; fi
  ask_yn "Remove the Telegram alert settings?" || cancel
  backup_file "$WATCH_ENV"
  rm -f "$WATCH_ENV"
  log "Telegram alerts removed"
}

# ----- backups (iran) -----
bk_dirs() { ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sed 's#/$##' | sort -r || true; }
iran_bk_summary() {  # one line describing a backup dir
  local mf=$1/iran.manifest f="" ops
  if [[ ! -f $mf && -f $mf.rolledback ]]; then mf=$mf.rolledback; fi
  [[ -f $mf ]] || { echo "(no manifest)"; return 0; }
  ops=$(awk -F'\t' '$1=="F_BAK"||$1=="F_NEW"{n=split($2,a,"/"); printf "%s ", a[n]} $1=="FW"{printf "fw+ "} $1=="FW_DEL"{printf "fw- "}' "$mf")
  f=${ops:0:40}
  echo "${f:-(empty)}$([[ $mf == *.rolledback ]] && echo ' [undone]')"
}
iran_bk_file_of() { printf '%s/files/%s' "$1" "$(printf '%s' "$2" | tr '/' '_')"; }
iran_backup_diff() {  # DIR
  local f; f=$(iran_bk_file_of "$1" "$CONF")
  [[ -f $f ]] || { echo "This backup holds no copy of the relay config."; return 0; }
  echo "  (- backup, + current; the key line is hidden)"
  diff -u "$f" "$CONF" | grep -v -i 'password' | sed 1,2d | head -n 40 || true
  if diff -q "$f" "$CONF" >/dev/null 2>&1; then echo "  The current config is identical to this backup."; fi
}
iran_backup_restore() {  # DIR  - put that backup's config.json back
  iran_need_installed
  local f; f=$(iran_bk_file_of "$1" "$CONF")
  [[ -f $f ]] || die "this backup holds no copy of the relay config"
  xray_test_bin "$BIN" "$f" || die "that config is rejected by the installed Xray: $(tail -n 2 "$TMP/xtest.out" | tr '\n' ' ')"
  iran_backup_diff "$1"
  if [[ $DRY == 1 ]]; then dry "would restore $f as $CONF and restart $SVC"; return 0; fi
  ask_yn "Restore this config and restart $SVC?" || cancel
  begin_step "Restore config from $(basename "$1")"
  put_file "$CONF" 640 "root:$SVC" <"$f"
  if [[ $CHANGED == 1 ]]; then iran_restart_wait || die "$SVC did not come back"; fi
  end_step
}

iran_uninstall() {
  need_cmds systemctl
  if [[ $DRY != 1 && $EUID -ne 0 ]]; then die "run as root (or use --dry-run)"; fi
  iran_installed || [[ -d $STATE_DIR ]] || { echo "Nothing to remove: the relay is not installed."; return 0; }
  iran_load_runtime
  echo "  This will remove ONLY what this tool created:"
  echo "    services : $SVC, $WATCH_SVC timer+service (stopped and disabled)"
  echo "    files    : $BIN, $CONF_DIR/, $UNIT,"
  echo "               $WATCH_BIN, the two $WATCH_SVC units, $STATE_DIR/ (incl. the stored Shecan URL)"
  echo "    firewall : the single rule allowing ${FOREIGN_IP:-?} -> port $SS_PORT (kind: $FW_KIND)"
  echo "    user     : system user $SVC"
  echo "  It keeps: the SS key file, /root/gemini-shecan-backup/, this menu, the log file."
  echo "  It never touches the tunnel, other firewall rules, or any other xray / x-ui."
  echo "  Gemini through the foreign server stops working until you run the foreign Revert (or set up again)."
  if [[ $DRY == 1 ]]; then dry "would remove everything listed above"; return 0; fi
  ask_typed "Uninstall the Iran relay now?" || cancel
  begin_step "Uninstall"
  backup_file "$CONF"; backup_file "$WATCH_CONF"
  systemctl disable --now "$SVC" "$WATCH_SVC.timer" "$WATCH_SVC.service" >/dev/null 2>&1 || true
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  if [[ $FW_KIND != none && -n ${FOREIGN_IP:-} ]]; then fw_remove "$FW_KIND" "$FOREIGN_IP" "$SS_PORT" || true; fi
  rm -f "$BIN" "$UNIT" "$WATCH_BIN" "$SYSTEMD_DIR/$WATCH_SVC.service" "$SYSTEMD_DIR/$WATCH_SVC.timer" \
        "$CONF" "$WATCH_CONF" "$WATCH_ENV" "$URL_FILE" "$WATCH_STATE"
  rmdir --ignore-fail-on-non-empty "$CONF_DIR" "$STATE_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  userdel "$SVC" >/dev/null 2>&1 || true
  end_step
  log "uninstalled. Config/watch settings were saved in the backup folder ($(basename "$BK"))."
}

iran_guided_setup() {
  need_cmds python3 curl
  local fip="" url="" ver=""
  echo "  Guided setup of the Iran relay. You need: the foreign server's IP and your Shecan URL."
  ask_line fip "Foreign server IPv4 address" "${FOREIGN_IP:-}"
  valid_ipv4 "$fip" || die "that is not an IPv4 address"
  FOREIGN_IP=$fip
  if [[ ! -r $URL_FILE ]]; then read_secret url "Shecan registration URL"; export SHECAN_REGISTER_URL=$url; url=""; fi
  ask_line ver "Xray version (same as the foreign server; 'latest' if unsure)" "$XRAY_VERSION"
  XRAY_VERSION=$ver
  iran_setup_main
}

# =================================================== foreign: engine ====
# foreign engine (moved from the original script)

# ---------------------------------------------------- locate panel pieces --
sqlite_has_template() {
  [[ -f $1 ]] && [[ $(sqlite3 -readonly "$1" "select count(*) from settings where key='xrayTemplateConfig'" 2>/dev/null || echo 0) -ge 1 ]]
}

# panel_xray_test CONFIG -> 0 if accepted by the panel's Xray; message in $TMP/xtest.out
panel_xray_test() {
  ( cd "$XRAY_DIR" && XRAY_LOCATION_ASSET="$XRAY_DIR" "$XRAY_BIN" run -test -config "$1" >"$TMP/xtest.out" 2>&1 ) \
    || ( cd "$XRAY_DIR" && XRAY_LOCATION_ASSET="$XRAY_DIR" "$XRAY_BIN" -test -config "$1" >"$TMP/xtest.out" 2>&1 )
}

xray_err() { grep -v -i 'deprecated\|^Xray \|^A unified\|Reading config' "$TMP/xtest.out" | tail -n 3; }

read_template() {
  python3 - "$DB" "$TMP/template.orig.json" <<'PY'
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=30)
row = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
open(sys.argv[2], "w", encoding="utf-8", newline="").write(row[0])
PY
  python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/template.orig.json" \
    || die "the stored template is not valid JSON"
}

# Put the saved template (and sniffing values) back into the live DB.
py_restore() {  # py_restore DB BACKUP_DIR
  python3 - "$1" "$2" <<'PY'
import json, os, sqlite3, sys
db, bk = sys.argv[1:3]
con = sqlite3.connect(db, timeout=30)
tpl = open(os.path.join(bk, "template.orig.json"), encoding="utf-8", newline="").read()
n = con.execute("update settings set value=? where key='xrayTemplateConfig'", (tpl,)).rowcount
sp = os.path.join(bk, "sniffing.orig.json")
if os.path.exists(sp):
    for iid, val in json.load(open(sp)).items():
        con.execute("update inbounds set sniffing=? where id=?", (val, int(iid)))
con.commit()
print("restored template (%d row) and %s" % (n, "sniffing values" if os.path.exists(sp) else "no sniffing changes"))
PY
}

restart_panel() {
  log "restarting the panel: $RESTART_CMD"
  bash -c "$RESTART_CMD" || die "restarting the panel failed (command: $RESTART_CMD)"
}

# Wait until Xray runs again and (optionally) the regenerated config has/lacks our outbound.
wait_xray() {  # wait_xray present|absent
  local want=$1 i cfg="$XRAY_DIR/config.json" ok
  for i in $(seq 1 30); do
    sleep 1
    # exact process-name match (comm is cut to 15 chars); -f would also match this script's own arguments
    pgrep -x "$(basename "$XRAY_BIN" | cut -c1-15)" >/dev/null 2>&1 || continue
    if [[ -f $cfg ]]; then
      ok=0
      if grep -q "\"$TAG\"" "$cfg"; then ok=1; fi
      if [[ ($want == present && $ok == 1) || ($want == absent && $ok == 0) ]]; then return 0; fi
    else
      return 0    # config.json is somewhere else; process check only
    fi
  done
  return 1
}

# After restoring $BK/template.orig.json the tag is present only if that saved template had it.
expect_after_restore() { if grep -q "\"$TAG\"" "$BK/template.orig.json"; then echo present; else echo absent; fi; }

restore_from_backup() {
  py_restore "$DB" "$BK"
  restart_panel
  wait_xray "$(expect_after_restore)" || warn "Xray did not come back as expected after the restore - check: systemctl status x-ui"
}

# ---------------------------------------------------------------- rollback --
foreign_rollback_main() {
  local d="" cand
  if [[ -n $BACKUP_DIR_ARG ]]; then d=$BACKUP_DIR_ARG
  else
    for cand in $(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r); do
      if [[ -s ${cand}$MANIFEST ]]; then d=${cand%/}; break; fi
    done
  fi
  [[ -n $d && -s $d/$MANIFEST ]] || die "no $MANIFEST found under $BACKUP_ROOT (nothing to roll back)"
  BK=$d
  DB=$(awk -F'\t' '$1=="DB"{print $2}' "$BK/$MANIFEST")
  XRAY_BIN=$(awk -F'\t' '$1=="XRAY"{print $2}' "$BK/$MANIFEST")
  XRAY_DIR=$(dirname "$XRAY_BIN")
  RESTART_CMD=$(awk -F'\t' '$1=="RESTART"{print $2}' "$BK/$MANIFEST")
  log "rolling back run $(basename "$BK") (db: $DB)"
  if [[ $DRY == 1 ]]; then
    dry "would restore $([[ $RESTORE_FULL_DB == 1 ]] && echo 'the full DB copy' || echo 'the saved template/sniffing') and run: $RESTART_CMD"
    return 0
  fi
  echo "This restarts the panel and drops ALL user connections for a few seconds."
  confirm "Roll back now?" || die "aborted"
  trap - ERR
  if [[ $RESTORE_FULL_DB == 1 ]]; then
    [[ $RESTART_CMD == "systemctl restart x-ui" ]] || die "--restore-full-db needs the default systemd setup (x-ui.service)"
    systemctl stop x-ui
    cp -p "$BK/x-ui.db" "$DB"
    rm -f "$DB-wal" "$DB-shm"
    systemctl start x-ui
  else
    py_restore "$DB" "$BK"
    restart_panel
  fi
  wait_xray "$(expect_after_restore)" && log "rollback done: the generated Xray config matches the restored template" \
    || warn "could not confirm the restore from the generated config - check: systemctl status x-ui"
  mv -f "$BK/$MANIFEST" "$BK/$MANIFEST.rolledback"
}

# ------------------------------------------------------------------ inputs --
read_inputs() {
  [[ -n $IRAN_IP ]] || die "IRAN_IP is required (env or --iran-ip)"
  python3 -c 'import ipaddress,sys;ipaddress.IPv4Address(sys.argv[1])' "$IRAN_IP" 2>/dev/null \
    || die "IRAN_IP must be an IPv4 address"
  [[ $SS_PORT =~ ^[0-9]+$ && $SS_PORT -ge 1 && $SS_PORT -le 65535 ]] || die "invalid SS_PORT: $SS_PORT"
  [[ -n $KEY_FILE ]] || die "KEY_FILE is required (env or --key-file): the file written by setup-iran.sh"
  [[ -r $KEY_FILE ]] || die "key file not readable: $KEY_FILE"
  local mode; mode=$(stat -c %a "$KEY_FILE")
  if [[ $mode != 600 && $mode != 400 ]]; then warn "$KEY_FILE has mode $mode; it holds a secret, consider chmod 600"; fi
  KEY_VAL=$(<"$KEY_FILE")
  KEY_VAL=${KEY_VAL//[$'\r\n\t ']/}
  [[ $(printf '%s' "$KEY_VAL" | base64 -d 2>/dev/null | wc -c) == 16 ]] \
    || die "the key in $KEY_FILE is not base64 of 16 bytes ($SS_METHOD needs exactly that)"
}

# ===================================================== foreign: new code ====
locate_db() {  # quiet; sets DB (or leaves it empty)
  local c cands=() folder seen=""
  if [[ -n $DB ]]; then
    if [[ -f $DB ]]; then return 0; fi
    return 1
  fi
  folder=$(systemctl show x-ui -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^XUI_DB_FOLDER=//p' | head -n 1 || true)
  if [[ -n $folder ]]; then cands+=("$folder/x-ui.db"); fi
  cands+=("$GM_ROOT/etc/x-ui/x-ui.db" /usr/local/x-ui/db/x-ui.db /usr/local/x-ui/x-ui.db /opt/x-ui/x-ui.db)
  # only system locations: a copy in /root or /home is usually a backup, never the live panel database
  while IFS= read -r c; do cands+=("$c"); done < <(find /etc /usr/local /opt /var/lib -maxdepth 4 -name x-ui.db 2>/dev/null || true)
  for c in "${cands[@]}"; do
    if [[ -f $c && $seen != *"|$c|"* ]]; then
      seen+="|$c|"
      if sqlite_has_template "$c"; then DB=$c; return 0; fi
    fi
  done
  return 1
}

find_db() {
  if [[ -n $DB && ! -f $DB ]]; then die "database not found: $DB"; fi
  locate_db || die "could not find a 3X-UI database with an xrayTemplateConfig row.
  - Pass it explicitly with --db PATH.
  - If the panel never saved a custom template, open the panel -> Xray Configs, press Save once (no changes), then re-run."
  sqlite_has_template "$DB" || die "$DB has no settings.xrayTemplateConfig row (open the panel -> Xray Configs and press Save once, then re-run)"
  log "3X-UI database: $DB"
}

locate_xray() {  # quiet; sets XRAY_BIN / XRAY_DIR
  local c
  if [[ -z $XRAY_BIN ]]; then
    for c in /usr/local/x-ui/bin/xray-linux-* /opt/x-ui/bin/xray-linux-*; do
      if [[ -f $c && -x $c ]]; then XRAY_BIN=$c; break; fi
    done
    if [[ -z $XRAY_BIN ]]; then
      XRAY_BIN=$(find /usr/local /opt /root -maxdepth 4 -type f -name 'xray-linux-*' -perm -u+x 2>/dev/null | head -n 1 || true)
    fi
  fi
  if [[ -n $XRAY_BIN && -x $XRAY_BIN ]]; then XRAY_DIR=$(dirname "$XRAY_BIN"); return 0; fi
  return 1
}

find_xray() {
  locate_xray || die "panel Xray binary not found; pass --xray-bin PATH"
  log "panel Xray: $XRAY_BIN ($("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $1" "$2}'))"
  log "  -> use the same version on the Iran server: --xray-version $("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
}

need_panel() {
  need_cmds sqlite3 python3
  if [[ $DRY != 1 && $EUID -ne 0 ]]; then die "run as root (or use --dry-run)"; fi
  if [[ -z $DB ]]; then find_db; fi
  if [[ -z $XRAY_DIR ]]; then find_xray; fi
}

# ---------------------------------------------------------------------------
# One program for every template edit. Usage: py_tpl MODE IN [OUT]  (parameters in P_* env vars)
#   patch    full setup patch (P_FORM P_IP P_PORT P_KEY P_METHOD P_DOMAINS)
#   inspect  print shell assignments describing the current state
#   toggle   P_STATE=on|off         scope  P_TAGS="tag tag" (empty = all inbounds)
#   domains  P_DOMAINS="a b c"      revert   remove ir-gemini + its rules
#   logaccess P_ACCESS=path|none    diff   P_IN2=other template (summary of differences)
# A rule is "switched off" by prefixing its inboundTag entries with __gemini_off__: it stays in the
# template but can never match. Scope is the inboundTag list on the two Gemini rules.
py_tpl() {
  M=$1 P_IN=$2 P_OUT=${3:-} P_TAG=$TAG P_OFF=$OFF_MARK python3 - <<'PY'
import json, os, re, shlex, sys
e = os.environ
mode = e["M"]
GEM, OLD, OFF = e["P_TAG"], "gemini-shecan", e["P_OFF"]
say = print

def fail(m):
    print("PATCH-ERROR: " + m, file=sys.stderr)
    sys.exit(2)

text = open(e["P_IN"], encoding="utf-8").read()
tpl = json.loads(text)
orig = json.loads(text)
doms = ["full:" + d for d in e.get("P_DOMAINS", "").split()]

def parse_state(rule):
    tags = rule.get("inboundTag")
    if isinstance(tags, str):
        tags = [tags]
    if not tags:
        return False, []
    if all(t == OFF or t.startswith(OFF + "/") for t in tags):
        return True, [t[len(OFF) + 1:] for t in tags if t != OFF]
    return False, list(tags)

def set_state(rule, off, scope):
    if off:
        rule["inboundTag"] = [OFF + "/" + t for t in scope] if scope else [OFF]
    elif scope:
        rule["inboundTag"] = list(scope)
    else:
        rule.pop("inboundTag", None)

def find_rules(rules):
    gem = next((r for r in rules if r.get("outboundTag") == GEM and r.get("domain")), None)
    udp = None
    if gem:
        udp = next((r for r in rules if r is not gem and r.get("network") == "udp"
                    and str(r.get("port")) == "443" and r.get("domain") == gem["domain"]), None)
    return gem, udp

def need_rules(t):
    rr = t.get("routing", {}).get("rules")
    if not isinstance(t.get("outbounds"), list) or not isinstance(rr, list):
        fail("template has no outbounds/routing.rules")
    return rr

def dangling(t):
    tags = {o.get("tag") for o in t.get("outbounds", [])}
    if isinstance(t.get("api"), dict) and t["api"].get("tag"):
        tags.add(t["api"]["tag"])            # the virtual 'api' outbound
    bals = {b.get("tag") for b in t.get("routing", {}).get("balancers", [])}
    bad = set()
    for r in t.get("routing", {}).get("rules", []):
        if "outboundTag" in r and r["outboundTag"] not in tags:
            bad.add(("outboundTag", r["outboundTag"]))
        if "balancerTag" in r and r["balancerTag"] not in bals:
            bad.add(("balancerTag", r["balancerTag"]))
    return bad

def rsum(r):
    p = []
    if r.get("inboundTag"):
        p.append("in:" + ",".join(r["inboundTag"])[:28])
    if r.get("network"):
        p.append(str(r["network"]) + ("/" + str(r["port"]) if r.get("port") else ""))
    if r.get("domain"):
        p.append("%d domains" % len(r["domain"]))
    if r.get("protocol"):
        p.append("proto:" + ",".join(r["protocol"]) if isinstance(r["protocol"], list) else "proto:" + str(r["protocol"]))
    if r.get("ip"):
        p.append("ip:" + ",".join(r["ip"])[:20])
    return " ".join(p) + " -> " + str(r.get("outboundTag") or "bal:" + str(r.get("balancerTag")))

def shq(v):
    return shlex.quote(str(v))

# ------------------------------------------------------------------ inspect --
if mode == "inspect":
    outs = [o for o in tpl.get("outbounds", []) if o.get("tag") == GEM]
    ip = port = form = ""
    if outs:
        s = outs[0].get("settings", {})
        form = "servers" if "servers" in s else "flat"
        if form == "servers":
            s = (s["servers"] or [{}])[0]
        ip, port = s.get("address", ""), s.get("port", "")
    rules = tpl.get("routing", {}).get("rules", []) if isinstance(tpl.get("routing"), dict) else []
    g, u = find_rules(rules)
    state, scope, nd, dl = "missing", [], 0, ""
    if g:
        off, scope = parse_state(g)
        state = "off" if off else "on"
        if u is None or parse_state(u) != (off, scope):
            state = "partial"
        dl = [d[5:] if d.startswith("full:") else d for d in g["domain"]]
        nd, dl = len(dl), " ".join(dl)
    for k, v in (("T_HAS", 1 if outs else 0), ("T_IP", ip), ("T_PORT", port), ("T_FORM", form), ("T_STATE", state),
                 ("T_UDP", 1 if u else 0), ("T_SCOPE", ",".join(scope) or "all"), ("T_NDOM", nd), ("T_DOMAINS", dl),
                 ("T_ACCESS", (tpl.get("log") or {}).get("access", "__unset__"))):
        print("%s=%s" % (k, shq(v)))
    sys.exit(0)

# --------------------------------------------------------------------- diff --
if mode == "diff":
    other = json.load(open(e["P_IN2"], encoding="utf-8"))
    def tags(t): return sorted(o.get("tag", "?") for o in t.get("outbounds", []))
    a_t, b_t = tags(tpl), tags(other)
    for t in b_t:
        if t not in a_t: say("+ outbound '%s' comes back" % t)
    for t in a_t:
        if t not in b_t: say("- outbound '%s' goes away" % t)
    ar = [rsum(r) for r in tpl.get("routing", {}).get("rules", [])]
    br = [rsum(r) for r in other.get("routing", {}).get("rules", [])]
    for s in br:
        if s not in ar: say("+ rule: " + s)
    for s in ar:
        if s not in br: say("- rule: " + s)
    la, lb = (tpl.get("log") or {}).get("access"), (other.get("log") or {}).get("access")
    if la != lb: say("~ log.access: %s -> %s" % (la, lb))
    rest = [k for k in set(tpl) | set(other) if k not in ("outbounds", "routing", "log") and tpl.get(k) != other.get(k)]
    if rest: say("~ other sections differ: " + ", ".join(sorted(rest)))
    if tpl == other: say("= identical")
    if e.get("P_OUT"):
        open(e["P_OUT"], "w", encoding="utf-8").write(open(e["P_IN2"], encoding="utf-8").read())
        open(e["P_OUT"] + ".changed", "w").write("1" if tpl != other else "0")
    sys.exit(0)

# ------------------------------------------------------ modes that modify --
outs = tpl.get("outbounds")
rules = need_rules(tpl)
routing = tpl["routing"]
gem_rule, udp_rule = find_rules(rules)

if mode == "patch":
    carry = parse_state(gem_rule) if gem_rule else None     # keep an existing scope / off switch
    outs[:] = [o for o in outs if o.get("tag") != OLD] if any(o.get("tag") == OLD for o in outs) else outs
    if len(outs) != len(orig["outbounds"]): say("- removed outbound '%s'" % OLD)
    gone_bal = set()
    if isinstance(routing.get("balancers"), list):
        keep = []
        for b in routing["balancers"]:
            if "gemini" in json.dumps(b).lower(): gone_bal.add(b.get("tag")); say("- removed balancer '%s'" % b.get("tag"))
            else: keep.append(b)
        if keep: routing["balancers"] = keep
        else: del routing["balancers"]
    for key in ("observatory", "burstObservatory"):
        o = tpl.get(key)
        if isinstance(o, dict) and isinstance(o.get("subjectSelector"), list):
            sel = o["subjectSelector"]
            keep = [s for s in sel if "gemini" not in str(s).lower()]
            if len(keep) != len(sel):
                say("- removed gemini selectors from %s" % key)
                if keep: o["subjectSelector"] = keep
                else: del tpl[key]
    old_dom = gem_rule["domain"] if gem_rule else None
    def ours_udp(r):
        return r.get("network") == "udp" and str(r.get("port")) == "443" and r.get("domain") in (doms, old_dom)
    kept = []
    for r in rules:
        if r.get("outboundTag") in (OLD, GEM) or r.get("balancerTag") in gone_bal or ours_udp(r):
            say("- removed rule -> %s" % (r.get("outboundTag") or r.get("balancerTag")))
        else:
            kept.append(r)
    rules[:] = kept
    srv = {"address": e["P_IP"], "port": int(e["P_PORT"]), "method": e["P_METHOD"], "password": e["P_KEY"]}
    ob = {"tag": GEM, "protocol": "shadowsocks", "settings": {"servers": [srv]} if e["P_FORM"] == "servers" else srv}
    idx = next((i for i, o in enumerate(outs) if o.get("tag") == GEM), None)
    if idx is None:
        outs.append(ob)          # never at index 0: the first outbound is the default one
        say("+ added outbound '%s' (%s form, appended last so the default outbound is unchanged)" % (GEM, e["P_FORM"]))
    else:
        outs[idx] = ob
        say("+ replaced existing outbound '%s' in place" % GEM)
    def is_bt(r):
        p = r.get("protocol")
        p = [p] if isinstance(p, str) else (p or [])
        return "bittorrent" in p and r.get("outboundTag")
    pos = next((i for i, r in enumerate(rules) if is_bt(r)), None)
    if pos is None:
        fail("no 'bittorrent -> blocked' rule found in the template; refusing to guess where to insert")
    block = rules[pos]["outboundTag"]
    new_udp = {"type": "field", "network": "udp", "port": "443", "domain": list(doms), "outboundTag": block}
    new_gem = {"type": "field", "domain": list(doms), "outboundTag": GEM}
    if carry:
        set_state(new_udp, *carry); set_state(new_gem, *carry)
        if carry[0] or carry[1]: say("= kept the existing scope/switch of the Gemini rules")
    rules[pos + 1:pos + 1] = [new_udp, new_gem]
    say("+ inserted 2 rules after rule #%d (bittorrent -> %s): udp/443 -> %s, domains -> %s" % (pos, block, block, GEM))

elif mode == "toggle":
    if not gem_rule: fail("the Gemini rules are not in the template yet - run setup first")
    want_off = e["P_STATE"] == "off"
    for r in (gem_rule, udp_rule):
        if r is not None:
            _, scope = parse_state(r)
            set_state(r, want_off, scope)
    say("~ Gemini routing -> %s" % ("OFF (rules stay in the template but match nothing)" if want_off else "ON"))
    if udp_rule is None: say("! the udp/443 block rule is missing (QUIC is not blocked)")

elif mode == "scope":
    if not gem_rule: fail("the Gemini rules are not in the template yet - run setup first")
    tags = e.get("P_TAGS", "").split()
    for r in (gem_rule, udp_rule):
        if r is not None:
            off, _ = parse_state(r)
            set_state(r, off, tags)
    say("~ scope -> %s" % (", ".join(tags) if tags else "all inbounds"))

elif mode == "domains":
    if not gem_rule: fail("the Gemini rules are not in the template yet - run setup first")
    if not doms: fail("the domain list cannot be empty")
    old = [d[5:] if d.startswith("full:") else d for d in gem_rule["domain"]]
    new = [d[5:] for d in doms]
    for d in new:
        if d not in old: say("+ " + d)
    for d in old:
        if d not in new: say("- " + d)
    gem_rule["domain"] = list(doms)
    if udp_rule is not None: udp_rule["domain"] = list(doms)

elif mode == "revert":
    n = len(outs)
    outs[:] = [o for o in outs if o.get("tag") not in (GEM, OLD)]
    if len(outs) != n: say("- removed outbound '%s'" % GEM)
    kept = []
    for r in rules:
        if r is gem_rule or r is udp_rule or r.get("outboundTag") in (GEM, OLD):
            say("- removed rule: " + rsum(r))
        else:
            kept.append(r)
    rules[:] = kept

elif mode == "logaccess":
    a = e["P_ACCESS"]
    tpl.setdefault("log", {})["access"] = a
    say("~ log.access: %s -> %s" % ((orig.get("log") or {}).get("access", "(unset)"), a))

else:
    fail("unknown mode " + mode)

new_bad = dangling(tpl) - dangling(orig)
if new_bad: fail("dangling references after the change: %s" % sorted(new_bad))
for k, v in sorted(dangling(orig)): say("! pre-existing dangling %s '%s' (not touched)" % (k, v))

m = re.search(r"\n( +)\"", text)
indent = len(m.group(1)) if m else (None if "\n" not in text else 2)
open(e["P_OUT"], "w", encoding="utf-8").write(json.dumps(tpl, indent=indent, ensure_ascii=False))
open(e["P_OUT"] + ".changed", "w").write("1" if tpl != orig else "0")
PY
}

# ---------------------------------------------------------- sniffing audit --
# Modes: audit (human report + count file) | list (TSV) | fix IDS (save originals in OUT) | restore (OUT holds id->value; EXTRA = where to save current values)
SNIFF_PY='
import json, os, sqlite3, sys
mode, db, out = sys.argv[1:4]
extra = sys.argv[4] if len(sys.argv) > 4 else ""
rw = mode in ("fix", "restore")
con = sqlite3.connect("file:%s?mode=%s" % (db, "rw" if rw else "ro"), uri=True, timeout=30)
cols = [r[1] for r in con.execute("pragma table_info(inbounds)")]
if "sniffing" not in cols:
    if mode == "audit":
        print("  (this panel version has no inbounds.sniffing column - audit skipped)")
        open(out, "w").write("0")
    sys.exit(0)
flagged, disabled, total = [], 0, 0
for iid, remark, port, proto, enable, sn in con.execute("select id, remark, port, protocol, enable, sniffing from inbounds order by id"):
    if proto in ("tunnel", "dokodemo-door"):
        continue
    total += 1
    if not enable:
        disabled += 1
        continue
    try:
        s = json.loads(sn) if sn else {}
    except Exception:
        s = {}
    probs = []
    if not s.get("enabled"):
        probs.append("sniffing disabled")
    else:
        d = s.get("destOverride") or []
        if "tls" not in d: probs.append("lacks tls")
        if "http" not in d: probs.append("lacks http")
        if s.get("routeOnly"): probs.append("routeOnly=true")
        if s.get("metadataOnly"): probs.append("metadataOnly=true")
    if probs:
        flagged.append((iid, remark, port, proto, probs, sn, s))
if mode == "audit":
    print("  %d client inbound(s) checked (%d disabled and skipped)" % (total, disabled))
    for iid, remark, port, proto, probs, _, _ in flagged:
        print("  ! id=%s %-18s port=%-5s %-12s %s" % (iid, remark, port, proto, ", ".join(probs)))
    if not flagged:
        print("  all enabled inbounds have sniffing with tls+http and no routeOnly/metadataOnly")
    open(out, "w").write(str(len(flagged)))
elif mode == "list":
    for iid, remark, port, proto, probs, _, _ in flagged:
        print("%s\t%s\t%s\t%s\t%s" % (iid, remark, port, proto, ", ".join(probs)))
elif mode == "fix":
    want = None if extra in ("", "all") else set(extra.split(","))
    saved = json.load(open(out)) if os.path.exists(out) else {}
    n = 0
    for iid, remark, port, proto, probs, sn, s in flagged:
        if want is not None and str(iid) not in want:
            continue
        saved.setdefault(str(iid), sn)
        s["enabled"] = True
        d = list(s.get("destOverride") or [])
        for x in ("http", "tls"):
            if x not in d: d.append(x)
        s["destOverride"], s["routeOnly"], s["metadataOnly"] = d, False, False
        con.execute("update inbounds set sniffing=? where id=?", (json.dumps(s, indent=2), iid))
        n += 1
    json.dump(saved, open(out, "w"))
    con.commit()
    print("  sniffing fixed on %d inbound(s)" % n)
elif mode == "restore":
    data = json.load(open(out))
    saved = {}
    for iid, val in data.items():
        row = con.execute("select sniffing from inbounds where id=?", (int(iid),)).fetchone()
        if row is None:
            continue
        saved[iid] = row[0]
        con.execute("update inbounds set sniffing=? where id=?", (val, int(iid)))
    json.dump(saved, open(extra, "w"))
    con.commit()
    print("  sniffing values restored on %d inbound(s)" % len(saved))
'

sniff_audit() {
  log "== Sniffing audit (report only)"
  echo "  Domain rules need the destination domain, so the inbound must sniff (tls/http) and must"
  echo "  not use routeOnly: with routeOnly the connection to ir-gemini would still carry an IP,"
  echo "  and the Iran relay (which only accepts the listed domains) would refuse it."
  python3 -c "$SNIFF_PY" audit "$DB" "$TMP/sniff.count"
  SNIFF_FLAGGED=$(<"$TMP/sniff.count")
  if [[ $SNIFF_FLAGGED -gt 0 && $FIX_SNIFFING == 0 ]]; then
    echo "  -> not changed. Menu: Sniffing > fix selected (or re-run with --fix-sniffing)."
  fi
}

# ------------------------------------------------------ facts about the panel --
T_HAS=0 T_IP="" T_PORT="" T_FORM="" T_STATE=missing T_UDP=0 T_SCOPE=all T_NDOM=0 T_DOMAINS="" T_ACCESS=""
foreign_facts() {  # reads the template from the DB and sets the T_* variables (quiet; returns 1 on failure)
  T_HAS=0 T_IP="" T_PORT="" T_FORM="" T_STATE=missing T_UDP=0 T_SCOPE=all T_NDOM=0 T_DOMAINS="" T_ACCESS=""
  [[ -n $DB ]] || return 1
  if ( read_template ) >/dev/null 2>&1; then
    eval "$(py_tpl inspect "$TMP/template.orig.json")"
    return 0
  fi
  return 1
}

foreign_domain_list() {  # the hosts currently routed (falls back to the built-in 9)
  if foreign_facts && [[ $T_NDOM -gt 0 ]]; then printf '%s\n' $T_DOMAINS; else printf '%s\n' "${GEMINI_DOMAINS[@]}"; fi
}

foreign_checks() {
  chk_reset
  if [[ -z $DB ]]; then
    chk fail "3X-UI database not found" "Run with --db /path/x-ui.db, or open the panel > Xray Configs and press Save once."
    return 0
  fi
  local xp age res t gen
  xp=$(basename "${XRAY_BIN:-xray-linux}" | cut -c1-15)
  if systemctl is-active --quiet x-ui 2>/dev/null || pgrep -x "$xp" >/dev/null 2>&1; then chk ok "Panel running (db: ${DB/#$GM_ROOT/})"
  else chk fail "Panel is NOT running" "systemctl status x-ui   then   systemctl restart x-ui"; fi
  if ! foreign_facts; then
    chk fail "Cannot read the Xray template from the panel database" "Check the database path (--db) and that the panel has saved its template once."
    return 0
  fi
  if [[ $T_HAS == 1 ]]; then
    if nc -z -w 3 "$T_IP" "$T_PORT" >/dev/null 2>&1; then chk ok "Iran relay $T_IP:$T_PORT is reachable"
    else chk fail "Iran relay $T_IP:$T_PORT is NOT reachable" "The path may be filtered, the relay down, or the Iran firewall blocks this server. On Iran: Health check."; fi
    chk ok "Outbound $TAG is in the template ($T_FORM form)"
  else
    chk fail "Outbound $TAG is missing" "Press s to run the setup."
  fi
  case $T_STATE in
    on)      if [[ $T_UDP != 1 ]]; then chk warn "Gemini routing is ON but the udp/443 (QUIC) block rule is missing" "Press s to re-run the setup; it re-creates both rules."
             elif [[ $T_SCOPE == all ]]; then chk ok "Gemini routing is ON for all inbounds ($T_NDOM hosts)"
             else chk ok "Gemini routing is ON for: ${T_SCOPE//,/ } ($T_NDOM hosts)"; fi ;;
    off)     chk warn "Gemini routing is OFF (rules kept, they match nothing)" "Menu 3 switches it back on." ;;
    partial) chk warn "The two Gemini rules disagree (one is on, one is off/missing)" "Menu 3: switch ON again to make them consistent." ;;
    *)       chk fail "Gemini routing rules are missing" "Press s to run the setup." ;;
  esac
  gen=$XRAY_DIR/config.json
  if [[ $T_HAS == 1 && -f $gen ]] && ! grep -q "\"$TAG\"" "$gen"; then
    chk warn "The running Xray config does not contain $TAG yet" "The panel needs a restart to load the template (menu 3 ON/OFF does that)."
  fi
  python3 -c "$SNIFF_PY" audit "$DB" "$TMP/sniff.count" >/dev/null 2>&1 || true
  SNIFF_FLAGGED=$(cat "$TMP/sniff.count" 2>/dev/null || echo 0)
  if [[ $SNIFF_FLAGGED -gt 0 ]]; then chk warn "$SNIFF_FLAGGED inbound(s) with bad sniffing (domain rules can miss)" "Menu 7 > fix selected."
  else chk ok "Sniffing is fine on every enabled inbound"; fi
  t=$(state_get last_test_ts); res=$(state_get last_test_res)
  if [[ -z $t ]]; then chk warn "No end-to-end test yet" "Menu 2 runs it."
  else
    age=$(fmt_age $(($(now) - t)))
    if [[ $res == OK* ]]; then chk ok "Last end-to-end test: $res, $age"; else chk fail "Last end-to-end test: $res, $age" "Menu 2 shows which step is broken."; fi
  fi
}

# ------------------------------------------------------- the commit pipeline --
COMMIT_FIX_IDS=""          # "" = no sniffing change, "all" or "1,2" = fix those inbounds in the same restart
COMMIT_RESTORE_FILE=""     # JSON id -> sniffing text to put back in the same restart

# foreign_commit NEWFILE : validate, back up, write the template (+ optional sniffing change), restart, verify.
foreign_commit() {
  local nf=$1 want
  if [[ $(<"$nf.changed") == 0 && -z $COMMIT_FIX_IDS && -z $COMMIT_RESTORE_FILE ]]; then
    echo "Nothing to change - it is already like this."
    return 0
  fi
  panel_xray_test "$nf" || die "the panel's Xray rejected the new template: $(xray_err | tr '\n' ' ') - nothing was written"
  log "new template validated with the panel's Xray"
  if [[ $DRY == 1 ]]; then dry "would back up the DB, write the template, restart: $RESTART_CMD"; return 0; fi
  ask_typed "The panel will restart ($RESTART_CMD).
  This drops ALL user connections for a few seconds." || cancel
  # the template must not have changed since we computed the new one (e.g. someone saved in the panel)
  ( read_template ) >/dev/null 2>&1 || die "cannot read the template again"
  cp "$TMP/template.orig.json" "$TMP/template.base.json"
  bk_dir
  sqlite3 "$DB" ".backup '$BK/x-ui.db'"
  chmod 600 "$BK/x-ui.db"
  [[ $(sqlite3 "$BK/x-ui.db" 'pragma integrity_check') == ok ]] || die "backup of the DB failed its integrity check"
  cp "$TMP/template.base.json" "$BK/template.orig.json"
  printf 'DB\t%s\nXRAY\t%s\nRESTART\t%s\n' "$DB" "$XRAY_BIN" "$RESTART_CMD" >"$BK/$MANIFEST"
  log "backup: $BK"
  APPLIED=1
  python3 - "$DB" "$nf" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=30)
n = con.execute("update settings set value=? where key='xrayTemplateConfig'", (open(sys.argv[2], encoding="utf-8").read(),)).rowcount
con.commit()
if n != 1: sys.exit("expected to update exactly 1 row, updated %d" % n)
PY
  if [[ -n $COMMIT_FIX_IDS ]]; then python3 -c "$SNIFF_PY" fix "$DB" "$BK/sniffing.orig.json" "$COMMIT_FIX_IDS"; fi
  if [[ -n $COMMIT_RESTORE_FILE ]]; then python3 -c "$SNIFF_PY" restore "$DB" "$COMMIT_RESTORE_FILE" "$BK/sniffing.orig.json"; fi
  restart_panel
  if grep -q "\"$TAG\"" "$nf"; then want=present; else want=absent; fi
  wait_xray "$want" || die "Xray did not come up as expected (generated config should be '$want' for $TAG) within 30 s"
  APPLIED=0
  log "panel restarted; Xray is running with the new template"
}

foreign_tpl_action() {  # foreign_tpl_action MODE   (P_* parameters set by the caller)
  need_panel
  read_template
  py_tpl "$1" "$TMP/template.orig.json" "$TMP/new.json" | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "could not compute the change"
  foreign_commit "$TMP/new.json"
}

foreign_routing_set() {  # on|off
  [[ $1 == on || $1 == off ]] || die "use: routing on|off"
  P_STATE=$1 foreign_tpl_action toggle
}

foreign_scope_apply() {  # tag... (empty = all inbounds)
  P_TAGS="$*" foreign_tpl_action scope
}

foreign_domains_apply() {  # host...  (complete new list)
  P_DOMAINS="$*" foreign_tpl_action domains
}

foreign_domain_add() {
  local h d cur=()
  h=$(norm_host "${1:-}")
  valid_host "$h" || die "not a valid hostname: ${1:-<empty>} (example: gemini.google.com)"
  need_panel
  mapfile -t cur < <(foreign_domain_list)
  for d in "${cur[@]}"; do if [[ $d == "$h" ]]; then echo "$h is already in the list."; return 0; fi; done
  foreign_domains_apply "${cur[@]}" "$h"
}
foreign_domain_remove() {
  local h d cur=() keep=()
  h=$(norm_host "${1:-}")
  need_panel
  mapfile -t cur < <(foreign_domain_list)
  for d in "${cur[@]}"; do if [[ $d != "$h" ]]; then keep+=("$d"); fi; done
  if ((${#keep[@]} == ${#cur[@]})); then echo "$h is not in the list."; return 0; fi
  foreign_domains_apply "${keep[@]}"
}
foreign_domain_set() {
  local d h list=()
  for d in "$@"; do h=$(norm_host "$d"); valid_host "$h" || die "not a valid hostname: $d"; list+=("$h"); done
  foreign_domains_apply "${list[@]}"
}

# Keep the Iran side in sync: push over SSH when that works, otherwise print the one-line command.
foreign_sync_iran() {  # the complete current list
  local cmd="gemini-menu --role iran --yes domain set $*" ip=$T_IP
  [[ -n $ip ]] || { foreign_facts || true; ip=$T_IP; }
  echo
  echo "  The Iran relay must accept the same hosts, or the missing ones are refused there."
  if [[ -n $ip ]] && command -v ssh >/dev/null 2>&1 && ssh -o BatchMode=yes -o ConnectTimeout=6 "root@$ip" true >/dev/null 2>&1; then
    if [[ $DRY == 1 ]]; then dry "SSH to $ip works: would run '$cmd' there"; return 0; fi
    if { [[ -t 0 ]] || [[ $YES == 1 ]]; } && ask_yn "  SSH to the Iran server ($ip) works. Push the new list there now?"; then
      ssh -o BatchMode=yes "root@$ip" "$cmd" && log "Iran relay updated" || warn "the push failed - run this ON the Iran server:  $cmd"
      return 0
    fi
  fi
  echo "  Run this ON the Iran server (one line):"
  echo "    $cmd"
}

# ------------------------------------------------------------- end-to-end test --
TEST_ROWS=()
foreign_test_prepare() {  # sets IRAN_IP/SS_PORT and $TMP/outbound.json; starts the temp Xray; sets TEST_PORT TEST_PID
  need_cmds python3 nc curl
  if [[ -z $XRAY_DIR ]]; then find_xray; fi
  if [[ -z $IRAN_IP || -z $KEY_FILE ]]; then
    need_cmds sqlite3
    [[ -n $DB ]] || find_db
    read_template
    local t
    t=$(python3 - "$TMP/template.orig.json" "$TAG" "$TMP/outbound.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
for o in t.get("outbounds", []):
    if o.get("tag") == sys.argv[2]:
        s = o.get("settings", {}); s = (s.get("servers") or [s])[0]
        print(s["address"], s["port"]); json.dump(o, open(sys.argv[3], "w")); sys.exit(0)
sys.exit(1)
PY
    ) || die "no '$TAG' outbound in the panel template - run the setup first (menu: s)"
    IRAN_IP=${t% *}; SS_PORT=${t#* }
  else
    read_inputs
    local form
    for form in servers flat; do
      P_FORM=$form P_IP=$IRAN_IP P_PORT=$SS_PORT P_KEY=$KEY_VAL P_METHOD=$SS_METHOD P_TAG=$TAG python3 - >"$TMP/outbound.$form.json" <<'PY'
import json, os
e = os.environ
s = {"address": e["P_IP"], "port": int(e["P_PORT"]), "method": e["P_METHOD"], "password": e["P_KEY"]}
print(json.dumps({"tag": e["P_TAG"], "protocol": "shadowsocks", "settings": {"servers": [s]} if e["P_FORM"] == "servers" else s}))
PY
      python3 -c 'import json,sys;json.dump({"outbounds":[json.load(open(sys.argv[1]))]},open(sys.argv[2],"w"))' "$TMP/outbound.$form.json" "$TMP/ob-only.json"
      if panel_xray_test "$TMP/ob-only.json"; then cp "$TMP/outbound.$form.json" "$TMP/outbound.json"; break; fi
    done
    [[ -s $TMP/outbound.json ]] || die "Xray rejected the outbound: $(xray_err | tr '\n' ' ')"
  fi
  NC_OK=0
  if nc -z -w 5 "$IRAN_IP" "$SS_PORT" >/dev/null 2>&1; then NC_OK=1; fi
  TEST_PORT=$(free_port)
  python3 - "$TMP/outbound.json" "$TEST_PORT" "$TMP/xray-test.log" >"$TMP/test-config.json" <<'PY'
import json, sys
ob = json.load(open(sys.argv[1]))
print(json.dumps({"log": {"loglevel": "warning", "error": sys.argv[3]},
  "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
  "outbounds": [ob]}))
PY
  ( cd "$XRAY_DIR" && exec "$XRAY_BIN" run -config "$TMP/test-config.json" >/dev/null 2>&1 ) &
  TEST_PID=$!
  for _ in $(seq 1 20); do if nc -z 127.0.0.1 "$TEST_PORT" 2>/dev/null; then break; fi; sleep 0.25; done
  nc -z 127.0.0.1 "$TEST_PORT" 2>/dev/null || { kill "$TEST_PID" 2>/dev/null || true; die "the temporary Xray did not start: $(tail -n 3 "$TMP/xray-test.log" 2>/dev/null)"; }
}

foreign_test_run() {  # foreign_test_run host...   -> TEST_ROWS and counters (all hosts probed in parallel)
  local d i=0 pids=() f
  rm -f "$TMP"/res.*
  for d in "$@"; do
    (
      rc=0
      out=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 -x "socks5h://127.0.0.1:$TEST_PORT" "https://$d/" 2>/dev/null) || rc=$?
      printf '%s\t%s\t%s\n' "$d" "$rc" "$out" >"$TMP/res.$i"
    ) &
    pids+=($!)
    i=$((i + 1))
  done
  wait "${pids[@]}" 2>/dev/null || true
  kill "$TEST_PID" 2>/dev/null || true
  TEST_ROWS=()
  for ((f = 0; f < i; f++)); do TEST_ROWS+=("$(cat "$TMP/res.$f")"); done
}

foreign_test_report() {  # prints the table + a plain-language verdict; sets TEST_OK / TEST_TOTAL
  local row d rc rest code t word ok=0 total=0 n403=0 verdict
  printf '\n  %-44s %-12s %s\n' "HOST" "RESULT" "TIME"
  for row in "${TEST_ROWS[@]}"; do
    IFS=$'\t' read -r d rc rest <<<"$row"
    code=${rest% *}; t=${rest#* }; total=$((total + 1))
    if [[ $rc == 0 && $code =~ ^[23] ]]; then word="OK"; ok=$((ok + 1))
    elif [[ $rc == 0 ]]; then word="OK ($code)"; ok=$((ok + 1)); if [[ $code == 403 ]]; then n403=$((n403 + 1)); fi
    else word="FAIL"; t="-"; fi
    if [[ $word == FAIL ]]; then
      printf '  %-44s %s%-12s%s %s\n' "${d:0:44}" "$C_R" "$word" "$C_N" "$t"
    else
      printf '  %-44s %s%-12s%s %ss\n' "${d:0:44}" "$C_G" "$word" "$C_N" "$t"
    fi
  done
  TEST_OK=$ok TEST_TOTAL=$total
  echo
  if [[ $NC_OK != 1 ]]; then
    verdict="BROKEN at: foreign -> Iran port ($IRAN_IP:$SS_PORT cannot be reached). The path may be filtered, the relay is down, or the Iran firewall does not allow this server. On Iran: Health check."
  elif ((ok == 0)); then
    verdict="BROKEN after the Iran port: it connects but nothing comes back. Most likely the Iran Shecan DNS is not working (registration lapsed) or Shecan cannot reach Google; a wrong key looks the same. On Iran: Health check, then Register."
  elif ((ok < total)); then
    verdict="PARTLY WORKING: $((total - ok)) host(s) fail. Those hostnames may not be served by Shecan, or are misspelled. Remove them from the list or check them on Iran."
  elif ((n403 == total)); then
    verdict="Answers come back, but every one is 403: Shecan/Google may be refusing the Iran IP. On Iran: Register this IP now."
  else
    verdict="The whole chain works: foreign -> Iran -> Shecan -> Google."
  fi
  echo "  $verdict"
  state_set last_test_ts "$(now)"
  state_set last_test_res "$([[ $ok == "$total" && $total -gt 0 && $NC_OK == 1 ]] && echo "OK $ok/$total" || echo "FAIL $ok/$total ok")"
}

foreign_test() {  # foreign_test [quick]
  local -a hosts=()
  foreign_test_prepare
  mapfile -t hosts < <(foreign_domain_list)
  if [[ ${1:-} == quick || $QUICK == 1 ]]; then
    if [[ $ALL_DOMAINS != 1 ]]; then hosts=(gemini.google.com generativelanguage.googleapis.com); fi
  fi
  log "temporary Xray on 127.0.0.1:$TEST_PORT, only outbound: $TAG -> $IRAN_IP:$SS_PORT (${#hosts[@]} hosts, in parallel)"
  foreign_test_run "${hosts[@]}"
  foreign_test_report
  [[ $TEST_OK == "$TEST_TOTAL" ]] || die "$((TEST_TOTAL - TEST_OK)) of $TEST_TOTAL probes failed"
}

# ------------------------------------------------------------------ learn mode --
learn_log_path() {  # resolved access-log path from T_ACCESS, or empty when logging is off
  local a=$T_ACCESS c
  case $a in ""|none|__unset__) return 0 ;; esac
  if [[ $a == /* ]]; then printf '%s' "$a"; return 0; fi
  for c in "$XRAY_DIR/$a" "$(dirname "$XRAY_DIR")/$a" "$XRAY_DIR/../$a"; do
    if [[ -f $c ]]; then printf '%s' "$c"; return 0; fi
  done
  printf '%s' "$XRAY_DIR/$a"
}

# learn_capture SECONDS OUTFILE FILTER : hosts seen in the access log during the next SECONDS seconds
learn_capture() {
  local secs=$1 out=$2 filt=$3 size0 left
  size0=$(stat -c %s "$LEARN_PATH" 2>/dev/null || echo 0)
  for ((left = secs; left > 0; left--)); do
    printf '\r  capturing...  %3ds left ' "$left"
    sleep 1
  done
  printf '\r  capture finished.            \n'
  python3 - "$LEARN_PATH" "$size0" "$filt" >"$out" <<'PY'
import os, re, sys
path, off, filt = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    size = os.path.getsize(path)
    f = open(path, "rb")
    f.seek(off if size >= off else 0)          # log rotated/truncated: read from the start
    data = f.read().decode("utf-8", "replace")
except OSError:
    data = ""
rx = re.compile(r"accepted (?:tcp|udp):([^:\s\]]+):(\d+)")
ip = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
seen = {}
for line in data.splitlines():
    if filt and filt not in line:
        continue
    m = rx.search(line)
    if not m:
        continue
    h = m.group(1).lower()
    if ip.match(h) or ":" in h:
        continue
    seen[h] = seen.get(h, 0) + 1
for h, n in sorted(seen.items()):
    print("%s\t%d" % (h, n))
PY
}

foreign_learn() {
  need_panel
  read_template
  eval "$(py_tpl inspect "$TMP/template.orig.json")"
  [[ $T_HAS == 1 ]] || die "$TAG is not set up yet - run the setup first (menu: s)"
  need_tty
  local turned_on=0 orig_access=$T_ACCESS idle=20 active=40 filt="" d
  LEARN_PATH=$(learn_log_path)
  if [[ -z $LEARN_PATH ]]; then
    echo "  The panel's access log is OFF (log.access = ${T_ACCESS/__unset__/unset}); learn mode reads it."
    echo "  Turning it on changes the template and restarts the panel (users are dropped for a few seconds)."
    ask_yn "  Turn the access log on for now?" || cancel
    LEARN_PATH=$GM_ROOT/var/log/gemini-menu-access.log
    if [[ $DRY != 1 ]]; then mkdir -p "$(dirname "$LEARN_PATH")"; : >>"$LEARN_PATH"; fi
    state_set learn_orig_access "$orig_access"
    P_ACCESS=$LEARN_PATH py_tpl logaccess "$TMP/template.orig.json" "$TMP/new.json" | sed 's/^/  /'
    foreign_commit "$TMP/new.json"
    turned_on=1
  fi
  if [[ $DRY == 1 ]]; then dry "would capture hostnames twice from $LEARN_PATH and offer the new ones"; return 0; fi
  echo "  Access log: $LEARN_PATH"
  echo "  The log holds ALL users' traffic. To only count your phone, type part of its line"
  echo "  (your client's email/name in the panel, or the phone's IP). Empty = count everything."
  ask_line filt "  Filter text" ""
  ask_line idle "  Seconds to capture with the phone IDLE" "$idle"
  ask_line active "  Seconds to capture while you USE Gemini" "$active"
  echo
  echo "  STEP 1 of 2: put the phone on the VPN, close Gemini and leave it alone."
  printf '  Press Enter to start the idle capture... '; IFS= read -r _ || true
  learn_capture "$idle" "$TMP/learn.idle" "$filt"
  echo "  STEP 2 of 2: now open the Gemini app and use it (chat, upload, voice...)."
  printf '  Press Enter, then start using Gemini right away... '; IFS= read -r _ || true
  learn_capture "$active" "$TMP/learn.active" "$filt"

  python3 - "$TMP/learn.idle" "$TMP/learn.active" "$T_DOMAINS" "${LEARN_SKIP_HOSTS[*]}" "${LEARN_SKIP_SUFFIX[*]}" >"$TMP/learn.new" <<'PY'
import sys
def load(p):
    d = {}
    for line in open(p):
        h, n = line.rstrip("\n").split("\t")
        d[h] = int(n)
    return d
idle, active = load(sys.argv[1]), load(sys.argv[2])
have, skip, suf = set(sys.argv[3].split()), set(sys.argv[4].split()), sys.argv[5].split()
for h, n in sorted(active.items(), key=lambda kv: (-kv[1], kv[0])):
    if h in idle or h in have or h in skip:
        continue
    if any(h == s or h.endswith("." + s) for s in suf):
        continue
    print("%s\t%d" % (h, n))
PY
  MS_LABEL=(); MS_SEL=()
  local h n
  LEARN_HOSTS=()
  while IFS=$'\t' read -r h n; do MS_LABEL+=("$h   ($n request(s))"); MS_SEL+=(0); LEARN_HOSTS+=("$h"); done <"$TMP/learn.new"
  if ((${#MS_LABEL[@]} == 0)); then
    echo
    echo "  No new hostnames appeared in step 2 (idle traffic, hosts already routed and known"
    echo "  background hosts are hidden). Is sniffing on, and did the phone really use the VPN?"
  else
    ui_multiselect "Learn mode: new hostnames" "Tick the ones that belong to Gemini, then press d. Unsure? Leave them out." || true
  fi
  local -a picked=() cur=()
  for d in "${!MS_SEL[@]}"; do if [[ ${MS_SEL[d]} == 1 ]]; then picked+=("${LEARN_HOSTS[d]}"); fi; done
  if ((${#picked[@]} > 0)); then
    mapfile -t cur < <(foreign_domain_list)
    echo "  Adding: ${picked[*]}"
    foreign_domains_apply "${cur[@]}" "${picked[@]}"
    foreign_sync_iran "${cur[@]}" "${picked[@]}"
  fi
  if [[ $turned_on == 1 ]] && ask_yn "  Turn the access log back off (restores log.access = ${orig_access/__unset__/unset})? This restarts the panel again."; then
    read_template
    P_ACCESS=$orig_access py_tpl logaccess "$TMP/template.orig.json" "$TMP/new.json" | sed 's/^/  /'
    foreign_commit "$TMP/new.json"
  fi
}

# ---------------------------------------------------------- sniffing (menu) --
foreign_sniff_fix() {  # foreign_sniff_fix [ids|all]  (asks which ones when no argument and a terminal is present)
  need_panel
  local ids=${1:-} line iid remark port proto probs
  local -a all=()
  while IFS=$'\t' read -r iid remark port proto probs; do all+=("$iid|$remark|$port|$proto|$probs"); done < <(python3 -c "$SNIFF_PY" list "$DB" /dev/null)
  if ((${#all[@]} == 0)); then echo "  Every enabled inbound already sniffs correctly - nothing to fix."; return 0; fi
  if [[ -z $ids ]]; then
    MS_LABEL=(); MS_SEL=()
    for line in "${all[@]}"; do IFS='|' read -r iid remark port proto probs <<<"$line"; MS_LABEL+=("$remark :$port $proto - $probs"); MS_SEL+=(1); done
    ui_multiselect "Fix sniffing" "These inbounds have a problem. Tick the ones to fix, then d." || cancel
    local i sel=()
    for i in "${!MS_SEL[@]}"; do if [[ ${MS_SEL[i]} == 1 ]]; then sel+=("${all[i]%%|*}"); fi; done
    ((${#sel[@]} > 0)) || cancel
    ids=$(IFS=,; echo "${sel[*]}")
  fi
  echo "  Will set on inbound id(s) $ids: sniffing ON with http+tls, routeOnly off, metadataOnly off."
  echo "  (The old values are saved in the backup, so Backups > restore can undo it.)"
  read_template
  cp "$TMP/template.orig.json" "$TMP/new.json"; echo 0 >"$TMP/new.json.changed"
  COMMIT_FIX_IDS=$ids
  foreign_commit "$TMP/new.json"
}

# ----------------------------------------------------------------- backups --
foreign_bk_summary() {
  local d=$1 s=""
  [[ -f $d/template.orig.json ]] && s+="template "
  [[ -f $d/sniffing.orig.json ]] && s+="sniffing "
  [[ -f $d/x-ui.db ]] && s+="db-copy "
  [[ -f $d/foreign.manifest.rolledback ]] && s+="[undone]"
  echo "${s:-(empty)}"
}
foreign_backup_diff() {  # DIR : what restoring that backup's template would change
  need_cmds python3
  [[ -f $1/template.orig.json ]] || { echo "This backup holds no template copy."; return 0; }
  [[ -n $DB ]] || find_db
  read_template
  echo "  Restoring this backup would change the CURRENT template like this:"
  P_IN2=$1/template.orig.json py_tpl diff "$TMP/template.orig.json" | sed 's/^/    /'
}
foreign_backup_restore() {  # DIR
  need_panel
  local d=$1
  [[ -f $d/template.orig.json ]] || die "this backup holds no template copy"
  read_template
  P_IN2=$d/template.orig.json P_OUT=$TMP/new.json py_tpl diff "$TMP/template.orig.json" "$TMP/new.json" | sed 's/^/  /'
  COMMIT_RESTORE_FILE=""
  if [[ -f $d/sniffing.orig.json ]] && ask_opt "  This backup also saved sniffing values. Restore them too?"; then COMMIT_RESTORE_FILE=$d/sniffing.orig.json; fi
  foreign_commit "$TMP/new.json"
}

# ------------------------------------------------------------------ revert --
foreign_revert() {
  need_panel
  read_template
  local first="" d restore_full=0
  py_tpl revert "$TMP/template.orig.json" "$TMP/new.json" | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || die "could not compute the change"
  # the template as it was before this tool first touched it = the oldest backup copy
  for d in $(bk_dirs | sort); do if [[ -f $d/template.orig.json ]]; then first=$d; break; fi; done
  if [[ -n $first ]]; then
    echo "  Compared with the template from before this tool first ran ($(basename "$first")):"
    P_IN2=$first/template.orig.json py_tpl diff "$TMP/new.json" | sed 's/^/    /'
    if ! grep -q '^= identical' < <(P_IN2=$first/template.orig.json py_tpl diff "$TMP/new.json"); then
      if ask_opt "  Restore that ORIGINAL template completely (drops template edits made since)?"; then restore_full=1; fi
    fi
  fi
  if [[ $restore_full == 1 ]]; then cp "$first/template.orig.json" "$TMP/new.json"; echo 1 >"$TMP/new.json.changed"; fi
  # sniffing values: oldest saved value per inbound wins
  python3 - "$BACKUP_ROOT" "$TMP/sniff.merge.json" <<'PY'
import glob, json, os, sys
merged = {}
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*", "sniffing.orig.json"))):
    for k, v in json.load(open(p)).items():
        merged.setdefault(k, v)
json.dump(merged, open(sys.argv[2], "w"))
PY
  COMMIT_RESTORE_FILE=""
  if [[ $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/sniff.merge.json") -gt 0 ]]; then
    echo "  Sniffing values saved by this tool will be put back as well."
    COMMIT_RESTORE_FILE=$TMP/sniff.merge.json
  fi
  foreign_commit "$TMP/new.json"
}

# ----------------------------------------------------------- guided setup --
foreign_guided_setup() {
  local ip="" kf=""
  foreign_facts >/dev/null 2>&1 || true
  echo "  Guided setup of the foreign side. You need the Iran relay's IP and its key file."
  echo "  (On Iran: menu 3 'Connection info' shows the two commands that bring the key file here.)"
  ask_line ip "Iran server IPv4 address" "${T_IP:-$IRAN_IP}"
  valid_ipv4 "$ip" || die "that is not an IPv4 address"
  ask_line kf "Path of the key file on THIS server" "${KEY_FILE:-/root/gemini-ss.key}"
  IRAN_IP=$ip KEY_FILE=$kf
  foreign_setup
}

foreign_setup() {
  need_cmds sqlite3 python3 nc base64
  if [[ $DRY != 1 && $EUID -ne 0 ]]; then die "run as root (or use --dry-run)"; fi
  read_inputs
  log "checking foreign -> Iran reachability: $IRAN_IP:$SS_PORT"
  if nc -zv -w 5 "$IRAN_IP" "$SS_PORT"; then NC_OK=1; else NC_OK=0; fi
  if [[ $NC_OK != 1 ]]; then
    die "$IRAN_IP:$SS_PORT is not reachable from this server. The foreign -> Iran path may be filtered, the relay may not be running,
or the Iran firewall does not allow this server's IP. Fix that first (set up the Iran side, check the allowed foreign IP), then re-run."
  fi
  if [[ -z $DB ]]; then find_db; fi
  if [[ -z $XRAY_DIR ]]; then find_xray; fi
  read_template
  log "== Patching the template"
  local form ok="" cur
  cur=$(eval "$(py_tpl inspect "$TMP/template.orig.json")"; echo "$T_DOMAINS")
  if [[ -n $cur ]]; then read -r -a GEMINI_DOMAINS <<<"$cur"; log "keeping the current domain list (${#GEMINI_DOMAINS[@]} hosts)"; fi
  if panel_xray_test "$TMP/template.orig.json"; then log "original template passes 'xray -test'"
  else warn "the ORIGINAL template does not pass 'xray -test' in this environment: $(xray_err | tr '\n' ' ')"; fi
  for form in servers flat; do
    P_FORM=$form P_IP=$IRAN_IP P_PORT=$SS_PORT P_KEY=$KEY_VAL P_METHOD=$SS_METHOD P_DOMAINS="${GEMINI_DOMAINS[*]}" \
      py_tpl patch "$TMP/template.orig.json" "$TMP/template.$form.json" >"$TMP/patch.$form.log"
    if panel_xray_test "$TMP/template.$form.json"; then ok=$form; break; fi
    warn "Xray rejected the '$form' outbound form: $(xray_err | tr '\n' ' ')"
  done
  [[ -n $ok ]] || die "Xray rejected the patched template in both outbound forms; nothing was written"
  sed 's/^/  /' "$TMP/patch.$ok.log"
  log "patched template validated with the panel's Xray (outbound form: $ok)"
  sniff_audit
  COMMIT_FIX_IDS=""
  if [[ $FIX_SNIFFING == 1 && $SNIFF_FLAGGED -gt 0 ]]; then COMMIT_FIX_IDS=all; fi
  foreign_commit "$TMP/template.$ok.json"
  echo
  echo "Next: gemini-menu foreign test      (checks foreign -> Iran -> Shecan -> Google)"
  echo "Undo: gemini-menu foreign rollback"
}

# ============================================================= iran: menus ====
iran_follow() {  # live tail; Ctrl-C stops the tail only and returns to the menu
  trap ':' INT
  "$@" || true
  trap on_int INT
}

iran_health_screen() {
  ui_screen "Health check"
  printf '  running live checks (the DNS test takes a few seconds)...\n\n'
  iran_checks
  chk_render verbose
  echo
  if chk_worst; then echo "  Everything is fine."; fi
  ui_pause
}

iran_domains_menu() {
  local k cur=() i h n
  while true; do
    ui_screen "Domain list (Shecan DNS + routing)"
    mapfile -t cur < <(cfg_py domains 2>/dev/null || true)
    for i in "${!cur[@]}"; do
      if ((i < 12)); then printf '  %2d. %s\n' "$((i + 1))" "${cur[i]}"; fi
    done
    if ((${#cur[@]} > 12)); then printf '  ... and %d more\n' "$((${#cur[@]} - 12))"; fi
    echo
    mi 1 "Add a hostname" "افزودن دامنه"
    mi 2 "Remove a hostname" "حذف دامنه"
    echo "  Changes are checked with 'xray -test' first; only $SVC restarts."
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) ask_line h "Hostname to add (e.g. gemini.google.com)" ""
         do_action "Add $h" iran_domain_add "$h" || true
         echo "  Remember: the foreign server must route the same host (foreign menu 5)."; ui_pause ;;
      2) ask_line n "Number or hostname to remove" ""
         if [[ $n =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#cur[@]} ]]; then h=${cur[n - 1]}; else h=$n; fi
         do_action "Remove $h" iran_domain_remove "$h" || true
         echo "  Remember: remove it on the foreign server too (foreign menu 5)."; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

iran_logs_menu() {
  local k m
  while true; do
    ui_screen "Logs"
    local until; until=$(state_get access_until)
    if [[ $(cfg_py access 2>/dev/null) == on ]]; then
      st_line warn "Access log is ON${until:+ (auto-off in $(((until - $(now)) / 60 + 1)) min)}"
    else
      st_line info "Access log is off (normal: connections are not recorded)"
    fi
    echo
    mi 1 "Last 50 lines - relay" "۵۰ خط آخر رله"
    mi 2 "Last 50 lines - health timer" "۵۰ خط آخر تایمر"
    mi 3 "Live tail (Ctrl-C stops)" "نمایش زنده"
    mi 4 "Access log ON for N minutes" "روشن کردن لاگ دسترسی"
    mi 5 "Access log OFF now" "خاموش کردن لاگ دسترسی"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) journalctl -u "$SVC" -n 50 --no-pager; ui_pause ;;
      2) journalctl -u "$WATCH_SVC" -n 50 --no-pager; ui_pause ;;
      3) echo "  Live log of $SVC - press Ctrl-C to stop."; iran_follow journalctl -u "$SVC" -f -n 10 -o cat ;;
      4) ask_line m "Minutes (1-240)" "10"
         do_action "Access log ON for $m min" iran_access_on "$m" || true; ui_pause ;;
      5) do_action "Access log OFF" iran_access_off || true; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

iran_service_menu() {
  local k
  while true; do
    ui_screen "Service, timer and alerts"
    st_line info "$SVC: $(systemctl is-active "$SVC" 2>/dev/null || echo unknown)   timer: $(systemctl is-active "$WATCH_SVC.timer" 2>/dev/null || echo unknown)"
    st_line info "Telegram alerts: $([[ -f $WATCH_ENV ]] && echo configured || echo 'not configured')"
    echo
    mi 1 "Start relay" "روشن کردن"
    mi 2 "Restart relay" "راه‌اندازی مجدد"
    mi 3 "Stop relay" "توقف"
    mi 4 "Health timer ON" "تایمر سلامت روشن"
    mi 5 "Health timer OFF" "تایمر سلامت خاموش"
    mi 6 "Telegram alerts: set / change" "هشدار تلگرام"
    mi 7 "Telegram alerts: remove" "حذف هشدار"
    mi 8 "Update the timer's copy of this tool" "به‌روزرسانی تایمر"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) do_action "Start $SVC" iran_service start || true; ui_pause ;;
      2) do_action "Restart $SVC" iran_service restart || true; ui_pause ;;
      3) do_action "Stop $SVC" iran_service stop || true; ui_pause ;;
      4) do_action "Health timer on" iran_timer on || true; ui_pause ;;
      5) do_action "Health timer off" iran_timer off || true; ui_pause ;;
      6) do_action "Telegram alerts" iran_tg_set || true; ui_pause ;;
      7) do_action "Remove Telegram alerts" iran_tg_off || true; ui_pause ;;
      8) do_action "Update timer copy" iran_update_watch_copy || true; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}
iran_update_watch_copy() {
  iran_need_installed
  if [[ $DRY == 1 ]]; then dry "would copy this tool to $WATCH_BIN"; return 0; fi
  ask_yn "Copy this version of the tool to $WATCH_BIN (used by the timer)?" || cancel
  begin_step "Update timer copy"
  install_watch_copy
  end_step
  log "timer copy is now this version"
}

iran_backups_menu() {
  local k i n off=0
  local -a dirs=()
  while true; do
    ui_screen "Backups"
    mapfile -t dirs < <(bk_dirs | sed -n "$((off + 1)),$((off + 9))p")
    if ((${#dirs[@]} == 0)); then echo "  No backups yet. They are created the first time something changes."; fi
    for i in "${!dirs[@]}"; do printf '  %d) %s  %s\n' "$((i + 1))" "$(basename "${dirs[i]}")" "$(iran_bk_summary "${dirs[i]}")"; done
    echo
    echo "  Pick a number to look at it (diff / restore config / undo the whole run)."
    echo "  f) older ones   b) newer ones"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      [1-9]) n=$((k - 1)); if ((n < ${#dirs[@]})); then iran_backup_detail "${dirs[n]}"; fi ;;
      f) if ((${#dirs[@]} == 9)); then off=$((off + 9)); fi ;;
      b) off=$((off >= 9 ? off - 9 : 0)) ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}
iran_backup_detail() {  # DIR
  local d=$1 k
  while true; do
    ui_screen "Backup $(basename "$d")"
    echo "  Contains: $(iran_bk_summary "$d")"
    echo
    mi 1 "Diff: this backup's config vs current" "مقایسه با تنظیمات فعلی"
    mi 2 "Restore this backup's config" "بازگردانی تنظیمات"
    mi 3 "Undo the whole run it belongs to" "لغو کل آن اجرا"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) iran_backup_diff "$d"; ui_pause ;;
      2) do_action "Restore config from $(basename "$d")" iran_backup_restore "$d" || true; ui_pause ;;
      3) BACKUP_DIR_ARG=$d do_action "Undo run $(basename "$d")" iran_rollback_main || true; BACKUP_DIR_ARG=""; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

iran_menu() {
  local k need=1 ip
  while true; do
    if ((need)); then printf '\n  checking...\n'; iran_checks; need=0; fi
    ui_screen "Iran relay"
    chk_render
    echo
    mi 1 "Health check" "بررسی سلامت"
    mi 2 "Register this IP with Shecan" "ثبت IP در شکن"
    mi 3 "Connection info" "اطلاعات اتصال"
    mi 4 "Change allowed foreign IP" "تغییر IP مجاز سرور خارج"
    mi 5 "Domain list" "فهرست دامنه‌ها"
    mi 6 "Logs" "لاگ‌ها"
    mi 7 "Service, timer, alerts" "سرویس و هشدار"
    mi 8 "Backups" "پشتیبان‌ها"
    mi 9 "Uninstall" "حذف کامل"
    ui_footer "0) Exit   s) Guided setup"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) iran_health_screen ;;
      2) ui_screen "Register with Shecan"; do_action "Register IP with Shecan" iran_register_now || true; ui_pause; need=1 ;;
      3) ui_screen "Connection info"
         do_action "Connection info" iran_info || true
         printf '\n  r = reveal the key once, any other key = back: '; k=$(ui_key); echo
         if [[ $k == r ]]; then do_action "Reveal key" iran_reveal_key || true; fi ;;
      4) ui_screen "Change allowed foreign IP"
         iran_load_runtime; echo "  Currently allowed: ${FOREIGN_IP:-?}"
         ask_line ip "  New foreign server IPv4" ""
         do_action "Allow $ip" iran_change_foreign_ip "$ip" || true; ui_pause; need=1 ;;
      5) iran_domains_menu; need=1 ;;
      6) iran_logs_menu; need=1 ;;
      7) iran_service_menu; need=1 ;;
      8) iran_backups_menu; need=1 ;;
      9) ui_screen "Uninstall"; do_action "Uninstall the Iran relay" iran_uninstall || true; ui_pause; need=1 ;;
      s) ui_screen "Guided setup"; do_action "Guided setup" iran_guided_setup || true; ui_pause; need=1 ;;
      r) need=1 ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

# =========================================================== foreign: menus ====
foreign_inbounds_tsv() {  # tag <TAB> port <TAB> remark <TAB> protocol   (enabled client inbounds)
  python3 - "$DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=30)
for tag, port, remark, proto, en in con.execute("select tag, port, remark, protocol, enable from inbounds order by id"):
    if proto in ("tunnel", "dokodemo-door") or not en:
        continue
    print("%s\t%s\t%s\t%s" % (tag, port, remark, proto))
PY
}

foreign_scope_pick() {
  need_panel
  foreign_facts || die "cannot read the template"
  [[ $T_STATE != missing ]] || die "the Gemini rules are not in the template yet - run the setup first (menu: s)"
  local tag port remark proto i total picked=() tags=()
  MS_LABEL=(); MS_SEL=()
  while IFS=$'\t' read -r tag port remark proto; do
    tags+=("$tag"); MS_LABEL+=("$tag  :$port  ${remark:-(no name)}  [$proto]")
    if [[ $T_SCOPE == all || ",$T_SCOPE," == *",$tag,"* ]]; then MS_SEL+=(1); else MS_SEL+=(0); fi
  done < <(foreign_inbounds_tsv)
  total=${#tags[@]}
  ((total > 0)) || die "no enabled client inbounds found in the panel"
  ui_multiselect "Scope: who uses $TAG" "Ticked inbounds send the Gemini hosts to Iran. Everything ticked = all inbounds." || cancel
  for i in "${!MS_SEL[@]}"; do if [[ ${MS_SEL[i]} == 1 ]]; then picked+=("${tags[i]}"); fi; done
  ((${#picked[@]} > 0)) || die "nothing ticked - to switch Gemini routing off use menu 3"
  if ((${#picked[@]} == total)); then foreign_scope_apply; else foreign_scope_apply "${picked[@]}"; fi
}

foreign_status_screen() {
  ui_screen "Status and diagnosis"
  printf '  running checks...\n\n'
  foreign_checks
  chk_render verbose
  echo
  if chk_worst; then echo "  Everything is fine."; fi
  ui_pause
}

foreign_routing_menu() {
  local k
  while true; do
    ui_screen "Gemini routing ON / OFF"
    foreign_facts || true
    case $T_STATE in
      on)  st_line ok "Gemini routing is ON (scope: $T_SCOPE)" ;;
      off) st_line warn "Gemini routing is OFF (scope kept: $T_SCOPE)" ;;
      partial) st_line warn "The two rules disagree - switch ON to make them consistent" ;;
      *)   st_line fail "The Gemini rules are not in the template - run the setup (s)" ;;
    esac
    echo "  OFF keeps both rules in the template but makes them match nothing, so Gemini"
    echo "  goes out the normal way. Good for quick A/B tests. Each switch restarts the panel."
    echo
    mi 1 "Switch ON" "روشن"
    mi 2 "Switch OFF" "خاموش"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) do_action "Gemini routing ON" foreign_routing_set on || true; ui_pause ;;
      2) do_action "Gemini routing OFF" foreign_routing_set off || true; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

foreign_domains_menu() {
  local k cur=() i h n
  while true; do
    ui_screen "Domain list"
    mapfile -t cur < <(foreign_domain_list 2>/dev/null || true)
    for i in "${!cur[@]}"; do
      if ((i < 12)); then printf '  %2d. %s\n' "$((i + 1))" "${cur[i]}"; fi
    done
    if ((${#cur[@]} > 12)); then printf '  ... and %d more\n' "$((${#cur[@]} - 12))"; fi
    echo
    mi 1 "Add a hostname" "افزودن دامنه"
    mi 2 "Remove a hostname" "حذف دامنه"
    echo "  After a change you can push the same list to the Iran relay."
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) ask_line h "Hostname to add (e.g. gemini.google.com)" ""
         if do_action "Add $h" foreign_domain_add "$h"; then mapfile -t cur < <(foreign_domain_list); foreign_sync_iran "${cur[@]}"; fi
         ui_pause ;;
      2) ask_line n "Number or hostname to remove" ""
         if [[ $n =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#cur[@]} ]]; then h=${cur[n - 1]}; else h=$n; fi
         if do_action "Remove $h" foreign_domain_remove "$h"; then mapfile -t cur < <(foreign_domain_list); foreign_sync_iran "${cur[@]}"; fi
         ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

foreign_sniffing_menu() {
  local k
  while true; do
    ui_screen "Sniffing"
    python3 -c "$SNIFF_PY" audit "$DB" "$TMP/sniff.count"
    echo
    echo "  Domain rules only work if the inbound sniffs tls/http (and routeOnly is off)."
    mi 1 "Fix selected inbounds" "اصلاح اینباندهای انتخابی"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) do_action "Fix sniffing" foreign_sniff_fix || true; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

foreign_backups_menu() {
  local k n off=0
  local -a dirs=()
  while true; do
    ui_screen "Backups"
    mapfile -t dirs < <(bk_dirs | sed -n "$((off + 1)),$((off + 9))p")
    if ((${#dirs[@]} == 0)); then echo "  No backups yet. They are created the first time something changes."; fi
    for n in "${!dirs[@]}"; do printf '  %d) %s  %s\n' "$((n + 1))" "$(basename "${dirs[n]}")" "$(foreign_bk_summary "${dirs[n]}")"; done
    echo
    echo "  Pick a number: see what restoring it would change, or restore it."
    echo "  f) older ones (the oldest = the template from before this tool)   b) newer ones"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      [1-9]) n=$((k - 1)); if ((n < ${#dirs[@]})); then foreign_backup_detail "${dirs[n]}"; fi ;;
      f) if ((${#dirs[@]} == 9)); then off=$((off + 9)); fi ;;
      b) off=$((off >= 9 ? off - 9 : 0)) ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}
foreign_backup_detail() {
  local d=$1 k
  while true; do
    ui_screen "Backup $(basename "$d")"
    echo "  Contains: $(foreign_bk_summary "$d")   (the state BEFORE that run)"
    echo
    mi 1 "Diff against the current template" "مقایسه با وضعیت فعلی"
    mi 2 "Restore it" "بازگردانی"
    ui_footer "0) Back"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) foreign_backup_diff "$d"; ui_pause ;;
      2) do_action "Restore backup $(basename "$d")" foreign_backup_restore "$d" || true; ui_pause ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

foreign_menu() {
  local k need=1
  while true; do
    if ((need)); then printf '\n  checking...\n'; foreign_checks; need=0; fi
    ui_screen "Foreign server (3X-UI)"
    chk_render
    echo
    mi 1 "Status and diagnosis" "وضعیت و عیب‌یابی"
    mi 2 "End-to-end test" "تست سرتاسری"
    mi 3 "Gemini routing ON / OFF" "روشن/خاموش کردن مسیر"
    mi 4 "Scope: which inbounds" "انتخاب اینباندها"
    mi 5 "Domain list" "فهرست دامنه‌ها"
    mi 6 "Learn mode (phone app)" "حالت یادگیری موبایل"
    mi 7 "Sniffing" "اسنیفینگ"
    mi 8 "Backups" "پشتیبان‌ها"
    mi 9 "Revert everything" "بازگردانی کامل"
    ui_footer "0) Exit   s) Guided setup"
    printf ' > '; k=$(ui_key); echo
    case $k in
      1) foreign_status_screen ;;
      2) ui_screen "End-to-end test"; do_action "End-to-end test" foreign_test || true; ui_pause; need=1 ;;
      3) foreign_routing_menu; need=1 ;;
      4) ui_screen "Scope"; do_action "Set scope" foreign_scope_pick || true; ui_pause; need=1 ;;
      5) foreign_domains_menu; need=1 ;;
      6) ui_screen "Learn mode"; do_action "Learn mode" foreign_learn || true; ui_pause; need=1 ;;
      7) foreign_sniffing_menu; need=1 ;;
      8) foreign_backups_menu; need=1 ;;
      9) ui_screen "Revert everything"; do_action "Revert everything" foreign_revert || true; ui_pause; need=1 ;;
      s) ui_screen "Guided setup"; do_action "Guided setup" foreign_guided_setup || true; ui_pause; need=1 ;;
      r) need=1 ;;
      D) if ((DRY)); then DRY=0; else DRY=1; fi ;;
      L) toggle_hints ;;
      0) return 0 ;;
      q) exit 0 ;;
    esac
  done
}

# ================================================================== main ====
SELF=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")

toggle_hints() { if ((HINTS)); then HINTS=0; else HINTS=1; fi; state_set hints "$HINTS"; }

usage() {
  cat <<'EOF'
gemini-menu.sh - menu and commands for "Gemini via Iran-side Shecan"

  gemini-menu.sh                      interactive menu (role is detected)
  gemini-menu.sh [flags] [iran|foreign] <command> [args]

Global flags: --role iran|foreign  --dry-run  --yes  --no-color  --no-hints  -h

IRAN commands
  status                  health check (exit 1 if something is FAIL)
  register                register this IP with Shecan now, with live check
  info [reveal]           IP, port, method, masked key, commands for the foreign side
  foreign-ip <IPv4>       change which IP may reach the relay (firewall only)
  domain list|add H|remove H|set H...   (alias: domains)
  logs [last|timer|follow|access N]   and   access-off
  service start|stop|restart     timer on|off     telegram set|off
  backups [list|diff N|restore N|undo N]
  uninstall               remove only what this tool created
  setup [flags]           install/repair the relay (--foreign-ip --ss-port --key-file
                          --shecan-url-file --xray-version --xray-bin)
  rollback [--backup-dir D]

FOREIGN commands
  status                  health check (exit 1 if something is FAIL)
  test [--quick]          end-to-end test, one row per host
  routing on|off|status   switch the two Gemini rules without deleting them
  scope all | set TAG... | list
  domain list|add H|remove H|set H...   (alias: domains; offers to sync Iran)
  learn                   capture hostnames used by the phone app
  sniffing audit|fix [IDS|all]
  backups [list|diff N|restore N]
  revert                  remove ir-gemini + its rules (restore the pre-tool template)
  setup [flags]           patch the panel template (--iran-ip --ss-port --key-file --db
                          --xray-bin --restart-cmd --fix-sniffing)
  rollback [--restore-full-db] [--backup-dir D]

Other: install-self (copy to /usr/local/bin/gemini-menu), watch (used by the health timer)
EOF
}

detect_role() {
  local f=0 i=0 k
  if [[ -n $ROLE ]]; then return 0; fi
  if locate_db; then f=1; fi
  if [[ -f $UNIT ]] || systemctl cat "$SVC.service" >/dev/null 2>&1; then i=1; fi
  if ((f && !i)); then ROLE=foreign
  elif ((i && !f)); then ROLE=iran
  elif [[ -t 0 && -t 1 ]]; then
    ui_clear
    if ((f && i)); then echo "  Both a 3X-UI panel and the Iran relay were found on this server."
    else echo "  Could not tell which server this is (no 3X-UI database, no $SVC)."; fi
    echo
    echo "  1) Iran server     (the relay)"
    echo "  2) Foreign server  (3X-UI panel)"
    printf '\n  Which one is this? '
    k=$(ui_key); echo
    case $k in 1) ROLE=iran ;; 2) ROLE=foreign ;; *) echo "  Cancelled."; exit 0 ;; esac
  else
    die "cannot tell which server this is - use --role iran|foreign"
  fi
}

set_role() {
  case $ROLE in
    iran)    ROLE_LABEL="IRAN server";    MANIFEST=iran.manifest ;;
    foreign) ROLE_LABEL="FOREIGN server"; MANIFEST=foreign.manifest ;;
    *) die "--role must be iran or foreign" ;;
  esac
}

install_self() {  # copy this file to /usr/local/bin/gemini-menu (and refresh the timer's copy)
  if [[ $DRY == 1 ]]; then dry "would copy $SELF to $INSTALL_PATH"; return 0; fi
  mkdir -p "$(dirname "$INSTALL_PATH")"
  if [[ $SELF != "$INSTALL_PATH" ]]; then install -m 755 "$SELF" "$INSTALL_PATH"; fi
  if [[ -f $WATCH_BIN && $SELF != "$WATCH_BIN" ]]; then install -m 755 "$SELF" "$WATCH_BIN"; fi
  log "installed: type  gemini-menu  from now on"
}

offer_install_self() {
  local sum k
  if [[ ! -t 0 || ! -t 1 || $DRY == 1 || $EUID -ne 0 || $SELF == "$INSTALL_PATH" ]]; then return 0; fi
  if [[ -x $INSTALL_PATH ]] && cmp -s "$SELF" "$INSTALL_PATH"; then return 0; fi
  sum=$(md5sum "$SELF" | cut -d' ' -f1)
  if [[ $(state_get install_declined) == "$sum" ]]; then return 0; fi
  ui_clear
  if [[ -x $INSTALL_PATH ]]; then echo "  A different version of this tool is installed as $INSTALL_PATH."
  else echo "  First run. This tool can install itself so you only type:  gemini-menu"; fi
  printf '\n  Install / update %s now? [y/N] ' "$INSTALL_PATH"
  k=$(ui_key); echo
  if [[ $k == [yY] ]]; then run_action install_self || true; sleep 1
  else state_set install_declined "$sum"; fi
}

cli_backup_dir() {  # the N-th newest backup dir
  local d; d=$(bk_dirs | sed -n "${1:-0}p")
  [[ -n $d ]] || die "no backup number ${1:-?} (see: backups list)"
  printf '%s' "$d"
}

cli_backups_list() {  # cli_backups_list SUMMARY_FUNCTION
  local i=0 d
  while read -r d; do
    i=$((i + 1))
    printf '  %d) %s  %s\n' "$i" "$(basename "$d")" "$("$1" "$d")"
  done < <(bk_dirs | head -n 99)
  if ((i == 0)); then echo "  (no backups yet)"; fi
}

cli_iran() {
  local c=${1:-status} d
  shift || true
  case $c in
    status|health) iran_checks; chk_render verbose; chk_worst; [[ $? -lt 2 ]]; exit $? ;;
    register)   run_action iran_register_now ;;
    info)       run_action iran_info "${1:-}" ;;
    foreign-ip) run_action iran_change_foreign_ip "${1:-}" ;;
    domain|domains)
      case ${1:-list} in
        list)   run_action iran_domains_list ;;
        add)    run_action iran_domain_add "${2:-}" ;;
        remove) run_action iran_domain_remove "${2:-}" ;;
        set)    shift; run_action iran_domain_set "$@" ;;
        *) die "domain: use list | add H | remove H | set H..." ;;
      esac ;;
    logs)
      case ${1:-last} in
        last)   journalctl -u "$SVC" -n 50 --no-pager ;;
        timer)  journalctl -u "$WATCH_SVC" -n 50 --no-pager ;;
        follow) iran_follow journalctl -u "$SVC" -f -n 10 -o cat ;;
        access) run_action iran_access_on "${2:-10}" ;;
        *) die "logs: use last | timer | follow | access N" ;;
      esac ;;
    access-off) run_action iran_access_off ;;
    service)    run_action iran_service "${1:-}" ;;
    timer)      run_action iran_timer "${1:-}" ;;
    telegram)   case ${1:-set} in set) run_action iran_tg_set ;; off) run_action iran_tg_off ;; *) die "telegram: use set | off" ;; esac ;;
    backups)
      case ${1:-list} in
        list)    cli_backups_list iran_bk_summary ;;
        diff)    d=$(cli_backup_dir "${2:-}"); iran_backup_diff "$d" ;;
        restore) d=$(cli_backup_dir "${2:-}"); run_action iran_backup_restore "$d" ;;
        undo)    d=$(cli_backup_dir "${2:-}"); BACKUP_DIR_ARG=$d; run_action iran_rollback_main ;;
        *) die "backups: use list | diff N | restore N | undo N" ;;
      esac ;;
    uninstall)  run_action iran_uninstall ;;
    setup|apply) run_action iran_setup_main ;;
    rollback)   run_action iran_rollback_main ;;
    watch)      run_action watch_main ;;
    menu)       iran_menu ;;
    *) die "unknown iran command: $c (see: gemini-menu.sh help)" ;;
  esac
}

cli_sync_iran() {
  local -a l=()
  mapfile -t l < <(foreign_domain_list)
  run_action foreign_sync_iran "${l[@]}"
}

cli_foreign() {
  local c=${1:-status} d
  shift || true
  case $c in
    status|health) foreign_checks; chk_render verbose; chk_worst; [[ $? -lt 2 ]]; exit $? ;;
    test)       run_action foreign_test ;;
    routing)
      case ${1:-status} in
        on|off) run_action foreign_routing_set "$1" ;;
        status) foreign_facts || die "cannot read the template"; echo "Gemini routing: $T_STATE (scope: $T_SCOPE, $T_NDOM hosts)" ;;
        *) die "routing: use on | off | status" ;;
      esac ;;
    scope)
      case ${1:-list} in
        all)  run_action foreign_scope_apply ;;
        set)  shift; run_action foreign_scope_apply "$@" ;;
        list) foreign_facts || die "cannot read the template"; echo "scope: $T_SCOPE"; foreign_inbounds_tsv | awk -F'\t' '{printf "  %s  :%s  %s [%s]\n",$1,$2,$3,$4}' ;;
        *) die "scope: use all | set TAG... | list" ;;
      esac ;;
    domain|domains)
      case ${1:-list} in
        list)   run_action foreign_domain_list ;;
        add)    run_action foreign_domain_add "${2:-}" && cli_sync_iran ;;
        remove) run_action foreign_domain_remove "${2:-}" && cli_sync_iran ;;
        set)    shift; run_action foreign_domain_set "$@" && cli_sync_iran ;;
        *) die "domain: use list | add H | remove H | set H..." ;;
      esac ;;
    learn)      run_action foreign_learn ;;
    sniffing|audit)
      if [[ $c == audit ]]; then set -- audit "$@"; fi
      case ${1:-audit} in
        audit) need_cmds sqlite3 python3; [[ -n $DB ]] || find_db; sniff_audit ;;
        fix)   run_action foreign_sniff_fix "${2:-}" ;;
        *) die "sniffing: use audit | fix [IDS|all]" ;;
      esac ;;
    backups)
      case ${1:-list} in
        list)    cli_backups_list foreign_bk_summary ;;
        diff)    d=$(cli_backup_dir "${2:-}"); [[ -n $DB ]] || find_db; foreign_backup_diff "$d" ;;
        restore) d=$(cli_backup_dir "${2:-}"); run_action foreign_backup_restore "$d" ;;
        *) die "backups: use list | diff N | restore N" ;;
      esac ;;
    revert)     run_action foreign_revert ;;
    setup|apply) run_action foreign_setup ;;
    rollback)   run_action foreign_rollback_main ;;
    menu)       foreign_menu ;;
    *) die "unknown foreign command: $c (see: gemini-menu.sh help)" ;;
  esac
}

iran_setup_main() {
  need_cmds ss curl dig openssl python3 systemctl base64 sha256sum nc
  if [[ $DRY == 1 ]]; then log "DRY RUN - nothing will be changed"; fi
  resolve_inputs
  resolve_shecan_url
  discover
  check_port_free
  if iran_installed; then   # re-running over an installed relay keeps a customised domain list
    local -a cur=()
    mapfile -t cur < <(cfg_py domains 2>/dev/null || true)
    if ((${#cur[@]} > 0)); then GEMINI_DOMAINS=("${cur[@]}"); log "keeping the current domain list (${#cur[@]} hosts)"; fi
  fi
  log "Plan: relay on :$SS_PORT/tcp for $FOREIGN_IP, service $SVC, Xray ${XRAY_VERSION}$([[ -n $XRAY_BIN_SRC ]] && echo " (local binary)")"
  if [[ $DRY != 1 ]]; then confirm "Proceed? (nothing on this server's tunnel or existing firewall rules is modified)" || die "aborted"; fi

  XRAY_CHECK_BIN=""
  begin_step "SS key file"; save_key_file; end_step
  step_install_xray
  step_service_user_and_config
  step_service
  step_firewall
  step_shecan
  step_selftest
  step_watch

  local ip; ip=$(iran_detect_ip)
  echo
  log "DONE$([[ $DRY == 1 ]] && echo ' (dry run - nothing was changed)')"
  echo "  SS key file : $KEY_FILE   (copy it to the foreign server; the key is not printed)"
  echo "  On the foreign server run:"
  echo "    scp root@${ip:-<IRAN_IP>}:$KEY_FILE /root/gemini-ss.key"
  echo "    gemini-menu foreign setup --iran-ip ${ip:-<IRAN_IP>} --key-file /root/gemini-ss.key$([[ $SS_PORT != 20443 ]] && echo " --ss-port $SS_PORT")"
  if [[ -n $ip ]]; then echo "  (detected outbound address $ip - use the public IP registered with Shecan if it differs)"; fi
  echo "  Health and everything else: gemini-menu   (install it with: $0 install-self)"
}

parse_args() {
  POS=()
  while (($#)); do
    case $1 in
      --role)            ROLE=${2:?}; shift ;;
      --dry-run)         DRY=1 ;;
      --yes|-y)          YES=1 ;;
      --no-color)        NO_COLOR=1 ;;
      --no-hints)        HINTS=0; HINTS_FORCED=1 ;;
      --rollback)        FLAG_CMD=rollback ;;
      --legacy)          QUICK=1 ;;
      --quick)           QUICK=1 ;;
      --foreign-ip)      FOREIGN_IP=${2:?}; shift ;;
      --iran-ip)         IRAN_IP=${2:?}; shift ;;
      --ss-port)         SS_PORT=${2:?}; shift ;;
      --key-file)        KEY_FILE_ARG=${2:?}; KEY_FILE=$KEY_FILE_ARG; shift ;;
      --shecan-url-file) SHECAN_URL_FILE_ARG=${2:?}; shift ;;
      --xray-version)    XRAY_VERSION=${2:?}; shift ;;
      --xray-bin)        XRAY_BIN_SRC=${2:?}; XRAY_BIN=$XRAY_BIN_SRC; shift ;;
      --db)              DB=${2:?}; shift ;;
      --restart-cmd)     RESTART_CMD=${2:?}; shift ;;
      --fix-sniffing)    FIX_SNIFFING=1 ;;
      --all-domains)     ALL_DOMAINS=1 ;;
      --restore-full-db) RESTORE_FULL_DB=1 ;;
      --backup-dir)      BACKUP_DIR_ARG=${2:?}; shift ;;
      -h|--help)         FLAG_CMD=help ;;
      --*)               die "unknown flag: $1 (see: gemini-menu.sh help)" ;;
      *)                 POS+=("$1") ;;
    esac
    shift
  done
}

main() {
  local cmd=""
  FLAG_CMD=""; HINTS_FORCED=0
  parse_args "$@"
  ui_colors
  if [[ $FLAG_CMD == help || ${POS[0]:-} == help ]]; then usage; exit 0; fi
  TMP=$(mktemp -d)
  trap cleanup EXIT
  trap on_int INT
  if ((HINTS_FORCED == 0)) && [[ $(state_get hints) == 0 ]]; then HINTS=0; fi

  if [[ ${POS[0]:-} == iran || ${POS[0]:-} == foreign ]]; then ROLE=${POS[0]}; POS=("${POS[@]:1}"); fi
  cmd=${POS[0]:-}
  [[ -n $cmd ]] && POS=("${POS[@]:1}")

  case $cmd in
    install-self) run_action install_self; exit $? ;;
    watch) ROLE=iran; set_role; run_action watch_main; exit $? ;;
  esac
  if [[ -z $cmd && -n $FLAG_CMD ]]; then cmd=$FLAG_CMD; fi
  if [[ -n $FLAG_CMD && $FLAG_CMD == rollback ]]; then cmd=rollback; fi

  detect_role
  set_role
  if [[ $ROLE == foreign ]]; then locate_db || true; locate_xray || true; fi
  if [[ $ROLE == iran ]]; then iran_load_runtime 2>/dev/null || true; fi

  if [[ -z $cmd ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then die "the menu needs a terminal - run a subcommand instead (gemini-menu.sh help)"; fi
    if [[ $ROLE == iran ]]; then need_cmds ss curl dig openssl python3 systemctl nc; else need_cmds sqlite3 python3 nc curl; fi
    offer_install_self
    audit_log "menu opened"
    if [[ $ROLE == iran ]]; then iran_menu; else foreign_menu; fi
    ui_clear
    exit 0
  fi

  if [[ $ROLE == iran ]]; then cli_iran "$cmd" "${POS[@]}"; else cli_foreign "$cmd" "${POS[@]}"; fi
  exit $?
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
