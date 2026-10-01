#!/usr/bin/env bash
# tests/foreign_test.sh - end-to-end tests of the FOREIGN role against a sandbox with a REAL SQLite
# 3X-UI database. Fake: the machine (GM_ROOT), systemctl / the panel service (tests/fixtures/bin).
#   ./tests/foreign_test.sh
set -uo pipefail
unset GM_INPUT GM_COLOR GM_ASCII GM_COLUMNS GM_DRY GM_YES NO_COLOR GM_ROLE
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
./build.sh gemini-menu >/dev/null || exit 1
REPO=$PWD
FIX=$REPO/tests/fixtures/bin
BUNDLE=$REPO/dist/gemini-menu.sh
TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/foreign-test.XXXXXX")
PASS=0 FAIL=0
OUT="" RC=0

cleanup() {
  local p
  for p in "$TMPBASE"/*/fake/xui.pid "$TMPBASE"/*/listener.pid; do [[ -f $p ]] && kill "$(<"$p")" 2>/dev/null; done
  rm -rf "$TMPBASE"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; if [[ -n ${2:-} ]]; then printf '      %s\n' "$2"; fi; }
eq()   { if [[ $2 == "$3" ]]; then ok; else bad "$1" "want [$2] got [$3]"; fi; }
has()  { if grep -qF -- "$2" <<<"$OUT"; then ok; else bad "$1" "output lacks: $2"; sed 's/^/        | /' <<<"$OUT" | tail -n 16; fi; }
hasnt() { if grep -qF -- "$2" <<<"$OUT"; then bad "$1" "output unexpectedly has: $2"; else ok; fi; }
exists() { if [[ -e $2 ]]; then ok; else bad "$1" "missing: $2"; fi; }

# ---------------------------------------------------------------------------- sandbox + panel
new_sandbox() {
  local p
  for p in "${SB:-/nonexistent}"/fake/xui.pid "${SB:-/nonexistent}"/listener.pid; do [[ -f $p ]] && kill "$(<"$p")" 2>/dev/null; done   # earlier fake panels must not satisfy pgrep
  SB=$(mktemp -d "$TMPBASE/sb.XXXX")
  R=$SB/root; mkdir -p "$R/etc/x-ui" "$R/usr/local/x-ui/bin" "$SB/fake"
  DBF=$R/etc/x-ui/x-ui.db
  XBIN=$R/usr/local/x-ui/bin/xray-linux-test
  cp "$FIX/xray" "$XBIN"
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  KEYF=$SB/ss.key; openssl rand -base64 16 >"$KEYF"; chmod 600 "$KEYF"
  python3 - "$DBF" <<'PY'
import json, sqlite3, sys
tpl = {
  "log": {"access": "none", "loglevel": "warning"},
  "api": {"tag": "api", "services": ["HandlerService", "StatsService"]},
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "blocked"}],
  "routing": {"domainStrategy": "AsIs", "rules": [
    {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
    {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
    {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]}]}}
con = sqlite3.connect(sys.argv[1])
con.execute("create table settings (id integer primary key, key text, value text)")
con.execute("create table inbounds (id integer primary key, remark text, port integer, protocol text, enable integer, sniffing text, tag text)")
con.execute("insert into settings (key, value) values ('xrayTemplateConfig', ?)", (json.dumps(tpl, indent=2),))
good = json.dumps({"enabled": True, "destOverride": ["http", "tls"], "routeOnly": False})
con.executemany("insert into inbounds (remark, port, protocol, enable, sniffing, tag) values (?,?,?,?,?,?)", [
  ("Phone", 8443, "vless", 1, json.dumps({"enabled": False}), "in-8443"),
  ("Laptop", 2053, "trojan", 1, good, "in-2053"),
  ("", 443, "vless", 1, json.dumps({"enabled": True, "destOverride": ["tls"], "routeOnly": True}), "in-443"),
  ("api", 62789, "tunnel", 1, "", "api")])
con.commit()
PY
  ORIG_SHA=$(tplsha)
  # a "relay": something listening on the Iran side
  python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(8)
