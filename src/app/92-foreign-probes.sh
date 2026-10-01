# shellcheck shell=bash
# 92-foreign-probes.sh - dashboard checks for the foreign (3X-UI) server, one probe per row.
# Same rules as the Iran probes: print LEVEL<TAB>BADGE<TAB>detail[<TAB>hint]; hints name real actions.

_fna() { printf 'off\tN/A\t%s\n' "$1"; }

pr_f_panel() {
  local xp
  if [[ -z $DB ]]; then
    printf 'fail\tNO DB\t3X-UI database not found\tPass --db /path/x-ui.db, or open the panel > Xray Configs and press Save once.\n'
    return 0
  fi
  xp=$(basename "${XRAY_BIN:-xray-linux}" | cut -c1-15)
  if systemctl is-active --quiet x-ui 2>/dev/null || pgrep -x "$xp" >/dev/null 2>&1; then
    printf 'ok\tRUNNING\tpanel running (db: %s)\n' "${DB#"$GM_ROOT"}"
  else
    printf 'fail\tDOWN\tthe panel is not running\tsystemctl status x-ui   then   systemctl restart x-ui\n'
  fi
}

pr_f_outbound() {
  [[ -n $DB ]] || { _fna "no database"; return 0; }
  if ! foreign_facts; then
    printf 'fail\tUNREADABLE\tcannot read the Xray template from the panel database\tCheck --db, and that the panel has saved its template once.\n'
    return 0
  fi
  if [[ $T_HAS == 1 ]]; then
    printf 'ok\tPRESENT\toutbound %s -> %s:%s (%s form)\n' "$TAG" "$T_IP" "$T_PORT" "$T_FORM"
  else
    printf 'fail\tMISSING\toutbound %s is not in the template\tSetup: press s (or: gemini-menu foreign setup)\n' "$TAG"
  fi
}

pr_f_relay() {
  foreign_facts && [[ $T_HAS == 1 ]] || { _fna "no outbound yet"; return 0; }
  if nc -z -w 3 "$T_IP" "$T_PORT" >/dev/null 2>&1; then
    printf 'ok\tREACHABLE\tIran relay %s:%s answers\n' "$T_IP" "$T_PORT"
  else
    printf 'fail\tUNREACHABLE\tIran relay %s:%s is NOT reachable\tThe path may be filtered, the relay down, or the Iran firewall blocks this server. On Iran: gemini-menu iran status\n' "$T_IP" "$T_PORT"
  fi
}

pr_f_routing() {
  foreign_facts || { _fna "template unreadable"; return 0; }
  case $T_STATE in
    on)
      if [[ $T_UDP != 1 ]]; then
        printf 'warn\tNO QUIC BLOCK\trouting is ON but the udp/443 (QUIC) block rule is missing\tSetup re-creates both rules: press s.\n'
      elif [[ $T_SCOPE == all ]]; then
        printf 'ok\tON\tall inbounds, %s hosts\n' "$T_NDOM"
      else
        printf 'ok\tON\t%s hosts for: %s\n' "$T_NDOM" "${T_SCOPE//,/ }"
      fi ;;
    off)     printf 'warn\tOFF\trules kept but they match nothing (Gemini goes out the normal way)\tRouting > Switch ON\n' ;;
    partial) printf 'warn\tINCONSISTENT\tthe two Gemini rules disagree (one on, one off/missing)\tRouting > Switch ON makes them consistent.\n' ;;
    *)       printf 'fail\tMISSING\tthe Gemini routing rules are not in the template\tSetup: press s.\n' ;;
  esac
}

pr_f_sniffing() {
  [[ -n $DB ]] || { _fna "no database"; return 0; }
  local n
  n=$(panel_py list "$DB" 2>/dev/null | grep -c . || true)
  if ((n > 0)); then
    printf 'warn\t%s BAD\t%s inbound(s) with bad sniffing: domain rules can miss\tSniffing > Fix selected inbounds\n' "$n" "$n"
  else
    printf 'ok\tOK\tevery enabled inbound sniffs tls+http\n'
  fi
}

pr_f_generated() {
  foreign_facts && [[ $T_HAS == 1 && -f $XRAY_DIR/config.json ]] || { _fna "nothing to compare"; return 0; }
  if grep -q "\"$TAG\"" "$XRAY_DIR/config.json"; then
    printf 'ok\tLOADED\tthe running Xray config contains %s\n' "$TAG"
  else
    printf 'warn\tNOT LOADED\tthe running Xray config does not contain %s yet\tThe panel needs a restart to load the template (Routing ON/OFF does that).\n' "$TAG"
  fi
}

pr_f_test() {
  local t res age
  t=$(state_get last_test_ts)
  res=$(state_get last_test_res)
  if [[ ! $t =~ ^[0-9]+$ ]]; then
    printf 'warn\tNEVER\tno end-to-end test has run yet\tEnd-to-end test: press 2.\n'
    return 0
  fi
  age=$(fmt_age $(($(now) - t)))
  if [[ $res == OK* ]]; then printf 'ok\tPASSED\t%s, %s\n' "$res" "$age"
  else printf 'fail\tFAILED\t%s, %s\tEnd-to-end test (2) shows which hop is broken.\n' "$res" "$age"; fi
}

foreign_register_probes() {
  probe_register panel     pr_f_panel     "3X-UI panel"
  probe_register outbound  pr_f_outbound  "Outbound $TAG"
  probe_register relay     pr_f_relay     "Iran relay"
  probe_register routing   pr_f_routing   "Gemini routing"
  probe_register sniffing  pr_f_sniffing  "Sniffing"
  probe_register generated pr_f_generated "Running config"
  probe_register test      pr_f_test      "End-to-end test"
}

foreign_status() {
  local badge xv
  probe_refresh
  case $(probe_worst) in
    ok)   ui_badge badge ok "HEALTHY" ;;
    warn) ui_badge badge warn "ATTENTION" ;;
    *)    ui_badge badge fail "PROBLEM" ;;
  esac
  xv=""
  if [[ -x ${XRAY_BIN:-} ]]; then xv=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}'); fi
  ui_box_top "GEMINI $G_DOT SHECAN"
  ui_box_kv "Role" "${C_B}FOREIGN server (3X-UI)${C_0}  $badge"
  ui_box_probe "Panel" panel
  ui_box_probe "Outbound" outbound
  ui_box_probe "Iran relay" relay
  ui_box_probe "Routing" routing
  ui_box_probe "Sniffing" sniffing
  ui_box_probe "Running cfg" generated
  ui_box_probe "Last test" test
  ui_box_kv "Xray" "${xv:-unknown} ${C_DIM}(use the same version on the Iran server)${C_0}"
  ui_box_bottom
}
