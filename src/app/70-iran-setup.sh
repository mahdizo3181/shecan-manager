# shellcheck shell=bash
# 70-iran-setup.sh - install / repair the Iran relay end to end.
#
# Run as:  gemini-menu iran setup [flags]     (or the menu's "s", or ./setup-iran.sh)
# Missing inputs are asked for interactively (typos re-ask, b cancels); with no terminal they must
# come from flags / environment. Re-running over an installed relay is safe: every step is
# idempotent, the domain list is kept, stored settings only fill the gaps.
#
# Honest transactions: each step is undone on its own if it fails; steps that already finished stay
# and are listed as PARTIAL, together with the command that undoes the whole run.

XRAY_VERSION_SET=0

# ---------------------------------------------------------------- inputs ---------------------
iran_setup_inputs() {
  local key_file=${KEY_FILE_ARG:-$DEFAULT_KEY_FILE} src
  if iran_installed; then iran_load_runtime keep; fi

  if [[ -z $FOREIGN_IP ]]; then
    ((IN_OK)) || act_fail "the foreign server's IP is required (--foreign-ip IP or the FOREIGN_IP variable)"
    ui_say "You need: the foreign server's IPv4 and your Shecan registration URL."
    prompt_ipv4 FOREIGN_IP "Foreign server IPv4 address" || act_cancel
  fi
  v_ipv4 "$FOREIGN_IP" || act_fail "FOREIGN_IP must be an IPv4 address ($IN_ERR)"
  v_port "$SS_PORT" || act_fail "invalid SS_PORT: $SS_PORT ($IN_ERR)"

  # Xray version: asked once when a person is at the keyboard and nothing was specified
  if ((!XRAY_VERSION_SET)) && [[ -z $XRAY_BIN_SRC ]] && ((IN_OK)) && [[ $GM_YES != 1 ]] && ! is_dry; then
    prompt_valid XRAY_VERSION "Xray version (same as the foreign server; 'latest' if unsure)" "$XRAY_VERSION" v_nonempty || act_cancel
  fi

  # SS key: env > --key-file > existing default file > generated
  if [[ -n ${SS_KEY:-} ]]; then
    SS_KEY_VAL=$SS_KEY
    src=env
  elif [[ -n $KEY_FILE_ARG ]]; then
    [[ -r $KEY_FILE_ARG ]] || act_fail "key file not readable: $KEY_FILE_ARG"
    SS_KEY_VAL=$(<"$KEY_FILE_ARG")
    src=file
  elif [[ -r $DEFAULT_KEY_FILE ]]; then
    SS_KEY_VAL=$(<"$DEFAULT_KEY_FILE")
    src=file
  else
    SS_KEY_VAL=$(openssl rand -base64 16)
    src=generated
  fi
  unset SS_KEY
  SS_KEY_VAL=${SS_KEY_VAL//[$'\r\n\t ']/}
  # 2022-blake3-aes-128-gcm needs exactly 16 random bytes, base64 encoded.
  v_b64_bytes "$SS_KEY_VAL" 16 || act_fail "the SS key is not base64 of 16 bytes (generate one with: openssl rand -base64 16)"
  KEY_FILE=$key_file
  KEY_SRC=$src

  # Shecan URL: env > --shecan-url-file > stored copy > ask
  SHECAN_URL_SRC="" NEW_URL=""
  if [[ -n ${SHECAN_REGISTER_URL:-} ]]; then
    NEW_URL=$SHECAN_REGISTER_URL
    SHECAN_URL_SRC=env
  elif [[ -n $SHECAN_URL_FILE_ARG ]]; then
    [[ -r $SHECAN_URL_FILE_ARG ]] || act_fail "cannot read $SHECAN_URL_FILE_ARG"
    NEW_URL=$(<"$SHECAN_URL_FILE_ARG")
    SHECAN_URL_SRC=file
  elif [[ -r $URL_FILE ]]; then
    SHECAN_URL_SRC=stored
  elif is_dry; then
    ui_warn "no Shecan registration URL given (a real run needs SHECAN_REGISTER_URL, --shecan-url-file, or it asks)"
    SHECAN_URL_SRC=stored
  elif ((IN_OK)); then
    prompt_valid NEW_URL "Shecan registration URL (paste it here)" "" v_url || act_cancel
    SHECAN_URL_SRC=ask
  else
    act_fail "the Shecan registration URL is missing: set SHECAN_REGISTER_URL or pass --shecan-url-file"
  fi
  unset SHECAN_REGISTER_URL
  NEW_URL=${NEW_URL//[$'\r\n\t ']/}
  if [[ $SHECAN_URL_SRC != stored ]]; then v_url "$NEW_URL" || act_fail "the Shecan URL is not valid ($IN_ERR)"; fi
}

# ---------------------------------------------------------------- read-only discovery --------
iran_discover() {
  local ufw_s=inactive nft_n=0 ipt_n=0 found line pat
  pat='gost|haproxy|socat|nginx|rathole|backhaul|frps|frpc|wstunnel|chisel|brook|sing-box|xray|x-ui|v2ray|hysteria|tuic|stunnel|udp2raw|ssh'
  if command -v ufw >/dev/null 2>&1; then ufw_s=$(ufw status 2>/dev/null | awk '/^Status:/{print $2}' || true); fi
  if command -v nft >/dev/null 2>&1; then nft_n=$(nft list ruleset 2>/dev/null | grep -c 'hook input' || true); fi
  if command -v iptables >/dev/null 2>&1; then ipt_n=$(iptables -S INPUT 2>/dev/null | wc -l || true); fi
  FW_KIND=$(fw_detect)
  found=$({ ss -tlnpH 2>/dev/null | grep -oE "\"($pat)[^\"]*\"" || true; systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E "$pat" || true; } | sort -u | tr '\n' ' ')
  ui_rule "Discovery (read-only)"
  ui_say "firewall   : ufw ${ufw_s:-none} | nft input hooks $nft_n | iptables INPUT lines $ipt_n  ${C_DIM}$G_SEP will use${C_0} ${C_B}$FW_KIND${C_0}"
  ui_say "tunnel sw  : ${found:-none identified}"
  if command -v iptables >/dev/null 2>&1 && iptables -t nat -S 2>/dev/null | grep -Eq 'DNAT|REDIRECT'; then
    ui_note "iptables NAT DNAT/REDIRECT rules present (possible kernel-level forwarder)"
  fi
  if ((VERBOSE)); then
    ui_note "listening TCP sockets:"
    while IFS= read -r line; do ui_note "  $line"; done < <(ss -tlnp 2>/dev/null || true)
  fi
  ui_note "nothing above is modified by this tool"
}

iran_check_port_free() {
  local line
  line=$(ss -tlnpH "sport = :$SS_PORT" 2>/dev/null || true)
  if [[ -z $line ]]; then return 0; fi
  if grep -q "\"$SVC\"" <<<"$line" || { systemctl is-active --quiet "$SVC" 2>/dev/null && [[ $(cfg_py port 2>/dev/null) == "$SS_PORT" ]]; }; then
    ui_ok "port $SS_PORT is used by our own $SVC (re-run) - fine"
    return 0
  fi
  act_fail "TCP port $SS_PORT is already in use by something else - choose another with --ss-port:
  $line"
}

# ---------------------------------------------------------------- the steps -------------------
iran_step_key() {
  iran_step "SS key file"
  if [[ $KEY_SRC == file ]]; then
    ui_ok "using the existing key file (${KEY_FILE_ARG:-$DEFAULT_KEY_FILE})"
  else
    mkdir_tracked "$(dirname "$KEY_FILE")" 700
    if is_dry; then
      dry_say "would store the SS key in $KEY_FILE (mode 600, key not shown)"
    else
      put_file "$KEY_FILE" 600 root:root < <(printf '%s\n' "$SS_KEY_VAL")
      ui_ok "SS key stored in $KEY_FILE"
    fi
  fi
  iran_step_done
}

iran_step_xray() {
  local want=${XRAY_VERSION#v} cur="" cand="" asset url exp got cv
  iran_step "Install Xray as $BIN"
  if [[ -x $BIN ]]; then cur=$(xray_ver "$BIN" || true); fi

  if [[ -n $XRAY_BIN_SRC ]]; then
    [[ -x $XRAY_BIN_SRC ]] || act_fail "--xray-bin is not an executable file: $XRAY_BIN_SRC"
    cand=$XRAY_BIN_SRC
  else
    if [[ -n $cur && ( $want == latest || $cur == "$want" ) ]]; then
      ui_ok "$BIN $cur already installed - keeping it"
      XRAY_CHECK_BIN=$BIN
      iran_step_done
      return 0
    fi
    case $(uname -m) in
      x86_64 | amd64)  asset=64 ;;
      aarch64 | arm64) asset=arm64-v8a ;;
      armv7l)          asset=arm32-v7a ;;
      *) act_fail "unsupported CPU architecture $(uname -m); use --xray-bin" ;;
    esac
    if [[ $want == latest ]]; then
      url=https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$asset.zip
    else
      url=https://github.com/XTLS/Xray-core/releases/download/v$want/Xray-linux-$asset.zip
    fi
    if is_dry; then
      dry_say "would download $url and verify its .dgst checksum"
      XRAY_CHECK_BIN=""
      if [[ -x $BIN ]]; then XRAY_CHECK_BIN=$BIN; fi
      return 0
    fi
    ui_note "downloading $url"
    curl -fL --retry 2 --connect-timeout 10 --max-time 180 -o "$GM_TMP/xray.zip" "$url" \
      || act_fail "download failed (GitHub unreachable from this server?). Copy an Xray binary here and use --xray-bin PATH"
    if curl -fsSL --max-time 30 -o "$GM_TMP/xray.dgst" "$url.dgst" 2>/dev/null; then
      exp=$(grep -i '256' "$GM_TMP/xray.dgst" | grep -oE '[0-9a-f]{64}' | head -1 || true)
      got=$(sha256sum "$GM_TMP/xray.zip" | awk '{print $1}')
      if [[ -z $exp ]]; then
        ui_warn "could not read a SHA-256 from the .dgst file - the archive is NOT checksum-verified"
      elif [[ $exp != "$got" ]]; then
        act_fail "SHA-256 mismatch for the downloaded archive"
      else
        ui_ok "checksum ok"
      fi
    else
      ui_warn "no .dgst checksum file available - the archive is NOT checksum-verified"
    fi
    python3 - "$GM_TMP/xray.zip" "$GM_TMP/xray" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
