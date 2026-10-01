# shellcheck shell=bash
# 60-iran-actions.sh - every Iran-side operation as an action (run through act_run).
#
# Conventions
#   * prompts:   prompt_x var "Label" || act_cancel      (typos re-ask; b cancels; never dies)
#   * changes:   iran_step "title" ... iran_step_done     (a failing step undoes only itself;
#                finished steps are kept and listed as PARTIAL)
#   * dry-run:   every change is guarded by is_dry / put_file / act_do and only describes itself
#   * nothing here calls die/exit directly: act_fail / act_cancel end the action

# ================================================================== health ====================
# Runs in the MAIN shell (call:) so the probe cache it refreshes is the one the dashboard shows.
iran_act_health() {
  ui_blank
  probe_refresh 1
  ui_rule "Health check"
  probe_report
  ui_blank
  case $(probe_worst) in
    ok)   ui_ok "Everything is fine." ;;
    warn) ui_warn "Works, but something needs attention (see the lines above)." ;;
    *)    ui_err "Something is broken (see what to do above). Health Check & Status > 'Fix everything that is wrong' handles the common cases." ;;
  esac
}

# CLI: prints the report and returns 0 healthy | 1 warn-only | 2 broken
iran_cli_status() {
  probe_refresh 1
  probe_report
  case $(probe_worst) in ok) return 0 ;; warn) return 1 ;; *) return 2 ;; esac
}

# ================================================================== registration ==============
iran_ask_shecan_url() {
  local u
  prompt_valid u "Shecan registration URL (paste it here)" "" v_url || act_cancel
  mkdir_tracked "$STATE_DIR" 700
  put_file "$URL_FILE" 600 root:root < <(printf '%s\n' "$u")
}

iran_verify_loop() {
  local i
  ui_note "checking the Shecan DNS answer (live, up to a few seconds)..."
  for i in 1 2 3; do
    if verify_hijack; then
      ui_ok "Shecan DNS check: $VERIFY_MSG"
      return 0
    fi
    ui_note "attempt $i/3: $VERIFY_MSG"
    if ((i < 3)); then sleep "${GM_DNS_RETRY_SLEEP:-5}"; fi
  done
  act_fail "registered, but the DNS check still fails: $VERIFY_MSG"
}

iran_register_call() {
  shecan_register "$URL_FILE" \
    || act_fail "registration call failed (curl exit $REG_RC; the URL is never shown). Check the URL/token and IPv4 internet access."
  state_set last_register_ok "$(now)"
  ui_ok "registration call succeeded"
}

iran_act_register() {
  iran_need_installed
  if [[ ! -r $URL_FILE ]]; then
    ui_note "No registration URL is stored yet."
    if is_dry; then dry_say "would ask for the Shecan URL and store it in $URL_FILE (mode 600)"; else iran_ask_shecan_url; fi
  fi
  if is_dry; then
    dry_say "would call the registration URL (never shown) with curl -4, then compare Shecan DNS with a neutral resolver"
    return 0
  fi
  confirm "Register this server's IP with Shecan now?" || act_cancel
  iran_register_call
  iran_verify_loop
}

iran_reconcile_register() {
  iran_need_installed
  iran_step "Shecan registration"
  if [[ ! -r $URL_FILE ]]; then
    ui_warn "no stored Shecan URL - use 'Register this IP' (it asks for it)"
    return 0
  fi
  if is_dry; then dry_say "would re-register and verify the DNS answer"; return 0; fi
  iran_register_call
  iran_verify_loop
  iran_step_done
}

