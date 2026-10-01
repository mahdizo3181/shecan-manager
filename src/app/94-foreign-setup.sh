# shellcheck shell=bash
# 94-foreign-setup.sh - patch the 3X-UI Xray template: outbound ir-gemini + two routing rules.
#
#   gemini-menu foreign setup [--iran-ip IP --key-file FILE --ss-port N --db PATH --xray-bin PATH --fix-sniffing]
#
# Missing inputs are asked for interactively. The patch removes the old gemini-shecan outbound and
# gemini-related balancers; appends ir-gemini last (the default outbound is unchanged); inserts two rules
# right after the "bittorrent -> blocked" rule: udp/443 for the domains -> blocked (QUIC falls back to
# TCP) and the domains -> ir-gemini. It refuses to guess if that rule is missing. The patched template
# is validated with the panel's own Xray, written with compare-and-swap, and a failed restart puts the
# previous template back automatically.

KEY_VAL=""

foreign_act_setup() {
  local form ok="" cur kf
  need_cmds sqlite3 python3 nc base64
  iran_require_root
  if [[ -z $DB ]]; then locate_db || true; fi
  if [[ -n $DB ]]; then foreign_facts >/dev/null 2>&1 || true; fi

  if [[ -z $IRAN_IP ]]; then
    ((IN_OK)) || act_fail "the Iran server's IP is required (--iran-ip IP or the IRAN_IP variable)"
    ui_say "You need the Iran relay's IP and its key file."
    ui_note "(On Iran: 'gemini-menu iran info' prints the two commands that bring the key file here.)"
    prompt_ipv4 IRAN_IP "Iran server IPv4 address" "${T_IP:-}" || act_cancel
  fi
  if [[ -z ${KEY_FILE_ARG:-${FKEY_FILE:-}} ]]; then
    ((IN_OK)) || act_fail "the key file is required (--key-file FILE: the file written by the Iran setup)"
    prompt_file kf "Path of the key file on THIS server" "/root/gemini-ss.key" || act_cancel
    KEY_FILE_ARG=$kf
  fi
  foreign_read_inputs

  act_step "Check the path foreign -> Iran"
  ui_note "checking $IRAN_IP:$SS_PORT ..."
  if nc -z -w 5 "$IRAN_IP" "$SS_PORT" >/dev/null 2>&1; then
    NC_OK=1
    ui_ok "$IRAN_IP:$SS_PORT is reachable"
  else
    NC_OK=0
    act_fail "$IRAN_IP:$SS_PORT is not reachable from this server. The foreign -> Iran path may be filtered, the relay may not be running, or the Iran firewall does not allow this server's IP. Fix that first (Iran side: gemini-menu iran status / foreign-ip), then re-run."
  fi

  act_step "Locate the panel"
  if [[ -z $DB ]]; then find_db; else ui_ok "3X-UI database: $DB"; fi
  if [[ -z $XRAY_DIR ]]; then find_xray; fi
  ftpl_read_or_fail

  act_step "Patch the template"
  cur=$(eval "$(py_tpl inspect "$GM_TMP/template.orig.json")"; echo "$T_DOMAINS")
  if [[ -n $cur ]]; then
    read -r -a GEMINI_DOMAINS <<<"$cur"
    ui_ok "keeping the current domain list (${#GEMINI_DOMAINS[@]} hosts)"
  fi
  if panel_xray_test "$GM_TMP/template.orig.json"; then
    ui_ok "the original template passes 'xray -test'"
  else
    ui_warn "the ORIGINAL template does not pass 'xray -test' in this environment: $(xray_err | tr '\n' ' ')"
  fi
  for form in servers flat; do
    P_FORM=$form P_IP=$IRAN_IP P_PORT=$SS_PORT P_KEY=$KEY_VAL P_METHOD=$SS_METHOD P_DOMAINS="${GEMINI_DOMAINS[*]}" \
      py_tpl patch "$GM_TMP/template.orig.json" "$GM_TMP/template.$form.json" >"$GM_TMP/patch.$form.log" \
      || act_fail "$(cat "$GM_TMP/patch.$form.log" 2>/dev/null) cannot patch this template"
    if panel_xray_test "$GM_TMP/template.$form.json"; then ok=$form; break; fi
    ui_warn "Xray rejected the '$form' outbound form: $(xray_err | tr '\n' ' ')"
  done
  [[ -n $ok ]] || act_fail "Xray rejected the patched template in both outbound forms; nothing was written"
  sed 's/^/  /' "$GM_TMP/patch.$ok.log"
  ui_ok "patched template validated with the panel's Xray (outbound form: $ok)"

  act_step "Sniffing audit (report only unless --fix-sniffing)"
  foreign_act_sniff_audit
  COMMIT_FIX_IDS=""
  if [[ $FIX_SNIFFING == 1 && $SNIFF_FLAGGED -gt 0 ]]; then COMMIT_FIX_IDS=all; fi
  if [[ $SNIFF_FLAGGED -gt 0 && $FIX_SNIFFING == 0 ]]; then
    ui_warn "$SNIFF_FLAGGED inbound(s) need sniffing: not changed. Inbounds: Scope & Sniffing > Fix sniffing (or --fix-sniffing)."
  fi

  foreign_commit "$GM_TMP/template.$ok.json"
  if ! is_dry; then role_set foreign; fi
  ui_blank
  ui_say "Next: gemini-menu foreign test      (checks foreign -> Iran -> Shecan -> Google)"
  ui_say "Undo: gemini-menu foreign rollback"
}
