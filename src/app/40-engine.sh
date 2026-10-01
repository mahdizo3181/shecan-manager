# shellcheck shell=bash
# 40-engine.sh - Shecan registration, DNS verification, Xray config generation and inspection,
# installed-state helpers. Ported from the original script; behaviour is unchanged except where
# noted "(fixed)".

fw_present() {  # fw_present KIND IP PORT   (read-only)
  local kind=$1 ip=$2 port=$3
  case $kind in
    ufw)      ufw status 2>/dev/null | grep -Eq "^${port}/tcp[[:space:]]+ALLOW[[:space:]]+${ip//./\\.}([[:space:]]|\$)" ;;
    iptables) iptables -C INPUT -s "$ip" -p tcp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null ;;
    nft)      nft -j list ruleset 2>/dev/null | nft_py ours "$ip" | grep -q . ;;
    *)        return 1 ;;
  esac
}

# shecan_register FILE - the URL goes to curl through stdin (-K -) so it never shows up in `ps`;
# output and stderr are discarded so it is never logged.
shecan_register() {
  local url
  url=$(<"$1")
  url=${url//[$'\r\n\t ']/}
  url=${url//\\/\\\\}
  url=${url//\"/\\\"}
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
  s=$(dns_a "${SHECAN_DNS[0]}" "$DNS_PROBE_HOST")
  if [[ -z $s ]]; then
    VERIFY_MSG="Shecan DNS ${SHECAN_DNS[0]} returned no A record for $DNS_PROBE_HOST (IP not registered / not allowed?)"
    return 1
  fi
  n=""
  for r in $NEUTRAL_DNS; do
    n=$(dns_a "$r" "$DNS_PROBE_HOST")
    if [[ -n $n ]]; then break; fi
  done
  if [[ -z $n ]]; then
    VERIFY_MSG="no neutral resolver answered, cannot compare with Shecan's answer"
    return 1
  fi
  if [[ -n $(comm -12 <(printf '%s\n' "$s") <(printf '%s\n' "$n")) ]]; then
    VERIFY_MSG="Shecan DNS answered the same address as a neutral resolver - the hijack is NOT active"
    return 1
  fi
  VERIFY_MSG="ok (shecan: $(tr '\n' ' ' <<<"$s")vs neutral: $(tr '\n' ' ' <<<"$n"))"
}

# ---- xray ----------------------------------------------------------------------------------------
xray_ver() { "$1" version 2>/dev/null | awk 'NR==1{print $2}'; }

xray_test_bin() {  # xray_test_bin BIN CONFIG -> 0 if accepted; message in $GM_TMP/xtest.out
  "$1" run -test -config "$2" >"$GM_TMP/xtest.out" 2>&1 || "$1" -test -config "$2" >"$GM_TMP/xtest.out" 2>&1
}

# gen_config FORM   (FORM = sockopt | settings: where freedom's domainStrategy lives)
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

# Facts about the installed relay, read from its config.json (never prints secrets except "key").
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

cfg_set_access() {  # cfg_set_access VALUE -> $GM_TMP/config.json = installed config with log.access changed
  python3 - "$CONF" "$1" "$GM_TMP/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.setdefault("log", {})["access"] = sys.argv[2]
open(sys.argv[3], "w").write(json.dumps(c, indent=2) + "\n")
PY
}

# Generate + validate the relay config for the current GEMINI_DOMAINS / SS_KEY_VAL / SS_PORT.
# Result: $GM_TMP/config.json and FORM_OK (where this Xray wants freedom.domainStrategy).
gen_validate_config() {
  local form cfgtmp chk_bin=${XRAY_CHECK_BIN:-$BIN}
  FORM_OK=""
  if [[ ! -x $chk_bin ]]; then
    ui_warn "no Xray binary to validate with yet (dry-run?): a real run tests the config with 'xray run -test'"
    gen_config sockopt >"$GM_TMP/config.json"
    FORM_OK=sockopt
    return 0
  fi
  for form in sockopt settings; do
    cfgtmp=$GM_TMP/config.$form.json
    gen_config "$form" >"$cfgtmp"
    if xray_test_bin "$chk_bin" "$cfgtmp"; then
      FORM_OK=$form
      cp "$cfgtmp" "$GM_TMP/config.json"
      break
    fi
    ui_warn "Xray rejected the '$form' form of freedom.domainStrategy: $(tail -n 1 "$GM_TMP/xtest.out")"
  done
  [[ -n $FORM_OK ]] || act_fail "Xray rejected every config variant; last error: $(tail -n 3 "$GM_TMP/xtest.out")"
  ui_ok "config validated with 'xray run -test' (freedom.domainStrategy under: $FORM_OK)"
}

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# ---- installed state -----------------------------------------------------------------------------
iran_installed() { [[ -f $UNIT && -f $CONF ]]; }

# iran_load_runtime [keep]  - SS_PORT / FOREIGN_IP / FW_KIND from the installed files.
#   default: the installed values WIN (status, repair, management actions).
#   keep:    values given by flags / environment win, the installed ones only fill the gaps
#            (setup). (fixed: the old script always let watch.conf overwrite --foreign-ip, so a
#            re-run with a new foreign IP silently kept the old one.)
iran_load_runtime() {
  local keep=${1:-} want_ip=$FOREIGN_IP want_port=$SS_PORT
  if [[ -r $WATCH_CONF ]]; then
    # shellcheck disable=SC1090
    . "$WATCH_CONF" || true
  fi
  if [[ -r $CONF ]]; then SS_PORT=$(cfg_py port 2>/dev/null || echo "$SS_PORT"); fi
  if [[ $keep == keep ]]; then
    if [[ -n $want_ip ]]; then FOREIGN_IP=$want_ip; fi
    if ((SS_PORT_EXPLICIT)); then SS_PORT=$want_port; fi
  fi
  return 0
}

iran_load_key() { SS_KEY_VAL=$(cfg_py key); }
iran_detect_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -n 1 || true; }

iran_last_register() {  # epoch of the last successful registration (state file, else journal), or empty
  local t
  t=$(state_get last_register_ok)
  if [[ -z $t ]]; then
    t=$(journalctl -u "$WATCH_SVC" --no-pager -o short-unix 2>/dev/null | grep 're-registration ok' | tail -n 1 | cut -d. -f1 || true)
  fi
  if [[ $t =~ ^[0-9]+$ ]]; then printf '%s' "$t"; fi
  return 0
}

iran_restart_wait() {  # restart only the relay and wait until it listens again
  local i
  systemctl restart "$SVC"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$SVC" && [[ -n $(ss -tlnH "sport = :$SS_PORT") ]]; then return 0; fi
    sleep "${GM_POLL_SLEEP:-1}"
  done
  journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null || true
  return 1
}

iran_need_installed() {
  iran_require_root
  if iran_installed; then
    iran_load_runtime
    return 0
  fi
  act_fail "the relay is not installed here - run the setup first (menu: s, or: gemini-menu iran setup)"
}

# ---- writers shared by setup and repair ------------------------------------------------------------
iran_write_watch_conf() {  # iran_write_watch_conf FOREIGN_IP SS_PORT FW_KIND
  put_file "$WATCH_CONF" 600 root:root < <(printf 'FOREIGN_IP=%q\nSS_PORT=%q\nFW_KIND=%q\n' "$1" "$2" "$3")
}

# The relay unit and the health timer units. The timer runs THE installed copy of this tool
# ($INSTALL_PATH): there is no second copy that could drift from the menu.
iran_write_relay_unit() {
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
}

iran_write_timer_units() {
  put_file "$SYSTEMD_DIR/$WATCH_SVC.service" 644 root:root <<EOF
[Unit]
Description=gemini-shecan health check (re-register Shecan IP, verify DNS, check $SVC)
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$WATCH_ENV
ExecStart=$INSTALL_PATH --role iran watch
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
}

# Make sure the file at $INSTALL_PATH is this very script.
iran_ensure_self() {
  if is_dry; then
    if [[ ! -x $INSTALL_PATH ]]; then dry_say "would install this tool as $INSTALL_PATH (the health timer runs it)"; fi
    return 0
  fi
  [[ -n $GM_SELF && -r $GM_SELF ]] \
    || act_fail "cannot find this script on disk to install it as $INSTALL_PATH (it was piped into bash). Download it to a file and run it from there."
  if [[ $GM_SELF == "$INSTALL_PATH" ]]; then return 0; fi
  if [[ -x $INSTALL_PATH ]] && cmp -s "$GM_SELF" "$INSTALL_PATH"; then return 0; fi
  mkdir_tracked "$(dirname "$INSTALL_PATH")" 755
  put_file "$INSTALL_PATH" 755 root:root <"$GM_SELF"
  ui_ok "installed $INSTALL_PATH (the timer and 'gemini-menu' both run this copy)"
}

tg_post() {  # tg_post TEXT   (TG_BOT / TG_CHAT from the environment) -> 0 if Telegram accepted it
  if [[ -z ${TG_BOT:-} || -z ${TG_CHAT:-} ]]; then return 1; fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' \
    "$TG_BOT" "$TG_CHAT" "$1" | curl -fsS --max-time 10 -o /dev/null -K - >/dev/null 2>&1
}
tg_send() {
  if [[ -z ${TG_BOT:-} || -z ${TG_CHAT:-} ]]; then return 0; fi
  tg_post "$1" || ui_note "telegram alert could not be sent"
}