# ================================================================== connection info ===========
iran_act_info() {
  iran_need_installed
  local ip keyf=$DEFAULT_KEY_FILE port_arg=""
  ip=$(iran_detect_ip)
  iran_load_key
  if [[ $SS_PORT != 20443 ]]; then port_arg=" --ss-port $SS_PORT"; fi
  ui_box_top "Connection info"
  ui_box_kv "This server" "${ip:-unknown}  ${C_DIM}(use the public IP registered with Shecan)${C_0}"
  ui_box_kv "Relay port" "$SS_PORT/tcp"
  ui_box_kv "Method" "$SS_METHOD"
  ui_box_kv "Allowed from" "${FOREIGN_IP:-unknown}"
  ui_box_kv "Key" "$(mask_key "$SS_KEY_VAL")  ${C_DIM}(last 4 characters only)${C_0}"
  ui_box_bottom
  if [[ ! -r $keyf ]]; then
    ui_warn "the key file is missing: the foreign server needs a file to read the key from"
    if is_dry; then
      dry_say "would save the key to $keyf (mode 600)"
    elif confirm "Create $keyf from the installed config?"; then
      mkdir_tracked "$(dirname "$keyf")" 700
      put_file "$keyf" 600 root:root < <(printf '%s\n' "$SS_KEY_VAL")
    fi
  fi
  ui_blank
  ui_say "On the FOREIGN server run these two commands:"
  ui_say "  scp root@${ip:-<IRAN_IP>}:$keyf /root/gemini-ss.key"
  ui_say "  gemini-menu foreign setup --iran-ip ${ip:-<IRAN_IP>} --key-file /root/gemini-ss.key$port_arg"
}

iran_act_reveal_key() {
  iran_need_installed
  iran_load_key
  ui_warn "The full key is printed ONCE on this screen. Anyone looking at it can read it."
  confirm_force "Show the key now?" || act_cancel
  printf '\n  KEY: %s\n  (not logged) press Enter to wipe it from the screen... ' "$SS_KEY_VAL"
  in_read _ "" || true
  if ((UI_TTY)); then printf '\e[3A\e[J'; fi
  ui_ok "key wiped from the visible screen (your terminal's scrollback may still hold it)"
}

# ================================================================== allowed foreign IP ========
# Idempotent repair: entering the address that is already set still re-checks the rule and
# re-adds it when it is missing. (fixed: the old code answered "already set" and stopped.)
iran_act_change_ip() {
  local new=${1:-} old r
  iran_need_installed
  old=$FOREIGN_IP
  if [[ -z $new ]]; then
    ui_say "Currently allowed: ${old:-none}"
    prompt_ipv4 new "Foreign server IPv4 to allow" "$old" || act_cancel
  else
    v_ipv4 "$new" || act_fail "not a valid IPv4 address: $new ($IN_ERR)"
  fi
  if [[ $new == "$old" ]]; then
    ui_info "$new is already the allowed address - re-checking its firewall rule"
  else
    ui_say "Firewall ($FW_KIND): allow $SS_PORT/tcp from $new   (instead of ${old:-nobody})"
    ui_note "Only the firewall rule changes; the relay config and the tunnel are untouched."
    if ! is_dry; then confirm "Apply?" || act_cancel; fi
  fi
  if is_dry; then
    dry_say "would ensure the rule for $new${old:+, remove the rule for $old}, update $WATCH_CONF"
    return 0
  fi
  iran_step "Firewall: allow $new"
  if [[ $FW_KIND == none ]]; then
    ui_warn "no active firewall: only the stored address changes. Update a provider firewall by hand."
  else
    r=$(fw_ensure "$FW_KIND" "$new" "$SS_PORT")
    case $r in
      added)   manifest_add FW "$FW_KIND" "$new:$SS_PORT"; ui_ok "firewall rule added for $new" ;;
      present) ui_ok "firewall rule for $new is present" ;;
      *)       ui_warn "no suitable input chain found for $FW_KIND - no rule added" ;;
    esac
    if [[ -n $old && $old != "$new" ]]; then
      manifest_add FW_DEL "$FW_KIND" "$old:$SS_PORT"
      fw_remove "$FW_KIND" "$old" "$SS_PORT"
      ui_ok "rule for $old removed"
    fi
  fi
  iran_write_watch_conf "$new" "$SS_PORT" "$FW_KIND"
  iran_step_done
  ui_ok "now only $new may reach port $SS_PORT"
}

# ================================================================== domain list ===============
iran_act_domains_list() {
  iran_need_installed
  local i=0 d
  while IFS= read -r d; do
    i=$((i + 1))
    ui_say "$(printf '%2d. %s' "$i" "$d")"
  done < <(cfg_py domains)
}

