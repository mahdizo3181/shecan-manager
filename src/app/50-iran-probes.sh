# shellcheck shell=bash
# 50-iran-probes.sh - the health checks, one probe per row of the dashboard.
#
# A probe prints  LEVEL <TAB> BADGE <TAB> detail [<TAB> hint]  and runs in its own subshell, in
# parallel with the others, so loading the installed settings inside it is safe and a slow DNS
# lookup does not delay the rest. Every hint names a repair that exists: "Health Check & Status > Repair ..." in the menu,
# or  gemini-menu iran repair X  on the command line (see 60-iran-actions.sh, iran_reconcile_*).

_na() { printf 'off\tN/A\tnot installed\n'; }

pr_service() {
  if ! iran_installed; then
    printf 'fail\tMISSING\tthe relay is not installed on this server\tChoose 1 (Setup / Reconfigure Relay), or: gemini-menu iran setup\n'
    return 0
  fi
  iran_load_runtime
  if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    printf 'ok\tACTIVE\t%s is running\n' "$SVC"
  else
    printf 'fail\tSTOPPED\t%s is not running\tService & Watch Timer Controls > Start the relay. View Logs shows why it stopped.\n' "$SVC"
  fi
}

pr_port() {
  iran_installed || { _na; return 0; }
  iran_load_runtime
  if [[ -n $(ss -tlnH "sport = :$SS_PORT" 2>/dev/null) ]]; then
    printf 'ok\tLISTENING\tport %s/tcp accepts connections\n' "$SS_PORT"
  else
    printf 'fail\tCLOSED\tnothing listens on port %s\tThe relay is down or the port is taken: Service & Watch Timer Controls > Restart.\n' "$SS_PORT"
  fi
}

pr_firewall() {
  iran_installed || { _na; return 0; }
  iran_load_runtime
  if [[ ${FW_KIND:-none} == none ]]; then
    printf 'warn\tOPEN\tno firewall detected: port %s is open to everyone\tThe SS key is still required. A provider firewall limited to %s would be safer.\n' "$SS_PORT" "${FOREIGN_IP:-the foreign IP}"
  elif fw_present "$FW_KIND" "$FOREIGN_IP" "$SS_PORT"; then
    printf 'ok\tALLOWED\tonly %s may reach port %s (%s)\n' "$FOREIGN_IP" "$SS_PORT" "$FW_KIND"
  else
    printf 'fail\tNO RULE\tno rule lets %s reach port %s (%s)\tHealth Check & Status > Repair the firewall rule (or: gemini-menu iran repair firewall)\n' "${FOREIGN_IP:-?}" "$SS_PORT" "$FW_KIND"
  fi
}

pr_dns() {
  iran_installed || { _na; return 0; }
  if ! command -v dig >/dev/null 2>&1; then
    printf 'warn\tNO DIG\tthe dig command is missing, cannot verify DNS\tapt-get install -y dnsutils\n'
    return 0
  fi
  if verify_hijack; then
    printf 'ok\tHIJACKED\tShecan answers differ from a neutral resolver (live check)\n'
  else
    printf 'fail\tINACTIVE\t%s\tRegister with Shecan (3). If it keeps failing, the URL/token may have expired.\n' "${VERIFY_MSG%% (*}"
  fi
}

pr_register() {
  iran_installed || { _na; return 0; }
  local t age
  t=$(iran_last_register)
  if [[ -z $t ]]; then
    printf 'warn\tNEVER\tno successful Shecan registration recorded\tRegister with Shecan (3), or wait for the 5-minute timer.\n'
    return 0
  fi
  age=$(($(now) - t))
  if ((age > 1200)); then
    printf 'warn\tSTALE\tlast registration %s\tThe watch timer should do it every 5 min: check the Timer row.\n' "$(fmt_age "$age")"
  else
    printf 'ok\tFRESH\tIP registered with Shecan %s\n' "$(fmt_age "$age")"
  fi
}

pr_timer() {
  iran_installed || { _na; return 0; }
  if ! systemctl is-active --quiet "$WATCH_SVC.timer" 2>/dev/null; then
    printf 'warn\tOFF\tthe health timer is not active\tHealth Check & Status > Repair the watch timer (or: gemini-menu iran repair timer)\n'
  elif [[ -e $LEGACY_WATCH_BIN ]] || ! grep -q "^ExecStart=$INSTALL_PATH " "$SYSTEMD_DIR/$WATCH_SVC.service" 2>/dev/null; then
    printf 'warn\tOUTDATED\tthe timer runs an old separate copy of the script\tHealth Check & Status > Repair the watch timer switches it to %s\n' "$INSTALL_PATH"
  else
    printf 'ok\tACTIVE\thealth timer every 5 min (runs %s)\n' "$INSTALL_PATH"
  fi
}

pr_guard() {
  iran_installed || { _na; return 0; }
  if [[ $(cfg_py catchall 2>/dev/null) == yes ]]; then
    printf 'ok\tGUARDED\tthe relay refuses everything except the Gemini hosts\n'
  else
    printf 'fail\tOPEN PROXY\tthe config has no catch-all block: the relay could proxy anything\tHealth Check & Status > Repair the relay config (or: gemini-menu iran repair config)\n'
  fi
}

pr_access() {
  iran_installed || { _na; return 0; }
  local until
  until=$(state_get access_until)
  if [[ $(cfg_py access 2>/dev/null) == on ]]; then
    printf 'warn\tON\taccess log is recording%s\tView Logs > Access log OFF now\n' "${until:+ (auto-off in $(((until - $(now)) / 60 + 1)) min)}"
  else
    printf 'off\tOFF\tnormal: connections are not recorded\n'
  fi
}

iran_register_probes() {
  probe_register service  pr_service  "Relay service"
  probe_register port     pr_port     "Relay port"
  probe_register firewall pr_firewall "Firewall"
  probe_register dns      pr_dns      "Shecan DNS"
  probe_register register pr_register "Registration"
  probe_register timer    pr_timer    "Health timer"
  probe_register guard    pr_guard    "Open-proxy guard"
  probe_register access   pr_access   "Access log"
}

# ---- the dashboard card --------------------------------------------------------------------------
iran_status() {
  local ip fip worst badge
  probe_refresh
  ip=$(iran_detect_ip)
  fip=""
  if iran_installed; then fip=$(iran_load_runtime; printf '%s' "${FOREIGN_IP:-}"); fi
  case $(probe_worst) in
    ok)   ui_badge badge ok "HEALTHY" ;;
    warn) ui_badge badge warn "ATTENTION" ;;
    *)    ui_badge badge fail "PROBLEM" ;;
  esac
  ui_box_top "GEMINI $G_DOT SHECAN"
  ui_box_kv "Role" "${C_B}IRAN relay${C_0}  $badge"
  ui_box_probe_rows "Relay:service" "Port:port" "Firewall:firewall" "Shecan DNS:dns" "Registered:register" \
    "Timer:timer" "Guard:guard" "Access log:access"
  ui_box_kv "Addresses" "${ip:-unknown} ${C_DIM}(this server)${C_0} $G_SEP ${fip:-?} ${C_DIM}(allowed foreign)${C_0}"
  ui_box_bottom
  worst=$(probe_worst)
  IRAN_WORST=$worst
}
IRAN_WORST=ok