while True:
    c,_=s.accept(); c.close()' "$PORT" >/dev/null 2>&1 &
  echo $! >"$SB/listener.pid"
  sleep 0.3
}
tplsha() {  # sha256 of the EXACT stored template text
  python3 - "$DBF" <<'PY'
import hashlib, sqlite3, sys
print(hashlib.sha256(sqlite3.connect(sys.argv[1]).execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0].encode()).hexdigest())
PY
}
tplpy() {  # tplpy 'python expression over t (the template dict)'  -> prints the result
  python3 - "$DBF" "$1" <<'PY'
import json, sqlite3, sys
t = json.loads(sqlite3.connect(sys.argv[1]).execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0])
print(eval(sys.argv[2]))
PY
}
nbk() { ls -1d "$R"/root/gemini-shecan-backup/*/ 2>/dev/null | wc -l; }
fenv() {
  echo PATH="$FIX:$PATH" GM_ROOT="$R" GM_FAKE="$SB/fake" GM_ASSUME_ROOT=1 GM_ASCII=1 GM_COLOR=0 NO_COLOR=1 GM_COLUMNS=100 \
    GM_FORCE_LINK=1 XUI_FAKE_DB="$DBF" XUI_FAKE_DIR="$R/usr/local/x-ui/bin" GM_WAIT_XRAY=4 GM_XRAY_POLL=0.3 GM_STATUS_TTL=0 TMPDIR="$TMPBASE"
}
# fgm args...: run the bundle (no terminal, no input); sets OUT / RC
fgm() {
  # shellcheck disable=SC2046
  OUT=$(env $(fenv) GM_INPUT= bash "$BUNDLE" --role foreign "$@" 2>&1 </dev/null)
  RC=$?
}
# fgmi "input" args...: answers prompts through stdin
fgmi() {
  local input=$1; shift
  # shellcheck disable=SC2046
  OUT=$(env $(fenv) GM_INPUT=stdin bash "$BUNDLE" --role foreign "$@" 2>&1 <<<"$input")
  RC=$?
}
setup_args() { echo setup --iran-ip 127.0.0.1 --ss-port "$PORT" --key-file "$KEYF" --xray-bin "$XBIN" --yes; }
# shellcheck disable=SC2046
fsetup() { fgm $(setup_args) "$@"; }

# ================================================================================ dry-run
new_sandbox
fsetup --dry-run
eq "dry-run setup exits 0" 0 "$RC"; has "dry-run is labelled" "[DRY-RUN]"; has "...says what it would do" "would back up the DB"
eq "dry-run leaves the template untouched" "$ORIG_SHA" "$(tplsha)"
eq "dry-run creates no backup" 0 "$(nbk)"

# ================================================================================ real setup
fsetup
eq "setup exits 0" 0 "$RC"; has "setup result OK" "[ OK ]  Setup"
hasnt "the SS key is never printed" "$(<"$KEYF")"
eq "outbound ir-gemini appended LAST (default outbound unchanged)" "direct,blocked,ir-gemini" "$(tplpy '",".join(o["tag"] for o in t["outbounds"])')"
eq "rules inserted right after bittorrent: udp/443 block, then domains -> ir-gemini" \
  "blocked|udp|443;ir-gemini|None|None" "$(tplpy '(lambda r, i: ";".join("%s|%s|%s" % (x["outboundTag"], x.get("network"), x.get("port")) for x in r[i+1:i+3]))(t["routing"]["rules"], [k for k,x in enumerate(t["routing"]["rules"]) if "bittorrent" in x.get("protocol", [])][0])')"
eq "the nine Gemini hosts are routed" 9 "$(tplpy 'len([r for r in t["routing"]["rules"] if r.get("outboundTag") == "ir-gemini"][0]["domain"])')"
eq "one backup folder was created" 1 "$(nbk)"
BK=$(ls -1d "$R"/root/gemini-shecan-backup/*/ | head -1); BK=${BK%/}
exists "backup holds the DB copy" "$BK/x-ui.db"; exists "...the original template" "$BK/template.orig.json"
exists "...the template this run wrote (for the guarded rollback)" "$BK/template.new.json"; exists "...and the manifest" "$BK/foreign.manifest"
eq "the backup template is the ORIGINAL" "$ORIG_SHA" "$(sha256sum <"$BK/template.orig.json" | cut -d' ' -f1)"
eq "the generated panel config was reloaded with the new outbound" yes "$(grep -q '"ir-gemini"' "$R/usr/local/x-ui/bin/config.json" && echo yes || echo no)"
eq "setup also installs the gemini command (link + file)" yes "$([[ -L $R/usr/local/bin/gemini && -x $R/usr/local/bin/gemini-menu ]] && echo yes || echo no)"
eq "role remembered after setup" foreign "$(tr -d '[:space:]' <"$R/etc/gemini-shecan/role")"
fsetup; eq "re-running setup exits 0" 0 "$RC"; has "...nothing to change" "nothing to change"; eq "...no new backup" 1 "$(nbk)"