# iran_domains_apply host...   (the COMPLETE new list)
iran_domains_apply() {
  local -a new=("$@") old=()
  local d added=() removed=()
  ((${#new[@]} >= 1)) || act_fail "the list cannot be empty"
  mapfile -t old < <(cfg_py domains)
  for d in "${new[@]}"; do if [[ " ${old[*]} " != *" $d "* ]]; then added+=("$d"); fi; done
  for d in "${old[@]}"; do if [[ " ${new[*]} " != *" $d "* ]]; then removed+=("$d"); fi; done
  if ((${#added[@]} + ${#removed[@]} == 0)); then
    ui_ok "the list is already exactly this - nothing to change"
    return 0
  fi
  for d in "${added[@]}"; do ui_say "${C_OK}+${C_0} $d"; done
  for d in "${removed[@]}"; do ui_say "${C_ERR}-${C_0} $d"; done
  ui_note "Applies to Shecan DNS lookups AND routing in the relay config; only $SVC restarts."
  iran_load_key
  GEMINI_DOMAINS=("${new[@]}")
  gen_validate_config
  if is_dry; then dry_say "would write $CONF and restart $SVC"; return 0; fi
  confirm "Apply and restart $SVC (Gemini sessions reconnect in a second)?" || act_cancel
  iran_step "Domain list (${#new[@]} hosts)"
  put_file "$CONF" 640 "root:$SVC" <"$GM_TMP/config.json"
  if ((CHANGED)); then iran_restart_wait || act_fail "$SVC did not come back on port $SS_PORT"; fi
  iran_step_done
  ui_ok "domain list updated (${#new[@]} hosts)"
  ui_warn "The foreign server must route the same hosts (foreign side: domain set ...)."
}

iran_domain_current() { mapfile -t "$1" < <(cfg_py domains); }

iran_act_domain_add() {
  local h=${1:-} d
  local -a cur=()
  iran_need_installed
  if [[ -z $h ]]; then
    prompt_hostname h "Hostname to add (e.g. gemini.google.com)" || act_cancel
  else
    v_hostname "$h" || act_fail "not a valid hostname: $h ($IN_ERR)"
    h=$IN_VALUE
  fi
  iran_domain_current cur
  for d in "${cur[@]}"; do
    if [[ $d == "$h" ]]; then ui_ok "$h is already in the list"; return 0; fi
  done
  iran_domains_apply "${cur[@]}" "$h"
}

iran_act_domain_remove() {
  local h=${1:-} d
  local -a cur=() keep=()
  iran_need_installed
  iran_domain_current cur
  if [[ -z $h ]]; then
    ((${#cur[@]} > 0)) || act_cancel "the list is empty"
    prompt_choice h "Remove which host (number or name)" "" "${cur[@]}" || act_cancel
  else
    v_hostname "$h" || act_fail "not a valid hostname: $h ($IN_ERR)"
    h=$IN_VALUE
  fi
  for d in "${cur[@]}"; do if [[ $d != "$h" ]]; then keep+=("$d"); fi; done
  if ((${#keep[@]} == ${#cur[@]})); then ui_ok "$h is not in the list"; return 0; fi
  iran_domains_apply "${keep[@]}"
}

iran_act_domain_set() {
  local d list=()
  iran_need_installed
  for d in "$@"; do
    v_hostname "$d" || act_fail "not a valid hostname: $d ($IN_ERR)"
    list+=("$IN_VALUE")
  done
  iran_domains_apply "${list[@]}"
}

# ================================================================== logs ======================
iran_act_logs() {  # iran_act_logs relay|timer
  case ${1:-} in
    relay) journalctl -u "$SVC" -n 50 --no-pager ;;
    timer) journalctl -u "$WATCH_SVC" -n 50 --no-pager ;;
    *) act_fail "logs: use relay | timer" 2 ;;
  esac
}

# Main shell (call:): journalctl gets the Ctrl-C, the menu stays. Always returns 0.
iran_logs_follow() {
  ui_note "Live log of $SVC - press Ctrl-C to stop."
  journalctl -u "$SVC" -f -n 10 -o cat || true
  GM_INT=0
  return 0
}

iran_act_access_on() {  # iran_act_access_on [minutes]
  local m=${1:-}
  iran_need_installed
  if [[ -z $m ]]; then
    prompt_int m "Minutes to keep the access log on" 1 240 10 || act_cancel
  else
    v_int_range "$m" 1 240 || act_fail "minutes: $IN_ERR"
    m=$IN_VALUE
  fi
  local self=$INSTALL_PATH
  if [[ ! -x $self ]]; then self=$GM_SELF; fi
  [[ -x $self ]] || is_dry || act_fail "the tool must be installed (gemini-menu iran install-self) so the automatic switch-off can run"
  iran_load_key
  cfg_set_access ""      # empty = Xray writes the access log to stdout, i.e. the journal
  ui_say "Turns the relay's access log ON for $m minute(s): every Gemini connection is logged to the journal."
  ui_note "It switches itself off afterwards (systemd timer), even if you close this session."
  if is_dry; then dry_say "would restart $SVC with access logging and schedule the automatic revert"; return 0; fi
  confirm "Continue? ($SVC restarts briefly)" || act_cancel
  iran_step "Access log on for $m min"
  put_file "$CONF" 640 "root:$SVC" <"$GM_TMP/config.json"
  if ((CHANGED)); then iran_restart_wait || act_fail "$SVC did not come back"; fi
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  must systemd-run --on-active="${m}m" --unit="$REVERT_UNIT" --collect "$self" --role iran --yes access-off >/dev/null
  state_set access_until "$(($(now) + m * 60))"
  iran_step_done
  ui_ok "access log is ON until $(date -d "+$m min" +%H:%M) - read it with: View Logs > Live tail"
}

iran_act_access_off() {
  iran_need_installed
  cfg_set_access none
  if is_dry; then dry_say "would set log.access back to none and restart $SVC"; return 0; fi
  iran_step "Access log off"
  put_file "$CONF" 640 "root:$SVC" <"$GM_TMP/config.json"
  if ((CHANGED)); then iran_restart_wait || act_fail "$SVC did not come back"; fi
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  state_set access_until ""
  iran_step_done
  ui_ok "access log is OFF"
}

# ================================================================== service, timer, alerts ====
iran_act_service() {  # iran_act_service start|stop|restart   (anything else is refused)
  local a=${1:-}
  case $a in
    start | stop | restart) ;;
    *) act_fail "service: use start | stop | restart (got '${a:-nothing}')" 2 ;;
  esac
  iran_need_installed
  ui_say "About to $a $SVC (Gemini requests through the relay pause while it is down)."
  if is_dry; then dry_say "would run: systemctl $a $SVC"; return 0; fi
  confirm "$a $SVC?" || act_cancel
  if [[ $a == restart ]]; then
    iran_restart_wait || act_fail "$SVC did not come back"
  else
    must systemctl "$a" "$SVC"
  fi
  ui_ok "$SVC: $(systemctl is-active "$SVC" 2>/dev/null || true)"
}

iran_act_timer() {  # iran_act_timer on|off   (anything else is refused - '' used to mean off)
  local a=${1:-}
  case $a in on | off) ;; *) act_fail "timer: use on | off (got '${a:-nothing}')" 2 ;; esac
  iran_need_installed
  if is_dry; then dry_say "would turn the health timer $a"; return 0; fi
  if [[ $a == on ]]; then
    must systemctl enable --now "$WATCH_SVC.timer" >/dev/null
  else
    must systemctl disable --now "$WATCH_SVC.timer" >/dev/null
  fi
  ui_ok "health timer: $(systemctl is-active "$WATCH_SVC.timer" 2>/dev/null || true)"
}

iran_act_tg_set() {
  local bot=${TG_BOT:-} chat=${TG_CHAT:-}
  iran_need_installed
  if [[ -z $bot ]]; then prompt_valid bot "Telegram bot token" "" v_tg_token || act_cancel; fi
  if [[ -z $chat ]]; then prompt_valid chat "Telegram chat id" "" v_tg_chat || act_cancel; fi
  ui_say "Alerts go out only when the health timer finds a problem (and when it recovers)."
  ui_say "Token to be stored: $(mask_key "$bot")"
  if is_dry; then dry_say "would store the token in $WATCH_ENV (mode 600)"; return 0; fi
  confirm "Save these alert settings?" || act_cancel
  iran_step "Telegram alert settings"
  put_file "$WATCH_ENV" 600 root:root < <(printf 'TG_BOT=%q\nTG_CHAT=%q\n' "$bot" "$chat")
  iran_step_done
  if TG_BOT=$bot TG_CHAT=$chat tg_post "gemini-shecan on $(hostname): test alert"; then
    ui_ok "test message sent"
  else
    ui_warn "saved, but the test message could not be sent (Telegram may be blocked from this server)"
  fi
}

iran_act_tg_off() {
  iran_need_installed
  if [[ ! -f $WATCH_ENV ]]; then ui_ok "no alert settings are stored"; return 0; fi
  if is_dry; then dry_say "would remove $WATCH_ENV"; return 0; fi
  confirm "Remove the Telegram alert settings?" || act_cancel
  iran_step "Remove Telegram alerts"
  backup_file "$WATCH_ENV"
  rm -f "$WATCH_ENV"
  iran_step_done
  ui_ok "Telegram alerts removed"
}

# ================================================================== repairs (reconcile_*) =====
# Each one makes the machine match the desired state, does nothing when it already does, and can
# be run any number of times.
iran_reconcile_firewall() {
  local kind r
  iran_need_installed
  iran_step "Firewall rule for ${FOREIGN_IP:-?} -> :$SS_PORT"
  [[ -n $FOREIGN_IP ]] || act_fail "the allowed foreign IP is unknown - set it first (Allowed foreign IP / gemini-menu iran foreign-ip IP)"
  kind=$(fw_detect)
  if is_dry; then dry_say "would ensure an ACCEPT rule via $kind for $FOREIGN_IP -> $SS_PORT/tcp"; return 0; fi
  if [[ $kind == none ]]; then
    ui_warn "no active firewall detected - nothing to open. (Provider firewall? allow $SS_PORT/tcp from $FOREIGN_IP there.)"
  else
    r=$(fw_ensure "$kind" "$FOREIGN_IP" "$SS_PORT")
    case $r in
      added)   manifest_add FW "$kind" "$FOREIGN_IP:$SS_PORT"; ui_ok "rule was missing - added" ;;
      present) ui_ok "rule already present" ;;
      *)       ui_warn "no suitable input chain found for $kind - no rule added" ;;
    esac
  fi
  if [[ $kind != "$FW_KIND" ]]; then
    ui_note "firewall kind changed: $FW_KIND -> $kind"
    FW_KIND=$kind
    iran_write_watch_conf "$FOREIGN_IP" "$SS_PORT" "$FW_KIND"
  fi
  iran_step_done
}

iran_reconcile_config() {
  local -a cur=()
  iran_need_installed
  iran_step "Relay config (domain list + catch-all guard)"
  iran_load_key
  iran_domain_current cur
  if ((${#cur[@]} > 0)); then GEMINI_DOMAINS=("${cur[@]}"); fi
  gen_validate_config
  if is_dry; then dry_say "would rewrite $CONF if it differs and restart $SVC"; return 0; fi
  put_file "$CONF" 640 "root:$SVC" <"$GM_TMP/config.json"
  if ((CHANGED)); then
    iran_restart_wait || act_fail "$SVC did not come back on port $SS_PORT"
    ui_ok "config rewritten (catch-all guard in place, access log off), relay restarted"
  else
    ui_ok "config already correct"
  fi
  iran_step_done
}

iran_reconcile_timer() {
  iran_need_installed
  iran_step "Health timer (one installed copy of the tool)"
  iran_ensure_self
  mkdir_tracked "$STATE_DIR" 700
  iran_write_watch_conf "$FOREIGN_IP" "$SS_PORT" "$FW_KIND"
  local existed=0
  if [[ -f $SYSTEMD_DIR/$WATCH_SVC.timer ]]; then existed=1; fi
  iran_write_timer_units
  if is_dry; then
    if [[ -e $LEGACY_WATCH_BIN ]]; then dry_say "would remove the old separate copy $LEGACY_WATCH_BIN"; fi
    dry_say "would enable the timer"
    return 0
  fi
  if [[ -e $LEGACY_WATCH_BIN ]]; then
    backup_file "$LEGACY_WATCH_BIN"
    rm -f "$LEGACY_WATCH_BIN"
    ui_ok "removed the old separate copy $LEGACY_WATCH_BIN (the timer now runs $INSTALL_PATH)"
  fi
  if ((existed == 0)); then manifest_add SVC "$WATCH_SVC.timer"; fi
  must systemctl daemon-reload
  must systemctl enable --now "$WATCH_SVC.timer" >/dev/null
  ui_ok "timer active - results: journalctl -u $WATCH_SVC"
  iran_step_done
}

iran_act_repair() {  # iran_act_repair [all|firewall|config|timer|register]
  local what=${1:-all}
  case $what in
    all)
      iran_reconcile_config
      iran_reconcile_firewall
      iran_reconcile_timer
      iran_reconcile_register
      ;;
    firewall) iran_reconcile_firewall ;;
    config)   iran_reconcile_config ;;
    timer)    iran_reconcile_timer ;;
    register) iran_reconcile_register ;;
    *) act_fail "repair: use all | firewall | config | timer | register (got '$what')" 2 ;;
  esac
  ui_ok "repair finished - press r to refresh the dashboard"
}