open(sys.argv[2], "wb").write(z.read("xray"))
PY
    chmod 755 "$GM_TMP/xray"
    cand=$GM_TMP/xray
  fi

  cv=$(xray_ver "$cand" || true)
  [[ -n $cv ]] || act_fail "$cand does not run (wrong architecture?)"
  if [[ $want != latest && $cv != "$want" ]]; then
    act_fail "Xray version mismatch: wanted $want, got $cv (the versions on both servers should match)"
  fi
  ui_ok "Xray $cv"
  XRAY_CHECK_BIN=$cand
  if is_dry; then dry_say "would install $cand as $BIN"; return 0; fi
  put_file "$BIN" 755 root:root <"$cand"
  if ((CHANGED)); then RESTART_NEEDED=1; fi
  XRAY_CHECK_BIN=$BIN
  iran_step_done
}

iran_step_config() {
  iran_step "Relay config $CONF"
  if is_dry; then
    dry_say "would create system user $SVC (no login) if missing"
  elif ! id "$SVC" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC"
    manifest_add USER_NEW "$SVC"
  fi
  mkdir_tracked "$CONF_DIR" 750 "root:$SVC"
  gen_validate_config
  put_file "$CONF" 640 "root:$SVC" <"$GM_TMP/config.json"
  if ((CHANGED)); then RESTART_NEEDED=1; fi
  iran_step_done
}

