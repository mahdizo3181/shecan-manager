#!/usr/bin/env bash
# tests/run.sh - logic tests for the Phase 1 foundation (no terminal needed).
#   ./tests/run.sh          run everything (builds first); also runs tests/pty_test.py if python3 exists
# Every regression listed in the Phase 0 diagnosis has a test here.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
./build.sh >/dev/null || exit 1

export GM_ASCII=1 GM_COLOR=0 GM_INPUT=stdin GM_COLUMNS=80 NO_COLOR=1
# shellcheck disable=SC1090
for f in src/lib/[0-9]*.sh; do source "$f"; done
gm_tmp_init
ui_detect
in_init
OUT=$GM_TMP/out
PASS=0 FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; if [[ -n ${2:-} ]]; then printf '      %s\n' "$2"; fi; }
eq()   { if [[ $2 == "$3" ]]; then ok; else bad "$1" "want [$2] got [$3]"; fi; }
has()  { if grep -qF -- "$2" "$OUT"; then ok; else bad "$1" "output lacks: $2"; sed 's/^/        | /' "$OUT" | head -15; fi; }
hasnt() { if grep -qF -- "$2" "$OUT"; then bad "$1" "output unexpectedly has: $2"; else ok; fi; }
count() { local n; n=$(grep -o -- "$2" "$OUT" | wc -l); eq "$1" "$3" "$n"; }   # occurrences (scripted prompts have no trailing newline)

# ============================== action runner ===================================================
a_fail_midway() { echo START; false; echo AFTER_FAILURE; }
act_run "t" a_fail_midway >"$OUT" 2>&1; rc=$?
eq "errexit: failing command stops the action" 1 "$rc"
hasnt "errexit: nothing runs after the failing command" AFTER_FAILURE
has "errexit: result line says FAILED" "[FAILED]"

act_run "t" a_fail_midway >"$OUT" 2>&1 || true
eq "runner refuses errexit-suppressed context (|| true)" 70 "$ACT_RC"
has "...and says why" "errexit is disabled"
hasnt "...and did not run the action" START
if act_run "t" a_fail_midway >"$OUT" 2>&1; then :; fi
eq "runner refuses errexit-suppressed context (if)" 70 "$ACT_RC"

a_cancel() { act_cancel "no changes"; echo AFTER; }
act_run "t" a_cancel >"$OUT" 2>&1; rc=$?
eq "act_cancel -> 10" 10 "$rc"; has "cancel shows CANCELLED" "[CANCELLED]"; hasnt "cancel stops the action" AFTER

a_fail3() { act_fail "boom" 3; echo AFTER; }
act_run "t" a_fail3 >"$OUT" 2>&1; rc=$?
eq "act_fail keeps its code" 3 "$rc"; has "..." "(exit 3)"; hasnt "..." AFTER

a_must() { must ls /nonexistent-gm-test; echo AFTER; }
act_run "t" a_must >"$OUT" 2>&1; rc=$?
eq "must ends the action with the command's code" 2 "$rc"; hasnt "..." AFTER

a_prompt_cancel() { local ip; prompt_ipv4 ip "IP" || act_cancel; echo "GOT $ip"; }
act_run "t" a_prompt_cancel >"$OUT" 2>&1 <<<"b"; rc=$?
eq "typing b at a prompt cancels the action" 10 "$rc"
act_run "t" a_prompt_cancel >"$OUT" 2>&1 </dev/null; rc=$?
eq "end of input cancels (no die, no hang)" 10 "$rc"
act_run "t" a_prompt_cancel >"$OUT" 2>&1 <<<$'oops\n\n1.2.3.4'; rc=$?
eq "typos re-prompt, then the action proceeds" 0 "$rc"; has "..." "GOT 1.2.3.4"

a_rollback() { act_on_fail echo ROLLED_BACK; act_defer echo DEFERRED; echo STEP; false; }
act_run "t" a_rollback >"$OUT" 2>&1
has "rollback runs on failure" ROLLED_BACK; has "deferred cleanup runs" DEFERRED
a_committed() { act_on_fail echo ROLLED_BACK; act_commit; act_defer echo DEFERRED; false; }
act_run "t" a_committed >"$OUT" 2>&1
hasnt "act_commit forgets rollbacks" ROLLED_BACK; has "defer still runs" DEFERRED
a_ok() { act_on_fail echo ROLLED_BACK; act_defer echo DEFERRED; echo FINE; }
act_run "t" a_ok >"$OUT" 2>&1; rc=$?
eq "success -> 0" 0 "$rc"; hasnt "no rollback on success" ROLLED_BACK; has "defer runs on success" DEFERRED; has "OK badge" "[ OK ]"