iran_act_install_self() {
  iran_require_root
  iran_step "Install this tool as $INSTALL_PATH"
  iran_ensure_self
  if iran_installed; then
    # point the timer units at the freshly installed copy (repair timer also migrates the old layout)
    iran_load_runtime
    iran_write_timer_units
    if ! is_dry; then must systemctl daemon-reload; fi
  fi
  iran_step_done
  ui_ok "installed: type  gemini-menu  from now on"
}

# ================================================================== backups ===================
bk_dirs() { ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sed 's#/$##' | sort -r || true; }

iran_bk_summary() {  # one line describing a backup dir
  local mf=$1/$MANIFEST ops f
  if [[ ! -f $mf && -f $mf.rolledback ]]; then mf=$mf.rolledback; fi
  [[ -f $mf ]] || { echo "(no manifest)"; return 0; }
  ops=$(awk -F'\t' '$1=="F_BAK"||$1=="F_NEW"{n=split($2,a,"/"); printf "%s ", a[n]} $1=="FW"{printf "fw+ "} $1=="FW_DEL"{printf "fw- "}' "$mf")
  f=${ops:0:40}
  echo "${f:-(empty)}$([[ $mf == *.rolledback ]] && echo ' [undone]')"
}
iran_bk_file_of() { printf '%s/files/%s' "$1" "$(printf '%s' "$2" | tr '/' '_')"; }