# ================================================================================ status
fgm status
eq "status: warnings only (bad sniffing) -> exit 1" 1 "$RC"; has "...routing is ON" "[ON]"; has "...relay reachable" "REACHABLE"; has "...sniffing flagged" "BAD"
fgm routing status; has "routing status" "Gemini routing: on"

# ================================================================================ Finding 7: compare-and-swap
new_sandbox; fsetup >/dev/null
BEFORE_BK=$(nbk)
# someone saves in the panel WHILE the tool waits for the typed confirmation
OUT=$({ sleep 1.5; python3 - "$DBF" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); v = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
t = json.loads(v); t["log"]["loglevel"] = "debug"; con.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, indent=2),)); con.commit()
PY
  echo yes; } | env $(fenv) GM_INPUT=stdin bash "$BUNDLE" --role foreign routing off 2>&1)
RC=$?
if ((RC != 0)); then ok; else bad "a concurrent panel edit must make the write fail"; fi
has "the conflict is reported" "changed by someone else"
has "...and says nothing was written" "NOTHING was written"
eq "the panel user's edit is still there (not overwritten)" debug "$(tplpy 't["log"]["loglevel"]')"
eq "routing was NOT switched off by the refused write" on "$(fgm routing status; grep -o 'routing: [a-z]*' <<<"$OUT" | cut -d' ' -f2)"
eq "the refused write left no stray backup" "$BEFORE_BK" "$(nbk)"
fgm routing off --yes; eq "after the conflict a fresh run works" 0 "$RC"
eq "...and keeps the panel user's edit" debug "$(tplpy 't["log"]["loglevel"]')"
fgm routing on --yes

# ================================================================================ guarded rollback
new_sandbox; fsetup >/dev/null
fgm rollback --yes
eq "rollback restores the original template" "$ORIG_SHA" "$(tplsha)"; has "...reports done" "rollback done"
eq "...the panel config no longer has the outbound" 0 "$(grep -c '"ir-gemini"' "$R/usr/local/x-ui/bin/config.json")"
fgm rollback --yes; eq "rolling back twice: nothing left to undo" 1 "$RC"; has "...says so" "nothing to roll back"
new_sandbox; fsetup >/dev/null
python3 - "$DBF" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); v = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
t = json.loads(v); t["log"]["loglevel"] = "info"; con.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, indent=2),)); con.commit()
PY
EDITED=$(tplsha)
fgm rollback --yes
eq "rollback after a later panel edit does NOT silently discard it" 10 "$RC"; has "...warns about the later edits" "edited afterwards"
eq "...the panel user's edit is intact" "$EDITED" "$(tplsha)"
fgmi $'yes\n' rollback --yes
eq "...an explicit typed 'yes' is required to discard it" 0 "$RC"; eq "...then the original is restored" "$ORIG_SHA" "$(tplsha)"

# ================================================================================ automatic restore
new_sandbox; fsetup >/dev/null
touch "$SB/fake/xui_fail_once"
fgm routing off --yes
if ((RC != 0)); then ok; else bad "a restart that does not bring Xray back must fail"; fi
has "failure is reported" "[FAILED]"; has "...the previous template is restored automatically" "restoring the previous template"
eq "...routing is back ON in the panel" on "$(tplpy '"on" if not any(str(i).startswith("__gemini_off__") for r in t["routing"]["rules"] for i in r.get("inboundTag", [])) else "off"')"
has "...and Xray runs again" "previous template restored; the panel's Xray is running again"

