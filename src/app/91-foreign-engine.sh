# shellcheck shell=bash
# 91-foreign-engine.sh - the foreign (3X-UI) side: locate the panel, read and patch its Xray
# template, write it back SAFELY, restart and verify.
#
# What is new compared with the previous script
#   * compare-and-swap (Finding 7): the template is read once at the start of an action; the write is
#     `UPDATE ... WHERE value = <exactly what was read>` inside one SQLite transaction. If anyone saved
#     in the panel in the meantime, nothing is written and the action says so. Rollback is guarded the
#     same way: it restores only if the template is still what this tool wrote.
#   * a refused write leaves no stray backup behind; a failed restart restores automatically.
#   * the template patch program (py_tpl) is the previous one, unchanged.

IRAN_IP=${IRAN_IP:-}
DB=${XUI_DB:-}
XRAY_BIN=""
XRAY_DIR=""
RESTART_CMD="systemctl restart x-ui"
FIX_SNIFFING=0 ALL_DOMAINS=0 QUICK=0 RESTORE_FULL_DB=0
TAG=ir-gemini                 # name of the outbound in the panel template
OFF_MARK=__gemini_off__       # inboundTag prefix that makes a rule match nothing (= switched off)
LEARN_SKIP_HOSTS=(mtalk.google.com android.clients.google.com play.googleapis.com firebaseinstallations.googleapis.com www.googleapis.com accounts.google.com)
LEARN_SKIP_SUFFIX=(gvt1.com)
COMMIT_FIX_IDS=""             # "" = no sniffing change, "all" or "1,2" = fix those inbounds in the same transaction
COMMIT_RESTORE_FILE=""        # JSON id -> sniffing text to put back in the same transaction
NC_OK=0
T_HAS=0 T_IP="" T_PORT="" T_FORM="" T_STATE=missing T_UDP=0 T_SCOPE=all T_NDOM=0 T_DOMAINS="" T_ACCESS=""

# ---------------------------------------------------------------- locate the panel -------------
sqlite_has_template() {
  [[ -f $1 ]] && [[ $(sqlite3 -readonly "$1" "select count(*) from settings where key='xrayTemplateConfig'" 2>/dev/null || echo 0) -ge 1 ]]
}

locate_db() {  # quiet; sets DB (or leaves it empty)
  local c cands=() folder seen=""
  if [[ -n $DB ]]; then
    if [[ -f $DB ]]; then return 0; fi
    return 1
  fi
  folder=$(systemctl show x-ui -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^XUI_DB_FOLDER=//p' | head -n 1 || true)
  if [[ -n $folder ]]; then cands+=("$folder/x-ui.db"); fi
  cands+=("$GM_ROOT/etc/x-ui/x-ui.db" "$GM_ROOT/usr/local/x-ui/db/x-ui.db" "$GM_ROOT/usr/local/x-ui/x-ui.db" "$GM_ROOT/opt/x-ui/x-ui.db")
  # only system locations: a copy in /root or /home is usually a backup, never the live panel database
  while IFS= read -r c; do cands+=("$c"); done < <(find "$GM_ROOT/etc" "$GM_ROOT/usr/local" "$GM_ROOT/opt" "$GM_ROOT/var/lib" -maxdepth 4 -name x-ui.db 2>/dev/null || true)
  for c in "${cands[@]}"; do
    if [[ -f $c && $seen != *"|$c|"* ]]; then
      seen+="|$c|"
      if sqlite_has_template "$c"; then DB=$c; return 0; fi
    fi
  done
  return 1
}

locate_xray() {  # quiet; sets XRAY_BIN / XRAY_DIR
  local c
  if [[ -z $XRAY_BIN && -n $XRAY_BIN_SRC ]]; then XRAY_BIN=$XRAY_BIN_SRC; fi
  if [[ -z $XRAY_BIN ]]; then
    for c in "$GM_ROOT"/usr/local/x-ui/bin/xray-linux-* "$GM_ROOT"/opt/x-ui/bin/xray-linux-*; do
      if [[ -f $c && -x $c ]]; then XRAY_BIN=$c; break; fi
    done
    if [[ -z $XRAY_BIN ]]; then
      XRAY_BIN=$(find "$GM_ROOT/usr/local" "$GM_ROOT/opt" "$GM_ROOT/root" -maxdepth 4 -type f -name 'xray-linux-*' -perm -u+x 2>/dev/null | head -n 1 || true)
    fi
  fi
  if [[ -n $XRAY_BIN && -x $XRAY_BIN ]]; then XRAY_DIR=$(dirname "$XRAY_BIN"); return 0; fi
  return 1
}

find_db() {
  if [[ -n $DB && ! -f $DB ]]; then act_fail "database not found: $DB"; fi
  locate_db || act_fail "could not find a 3X-UI database with an xrayTemplateConfig row.
  - Pass it explicitly with --db PATH.
  - If the panel never saved a custom template, open the panel -> Xray Configs, press Save once (no changes), then re-run."
  sqlite_has_template "$DB" || act_fail "$DB has no settings.xrayTemplateConfig row (open the panel -> Xray Configs and press Save once, then re-run)"
  ui_ok "3X-UI database: $DB"
}

find_xray() {
  locate_xray || act_fail "panel Xray binary not found; pass --xray-bin PATH"
  ui_ok "panel Xray: $XRAY_BIN ($("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $1" "$2}'))"
  ui_note "use the same version on the Iran server: --xray-version $("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')"
}