iran_act_backup_diff() {  # DIR
  local f
  f=$(iran_bk_file_of "$1" "$CONF")
  [[ -f $f ]] || { ui_note "This backup holds no copy of the relay config."; return 0; }
  ui_note "(- backup, + current; the key line is hidden)"
  diff -u "$f" "$CONF" | grep -v -i 'password' | sed 1,2d | head -n 40 || true
  if diff -q "$f" "$CONF" >/dev/null 2>&1; then ui_ok "the current config is identical to this backup"; fi
}

iran_act_backup_restore() {  # DIR - put that backup's config.json back
  local f
  iran_need_installed
  f=$(iran_bk_file_of "$1" "$CONF")
  [[ -f $f ]] || act_fail "this backup holds no copy of the relay config"
  xray_test_bin "$BIN" "$f" || act_fail "that config is rejected by the installed Xray: $(tail -n 2 "$GM_TMP/xtest.out" | tr '\n' ' ')"
  iran_act_backup_diff "$1"
  if is_dry; then dry_say "would restore $f as $CONF and restart $SVC"; return 0; fi
  confirm "Restore this config and restart $SVC?" || act_cancel
  iran_step "Restore config from $(basename "$1")"
  put_file "$CONF" 640 "root:$SVC" <"$f"
  if ((CHANGED)); then iran_restart_wait || act_fail "$SVC did not come back"; fi
  iran_step_done
}