# ================================================================================ validation refusals
new_sandbox
XRAY_FAKE_REJECT=1 fsetup
if ((RC != 0)); then ok; else bad "a template the panel's Xray rejects must not be written"; fi
has "setup: a rejected patch is reported before anything is written" "Xray rejected the patched template in both outbound forms"
eq "...the template is untouched" "$ORIG_SHA" "$(tplsha)"; eq "...no backup" 0 "$(nbk)"
fsetup >/dev/null; SHA_ON=$(tplsha); NB=$(nbk)
XRAY_FAKE_REJECT=1 fgm routing off --yes
if ((RC != 0)); then ok; else bad "routing off rejected by Xray must fail"; fi
has "commit: the panel's Xray rejects the new template" "rejected the new template"
eq "...nothing written" "$SHA_ON" "$(tplsha)"; eq "...no extra backup" "$NB" "$(nbk)"
python3 - "$DBF" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); v = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
t = json.loads(v); t["routing"]["rules"] = [r for r in t["routing"]["rules"] if "bittorrent" not in r.get("protocol", [])]
con.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, indent=2),)); con.commit()
PY
SHA2=$(tplsha)
fsetup
if ((RC != 0)); then ok; else bad "no bittorrent rule: must refuse to guess"; fi
has "...says it refuses to guess" "refusing to guess where to insert"; eq "...nothing written" "$SHA2" "$(tplsha)"
new_sandbox; kill "$(<"$SB/listener.pid")"; sleep 0.3
fsetup; eq "relay unreachable: setup fails before touching the panel" 1 "$RC"; has "...explains" "is not reachable from this server"; eq "...template untouched" "$ORIG_SHA" "$(tplsha)"
fgm setup --iran-ip 999.1.1.1 --key-file "$KEYF" --xray-bin "$XBIN" --yes; eq "bad IP refused" 1 "$RC"; has "...reason" "not an IPv4 address"
fgm setup --iran-ip 127.0.0.1 --yes --xray-bin "$XBIN"; eq "no key file and no terminal: clean error" 1 "$RC"; has "...says what is missing" "key file is required"
fgm routing sideways; eq "routing with junk is refused" 2 "$RC"
fgm sniffing fix 1,abc --yes; eq "sniffing fix with junk ids is refused" 2 "$RC"

# ================================================================================ domains + safe sync (Finding 10)
new_sandbox; fsetup >/dev/null
fgm domain add bard2.google.com --yes
eq "domain add exits 0" 0 "$RC"; eq "...both rules updated" "10,10" "$(tplpy '",".join(str(len(r["domain"])) for r in t["routing"]["rules"] if r.get("domain"))')"
has "...prints the Iran sync command, shell-quoted" "gemini-menu --role iran --yes domain set"
fgm domain add 'evil;rm -rf /.com' --yes; eq "invalid hostname refused" 1 "$RC"
fgm domain add '$(touch /tmp/pwned).example.com' --yes; eq "command substitution in a hostname refused" 1 "$RC"
fgm domain remove bard2.google.com --yes; eq "domain remove" 0 "$RC"
fgm domain list; has "domain list" "gemini.google.com"
# the sync command builder, directly
OUT=$(bash -c 'source "$1"; foreign_sync_cmd c gemini.google.com a-b.example.com && echo "$c"; foreign_sync_cmd c "x;y.com" && echo ACCEPTED-BAD; foreign_sync_cmd c "a.com" "\$(id).com" && echo ACCEPTED-BAD2; true' _ "$BUNDLE" 2>&1)
has "sync command lists the hosts" "gemini-menu --role iran --yes domain set gemini.google.com a-b.example.com"
hasnt "a hostname with ; is refused by the builder" ACCEPTED-BAD
hasnt "a hostname with \$() is refused by the builder" ACCEPTED-BAD2