iran_step_service() {
  local unit_existed=0 i
  iran_step "systemd service $SVC"
  if [[ -f $UNIT ]]; then unit_existed=1; fi
  iran_write_relay_unit
  if ((CHANGED)); then RESTART_NEEDED=1; fi
  if is_dry; then dry_say "would enable and (re)start $SVC and wait for it to listen on $SS_PORT"; return 0; fi
  if ((unit_existed == 0)); then manifest_add SVC "$SVC"; fi
  must systemctl daemon-reload
  systemctl enable "$SVC" >/dev/null 2>&1
  if ((RESTART_NEEDED)); then must systemctl restart "$SVC"; else must systemctl start "$SVC"; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$SVC" && [[ -n $(ss -tlnH "sport = :$SS_PORT") ]]; then
      ui_ok "$SVC is running and listening on $SS_PORT"
      iran_step_done
      return 0
    fi
    sleep "${GM_POLL_SLEEP:-1}"
  done
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null || true
  act_fail "$SVC did not come up on port $SS_PORT"
}

iran_step_firewall() {
  local r
  iran_step "Firewall: allow $SS_PORT/tcp from $FOREIGN_IP only ($FW_KIND)"
  if [[ $FW_KIND == none ]]; then
    ui_warn "no active firewall detected - nothing to open. (If the provider has a cloud firewall, allow $SS_PORT/tcp from $FOREIGN_IP there.)"
    iran_step_done
    return 0
  fi
  if is_dry; then dry_say "would add one ACCEPT rule via $FW_KIND (existing rules untouched)"; return 0; fi
  r=$(fw_ensure "$FW_KIND" "$FOREIGN_IP" "$SS_PORT")
  case $r in
    added)   manifest_add FW "$FW_KIND" "$FOREIGN_IP:$SS_PORT"; ui_ok "firewall rule added" ;;
    present) ui_ok "firewall rule already present" ;;
    *)       ui_warn "no suitable input chain found for $FW_KIND (nothing drops traffic there?) - no rule added" ;;
  esac
  if [[ $FW_KIND == iptables || $FW_KIND == nft ]]; then
    ui_note "this rule is runtime-only; the health timer re-adds it if a firewall reload removes it"
  fi
  iran_step_done
}