iran_act_rollback() {  # iran_act_rollback [DIR]  - undo a whole run (default: the newest that changed something)
  local d=${1:-$BACKUP_DIR_ARG} cand
  iran_require_root
  if [[ -z $d ]]; then
    while IFS= read -r cand; do
      if [[ -s $cand/$MANIFEST ]]; then d=$cand; break; fi
    done < <(bk_dirs)
  fi
  [[ -n $d && -s $d/$MANIFEST ]] || act_fail "no backup with a $MANIFEST found under $BACKUP_ROOT (nothing to roll back)"
  ui_say "rolling back run $(basename "$d"):"
  awk -F'\t' '{printf "     %s %s\n", $1, $2}' "$d/$MANIFEST"
  if is_dry; then dry_say "would undo the entries above (last to first)"; return 0; fi
  confirm "Undo these changes? This stops $SVC and removes the firewall rule it added." || act_cancel
  BK=$d
  replay_manifest 0
  mv -f "$d/$MANIFEST" "$d/$MANIFEST.rolledback"
  ui_ok "rollback done. The SS key file (if any) and the backup folder were kept: $d"
}

# ================================================================== uninstall =================
iran_act_uninstall() {
  iran_require_root
  if ! iran_installed && [[ ! -e $WATCH_CONF && ! -e $URL_FILE && ! -e $BIN ]]; then
    ui_ok "nothing to remove: the relay is not installed"
    return 0
  fi
  iran_load_runtime
  ui_say "This removes ONLY what this tool created:"
  ui_say "  services : $SVC, $WATCH_SVC timer + service (stopped and disabled)"
  ui_say "  files    : $BIN, $CONF_DIR/, $UNIT, the two $WATCH_SVC units, $STATE_DIR/ (incl. the stored Shecan URL)"
  ui_say "  firewall : the single rule allowing ${FOREIGN_IP:-?} -> port $SS_PORT (kind: $FW_KIND)"
  ui_say "  user     : system user $SVC"
  ui_say "It keeps: the SS key file, the backup folder, this tool ($INSTALL_PATH) and the log file."
  ui_say "It never touches the tunnel, other firewall rules, or any other xray / x-ui."
  ui_note "Gemini through the foreign server stops working until you run the foreign Revert (or set up again)."
  if is_dry; then dry_say "would remove everything listed above"; return 0; fi
  confirm_typed "This permanently deletes the relay, its config, the stored Shecan URL and the timer." yes || act_cancel
  iran_step "Uninstall"
  backup_file "$CONF"
  backup_file "$WATCH_CONF"
  systemctl disable --now "$SVC" "$WATCH_SVC.timer" "$WATCH_SVC.service" >/dev/null 2>&1 || true
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  if [[ $FW_KIND != none && -n ${FOREIGN_IP:-} ]]; then fw_remove "$FW_KIND" "$FOREIGN_IP" "$SS_PORT" || true; fi
  rm -f "$BIN" "$UNIT" "$LEGACY_WATCH_BIN" "$SYSTEMD_DIR/$WATCH_SVC.service" "$SYSTEMD_DIR/$WATCH_SVC.timer" \
    "$CONF" "$WATCH_CONF" "$WATCH_ENV" "$URL_FILE" "$WATCH_STATE"
  rmdir --ignore-fail-on-non-empty "$CONF_DIR" "$STATE_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  userdel "$SVC" >/dev/null 2>&1 || true
  act_commit
  ui_ok "uninstalled. Config/watch settings were saved in the backup folder ($(basename "$BK"))."
}

