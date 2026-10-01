# shellcheck shell=bash
# 93-foreign-actions.sh - every foreign-side operation as an action (run through act_run).
#
# Conventions are the Iran ones: prompts re-ask and `b` cancels; an action that changes the panel
# goes through foreign_commit (typed confirmation, backup, compare-and-swap write, restart, verify,
# automatic restore on failure). Each action reads the template ONCE at its start.

# ================================================================== health ====================
foreign_act_health() {   # main shell (call:)
  ui_blank
  probe_refresh 1
  ui_rule "Health check"
  probe_report
  ui_blank
  case $(probe_worst) in
    ok)   ui_ok "Everything is fine." ;;
    warn) ui_warn "Works, but something needs attention (see the lines above)." ;;
    *)    ui_err "Something is broken (see what to do above)." ;;
  esac
}
foreign_cli_status() {
  probe_refresh 1
  probe_report
  case $(probe_worst) in ok) return 0 ;; warn) return 1 ;; *) return 2 ;; esac
}

# ================================================================== inputs ====================
# foreign_read_inputs: IRAN_IP / SS_PORT / key from flags or environment (act_fail on bad values)
foreign_read_inputs() {
  local kf=${KEY_FILE_ARG:-${FKEY_FILE:-}} mode key
  [[ -n $IRAN_IP ]] || act_fail "the Iran server's IP is required (--iran-ip IP or the IRAN_IP variable)"
  v_ipv4 "$IRAN_IP" || act_fail "IRAN_IP must be an IPv4 address ($IN_ERR)"
  v_port "$SS_PORT" || act_fail "invalid SS_PORT: $SS_PORT ($IN_ERR)"
  [[ -n $kf ]] || act_fail "the key file is required (--key-file FILE: the file written by the Iran setup)"
  [[ -r $kf ]] || act_fail "key file not readable: $kf"
  mode=$(stat -c %a "$kf")
  if [[ $mode != 600 && $mode != 400 ]]; then ui_warn "$kf has mode $mode; it holds a secret, consider chmod 600"; fi
  key=$(<"$kf")
  v_b64_bytes "$key" 16 || act_fail "the key in $kf is not base64 of 16 bytes ($SS_METHOD needs exactly that)"
  KEY_VAL=$IN_VALUE
}