iran_step_shecan() {
  iran_step "Shecan registration + DNS check"
  mkdir_tracked "$STATE_DIR" 700
  if is_dry; then
    dry_say "would store the registration URL in $URL_FILE (mode 600), call it with curl -4, then compare dig @${SHECAN_DNS[0]} $DNS_PROBE_HOST with a neutral resolver"
    return 0
  fi
  if [[ $SHECAN_URL_SRC != stored ]]; then
    put_file "$URL_FILE" 600 root:root < <(printf '%s\n' "$NEW_URL")
    NEW_URL=""
  fi
  iran_register_call
  iran_verify_loop
  iran_step_done
}

iran_step_selftest() {
  local port pid code rc=0 i
  iran_step "Self-test through $SVC (loopback)"
  if is_dry; then dry_say "would run a temporary loopback Xray client: $DNS_PROBE_HOST must work, example.com must be refused"; return 0; fi
  port=$(free_port)
  ST_PORT=$port ST_SS=$SS_PORT ST_KEY=$SS_KEY_VAL ST_METHOD=$SS_METHOD python3 - >"$GM_TMP/client.json" <<'PY'
import json, os
e = os.environ
print(json.dumps({
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": int(e["ST_PORT"]), "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
  "outbounds": [{"tag": "to-relay", "protocol": "shadowsocks", "settings": {"servers": [
    {"address": "127.0.0.1", "port": int(e["ST_SS"]), "method": e["ST_METHOD"], "password": e["ST_KEY"]}]}}]}))
PY
  "$BIN" run -config "$GM_TMP/client.json" >"$GM_TMP/client.log" 2>&1 &
  pid=$!
  act_defer kill "$pid"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
    sleep 0.5
  done
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -x "socks5h://127.0.0.1:$port" "https://$DNS_PROBE_HOST/" 2>/dev/null) || rc=$?
  if [[ $rc != 0 || $code == 000 ]]; then
    act_fail "self-test failed: https://$DNS_PROBE_HOST via the relay did not answer (curl exit $rc). The DNS check passed, so look at: Shecan registration, outbound access to the Shecan proxy IPs, or $SVC logs (journalctl -u $SVC)"
  fi
  ui_ok "$DNS_PROBE_HOST via the relay -> HTTP $code (the Shecan path works)"
  rc=0
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -x "socks5h://127.0.0.1:$port" "https://example.com/" 2>/dev/null) || rc=$?
  if [[ $rc == 0 && $code != 000 ]]; then
    systemctl stop "$SVC" || true
    replay_manifest 0            # undo the WHOLE run: a relay that proxies anything must not stay
    : >"$ACT_STATE"
    act_fail "SECURITY: the relay proxied https://example.com (HTTP $code) - it is an OPEN PROXY. $SVC was stopped and this run was undone."
  fi
  ui_ok "a non-Gemini destination is refused (the catch-all block works)"
  iran_step_done
}