need_panel() {  # inside an action
  need_cmds sqlite3 python3
  iran_require_root
  if [[ -z $DB ]]; then find_db; fi
  if [[ -z $XRAY_DIR ]]; then find_xray; fi
}

# ---------------------------------------------------------------- read the template -------------
# ftpl_read [FILE]  -> the stored template as text in FILE (default $GM_TMP/template.orig.json).
# Quiet and side-effect free (usable from probes); returns non-zero when unreadable / not JSON.
ftpl_read() {
  local out=${1:-$GM_TMP/template.orig.json}
  python3 - "$DB" "$out" <<'PY' || return 1
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=30)
row = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
if row is None:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8", newline="").write(row[0])
PY
  python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$out" 2>/dev/null
}

# the same, for use inside an action: stops it with a clear message
ftpl_read_or_fail() {
  ftpl_read "$@" || act_fail "cannot read a valid Xray template from the panel database ($DB)"
}

panel_xray_test() {  # panel_xray_test CONFIG -> 0 if accepted by the panel's Xray; message in $GM_TMP/xtest.out
  ( cd "$XRAY_DIR" && XRAY_LOCATION_ASSET="$XRAY_DIR" "$XRAY_BIN" run -test -config "$1" >"$GM_TMP/xtest.out" 2>&1 ) \
    || ( cd "$XRAY_DIR" && XRAY_LOCATION_ASSET="$XRAY_DIR" "$XRAY_BIN" -test -config "$1" >"$GM_TMP/xtest.out" 2>&1 )
}
xray_err() { grep -v -i 'deprecated\|^Xray \|^A unified\|Reading config' "$GM_TMP/xtest.out" | tail -n 3; }

# ---------------------------------------------------------------- template patch program -----
# (unchanged from the previous script)
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