# ================================================================== end-to-end test ===========
TEST_ROWS=()
foreign_test_prepare() {
  local t form kf=${KEY_FILE_ARG:-${FKEY_FILE:-}}
  need_cmds python3 nc curl
  if [[ -z $XRAY_DIR ]]; then find_xray; fi
  if [[ -z $IRAN_IP || -z $kf ]]; then
    need_cmds sqlite3
    if [[ -z $DB ]]; then find_db; fi
    ftpl_read_or_fail
    t=$(python3 - "$GM_TMP/template.orig.json" "$TAG" "$GM_TMP/outbound.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
for o in t.get("outbounds", []):
    if o.get("tag") == sys.argv[2]:
        s = o.get("settings", {}); s = (s.get("servers") or [s])[0]
        print(s["address"], s["port"]); json.dump(o, open(sys.argv[3], "w")); sys.exit(0)
sys.exit(1)
PY
    ) || act_fail "no '$TAG' outbound in the panel template - run the setup first (menu: s)"
    IRAN_IP=${t% *}
    SS_PORT=${t#* }
  else
    foreign_read_inputs
    for form in servers flat; do
      P_FORM=$form P_IP=$IRAN_IP P_PORT=$SS_PORT P_KEY=$KEY_VAL P_METHOD=$SS_METHOD P_TAG=$TAG python3 - >"$GM_TMP/outbound.$form.json" <<'PY'
import json, os
e = os.environ
s = {"address": e["P_IP"], "port": int(e["P_PORT"]), "method": e["P_METHOD"], "password": e["P_KEY"]}
print(json.dumps({"tag": e["P_TAG"], "protocol": "shadowsocks", "settings": {"servers": [s]} if e["P_FORM"] == "servers" else s}))
PY
      python3 -c 'import json,sys;json.dump({"outbounds":[json.load(open(sys.argv[1]))]},open(sys.argv[2],"w"))' "$GM_TMP/outbound.$form.json" "$GM_TMP/ob-only.json"
      if panel_xray_test "$GM_TMP/ob-only.json"; then cp "$GM_TMP/outbound.$form.json" "$GM_TMP/outbound.json"; break; fi
    done
    [[ -s $GM_TMP/outbound.json ]] || act_fail "Xray rejected the outbound: $(xray_err | tr '\n' ' ')"
  fi
  NC_OK=0
  if nc -z -w 5 "$IRAN_IP" "$SS_PORT" >/dev/null 2>&1; then NC_OK=1; fi
  TEST_PORT=$(free_port)
  python3 - "$GM_TMP/outbound.json" "$TEST_PORT" "$GM_TMP/xray-test.log" >"$GM_TMP/test-config.json" <<'PY'
import json, sys
ob = json.load(open(sys.argv[1]))
print(json.dumps({"log": {"loglevel": "warning", "error": sys.argv[3]},
  "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"auth": "noauth", "udp": False}}],
  "outbounds": [ob]}))
PY
  ( cd "$XRAY_DIR" && exec "$XRAY_BIN" run -config "$GM_TMP/test-config.json" >/dev/null 2>&1 ) &
  TEST_PID=$!
  act_defer kill "$TEST_PID"
  for _ in $(seq 1 20); do
    if nc -z 127.0.0.1 "$TEST_PORT" 2>/dev/null; then break; fi
    sleep 0.25
  done
  nc -z 127.0.0.1 "$TEST_PORT" 2>/dev/null || act_fail "the temporary Xray did not start: $(tail -n 3 "$GM_TMP/xray-test.log" 2>/dev/null)"
}

foreign_test_run() {  # foreign_test_run host...   all hosts probed in parallel
  local d i=0 f
  local -a pids=()
  rm -f "$GM_TMP"/res.*
  for d in "$@"; do
    (
      rc=0
      out=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 -x "socks5h://127.0.0.1:$TEST_PORT" "https://$d/" 2>/dev/null) || rc=$?
      printf '%s\t%s\t%s\n' "$d" "$rc" "$out" >"$GM_TMP/res.$i"
    ) &
    pids+=($!)
    i=$((i + 1))
  done
  wait "${pids[@]}" 2>/dev/null || true
  kill "$TEST_PID" 2>/dev/null || true
  TEST_ROWS=()
  for ((f = 0; f < i; f++)); do TEST_ROWS+=("$(<"$GM_TMP/res.$f")"); done
}