a_partial() { act_partial "service installed"; act_fail "later step failed"; }
act_run "t" a_partial >"$OUT" 2>&1
has "partial failure is reported honestly" "[PARTIAL]"; has "..." "service installed"

GM_DRY=1 act_run "t" a_ok >"$OUT" 2>&1
has "dry-run result is labelled, not 'OK'" "[DRY-RUN]"; hasnt "..." "[ OK ]"
a_do() { act_do "delete everything" echo REALLY_RAN; }
GM_DRY=1 act_run "t" a_do >"$OUT" 2>&1; hasnt "act_do does nothing in dry-run" REALLY_RAN; has "...and says what it would do" "would delete everything"
act_run "t" a_do >"$OUT" 2>&1; has "act_do runs for real otherwise" REALLY_RAN

# ============================== validators & prompts ============================================
vt() { local fn=$1 want=$2; shift 2; if "$fn" "$@" 2>/dev/null; then got=ok; else got=bad; fi; eq "$fn $*" "$want" "$got"; }
vt v_ipv4 ok 1.2.3.4; vt v_ipv4 ok 255.255.255.0; vt v_ipv4 bad 256.1.1.1; vt v_ipv4 bad 1.2.3; vt v_ipv4 bad 01.2.3.4
vt v_ipv4 bad "1.2.3.4 "; vt v_ipv4 bad a.b.c.d; vt v_ipv4 bad ""
vt v_port ok 1; vt v_port ok 65535; vt v_port bad 0; vt v_port bad 65536; vt v_port bad 80a; vt v_port bad ""
vt v_int_range ok 5 1 10; vt v_int_range bad 11 1 10; vt v_int_range bad -1 1 10
v_hostname "HTTPS://Gemini.Google.com/chat"; eq "hostname is normalised" gemini.google.com "$IN_VALUE"
v_hostname "full:bard.google.com."; eq "full: prefix and trailing dot removed" bard.google.com "$IN_VALUE"
vt v_hostname bad 'a;rm -rf /.com'; vt v_hostname bad 'x$(reboot).example.com'; vt v_hostname bad localhost; vt v_hostname bad -a.com
v_choice 2 one two three; eq "choice by number" two "$IN_VALUE"; v_choice THREE one two three; eq "choice by name" three "$IN_VALUE"
vt v_choice bad 4 one two three
vt v_b64_bytes ok "$(printf '0123456789abcdef' | base64)" 16; vt v_b64_bytes bad "AAAA" 16

ip=""; prompt_ipv4 ip "IP" >"$OUT" 2>&1 <<<$'abc\n\n999.1.1.1\n1.2.3.4'; rc=$?
eq "prompt_ipv4 re-asks until valid" "0:1.2.3.4" "$rc:$ip"
count "...with one inline error per mistake" "  x " 3
has "...a helpful message" "not an IPv4 address"
port=""; prompt_port port "Port" 20443 >"$OUT" 2>&1 <<<""; eq "Enter takes the default" 20443 "$port"
IN_EOF=0; prompt_port port "Port" >"$OUT" 2>&1 </dev/null; rc=$?; eq "EOF -> cancelled (10), flagged" "10:1" "$rc:$IN_EOF"
prompt_port port "Port" >"$OUT" 2>&1 <<<"cancel"; eq "cancel word -> 10" 10 $?
h=""; prompt_hostname h "Host" >"$OUT" 2>&1 <<<"HTTP://Aistudio.Google.com/x"; eq "prompt_hostname normalises" aistudio.google.com "$h"
n=""; prompt_int n "Minutes" 1 240 10 >"$OUT" 2>&1 <<<$'0\n999\n\n'; eq "prompt_int: range errors then default" 10 "$n"
e=""; IN_ALLOW_EMPTY=1 prompt_valid e "Optional" "" v_nonempty >"$OUT" 2>&1 <<<""; eq "IN_ALLOW_EMPTY lets an empty answer through" "0" "$?"
s=""; prompt_secret s "Secret" >"$OUT" 2>&1 <<<$'\nhunter2'; eq "secret: empty is re-asked" hunter2 "$s"; hasnt "secret is not echoed back" hunter2
c=""; prompt_choice c "Pick" "" red green >"$OUT" 2>&1 <<<$'7\ngreen'; eq "prompt_choice" green "$c"