# ---------------------------------------------------------------- database program -------------
# panel_py MODE ...   one program for everything that touches the panel database besides the
# template text itself.
#   audit    DB COUNTFILE        human report of inbounds whose sniffing would stop domain rules; count -> file
#   list     DB                  id remark port protocol problems   (flagged inbounds)   fields separated by \x1f
#   inbounds DB                  tag port remark protocol           (enabled client inbounds)  fields separated by \x1f
#   (\x1f, not a tab: tabs collapse in `read`, which would shift fields when a remark is empty)
#   commit   DB BASE NEW BKDIR FIXIDS RESTOREFILE
#            ONE transaction: template compare-and-swap (BASE = text read earlier, NEW = "-" to skip),
#            optional sniffing fix / restore. Exit 3 = CONFLICT, nothing written.
#   restore  DB BKDIR EXPECTED   put the saved template (+ sniffing) back. EXPECTED = file holding the text
#            the template must STILL be (compare-and-swap), or "-" to restore unconditionally. Exit 3 = CONFLICT.
panel_py() {
  python3 - "$@" <<'PY'
import json, os, sqlite3, sys

mode, db = sys.argv[1], sys.argv[2]
rw = mode in ("commit", "restore")
con = sqlite3.connect("file:%s?mode=%s" % (db, "rw" if rw else "ro"), uri=True, timeout=30, isolation_level=None)


def flagged_inbounds():
    cols = [r[1] for r in con.execute("pragma table_info(inbounds)")]
    if "sniffing" not in cols:
        return None, 0, 0
    flagged, disabled, total = [], 0, 0
    for iid, remark, port, proto, enable, sn in con.execute(
            "select id, remark, port, protocol, enable, sniffing from inbounds order by id"):
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
    return flagged, disabled, total


def clean(v):
    return "".join(ch for ch in str(v) if ch.isprintable() and ch not in "\t\n")


if mode == "audit":
    out = sys.argv[3]
    flagged, disabled, total = flagged_inbounds()
    if flagged is None:
        print("  (this panel version has no inbounds.sniffing column - audit skipped)")
        open(out, "w").write("0")
        sys.exit(0)
    print("  %d client inbound(s) checked (%d disabled and skipped)" % (total, disabled))
    for iid, remark, port, proto, probs, _, _ in flagged:
        print("  ! id=%s %-18s port=%-5s %-12s %s" % (iid, clean(remark)[:18], port, proto, ", ".join(probs)))
    if not flagged:
        print("  all enabled inbounds have sniffing with tls+http and no routeOnly/metadataOnly")
    open(out, "w").write(str(len(flagged)))

elif mode == "list":
    flagged, _, _ = flagged_inbounds()
    for iid, remark, port, proto, probs, _, _ in (flagged or []):
        print("\x1f".join([str(iid), clean(remark), str(port), str(proto), ", ".join(probs)]))

elif mode == "inbounds":
    for tag, port, remark, proto, en in con.execute("select tag, port, remark, protocol, enable from inbounds order by id"):
        if proto in ("tunnel", "dokodemo-door") or not en:
            continue
        print("\x1f".join([clean(tag), str(port), clean(remark), str(proto)]))

elif mode == "commit":
    base_f, new_f, bk, fix, restore_f = sys.argv[3:8]
    con.execute("BEGIN IMMEDIATE")
    try:
        if new_f != "-":
            base = open(base_f, encoding="utf-8", newline="").read()
            new = open(new_f, encoding="utf-8", newline="").read()
            n = con.execute("update settings set value=? where key='xrayTemplateConfig' and value=?", (new, base)).rowcount
            if n != 1:
                con.execute("ROLLBACK")
                print("CONFLICT: the template in the panel is not what was read")
                sys.exit(3)
        saved_path = os.path.join(bk, "sniffing.orig.json")
        saved = json.load(open(saved_path)) if os.path.exists(saved_path) else {}
        if fix:
            flagged, _, _ = flagged_inbounds()
            want = None if fix == "all" else set(fix.split(","))
            n_fix = 0
            for iid, remark, port, proto, probs, sn, s in (flagged or []):
                if want is not None and str(iid) not in want:
                    continue
                saved.setdefault(str(iid), sn)
                s["enabled"] = True
                d = list(s.get("destOverride") or [])
                for x in ("http", "tls"):
                    if x not in d: d.append(x)
                s["destOverride"], s["routeOnly"], s["metadataOnly"] = d, False, False
                n = con.execute("update inbounds set sniffing=? where id=? and sniffing is ?",
                                (json.dumps(s, indent=2), iid, sn)).rowcount
                if n != 1:
                    con.execute("ROLLBACK")
                    print("CONFLICT: inbound %s was changed in the panel while this ran" % iid)
                    sys.exit(3)
                n_fix += 1
            print("  sniffing fixed on %d inbound(s)" % n_fix)
        if restore_f:
            for iid, val in json.load(open(restore_f)).items():
                row = con.execute("select sniffing from inbounds where id=?", (int(iid),)).fetchone()
                if row is None:
                    continue
                saved.setdefault(str(iid), row[0])
                con.execute("update inbounds set sniffing=? where id=?", (val, int(iid)))
            print("  sniffing values restored")
        if saved:
            json.dump(saved, open(saved_path, "w"))
        con.execute("COMMIT")
    except SystemExit:
        raise
    except Exception:
        con.execute("ROLLBACK")
        raise

elif mode == "restore":
    bk, expected = sys.argv[3:5]
    con.execute("BEGIN IMMEDIATE")
    tpl = open(os.path.join(bk, "template.orig.json"), encoding="utf-8", newline="").read()
    if expected == "-":
        n = con.execute("update settings set value=? where key='xrayTemplateConfig'", (tpl,)).rowcount
    else:
        exp = open(expected, encoding="utf-8", newline="").read()
        n = con.execute("update settings set value=? where key='xrayTemplateConfig' and value=?", (tpl, exp)).rowcount
    if n != 1:
        con.execute("ROLLBACK")
        print("CONFLICT: the template in the panel is no longer what this run wrote")
        sys.exit(3)
    sp = os.path.join(bk, "sniffing.orig.json")
    if os.path.exists(sp):
        for iid, val in json.load(open(sp)).items():
            con.execute("update inbounds set sniffing=? where id=?", (val, int(iid)))
    con.execute("COMMIT")
    print("restored the saved template%s" % (" and sniffing values" if os.path.exists(sp) else ""))
PY
}