# ================================================================== health timer run ==========
# Non-interactive: run by the systemd timer (as:  gemini-menu --role iran watch).
iran_act_watch() {
  local -a problems=()
  local prev="" msg
  [[ -r $WATCH_CONF ]] || act_fail "not installed (no $WATCH_CONF)"
  iran_load_runtime
  if [[ -r $URL_FILE ]]; then
    if shecan_register "$URL_FILE"; then
      ui_ok "shecan re-registration ok"
      state_set last_register_ok "$(now)"
    else
      problems+=("Shecan re-registration failed (curl exit $REG_RC)")
    fi
    sleep "${GM_WATCH_SLEEP:-2}"
  else
    problems+=("no stored Shecan URL ($URL_FILE)")
  fi
  if verify_hijack; then ui_ok "DNS hijack ok: $VERIFY_MSG"; else problems+=("DNS check: $VERIFY_MSG"); fi
  if systemctl is-active --quiet "$SVC"; then ui_ok "$SVC running"; else problems+=("$SVC is not running"); fi
  if [[ $FW_KIND == iptables || $FW_KIND == nft ]]; then
    case $(fw_ensure "$FW_KIND" "$FOREIGN_IP" "$SS_PORT" 2>/dev/null || echo error) in
      added) ui_ok "firewall rule was missing and has been re-added" ;;
      error) problems+=("firewall rule missing and could not be re-added") ;;
    esac
  fi
  mkdir -p "$(dirname "$WATCH_STATE")"
  if [[ -r $WATCH_STATE ]]; then prev=$(<"$WATCH_STATE"); fi
  if ((${#problems[@]} > 0)); then
    msg=$(printf '%s; ' "${problems[@]}")
    if [[ $prev != FAIL ]]; then tg_send "gemini-shecan on $(hostname): $msg"; fi
    printf 'FAIL' >"$WATCH_STATE"
    act_fail "PROBLEM: $msg" 1
  fi
  if [[ $prev == FAIL ]]; then tg_send "gemini-shecan on $(hostname): recovered"; fi
  printf 'OK' >"$WATCH_STATE"
  ui_ok "all checks ok"
}