confirm "Sure?" >"$OUT" 2>&1 <<<$'maybe\ny'; eq "confirm: invalid answer re-asks, then yes" 0 $?
confirm "Sure?" >"$OUT" 2>&1 <<<"n"; eq "confirm: no -> 1" 1 $?
confirm "Sure?" y >"$OUT" 2>&1 <<<""; eq "confirm: Enter takes default y" 0 $?
confirm "Sure?" n >"$OUT" 2>&1 <<<""; eq "confirm: Enter takes default n" 1 $?
confirm "Sure?" >"$OUT" 2>&1 <<<""; eq "confirm: Enter without default re-asks, then EOF cancels" 10 $?
confirm "Sure?" >"$OUT" 2>&1 <<<"b"; eq "confirm: b -> 10" 10 $?
GM_YES=1 confirm "Sure?" >"$OUT" 2>&1 </dev/null; eq "--yes answers confirm" 0 $?
confirm_typed "Dangerous" yes >"$OUT" 2>&1 <<<$'nope\nyes'; eq "confirm_typed needs the word" 0 $?
confirm_typed "Dangerous" yes >"$OUT" 2>&1 <<<"b"; eq "confirm_typed: b cancels" 10 $?
GM_YES=1 confirm_typed "Dangerous" yes >"$OUT" 2>&1 </dev/null; eq "--yes skips confirm_typed" 0 $?
GM_YES=1 confirm_typed_force "Secret" yes >"$OUT" 2>&1 <<<"b"; eq "--yes can NOT skip confirm_typed_force" 10 $?

# ============================== multi-select ====================================================
labels=(alpha beta gamma); sel=(1 0 0); chosen=(untouched)
pick_many chosen "Pick" labels sel >"$OUT" 2>&1 <<<$'2\nd'; eq "pick_many toggles and returns indexes" "0:0 1" "$?:${chosen[*]}"
chosen=(untouched); pick_many chosen "Pick" labels sel >"$OUT" 2>&1 <<<$'3\n1\nb'; rc=$?
eq "pick_many: cancel returns 10" 10 "$rc"; eq "...and leaves the caller's selection alone" "untouched|1 0 0" "${chosen[*]}|${sel[*]}"
pick_many chosen "Pick" labels sel >"$OUT" 2>&1 <<<$'1a\n9\n2-\nd'; eq "pick_many: junk is rejected, result = initial" "0:0" "$?:${chosen[*]}"
count "...each bad line gets one inline error" "  x " 3
pick_many chosen "Pick" labels sel >"$OUT" 2>&1 <<<$'1-3\nd'; eq "pick_many: ranges" "1 2" "${chosen[*]}"
pick_many chosen "Pick" labels sel >"$OUT" 2>&1 <<<$'2 zzz\nd'; eq "pick_many: one bad token rejects the WHOLE line" "0" "${chosen[*]}"
gd=$(mktemp -d "$GM_TMP/glob.XXXX"); touch "$gd/a" "$gd/n" "$gd/d"
( cd "$gd" && pick_many chosen "Pick" labels sel >"$OUT" 2>&1 <<<$'*\nd'; echo "${chosen[*]}" >"$GM_TMP/glob.res" )
eq "pick_many: '*' is never glob-expanded (files a/n/d exist)" "0" "$(<"$GM_TMP/glob.res")"

# ============================== rendering =======================================================
ui_safe clean $'hi\e[31mred\x07'; eq "ui_safe drops control characters" "hi[31mred" "$clean"
ui_vlen n $'\e[1;36mHello\e[0m world'; eq "ui_vlen ignores colour escapes" 11 "$n"