foreign_test_report() {  # table + a plain-language verdict; sets TEST_OK / TEST_TOTAL
  local row d rc rest code t word badge ok=0 total=0 n403=0 verdict
  ui_blank
  ui_box_top "End-to-end test"
  for row in "${TEST_ROWS[@]}"; do
    IFS=$'\t' read -r d rc rest <<<"$row"
    code=${rest% *}
    t=${rest#* }
    total=$((total + 1))
    if [[ $rc == 0 && $code =~ ^[23] ]]; then
      ui_badge badge ok "OK"; ok=$((ok + 1))
    elif [[ $rc == 0 ]]; then
      ui_badge badge ok "OK $code"; ok=$((ok + 1))
      if [[ $code == 403 ]]; then n403=$((n403 + 1)); fi
    else
      ui_badge badge fail "FAIL"; t="-"
    fi
    ui_safe d "$d" 44
    ui_box_row "$(printf '%-44s' "$d") $badge ${C_DIM}${t}s${C_0}"
  done
  ui_box_bottom
  TEST_OK=$ok TEST_TOTAL=$total
  if [[ $NC_OK != 1 ]]; then
    verdict="BROKEN at: foreign -> Iran port ($IRAN_IP:$SS_PORT cannot be reached). The path may be filtered, the relay is down, or the Iran firewall does not allow this server. On Iran: gemini-menu iran status."
  elif ((ok == 0)); then
    verdict="BROKEN after the Iran port: it connects but nothing comes back. Most likely the Iran Shecan DNS is not working (registration lapsed) or Shecan cannot reach Google; a wrong key looks the same. On Iran: status, then register."
  elif ((ok < total)); then
    verdict="PARTLY WORKING: $((total - ok)) host(s) fail. Those hostnames may not be served by Shecan, or are misspelled. Remove them from the list or check them on Iran."
  elif ((n403 == total)); then
    verdict="Answers come back, but every one is 403: Shecan/Google may be refusing the Iran IP. On Iran: register this IP now."
  else
    verdict="The whole chain works: foreign -> Iran -> Shecan -> Google."
  fi
  ui_say "$verdict"
  state_set last_test_ts "$(now)"
  state_set last_test_res "$([[ $ok == "$total" && $total -gt 0 && $NC_OK == 1 ]] && echo "OK $ok/$total" || echo "FAIL $ok/$total ok")"
}

foreign_act_test() {  # foreign_act_test [quick]
  local -a hosts=()
  foreign_test_prepare
  mapfile -t hosts < <(foreign_domain_list)
  if [[ ${1:-} == quick || $QUICK == 1 ]]; then
    if [[ $ALL_DOMAINS != 1 ]]; then hosts=(gemini.google.com generativelanguage.googleapis.com); fi
  fi
  ui_note "temporary Xray on 127.0.0.1:$TEST_PORT, only outbound: $TAG -> $IRAN_IP:$SS_PORT (${#hosts[@]} hosts, in parallel)"
  foreign_test_run "${hosts[@]}"
  foreign_test_report
  # a closed relay port fails the test even if some probe got an answer from somewhere else
  if [[ $NC_OK != 1 ]]; then act_fail "the Iran relay port $IRAN_IP:$SS_PORT is not reachable"; fi
  ((TEST_OK == TEST_TOTAL)) || act_fail "$((TEST_TOTAL - TEST_OK)) of $TEST_TOTAL probes failed"
}

# ================================================================== routing, scope ============
foreign_act_routing() {  # foreign_act_routing on|off
  [[ ${1:-} == on || ${1:-} == off ]] || act_fail "routing: use on | off (got '${1:-nothing}')" 2
  P_STATE=$1 foreign_tpl_action toggle
}

foreign_scope_apply() { P_TAGS="$*" foreign_tpl_action scope; }

foreign_act_scope() {  # foreign_act_scope [all | TAG...]   (no argument: pick interactively)
  local line tag port remark proto i total
  local -a tags=() labels=() sel=() chosen=() picked=()
  need_panel
  foreign_facts || act_fail "cannot read the template"
  [[ $T_STATE != missing ]] || act_fail "the Gemini rules are not in the template yet - run the setup first (menu: s)"
  if (($# > 0)); then
    if [[ $1 == all ]]; then foreign_scope_apply; else foreign_scope_apply "$@"; fi
    return 0
  fi
  while IFS=$'\x1f' read -r tag port remark proto; do
    tags+=("$tag")
    labels+=("$tag  :$port  ${remark:-(no name)}  [$proto]")
    if [[ $T_SCOPE == all || ",$T_SCOPE," == *",$tag,"* ]]; then sel+=(1); else sel+=(0); fi
  done < <(panel_py inbounds "$DB")
  total=${#tags[@]}
  ((total > 0)) || act_fail "no enabled client inbounds found in the panel"
  ((IN_OK)) || act_fail "choosing inbounds needs a terminal (or: scope all | scope set TAG...)"
  pick_many chosen "Scope: who uses $TAG (ticked inbounds send the Gemini hosts to Iran)" labels sel || act_cancel
  for i in "${chosen[@]}"; do picked+=("${tags[i]}"); done
  ((${#picked[@]} > 0)) || act_fail "nothing ticked - to switch Gemini routing off use Routing > OFF"
  if ((${#picked[@]} == total)); then foreign_scope_apply; else foreign_scope_apply "${picked[@]}"; fi
}

# ================================================================== domain list ===============
foreign_act_domains_list() { need_panel; foreign_domain_list | nl -w2 -s'. ' | sed 's/^/  /'; }

foreign_domains_apply() { P_DOMAINS="$*" foreign_tpl_action domains; }   # the COMPLETE new list

foreign_act_domain_add() {
  local h=${1:-} d
  local -a cur=()
  need_panel
  if [[ -z $h ]]; then
    prompt_hostname h "Hostname to add (e.g. gemini.google.com)" || act_cancel
  else
    v_hostname "$h" || act_fail "not a valid hostname: $h ($IN_ERR)"
    h=$IN_VALUE
  fi
  mapfile -t cur < <(foreign_domain_list)
  for d in "${cur[@]}"; do
    if [[ $d == "$h" ]]; then ui_ok "$h is already in the list"; return 0; fi
  done
  foreign_domains_apply "${cur[@]}" "$h"
  foreign_sync_iran "${cur[@]}" "$h"
}

foreign_act_domain_remove() {
  local h=${1:-} d
  local -a cur=() keep=()
  need_panel
  mapfile -t cur < <(foreign_domain_list)
  if [[ -z $h ]]; then
    ((${#cur[@]} > 0)) || act_cancel "the list is empty"
    prompt_choice h "Remove which host (number or name)" "" "${cur[@]}" || act_cancel
  else
    v_hostname "$h" || act_fail "not a valid hostname: $h ($IN_ERR)"
    h=$IN_VALUE
  fi
  for d in "${cur[@]}"; do if [[ $d != "$h" ]]; then keep+=("$d"); fi; done
  if ((${#keep[@]} == ${#cur[@]})); then ui_ok "$h is not in the list"; return 0; fi
  foreign_domains_apply "${keep[@]}"
  foreign_sync_iran "${keep[@]}"
}

foreign_act_domain_set() {
  local d
  local -a list=()
  need_panel
  for d in "$@"; do
    v_hostname "$d" || act_fail "not a valid hostname: $d ($IN_ERR)"
    list+=("$IN_VALUE")
  done
  foreign_domains_apply "${list[@]}"
  foreign_sync_iran "${list[@]}"
}

foreign_act_sync_iran() {
  local -a l=()
  need_panel
  mapfile -t l < <(foreign_domain_list)
  foreign_sync_iran "${l[@]}"
}

# ================================================================== sniffing ==================
foreign_act_sniff_audit() {
  need_cmds sqlite3 python3
  if [[ -z $DB ]]; then find_db; fi
  ui_note "Domain rules need the destination domain, so the inbound must sniff (tls/http) and must"
  ui_note "not use routeOnly: with routeOnly the connection to $TAG would still carry an IP and the"
  ui_note "Iran relay (which only accepts the listed domains) would refuse it."
  panel_py audit "$DB" "$GM_TMP/sniff.count"
  SNIFF_FLAGGED=$(<"$GM_TMP/sniff.count")
}
SNIFF_FLAGGED=0

foreign_act_sniff_fix() {  # foreign_act_sniff_fix [ids|all]   (no argument: pick interactively)
  local ids=${1:-} iid remark port proto probs i
  local -a all=() labels=() sel=() chosen=() pick=()
  need_panel
  while IFS=$'\x1f' read -r iid remark port proto probs; do
    all+=("$iid")
    labels+=("$remark :$port $proto - $probs")
    sel+=(1)
  done < <(panel_py list "$DB")
  if ((${#all[@]} == 0)); then ui_ok "every enabled inbound already sniffs correctly - nothing to fix"; return 0; fi
  if [[ -z $ids ]]; then
    ((IN_OK)) || act_fail "choosing inbounds needs a terminal (or: sniffing fix all | sniffing fix ID,ID)"
    pick_many chosen "These inbounds have a problem: tick the ones to fix" labels sel || act_cancel
    ((${#chosen[@]} > 0)) || act_cancel "nothing ticked"
    for i in "${chosen[@]}"; do pick+=("${all[i]}"); done
    ids=$(IFS=,; echo "${pick[*]}")
  elif [[ $ids != all ]]; then
    [[ $ids =~ ^[0-9]+(,[0-9]+)*$ ]] || act_fail "sniffing fix: use all or a comma-separated list of inbound ids (got '$ids')" 2
  fi
  ui_say "Will set on inbound id(s) $ids: sniffing ON with http+tls, routeOnly off, metadataOnly off."
  ui_note "(The old values are saved in the backup, so Backups > restore can undo it.)"
  ftpl_read_or_fail
  cp "$GM_TMP/template.orig.json" "$GM_TMP/new.json"
  echo 0 >"$GM_TMP/new.json.changed"
  COMMIT_FIX_IDS=$ids
  foreign_commit "$GM_TMP/new.json"
}

# ================================================================== learn mode ================
learn_log_path() {  # resolved access-log path from T_ACCESS, or empty when logging is off
  local a=$T_ACCESS c
  case $a in "" | none | __unset__) return 0 ;; esac
  if [[ $a == /* ]]; then printf '%s' "$a"; return 0; fi
  for c in "$XRAY_DIR/$a" "$(dirname "$XRAY_DIR")/$a" "$XRAY_DIR/../$a"; do
    if [[ -f $c ]]; then printf '%s' "$c"; return 0; fi
  done
  printf '%s' "$XRAY_DIR/$a"
}

# learn_capture SECONDS OUTFILE FILTER : hostnames seen in the access log during the next SECONDS seconds.
# Only strict DNS names survive (letters, digits, hyphen, dots; <= 253 chars): the log is written by
# clients, so anything else - shell metacharacters, escape sequences, IPs - is dropped here, counted,
# and never shown or used. (Findings 4 and 10.)
learn_capture() {
  local secs=$1 out=$2 filt=$3 size0 left
  size0=$(stat -c %s "$LEARN_PATH" 2>/dev/null || echo 0)
  for ((left = secs; left > 0; left--)); do
    if ((UI_TTY)); then printf '\r  capturing...  %3ds left ' "$left"; fi
    sleep 1
  done
  if ((UI_TTY)); then printf '\r  capture finished.            \n'; else ui_note "capture finished"; fi
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
dns = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
seen, dropped = {}, 0
for line in data.splitlines():
    if filt and filt not in line:
        continue
    m = rx.search(line)
    if not m:
        continue
    h = m.group(1).lower()
    if ip.match(h) or ":" in h:
        continue
    if not dns.match(h):
        dropped += 1
        continue
    seen[h] = seen.get(h, 0) + 1
for h, n in sorted(seen.items()):
    print("%s\t%d" % (h, n))
if dropped:
    sys.stderr.write("%d line(s) with a malformed hostname were ignored\n" % dropped)
PY
}

foreign_log_restore() {  # put log.access back to what it was before learn mode switched it on
  local orig
  orig=$(state_get learn_orig_access)
  if [[ -z $orig ]]; then ui_ok "the access log was not changed by learn mode"; return 0; fi
  case $orig in __unset__ | none) orig=none ;; esac      # (fixed: the old code wrote the literal text "__unset__")
  ftpl_read_or_fail
  P_ACCESS=$orig py_tpl logaccess "$GM_TMP/template.orig.json" "$GM_TMP/new.json" | sed 's/^/  /'
  foreign_commit "$GM_TMP/new.json"
  state_set learn_orig_access ""
}
foreign_act_learn_restore() { need_panel; foreign_log_restore; }

foreign_act_learn() {
  local turned_on=0 idle=20 active=40 filt="" i h n
  local -a labels=() sel=() hosts=() chosen=() picked=() cur=()
  need_panel
  ftpl_read_or_fail
  eval "$(py_tpl inspect "$GM_TMP/template.orig.json")"
  [[ $T_HAS == 1 ]] || act_fail "$TAG is not set up yet - run the setup first (menu: s)"
  ((IN_OK)) || act_fail "learn mode needs a terminal (it walks you through using the phone app)"
  LEARN_PATH=$(learn_log_path)
  if [[ -z $LEARN_PATH ]]; then
    ui_say "The panel's access log is OFF (log.access = ${T_ACCESS/__unset__/unset}); learn mode reads it."
    ui_say "Turning it on changes the template and restarts the panel (users are dropped for a few seconds)."
    confirm "Turn the access log on for now?" y || act_cancel
    LEARN_PATH=$GM_ROOT/var/log/gemini-menu-access.log
    if ! is_dry; then mkdir -p "$(dirname "$LEARN_PATH")"; : >>"$LEARN_PATH"; fi
    state_set learn_orig_access "${T_ACCESS:-none}"
    P_ACCESS=$LEARN_PATH py_tpl logaccess "$GM_TMP/template.orig.json" "$GM_TMP/new.json" | sed 's/^/  /'
    foreign_commit "$GM_TMP/new.json"
    turned_on=1
    act_partial "the panel's access log is ON (learn mode switched it on)"
    act_tip "switch it back with: gemini-menu foreign learn-restore"
  fi
  if is_dry; then dry_say "would capture hostnames twice from $LEARN_PATH and offer the new ones"; return 0; fi
  ui_say "Access log: $LEARN_PATH"
  ui_say "The log holds ALL users' traffic. To count only your phone, type part of its line"
  ui_say "(your client's email/name in the panel, or the phone's IP). Empty = count everything."
  IN_ALLOW_EMPTY=1 prompt_valid filt "Filter text" "" v_nonempty || act_cancel
  prompt_int idle "Seconds to capture with the phone IDLE" 1 600 "$idle" || act_cancel
  prompt_int active "Seconds to capture while you USE Gemini" 1 600 "$active" || act_cancel
  ui_blank
  ui_step "STEP 1 of 2: put the phone on the VPN, close Gemini and leave it alone."
  in_read _ "  Press Enter to start the idle capture... " || act_cancel
  learn_capture "$idle" "$GM_TMP/learn.idle" "$filt"
  ui_step "STEP 2 of 2: now open the Gemini app and use it (chat, upload, voice...)."
  in_read _ "  Press Enter, then start using Gemini right away... " || act_cancel
  learn_capture "$active" "$GM_TMP/learn.active" "$filt"

  python3 - "$GM_TMP/learn.idle" "$GM_TMP/learn.active" "$T_DOMAINS" "${LEARN_SKIP_HOSTS[*]}" "${LEARN_SKIP_SUFFIX[*]}" >"$GM_TMP/learn.new" <<'PY'
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
  while IFS=$'\t' read -r h n; do
    v_hostname "$h" || continue                  # belt and braces: the same validator the typed path uses
    hosts+=("$IN_VALUE")
    labels+=("$IN_VALUE   ($n request(s))")
    sel+=(0)
  done <"$GM_TMP/learn.new"
  if ((${#hosts[@]} == 0)); then
    ui_blank
    ui_note "No new hostnames appeared in step 2 (idle traffic, hosts already routed and known"
    ui_note "background hosts are hidden). Is sniffing on, and did the phone really use the VPN?"
  else
    # cancelling here ends the action (pick_many returns 10): no "ghost ticks" get applied
    pick_many chosen "New hostnames: tick the ones that belong to Gemini (unsure? leave them out)" labels sel || act_cancel
    for i in "${chosen[@]}"; do picked+=("${hosts[i]}"); done
    if ((${#picked[@]} > 0)); then
      mapfile -t cur < <(foreign_domain_list)
      ui_say "Adding: ${picked[*]}"
      foreign_domains_apply "${cur[@]}" "${picked[@]}"
      foreign_sync_iran "${cur[@]}" "${picked[@]}"
    fi
  fi
  if ((turned_on)); then
    if confirm "Turn the access log back off? This restarts the panel again." y; then
      foreign_log_restore
      : >"$ACT_STATE"
    else
      ui_note "left ON. Switch it off later with: gemini-menu foreign learn-restore"
    fi
  fi
}

# ================================================================== backups ===================
foreign_bk_summary() {
  local d=$1 s=""
  if [[ -f $d/template.orig.json ]]; then s+="template "; fi
  if [[ -f $d/sniffing.orig.json ]]; then s+="sniffing "; fi
  if [[ -f $d/x-ui.db ]]; then s+="db-copy "; fi
  if [[ -f $d/foreign.manifest.rolledback ]]; then s+="[undone]"; fi
  echo "${s:-(empty)}"
}

foreign_act_backup_diff() {  # DIR
  need_cmds python3
  [[ -f $1/template.orig.json ]] || { ui_note "This backup holds no template copy."; return 0; }
  if [[ -z $DB ]]; then find_db; fi
  ftpl_read_or_fail
  ui_note "Restoring this backup would change the CURRENT template like this:"
  P_IN2=$1/template.orig.json py_tpl diff "$GM_TMP/template.orig.json" | sed 's/^/    /'
}

foreign_act_backup_restore() {  # DIR
  local d=$1
  need_panel
  [[ -f $d/template.orig.json ]] || act_fail "this backup holds no template copy"
  ftpl_read_or_fail
  P_IN2=$d/template.orig.json P_OUT=$GM_TMP/new.json py_tpl diff "$GM_TMP/template.orig.json" "$GM_TMP/new.json" | sed 's/^/  /'
  COMMIT_RESTORE_FILE=""
  if [[ -f $d/sniffing.orig.json ]] && foreign_ask_optional "This backup also saved sniffing values. Restore them too?"; then
    COMMIT_RESTORE_FILE=$d/sniffing.orig.json
  fi
  foreign_commit "$GM_TMP/new.json"
}

# an optional extra: --yes means "skip it" (only an explicit answer at a terminal enables it)
foreign_ask_optional() {
  if [[ $GM_YES == 1 ]]; then return 1; fi
  confirm "$1" n
}

# ================================================================== revert ====================
foreign_act_revert() {
  local first="" d restore_full=0
  need_panel
  ftpl_read_or_fail
  if ! py_tpl revert "$GM_TMP/template.orig.json" "$GM_TMP/new.json" | sed 's/^/  /'; then act_fail "could not compute the change"; fi
  # the template as it was before this tool first touched it = the oldest backup copy
  for d in $(bk_dirs | sort); do
    if [[ -f $d/template.orig.json ]]; then first=$d; break; fi
  done
  if [[ -n $first ]]; then
    ui_say "Compared with the template from before this tool first ran ($(basename "$first")):"
    P_IN2=$first/template.orig.json py_tpl diff "$GM_TMP/new.json" | sed 's/^/    /'
    if ! P_IN2=$first/template.orig.json py_tpl diff "$GM_TMP/new.json" | grep -q '^= identical'; then
      if foreign_ask_optional "Restore that ORIGINAL template completely (drops template edits made since)?"; then restore_full=1; fi
    fi
  fi
  if ((restore_full)); then
    cp "$first/template.orig.json" "$GM_TMP/new.json"
    echo 1 >"$GM_TMP/new.json.changed"
  fi
  # sniffing values: the oldest saved value per inbound wins
  python3 - "$BACKUP_ROOT" "$GM_TMP/sniff.merge.json" <<'PY'
import glob, json, os, sys
merged = {}
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*", "sniffing.orig.json"))):
    for k, v in json.load(open(p)).items():
        merged.setdefault(k, v)
json.dump(merged, open(sys.argv[2], "w"))
PY
  COMMIT_RESTORE_FILE=""
  if [[ $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$GM_TMP/sniff.merge.json") -gt 0 ]]; then
    ui_say "Sniffing values saved by this tool will be put back as well."
    COMMIT_RESTORE_FILE=$GM_TMP/sniff.merge.json
  fi
  foreign_commit "$GM_TMP/new.json"
}

# ================================================================== rollback (undo a run) =====
foreign_act_rollback() {  # foreign_act_rollback [DIR]   undo the newest run that changed something
  local d=${1:-$BACKUP_DIR_ARG} cand rc=0 exp
  iran_require_root
  if [[ -z $d ]]; then
    while IFS= read -r cand; do
      if [[ -s $cand/$MANIFEST ]]; then d=$cand; break; fi
    done < <(bk_dirs)
  fi
  [[ -n $d && -s $d/$MANIFEST ]] || act_fail "no $MANIFEST found under $BACKUP_ROOT (nothing to roll back)"
  BK=$d
  DB=$(awk -F'\t' '$1=="DB"{print $2}' "$BK/$MANIFEST")
  XRAY_BIN=$(awk -F'\t' '$1=="XRAY"{print $2}' "$BK/$MANIFEST")
  XRAY_DIR=$(dirname "$XRAY_BIN")
  RESTART_CMD=$(awk -F'\t' '$1=="RESTART"{print $2}' "$BK/$MANIFEST")
  ui_say "rolling back run $(basename "$BK") (db: $DB)"
  if is_dry; then
    dry_say "would restore $([[ $RESTORE_FULL_DB == 1 ]] && echo 'the full DB copy' || echo 'the saved template/sniffing') and run: $RESTART_CMD"
    return 0
  fi
  ui_warn "This restarts the panel and drops ALL user connections for a few seconds."
  confirm "Roll back now?" n || act_cancel
  if [[ $RESTORE_FULL_DB == 1 ]]; then
    [[ $RESTART_CMD == "systemctl restart x-ui" ]] || act_fail "--restore-full-db needs the default systemd setup (x-ui.service)"
    ui_warn "the WHOLE database copy is restored: traffic counters and clients changed since then are lost"
    confirm_typed_force "Replace the live panel database with the backup copy?" yes || act_cancel
    must systemctl stop x-ui
    cp -p "$BK/x-ui.db" "$DB"
    rm -f "$DB-wal" "$DB-shm"
    must systemctl start x-ui
  else
    exp=$BK/template.new.json
    [[ -f $exp ]] || exp=-
    panel_py restore "$DB" "$BK" "$exp" || rc=$?
    if ((rc == 3)); then
      ui_warn "the template in the panel is NOT what this run wrote: it was edited afterwards."
      ui_note "Restoring the saved one would discard those later edits."
      confirm_typed_force "Restore the saved template anyway and lose the later edits?" yes || act_cancel
      panel_py restore "$DB" "$BK" - || act_fail "the restore failed"
    elif ((rc != 0)); then
      act_fail "the restore failed (exit $rc)"
    fi
    restart_panel || act_fail "restarting the panel failed (command: $RESTART_CMD)"
  fi
  if wait_xray "$(expect_after_restore "$BK")"; then
    ui_ok "rollback done: the generated Xray config matches the restored template"
  else
    ui_warn "could not confirm the restore from the generated config - check: systemctl status x-ui"
  fi
  mv -f "$BK/$MANIFEST" "$BK/$MANIFEST.rolledback"
}