# ---------------------------------------------------------------- facts about the panel ---------
# foreign_facts: reads the template and sets the T_* variables. Quiet; returns 1 on failure.
foreign_facts() {
  T_HAS=0 T_IP="" T_PORT="" T_FORM="" T_STATE=missing T_UDP=0 T_SCOPE=all T_NDOM=0 T_DOMAINS="" T_ACCESS=""
  [[ -n $DB ]] || return 1
  local f=$GM_TMP/facts.$BASHPID.json
  ftpl_read "$f" >/dev/null 2>&1 || return 1
  eval "$(py_tpl inspect "$f")"
  return 0
}

foreign_domain_list() {  # the hosts currently routed (falls back to the built-in 9)
  if foreign_facts && [[ $T_NDOM -gt 0 ]]; then printf '%s\n' $T_DOMAINS; else printf '%s\n' "${GEMINI_DOMAINS[@]}"; fi
}

# ---------------------------------------------------------------- restart + verify ---------------
restart_panel() {
  ui_note "restarting the panel: $RESTART_CMD"
  bash -c "$RESTART_CMD" || return 1
}

# wait_xray present|absent [BEFORE_MTIME]: the panel's Xray runs again and its regenerated config has/lacks our tag
wait_xray() {
  local want=$1 before=${2:-} i cfg="$XRAY_DIR/config.json" ok now_m
  for i in $(seq 1 "${GM_WAIT_XRAY:-30}"); do
    sleep "${GM_XRAY_POLL:-1}"
    # exact process-name match (comm is cut to 15 chars); -f would also match this script's own arguments
    pgrep -x "$(basename "$XRAY_BIN" | cut -c1-15)" >/dev/null 2>&1 || continue
    if [[ -f $cfg ]]; then
      ok=0
      if grep -q "\"$TAG\"" "$cfg"; then ok=1; fi
      if [[ ($want == present && $ok == 1) || ($want == absent && $ok == 0) ]]; then
        now_m=$(stat -c %Y "$cfg" 2>/dev/null || echo "")
        if [[ -n $before && $now_m == "$before" ]]; then
          ui_warn "the panel did not rewrite $cfg on restart - the match is against the previous file"
        fi
        return 0
      fi
    else
      return 0    # config.json is somewhere else; process check only
    fi
  done
  return 1
}