iran_step_timer() {
  local existed=0
  iran_step "Health timer $WATCH_SVC.timer (every 5 min, runs $INSTALL_PATH)"
  iran_ensure_self
  mkdir_tracked "$STATE_DIR" 700
  if [[ -f $SYSTEMD_DIR/$WATCH_SVC.timer ]]; then existed=1; fi
  iran_write_watch_conf "$FOREIGN_IP" "$SS_PORT" "$FW_KIND"
  if [[ -n ${TG_BOT:-} && -n ${TG_CHAT:-} ]]; then
    put_file "$WATCH_ENV" 600 root:root < <(printf 'TG_BOT=%q\nTG_CHAT=%q\n' "$TG_BOT" "$TG_CHAT")
    ui_ok "Telegram alerts configured (token not shown)"
  fi
  unset TG_BOT TG_CHAT
  iran_write_timer_units
  if is_dry; then dry_say "would enable the timer"; return 0; fi
  if [[ -e $LEGACY_WATCH_BIN ]]; then
    backup_file "$LEGACY_WATCH_BIN"
    rm -f "$LEGACY_WATCH_BIN"
    ui_ok "removed the old separate copy $LEGACY_WATCH_BIN"
  fi
  if ((existed == 0)); then manifest_add SVC "$WATCH_SVC.timer"; fi
  must systemctl daemon-reload
  must systemctl enable --now "$WATCH_SVC.timer" >/dev/null
  ui_ok "timer active - results: journalctl -u $WATCH_SVC"
  iran_step_done
}

# ---------------------------------------------------------------- the action -------------------
iran_act_setup() {
  local ip port_arg=""
  local -a cur=()
  need_cmds ss curl dig openssl python3 systemctl base64 sha256sum nc
  iran_require_root
  iran_setup_inputs
  iran_discover
  iran_check_port_free
  if iran_installed; then           # re-running keeps a customised domain list
    iran_domain_current cur
    if ((${#cur[@]} > 0)); then GEMINI_DOMAINS=("${cur[@]}"); fi
  fi
  ui_blank
  ui_box_top "Plan"
  ui_box_kv "Relay" "$SVC on :$SS_PORT/tcp, Xray ${XRAY_VERSION}$([[ -n $XRAY_BIN_SRC ]] && echo ' (local binary)')"
  ui_box_kv "Allowed from" "$FOREIGN_IP ${C_DIM}only (firewall: $FW_KIND)${C_0}"
  ui_box_kv "Hosts" "${#GEMINI_DOMAINS[@]} Gemini hostnames"
  ui_box_kv "SS key" "$KEY_SRC ${C_DIM}(never shown)${C_0}"
  ui_box_kv "Shecan URL" "$SHECAN_URL_SRC ${C_DIM}(never shown)${C_0}"
  ui_box_kv "Timer" "runs $INSTALL_PATH every 5 min"
  ui_box_bottom
  ui_note "Nothing on this server's tunnel or its existing firewall rules is modified."
  if ! is_dry; then confirm "Proceed?" || act_cancel; fi

  XRAY_CHECK_BIN=""
  iran_step_key
  iran_step_xray
  iran_step_config
  iran_step_service
  iran_step_firewall
  iran_step_shecan
  iran_step_selftest
  iran_step_timer
  if ! is_dry; then role_set iran; fi

  ip=$(iran_detect_ip)
  if [[ $SS_PORT != 20443 ]]; then port_arg=" --ss-port $SS_PORT"; fi
  ui_blank
  ui_box_top "Next: the foreign server"
  ui_box_row "Copy the key file (it is not printed) and run setup there:"
  ui_box_blank
  ui_box_row "  scp root@${ip:-<IRAN_IP>}:$KEY_FILE /root/gemini-ss.key"
  ui_box_row "  gemini-menu foreign setup --iran-ip ${ip:-<IRAN_IP>} --key-file /root/gemini-ss.key$port_arg"
  ui_box_bottom
  if [[ -n $ip ]]; then ui_note "(detected outbound address $ip - use the public IP registered with Shecan if it differs)"; fi
  ui_note "Health and everything else: gemini-menu"
}