frame_errs() {  # prints every line that is not exactly UI_W columns wide (colour escapes ignored)
  local line plain
  while IFS= read -r line; do
    plain=${line//$'\e'\[*([0-9;])m/}
    if ((${#plain} != UI_W)); then printf 'width %d: %s\n' "${#plain}" "$plain"; fi
  done
}
draw() {
  local b
  ui_box_top "Title"; ui_box_kv "Role" "IRAN"; ui_box_row "$(printf 'x%.0s' {1..300})"
  ui_badge b ok ACTIVE; ui_box_kv "Relay" "$b detail"; ui_box_sep; ui_box_blank; ui_box_bottom
}
for w in 60 80 100; do GM_COLUMNS=$w ui_width; eq "ASCII frame aligned at $w columns" "" "$(draw | frame_errs)"; done
res=$(LC_ALL=C.UTF-8 GM_ASCII=0 GM_COLOR=1; export LC_ALL GM_ASCII GM_COLOR; ui_detect; GM_COLUMNS=80 ui_width; draw | frame_errs)
eq "Unicode + colour frame aligned (and UI_UNICODE on)" "" "$res"
ui_detect

# ============================== probes ==========================================================
probe_register fast p_fast "Fast"; probe_register slow p_slow "Slow"; probe_register junk p_junk "Junk"
p_fast() { printf 'ok\tACTIVE\tall good\n'; }
p_slow() { sleep 5; printf 'ok\tOK\tlate\n'; }
p_junk() { echo "not a valid line"; }
t0=$SECONDS; GM_PROBE_TIMEOUT=2 probe_refresh 1 >"$OUT" 2>&1; el=$((SECONDS - t0))
eq "probe: ok result parsed" "ok|ACTIVE|all good" "${PROBE_LVL[fast]}|${PROBE_BADGE[fast]}|${PROBE_MSG[fast]}"
eq "probe: a slow probe times out as a warning" "warn" "${PROBE_LVL[slow]}"; eq "...with a clear message" "did not answer in time (skipped)" "${PROBE_MSG[slow]}"
eq "probe: malformed output becomes a warning" warn "${PROBE_LVL[junk]}"
if ((el <= 3)); then ok; else bad "probe: timeout bounds the wait" "took ${el}s"; fi
eq "probe_worst" warn "$(probe_worst)"
probe_clear_all() { PROBE_IDS=(); PROBE_LVL=(); PROBE_FN=(); }
probe_clear_all
for i in 1 2 3; do eval "p_par$i() { sleep 1; printf 'ok\tOK\tdone $i\n'; }"; probe_register "par$i" "p_par$i" "P$i"; done
t0=$SECONDS; probe_refresh 1 >"$OUT" 2>&1; el=$((SECONDS - t0))
if ((el <= 2)); then ok; else bad "probes run in parallel (3 x 1s)" "took ${el}s"; fi
PROBE_AT=$SECONDS; t0=$SECONDS; probe_refresh >"$OUT" 2>&1; if ((SECONDS - t0 == 0)); then ok; else bad "fresh cache is not re-probed"; fi
probe_clear_all

t_ok()  { echo "hello"; }
t_bad() { echo "line1"; echo "the error"; return 4; }
UI_TASK_QUIET=0 ui_task "Good task" t_ok >"$OUT" 2>&1; eq "ui_task success" "0:hello" "$?:$UI_TASK_OUT"
ui_task "Bad task" t_bad >"$OUT" 2>&1; eq "ui_task failure code" 4 $?; has "ui_task shows captured output on failure" "the error"

# ============================== menu engine =====================================================
m_action()  { local ip; prompt_ipv4 ip "IP" || act_cancel; echo "ACTION GOT $ip"; }
m_off()     { MENU_WHY="needs setup first"; return 1; }
menu_screen root "Root"
menu_item root 1 "Do thing" "prompts once" action:m_action
menu_item root 2 "Sub" "" screen:sub
menu_item root 3 "Locked" "" action:m_action m_off
menu_screen sub "Sub"
menu_item sub 1 "Nothing" "" action:m_action
menu_run root >"$OUT" 2>&1 <<<$'zzz\n\n?\n1\n7.7.7.7\n3\nd\n2\nb\nb\nq'; rc=$?
eq "menu_run exits cleanly on q" 0 "$rc"
has "unknown input -> one inline error" '"zzz" is not an option'
has "action's prompt read the KEYBOARD, not the menu's item list" "ACTION GOT 7.7.7.7"
has "action result line appears" "[ OK ]"
has "disabled item explains itself" "needs setup first"
has "d toggles dry-run" "Dry-run is ON"
has "submenu crumbs" "Root > Sub"
has "b at top level is harmless" "top level"
has "? shows help" "How this menu works"
count "invalid input / help do not redraw the menu (4 draws: start, after action, after d, after back)" "+- Root -" 4
GM_DRY=0
menu_run root >"$OUT" 2>&1 <<<$'12\nq'; has "a typo is not an instant trigger: '12' is just invalid" '"12" is not an option'
menu_run root >"$OUT" 2>&1 </dev/null; eq "EOF on the menu ends it cleanly" 0 $?

( menu_screen bad "Bad"; menu_item bad q "x" "" back ) >"$OUT" 2>&1; eq "reserved keys are rejected at definition time" 1 $?
( menu_screen bad2 "Bad"; menu_item bad2 1 "x" "" back; menu_item bad2 1 "y" "" back ) >"$OUT" 2>&1; eq "duplicate keys are rejected" 1 $?


# ============================== shims (Finding 5) ===============================================
sd=$(mktemp -d "$GM_TMP/shim.XXXX"); mkdir -p "$sd/dist"
cp setup-iran.sh setup-foreign.sh "$sd/"
printf '#!/usr/bin/env bash\necho "ENGINE: $*"\n' >"$sd/dist/gemini-menu.sh"; cp "$sd/dist/gemini-menu.sh" "$sd/gemini-menu.sh"; chmod +x "$sd"/dist/gemini-menu.sh "$sd"/gemini-menu.sh
shim() { "$sd/$1" "${@:2}" >"$OUT" 2>&1; }
shim setup-iran.sh;                            has "iran shim: no args -> setup" "ENGINE: --role iran setup"
shim setup-iran.sh --dry-run --xray-version 26.3.27; has "iran shim: flags only -> setup" "ENGINE: --role iran setup --dry-run --xray-version 26.3.27"
shim setup-iran.sh watch;                      has "iran shim: watch" "ENGINE: --role iran watch"
shim setup-iran.sh --yes status;               has "iran shim: command AFTER a flag is honoured" "ENGINE: --role iran --yes status"; hasnt "..." "setup"
shim setup-iran.sh --foreign-ip 1.2.3.4;       has "iran shim: a flag VALUE is not mistaken for a command" "ENGINE: --role iran setup --foreign-ip 1.2.3.4"
shim setup-foreign.sh;                         has "foreign shim: no args -> apply" "ENGINE: --role foreign apply"
shim setup-foreign.sh test;                    has "foreign shim: test" "ENGINE: --role foreign test"; hasnt "..." "apply"
shim setup-foreign.sh --yes test;              has "foreign shim: '--yes test' stays test (it used to run apply --yes!)" "ENGINE: --role foreign --yes test"; hasnt "..." "apply"
shim setup-foreign.sh --dry-run audit;         has "foreign shim: '--dry-run audit'" "--role foreign --dry-run audit"
shim setup-foreign.sh --iran-ip 9.9.9.9 --key-file /k; has "foreign shim: flag values are skipped" "foreign apply --iran-ip 9.9.9.9 --key-file /k"

# ============================== bundles =========================================================
bash -n dist/demo.sh && ok || bad "demo bundle syntax"
bash dist/demo.sh --help >"$OUT" 2>&1; eq "demo --help" 0 $?; has "..." "--dry-run"
bash dist/demo.sh --bogus >"$OUT" 2>&1; eq "unknown option -> 2" 2 $?
GM_ASCII=1 DEMO_DNS_DELAY=0.2 bash dist/demo.sh --status >"$OUT" 2>&1; eq "--status renders" 0 $?; has "..." "[ACTIVE]"
GM_INPUT="" setsid -w bash dist/demo.sh </dev/null >"$OUT" 2>&1; eq "no terminal -> clean message, exit 1" 1 $?; has "..." "no terminal"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
echo "--- iran integration (sandbox)"; bash tests/iran_test.sh || FAIL=$((FAIL + 1))
echo "--- foreign integration (sandbox, real SQLite)"; bash tests/foreign_test.sh || FAIL=$((FAIL + 1))
if command -v python3 >/dev/null 2>&1 && [[ -f tests/pty_test.py ]]; then
  echo "--- pty tests (foundation)"; python3 tests/pty_test.py || FAIL=$((FAIL + 1))
  echo "--- pty tests (iran menu)"; python3 tests/pty_iran_test.py || FAIL=$((FAIL + 1))
  echo "--- pty tests (foreign menu)"; python3 tests/pty_foreign_test.py || FAIL=$((FAIL + 1))
fi
exit $((FAIL > 0))