# after restoring $BK/template.orig.json the tag is present only if that saved template had it
expect_after_restore() { if grep -q "\"$TAG\"" "$1/template.orig.json"; then echo present; else echo absent; fi; }

# ---------------------------------------------------------------- the commit pipeline ------------
foreign_drop_backup() {  # rollback hook: the write was refused, so nothing happened - leave no stray backup
  if [[ -n ${1:-} && -d $1 ]]; then rm -rf "$1"; fi
}

# Runs when something fails AFTER the database write (restart / verification).
foreign_auto_restore() {  # foreign_auto_restore BKDIR
  local bk=$1 rc=0 exp=$1/template.new.json
  ui_warn "restoring the previous template..."
  [[ -f $exp ]] || exp=-
  panel_py restore "$DB" "$bk" "$exp" || rc=$?
  if ((rc != 0)); then
    ui_err "automatic restore FAILED (exit $rc) - the new template is still in the panel database"
    act_partial "the new template was written to the panel database (backup: $bk)"
    act_tip "restore it with: gemini-menu foreign rollback   (or from the panel: Xray Configs)"
    return 0
  fi
  if restart_panel && wait_xray "$(expect_after_restore "$bk")"; then
    ui_ok "previous template restored; the panel's Xray is running again"
  else
    ui_warn "template restored, but the panel did not confirm a healthy restart - check: systemctl status x-ui"
  fi
  return 0
}

# foreign_commit NEWFILE
#   The BASE is $GM_TMP/template.orig.json: the template as read at the start of this action.
#   COMMIT_FIX_IDS / COMMIT_RESTORE_FILE ride in the same transaction (and the same restart).
foreign_commit() {
  local nf=$1 want rc=0 changed=1 mt0=""
  if [[ $(<"$nf.changed") == 0 ]]; then changed=0; fi
  if ((!changed)) && [[ -z $COMMIT_FIX_IDS && -z $COMMIT_RESTORE_FILE ]]; then
    ui_ok "nothing to change - it is already like this"
    return 0
  fi
  if ((changed)); then
    panel_xray_test "$nf" || act_fail "the panel's Xray rejected the new template: $(xray_err | tr '\n' ' ') - nothing was written"
    ui_ok "new template validated with the panel's Xray"
  fi
  if is_dry; then dry_say "would back up the DB, write the template (compare-and-swap), restart: $RESTART_CMD"; return 0; fi
  ui_warn "The panel will restart ($RESTART_CMD). This drops ALL user connections for a few seconds."
  confirm "Proceed?" || act_cancel

  act_step "Back up the panel database"
  BK=""                                       # every commit gets its own backup folder
  bk_dir
  sqlite3 "$DB" ".backup '$BK/x-ui.db'"
  chmod 600 "$BK/x-ui.db"
  [[ $(sqlite3 "$BK/x-ui.db" 'pragma integrity_check') == ok ]] || act_fail "the DB backup failed its integrity check"
  cp "$GM_TMP/template.orig.json" "$BK/template.orig.json"
  if ((changed)); then cp "$nf" "$BK/template.new.json"; fi
  printf 'DB\t%s\nXRAY\t%s\nRESTART\t%s\n' "$DB" "$XRAY_BIN" "$RESTART_CMD" >"$BK/$MANIFEST.pending"
  ui_ok "backup: $BK"
  act_on_fail foreign_drop_backup "$BK"

  act_step "Write the template (compare-and-swap)"
  panel_py commit "$DB" "$GM_TMP/template.orig.json" "$([[ $changed == 1 ]] && echo "$nf" || echo -)" "$BK" "$COMMIT_FIX_IDS" "$COMMIT_RESTORE_FILE" || rc=$?
  if ((rc == 3)); then
    act_fail "the panel's settings were changed by someone else after this tool read them (a save in the panel?). NOTHING was written. Review the panel, then run it again."
  elif ((rc != 0)); then
    act_fail "the database write failed (exit $rc); nothing was changed"
  fi
  mv -f "$BK/$MANIFEST.pending" "$BK/$MANIFEST"
  act_commit                                  # the write happened: the backup is now needed, keep it
  act_on_fail foreign_auto_restore "$BK"      # ...and a failed restart puts the old template back

  act_step "Restart the panel and verify"
  [[ -f $XRAY_DIR/config.json ]] && mt0=$(stat -c %Y "$XRAY_DIR/config.json" 2>/dev/null || true)
  restart_panel || act_fail "restarting the panel failed (command: $RESTART_CMD)"
  if grep -q "\"$TAG\"" "$nf"; then want=present; else want=absent; fi
  if ((!changed)); then want=any; fi      # sniffing-only change: the template (and our tag) did not move
  if [[ $want != any ]]; then
    wait_xray "$want" "$mt0" || act_fail "Xray did not come up as expected (generated config should be '$want' for $TAG) within ${GM_WAIT_XRAY:-30} s"
  else
    wait_xray present "$mt0" || wait_xray absent "$mt0" || act_fail "the panel's Xray did not come back"
  fi
  act_commit
  ui_ok "panel restarted; Xray is running with the new settings"
}