# ================================================================================ scope
fgm scope set in-8443 --yes; eq "scope set exits 0" 0 "$RC"
eq "...only that inbound is in the rules" "in-8443" "$(tplpy '",".join(sorted({i for r in t["routing"]["rules"] if r.get("outboundTag")=="ir-gemini" for i in r.get("inboundTag", [])}))')"
fgm scope list; has "scope list" "in-8443"
has "...an inbound with an EMPTY remark keeps its columns intact" "in-443  :443   [vless]"
fgm scope all --yes; eq "scope all" 0 "$RC"; eq "...rules unscoped" "" "$(tplpy '",".join(sorted({i for r in t["routing"]["rules"] if r.get("outboundTag")=="ir-gemini" for i in r.get("inboundTag", [])}))')"
fgmi $'3\nb\n' scope pick; eq "interactive scope: b cancels" 10 "$RC"; has "...CANCELLED" "[CANCELLED]"
eq "...and nothing was applied (no ghost ticks)" "" "$(tplpy '",".join(sorted({i for r in t["routing"]["rules"] if r.get("outboundTag")=="ir-gemini" for i in r.get("inboundTag", [])}))')"
fgmi $'*\n1 3\nd\nyes\n' scope pick; has "interactive scope: '*' is rejected, not expanded" "is not valid here"
eq "...a proper selection applies (all start ticked; '1 3' un-ticks two)" "in-2053" "$(tplpy '",".join(sorted({i for r in t["routing"]["rules"] if r.get("outboundTag")=="ir-gemini" for i in r.get("inboundTag", [])}))')"
fgm scope all --yes >/dev/null