foreign_tpl_action() {  # foreign_tpl_action MODE   (P_* parameters set by the caller)
  need_panel
  ftpl_read_or_fail
  if ! py_tpl "$1" "$GM_TMP/template.orig.json" "$GM_TMP/new.json" | sed 's/^/  /'; then act_fail "could not compute the change"; fi
  foreign_commit "$GM_TMP/new.json"
}

# ---------------------------------------------------------------- safe sync to the Iran relay -----
# foreign_sync_cmd OUT host...  -> the command to run ON the Iran server. Every word is shell-quoted
# with printf %q, and every host must be a valid hostname: nothing a log line can contain reaches a shell.
foreign_sync_cmd() {
  local -n __o_sc=$1
  local __sc_h __sc_cmd
  shift
  for __sc_h in "$@"; do v_hostname "$__sc_h" >/dev/null 2>&1 || return 1; done
  __sc_cmd=$(printf '%q ' gemini-menu --role iran --yes domain set "$@")
  __o_sc=${__sc_cmd% }
}

# Keep the Iran side in sync: push over SSH when that works, otherwise print the command.
foreign_sync_iran() {  # the COMPLETE current list
  local cmd ip=$T_IP
  if [[ -z $ip ]]; then foreign_facts || true; ip=$T_IP; fi
  foreign_sync_cmd cmd "$@" || { ui_warn "the list contains an invalid hostname - not syncing"; return 0; }
  ui_blank
  ui_say "The Iran relay must accept the same hosts, or the missing ones are refused there."
  if v_ipv4 "$ip" >/dev/null 2>&1 && command -v ssh >/dev/null 2>&1 \
    && ssh -o BatchMode=yes -o ConnectTimeout=6 -- "root@$ip" true >/dev/null 2>&1; then
    if is_dry; then dry_say "SSH to $ip works: would run it there: $cmd"; return 0; fi
    if confirm "SSH to the Iran server ($ip) works. Push the new list there now?"; then
      if ssh -o BatchMode=yes -- "root@$ip" "$cmd"; then ui_ok "Iran relay updated"; else ui_warn "the push failed - run this ON the Iran server:  $cmd"; fi
      return 0
    fi
  fi
  ui_say "Run this ON the Iran server (one line):"
  ui_say "  $cmd"
}