# ================================================================================ sniffing audit / fix / revert
fgm sniffing audit; has "audit lists the bad inbounds" "id=1"; has "...including the empty-remark one" "id=3"; hasnt "...not the good one" "id=2"
fgm sniffing fix all --yes; eq "sniffing fix exits 0" 0 "$RC"; has "...reports it" "sniffing fixed on 2 inbound(s)"
eq "...sniffing is fixed in the DB" 0 "$(sqlite3 "$DBF" "select count(*) from inbounds where id in (1,3) and (sniffing not like '%\"tls\"%' or sniffing like '%\"routeOnly\": true%')")"
fgm sniffing audit; has "audit is clean afterwards" "all enabled inbounds have sniffing"
LB=$(ls -1d "$R"/root/gemini-shecan-backup/*/ | tail -1); exists "the old sniffing values are in the backup" "${LB}sniffing.orig.json"
fgm status; has "status: sniffing is OK after the fix" "every enabled inbound sniffs tls+http"
fgm revert --yes; eq "revert exits 0" 0 "$RC"
eq "...ir-gemini is gone from the template" 0 "$(tplpy 'sum(1 for o in t["outbounds"] if o["tag"]=="ir-gemini")')"
eq "...sniffing values restored to the originals" 1 "$(sqlite3 "$DBF" "select count(*) from inbounds where id=1 and sniffing like '%\"enabled\": false%'")"

# ================================================================================ end-to-end test action
new_sandbox; fsetup >/dev/null
fgm test --quick; eq "end-to-end test passes" 0 "$RC"; has "...whole chain works" "The whole chain works"
fgm status; hasnt "...the recorded result shows up" "NEVER"
kill "$(<"$SB/listener.pid")"; sleep 0.3
fgm test --quick; eq "relay down: test fails" 1 "$RC"; has "...names the broken hop" "BROKEN at: foreign -> Iran port"

# ================================================================================ learn mode: hostile log lines
new_sandbox; fsetup >/dev/null
LOG=$R/var/log/panel-access.log; mkdir -p "$(dirname "$LOG")"; : >"$LOG"
python3 - "$DBF" "$LOG" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); v = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
t = json.loads(v); t["log"]["access"] = sys.argv[2]; con.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, indent=2),)); con.commit()
PY
( sleep 2.2; {
  for i in 1 2 3; do echo "2026/10/01 10:00:0$i from 1.2.3.4:5555 accepted tcp:newhost.googleapis.com:443 [in-8443 -> direct]"; done
  echo '2026/10/01 10:00:05 from 1.2.3.4:1 accepted tcp:x$(touch PWNED).example.com:443 [in-8443 -> direct]'
  echo '2026/10/01 10:00:06 from 1.2.3.4:1 accepted tcp:evil;reboot.example.com:443 [in-8443 -> direct]'
  printf '2026/10/01 10:00:07 from 1.2.3.4:1 accepted tcp:esc\033[31mseq.example.com:443 [x]\n'
  echo '2026/10/01 10:00:08 from 1.2.3.4:1 accepted tcp:mtalk.google.com:5228 [in-8443 -> direct]'
  } >>"$LOG" ) &
WRITER=$!
fgmi $'\n1\n3\n\n\n1\nd\nyes\n' learn
wait "$WRITER" 2>/dev/null
eq "learn mode exits 0" 0 "$RC"
has "the legitimate new host was offered" "newhost.googleapis.com"
hasnt "shell metacharacters never reach the screen (\$())" 'touch PWNED'
hasnt "...nor ';'" "evil;reboot"
hasnt "...nor escape sequences" $'\033[31m'
hasnt "known background hosts stay hidden" "mtalk.google.com"
eq "the host was added to the rules" 1 "$(tplpy 'sum(1 for r in t["routing"]["rules"] if r.get("outboundTag")=="ir-gemini" and "full:newhost.googleapis.com" in r["domain"])')"
eq "nothing hostile reached the template" 0 "$(tplpy 'sum(1 for r in t["routing"]["rules"] for d in r.get("domain", []) if any(c in d for c in ";$( ")) ')"
eq "...and nothing was executed" 0 "$(ls "$PWD"/PWNED 2>/dev/null | wc -l)"
has "the Iran sync command is printed quoted" "domain set"
# access log OFF in the panel: learn mode turns it on, and offers to turn it back off
new_sandbox; fsetup >/dev/null
ALOG=$R/var/log/gemini-menu-access.log
( sleep 5.5; echo "2026/10/01 10:00:01 from 1.2.3.4:5 accepted tcp:learned.googleapis.com:443 [x]" >>"$ALOG" ) &
WRITER=$!
fgmi $'y\nyes\n\n1\n6\n\n\n1\nd\nyes\ny\nyes\n' learn
wait "$WRITER" 2>/dev/null
eq "learn with the access log OFF exits 0" 0 "$RC"
has "learn mode explains it must switch the log on" "access log is OFF"
has "...found the new host" "learned.googleapis.com"
has "...offered to turn the log back off" "Turn the access log back off"
eq "...the log is back to 'none' (not the literal text __unset__)" none "$(tplpy 't["log"]["access"]')"
eq "...the host stayed in the rules" 1 "$(tplpy 'sum(1 for r in t["routing"]["rules"] if r.get("outboundTag")=="ir-gemini" and "full:learned.googleapis.com" in r["domain"])')"
# cancel the picker: no ghost ticks
new_sandbox; fsetup >/dev/null
LOG=$R/var/log/panel-access.log; mkdir -p "$(dirname "$LOG")"; : >"$LOG"
python3 - "$DBF" "$LOG" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); v = con.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]
t = json.loads(v); t["log"]["access"] = sys.argv[2]; con.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, indent=2),)); con.commit()
PY
SHA3=$(tplsha)
( sleep 2.2; echo "2026/10/01 10:00:01 from 1.2.3.4:5 accepted tcp:ghost.googleapis.com:443 [x]" >>"$LOG" ) &
WRITER=$!
fgmi $'\n1\n3\n\n\n1\nb\n' learn
wait "$WRITER" 2>/dev/null
eq "learn: cancelling the picker cancels the action (exit 10)" 10 "$RC"; has "...CANCELLED" "[CANCELLED]"
eq "...and the ticked host was NOT applied (no ghost ticks)" "$SHA3" "$(tplsha)"

# ================================================================================ backups
new_sandbox; fsetup >/dev/null
fgm backups list; has "backups list" "1)"; has "...summarised" "template"
fgm backups diff 1; eq "backups diff" 0 "$RC"
fgm backups diff abc; eq "backups diff with junk refused" 2 "$RC"

printf '\n%d passed, %d failed (foreign)\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
