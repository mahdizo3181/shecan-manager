#!/usr/bin/env bash
# tests/iran_test.sh - end-to-end tests of the Iran role against a sandbox.
#
# The bundle runs for real; only the machine is fake: GM_ROOT points at a temp directory and
# tests/fixtures/bin supplies stub systemctl / iptables / curl / dig / useradd and an Xray that
# really listens on its port. Nothing here touches the host.
#   ./tests/iran_test.sh
set -uo pipefail
unset GM_INPUT GM_COLOR GM_ASCII GM_COLUMNS GM_DRY GM_YES NO_COLOR GM_ROLE GM_LEGACY   # hermetic: nothing from the caller leaks in
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
./build.sh gemini-menu >/dev/null || exit 1
REPO=$PWD
FIX=$REPO/tests/fixtures/bin
BUNDLE=$REPO/dist/gemini-menu.sh
TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/iran-test.XXXXXX")
PASS=0 FAIL=0
OUT=""; RC=0

cleanup() {
  local p
  for p in "$TMPBASE"/*/fake/svc/*.pid; do [[ -f $p ]] && kill "$(<"$p")" 2>/dev/null; done
  rm -rf "$TMPBASE"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; if [[ -n ${2:-} ]]; then printf '      %s\n' "$2"; fi; }
eq()   { if [[ $2 == "$3" ]]; then ok; else bad "$1" "want [$2] got [$3]"; fi; }
has()  { if grep -qF -- "$2" <<<"$OUT"; then ok; else bad "$1" "output lacks: $2"; sed 's/^/        | /' <<<"$OUT" | tail -n 14; fi; }
hasnt() { if grep -qF -- "$2" <<<"$OUT"; then bad "$1" "output unexpectedly has: $2"; else ok; fi; }
exists()  { if [[ -e $2 ]]; then ok; else bad "$1" "missing: $2"; fi; }
absent()  { if [[ ! -e $2 ]]; then ok; else bad "$1" "should not exist: $2"; fi; }
filehas() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok; else bad "$1" "$2 lacks: $3"; fi; }

new_sandbox() {
  SB=$(mktemp -d "$TMPBASE/sb.XXXX")
  mkdir -p "$SB/root" "$SB/fake"
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  R=$SB/root
  FOREIGN=203.0.113.9
}
# gm [args...]  -> runs the bundle in the sandbox; sets OUT and RC
gm() {
  OUT=$(PATH=$FIX:${EXTRA_PATH:+$EXTRA_PATH:}$PATH GM_ROOT=$R GM_FAKE=$SB/fake GM_ASSUME_ROOT=1 GM_ASCII=1 GM_COLOR=0 NO_COLOR=1 GM_INPUT= GM_FORCE_LINK=${FORCE_LINK-1} \
    GM_DNS_RETRY_SLEEP=0 GM_POLL_SLEEP=0.2 GM_WATCH_SLEEP=0 GM_STATUS_TTL=0 GM_COLUMNS=100 TMPDIR=$TMPBASE \
    SHECAN_REGISTER_URL=${URL-https://shecan.invalid/register?token=SECRET123} \
    bash "$BUNDLE" "$@" 2>&1 </dev/null)
  RC=$?
}
# gmi "typed input" args...  (answers prompts through stdin)
gmi() {
  local input=$1; shift
  OUT=$(PATH=$FIX:$PATH GM_ROOT=$R GM_FAKE=$SB/fake GM_ASSUME_ROOT=1 GM_ASCII=1 GM_COLOR=0 NO_COLOR=1 GM_INPUT=stdin GM_FORCE_LINK=${FORCE_LINK-1} \
    GM_DNS_RETRY_SLEEP=0 GM_POLL_SLEEP=0.2 GM_WATCH_SLEEP=0 GM_STATUS_TTL=0 GM_COLUMNS=100 TMPDIR=$TMPBASE \
    bash "$BUNDLE" "$@" 2>&1 <<<"$input")
  RC=$?
}
setup_args() { echo --role iran setup --foreign-ip "$FOREIGN" --ss-port "$PORT" --xray-bin "$FIX/xray" --yes; }
# shellcheck disable=SC2046
do_setup() { gm $(setup_args) "$@"; }

# ============================================================================ dry-run
new_sandbox
do_setup --dry-run
eq "dry-run setup exits 0" 0 "$RC"
has "dry-run is labelled" "[DRY-RUN]"
has "dry-run shows the plan" "Plan"
absent "dry-run writes nothing (config)" "$R/usr/local/etc/xray-gemini/config.json"
absent "dry-run writes nothing (state dir)" "$R/etc/gemini-shecan"
absent "dry-run writes nothing (backups)" "$R/root/gemini-shecan-backup"
absent "dry-run does not remember a role" "$R/etc/gemini-shecan/role"

# ============================================================================ real setup
new_sandbox
do_setup
eq "setup exits 0" 0 "$RC"
has "setup result is OK" "[ OK ]  Setup"
hasnt "the Shecan URL token is never printed" SECRET123
exists "relay binary installed" "$R/usr/local/bin/xray-gemini"
exists "relay config written" "$R/usr/local/etc/xray-gemini/config.json"
exists "systemd unit written" "$R/etc/systemd/system/xray-gemini.service"
eq "Shecan URL stored with mode 600" 600 "$(stat -c %a "$R/etc/gemini-shecan/shecan-url")"
eq "SS key file mode 600" 600 "$(stat -c %a "$R/root/gemini-shecan/ss.key")"
eq "role remembered after setup" iran "$(tr -d '[:space:]' <"$R/etc/gemini-shecan/role")"
filehas "firewall rule added for the foreign IP only" "$SB/fake/iptables.rules" "-s $FOREIGN -p tcp --dport $PORT -m comment --comment gemini-shecan -j ACCEPT"
filehas "watch.conf has the foreign IP" "$R/etc/gemini-shecan/watch.conf" "FOREIGN_IP=$FOREIGN"
exists "the tool installed itself once" "$R/usr/local/bin/gemini-menu"
filehas "timer runs the INSTALLED tool (Finding 12)" "$R/etc/systemd/system/gemini-shecan-watch.service" "ExecStart=$R/usr/local/bin/gemini-menu --role iran watch"
absent "no second out-of-sync copy of the script" "$R/usr/local/sbin/gemini-shecan-watch"
filehas "catch-all block is in the config" "$R/usr/local/etc/xray-gemini/config.json" '"network": "tcp,udp"'
KEYVAL=$(tr -d '[:space:]' <"$R/root/gemini-shecan/ss.key")

# idempotent re-run
do_setup
eq "re-running setup exits 0" 0 "$RC"
has "...firewall rule already present" "firewall rule already present"
has "...nothing duplicated" "[ OK ]  Setup"
eq "...exactly one firewall rule" 1 "$(grep -c . "$SB/fake/iptables.rules")"

# the old bug: --foreign-ip on an installed relay was silently ignored (watch.conf won)
do_setup --foreign-ip 198.51.100.77
eq "setup with a NEW --foreign-ip exits 0" 0 "$RC"
filehas "...the new IP is stored (Finding 13)" "$R/etc/gemini-shecan/watch.conf" "FOREIGN_IP=198.51.100.77"
FOREIGN=198.51.100.77
do_setup --foreign-ip "$FOREIGN" >/dev/null

# ============================================================================ status
gm --role iran status
eq "status: healthy relay -> exit 0" 0 "$RC"
has "status shows the guard" "GUARDED"
has "status shows the firewall rule" "ALLOWED"
has "status shows DNS hijack" "HIJACKED"
hasnt "status never prints the key" "$KEYVAL"

# ============================================================================ Finding 6: idempotent repair
iptables_clear() { : >"$SB/fake/iptables.rules"; }
iptables_clear
gm --role iran status
eq "missing firewall rule -> status exit 2" 2 "$RC"; has "...says NO RULE" "NO RULE"; has "...names the repair" "repair firewall"
gm --role iran foreign-ip "$FOREIGN"
eq "entering the SAME foreign IP exits 0" 0 "$RC"
has "...re-checks instead of 'already set'" "re-checking its firewall rule"
has "...and re-adds the missing rule (Finding 6)" "firewall rule added for $FOREIGN"
gm --role iran status; eq "...status is healthy again" 0 "$RC"
iptables_clear
gm --role iran repair firewall
eq "repair firewall exits 0" 0 "$RC"; has "...re-added" "rule was missing - added"
gm --role iran repair firewall; has "repair is idempotent" "rule already present"

# ============================================================================ catch-all guard repair
python3 - "$R/usr/local/etc/xray-gemini/config.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["routing"]["rules"].pop(); open(p, "w").write(json.dumps(c, indent=2) + "\n")
PY
gm --role iran status
eq "no catch-all -> status exit 2" 2 "$RC"; has "...flagged as OPEN PROXY" "OPEN PROXY"
gm --role iran repair config
eq "repair config exits 0" 0 "$RC"; has "...rewrote the config" "config rewritten"
gm --role iran status; eq "...guard is back, status healthy" 0 "$RC"
gm --role iran repair config; has "repair config is idempotent" "config already correct"

# ============================================================================ legacy timer migration
mkdir -p "$R/usr/local/sbin"; cp "$BUNDLE" "$R/usr/local/sbin/gemini-shecan-watch"
sed -i "s#^ExecStart=.*#ExecStart=$R/usr/local/sbin/gemini-shecan-watch watch#" "$R/etc/systemd/system/gemini-shecan-watch.service"
gm --role iran status; has "old separate script copy is flagged" "OUTDATED"
gm --role iran repair timer
eq "repair timer exits 0" 0 "$RC"
absent "...the old copy is removed" "$R/usr/local/sbin/gemini-shecan-watch"
filehas "...the unit runs the installed tool" "$R/etc/systemd/system/gemini-shecan-watch.service" "ExecStart=$R/usr/local/bin/gemini-menu --role iran watch"

# ============================================================================ domains
gm --role iran domain add bard.google.com --yes; eq "domain add" 0 "$RC"
filehas "...config has it" "$R/usr/local/etc/xray-gemini/config.json" "full:bard.google.com"
filehas "...relay still guarded" "$R/usr/local/etc/xray-gemini/config.json" '"network": "tcp,udp"'
gm --role iran domain add 'evil;rm -rf /.com' --yes; eq "invalid hostname is refused" 1 "$RC"; has "...with a reason" "not a valid hostname"
gm --role iran domain add HTTPS://Aistudio.Google.com/x --yes; has "existing host (normalised) is recognised" "already in the list"
gm --role iran domain list; has "domain list shows hosts" "bard.google.com"
gm --role iran domain remove bard.google.com --yes; eq "domain remove" 0 "$RC"
gm --role iran domain list; hasnt "...gone" "bard.google.com"
gmi $'zzz\n\n99\n2\nn' --role iran domain remove
has "interactive remove: typos re-ask" "pick one of the listed options"

# ============================================================================ argument validation (Finding 9)
gm --role iran timer ""; eq "timer with an empty argument is refused (used to switch it OFF)" 2 "$RC"
gm --role iran timer maybe; eq "timer with junk is refused" 2 "$RC"
gm --role iran service reload-or-mask --yes; eq "service with an arbitrary verb is refused" 2 "$RC"
gm --role iran timer on --yes; eq "timer on works" 0 "$RC"
gm --role iran backups diff abc; eq "backups diff with a non-number is refused" 2 "$RC"

# ============================================================================ info never leaks the key
gm --role iran info
eq "info exits 0" 0 "$RC"; hasnt "info does not print the full key" "$KEYVAL"; has "...shows the scp command" "scp root@"

# ============================================================================ access log + auto-off
gm --role iran access-on 5 --yes; eq "access-on exits 0" 0 "$RC"
filehas "...auto-off runs the INSTALLED tool" "$SB/fake/systemd-run.log" "$R/usr/local/bin/gemini-menu --role iran --yes access-off"
gm --role iran access-off --yes; eq "access-off exits 0" 0 "$RC"
gm --role iran access-on 999 --yes; eq "access-on rejects 999 minutes" 1 "$RC"

# ============================================================================ watch (health timer run)
gm --role iran watch; eq "watch: healthy -> 0" 0 "$RC"
touch "$SB/fake/dns_bad"
gm --role iran watch; eq "watch: DNS hijack lost -> exit 1" 1 "$RC"; has "...says why" "DNS check"
rm -f "$SB/fake/dns_bad"
gm --role iran watch; eq "watch: recovers" 0 "$RC"

# ============================================================================ rollback keeps the key, removes the rest
gm --role iran rollback --yes --dry-run; eq "rollback dry-run" 0 "$RC"; has "...describes the undo" "would undo"
# ============================================================================ uninstall
gm --role iran uninstall --yes
eq "uninstall exits 0" 0 "$RC"
absent "uninstall: config removed" "$R/usr/local/etc/xray-gemini/config.json"
absent "uninstall: unit removed" "$R/etc/systemd/system/xray-gemini.service"
absent "uninstall: Shecan URL removed" "$R/etc/gemini-shecan/shecan-url"
exists "uninstall: SS key file kept" "$R/root/gemini-shecan/ss.key"
exists "uninstall: the tool itself kept" "$R/usr/local/bin/gemini-menu"
eq "uninstall: firewall rule removed" 0 "$(grep -c . "$SB/fake/iptables.rules")"
gm --role iran status; eq "after uninstall status is broken (exit 2)" 2 "$RC"; has "...says how to fix it" "Setup / Reconfigure Relay"

# ============================================================================ Finding 8: honest partial failure
new_sandbox
touch "$SB/fake/reg_fail"
do_setup
if ((RC != 0)); then ok; else bad "setup with a failing registration must fail"; fi
has "result says FAILED" "[FAILED]"
has "result says PARTIAL (Finding 8)" "[PARTIAL]"
has "...lists the firewall step as kept" "Firewall: allow $PORT/tcp from $FOREIGN"
has "...lists the service step as kept" "systemd service xray-gemini"
has "...tells how to undo everything" "gemini-menu iran rollback"
hasnt "...no false 'nothing half-applied' claim" "nothing half-applied"
exists "kept: the relay config" "$R/usr/local/etc/xray-gemini/config.json"
absent "undone: the failing step's own file (Shecan URL)" "$R/etc/gemini-shecan/shecan-url"
absent "not reached: the timer" "$R/etc/systemd/system/gemini-shecan-watch.timer"
rm -f "$SB/fake/reg_fail"
gm --role iran rollback --yes
eq "rollback of the partial run exits 0" 0 "$RC"
absent "rollback removed the config" "$R/usr/local/etc/xray-gemini/config.json"
exists "rollback keeps the SS key file" "$R/root/gemini-shecan/ss.key"
eq "rollback removed the firewall rule" 0 "$(grep -c . "$SB/fake/iptables.rules")"
do_setup; eq "after a rollback the setup can run again" 0 "$RC"

# ============================================================================ open-proxy self-test
new_sandbox
touch "$SB/fake/open_proxy"
do_setup
if ((RC != 0)); then ok; else bad "an open relay must fail the setup"; fi
has "SECURITY message" "OPEN PROXY"
hasnt "nothing is left listed as kept" "[PARTIAL]"
absent "the whole run was undone (config)" "$R/usr/local/etc/xray-gemini/config.json"
eq "relay stopped" 0 "$(ls "$SB"/fake/svc/*.pid 2>/dev/null | wc -l)"

# ============================================================================ the global `gemini` command
new_sandbox
gm install
eq "install exits 0" 0 "$RC"
exists "the tool is installed as gemini-menu" "$R/usr/local/bin/gemini-menu"
eq "...executable" yes "$([[ -x $R/usr/local/bin/gemini-menu ]] && echo yes || echo no)"
eq "'gemini' is a symlink to it" "$R/usr/local/bin/gemini-menu" "$(readlink -f "$R/usr/local/bin/gemini")"
has "...and the result says how to use it" "just type:  gemini"
OUT=$(PATH=$FIX:$PATH GM_ROOT=$R GM_FAKE=$SB/fake "$R/usr/local/bin/gemini" --version 2>&1); has "running the link works from anywhere" "gemini-menu 0."
gm install; eq "install is idempotent" 0 "$RC"; has "...file up to date" "is up to date"; has "...link ready" "the command 'gemini' is ready"
gm install --dry-run; has "install --dry-run only describes" "would install this tool"
new_sandbox; mkdir -p "$R/usr/local/bin"; printf '#!/bin/sh\necho somebody-elses-gemini-cli\n' >"$R/usr/local/bin/gemini"; chmod +x "$R/usr/local/bin/gemini"
gm install
eq "a 'gemini' that is not ours: install still succeeds" 0 "$RC"
eq "...and is NEVER overwritten" "somebody-elses-gemini-cli" "$("$R/usr/local/bin/gemini")"
has "...with an explanation" "is not this tool"; exists "...gemini-menu still works" "$R/usr/local/bin/gemini-menu"
new_sandbox; mkdir -p "$SB/otherbin"; printf '#!/bin/sh\necho other\n' >"$SB/otherbin/gemini"; chmod +x "$SB/otherbin/gemini"
FORCE_LINK=0 EXTRA_PATH=$SB/otherbin gm install
has "another 'gemini' elsewhere on the PATH is not shadowed" "not shadowing it"
eq "...no link was created" no "$([[ -e $R/usr/local/bin/gemini ]] && echo yes || echo no)"
FORCE_LINK=1 EXTRA_PATH=$SB/otherbin gm install; eq "...GM_FORCE_LINK=1 overrides it" yes "$([[ -L $R/usr/local/bin/gemini ]] && echo yes || echo no)"
# the one-line install: the script arrives on stdin
new_sandbox
OUT=$(cat "$BUNDLE" | env PATH="$FIX:$PATH" GM_ROOT="$R" GM_FAKE="$SB/fake" GM_ASSUME_ROOT=1 GM_ASCII=1 GM_COLOR=0 NO_COLOR=1 GM_INPUT= GM_FORCE_LINK=1 TMPDIR="$TMPBASE" GM_INSTALL_URL="file://$BUNDLE" bash -s -- install 2>&1); RC=$?
eq "curl | bash -s -- install: exits 0" 0 "$RC"; has "...it fetched its own copy (a piped script has no file)" "piped into bash"
eq "...and installed gemini-menu + the gemini link" yes "$([[ -x $R/usr/local/bin/gemini-menu && -L $R/usr/local/bin/gemini ]] && echo yes || echo no)"
eq "...the installed copy is the real tool" "$(sha256sum <"$BUNDLE" | cut -d' ' -f1)" "$(sha256sum <"$R/usr/local/bin/gemini-menu" | cut -d' ' -f1)"
new_sandbox; printf 'not a script at all\n' >"$SB/junk"
OUT=$(cat "$BUNDLE" | env PATH="$FIX:$PATH" GM_ROOT="$R" GM_FAKE="$SB/fake" GM_ASSUME_ROOT=1 GM_ASCII=1 GM_COLOR=0 NO_COLOR=1 GM_INPUT= TMPDIR="$TMPBASE" GM_INSTALL_URL="file://$SB/junk" bash -s -- install 2>&1); RC=$?
if ((RC != 0)); then ok; else bad "a downloaded file that is not our script must be refused"; fi
has "...says so" "not a valid gemini-menu script"; eq "...and installs nothing" no "$([[ -e $R/usr/local/bin/gemini-menu ]] && echo yes || echo no)"
if ((EUID != 0)); then
  new_sandbox
  OUT=$(PATH="$FIX:$PATH" GM_ROOT="$R" GM_FAKE="$SB/fake" GM_ASCII=1 GM_COLOR=0 NO_COLOR=1 GM_INPUT= bash "$BUNDLE" install 2>&1 </dev/null); RC=$?
  eq "install as a normal user is refused" 1 "$RC"; has "...and says to use sudo" "run as root (for example with sudo)"
fi
new_sandbox; do_setup
eq "setup also installs the 'gemini' command" yes "$([[ -L $R/usr/local/bin/gemini ]] && echo yes || echo no)"
gm --role iran uninstall --yes
eq "uninstall keeps the tool and the 'gemini' command" yes "$([[ -x $R/usr/local/bin/gemini-menu && -L $R/usr/local/bin/gemini ]] && echo yes || echo no)"

# ============================================================================ the Shecan URL is asked for VISIBLY
new_sandbox
URL= gmi $'https://shecan.invalid/typed?token=VISIBLE\n' --role iran setup --foreign-ip "$FOREIGN" --ss-port "$PORT" --xray-bin "$FIX/xray" --yes
eq "setup asks for the Shecan URL when none is given, and accepts it typed" 0 "$RC"
has "...as a plain 'Label: ' prompt" "Shecan registration URL (paste it here): "
eq "...and stored it (mode 600)" "https://shecan.invalid/typed?token=VISIBLE|600" "$(tr -d '[:space:]' <"$R/etc/gemini-shecan/shecan-url")|$(stat -c %a "$R/etc/gemini-shecan/shecan-url")"
hasnt "...the URL is not echoed back by the tool" "token=VISIBLE"

# ============================================================================ validation without a terminal
new_sandbox
gm --role iran setup --xray-bin "$FIX/xray" --yes
eq "setup without --foreign-ip and no terminal fails cleanly (no hang, no die)" 1 "$RC"; has "...says what is missing" "foreign server's IP is required"
gm --role iran setup --foreign-ip 999.1.1.1 --xray-bin "$FIX/xray" --yes
eq "invalid IP is refused" 1 "$RC"; has "...with the reason" "not an IPv4 address"
gmi $'oops\n\n203.0.113.9\n' --role iran setup --ss-port "$PORT" --xray-bin "$FIX/xray" --dry-run
eq "interactive setup: typos re-ask, then proceeds" 0 "$RC"; has "...typo was reported" "not an IPv4 address"; has "...then the plan" "203.0.113.9"
gmi $'b\n' --role iran setup --ss-port "$PORT" --xray-bin "$FIX/xray"
eq "interactive setup: b cancels (exit 10)" 10 "$RC"; has "...CANCELLED" "[CANCELLED]"

# ============================================================================ Finding 11: role persistence
new_sandbox
gm status
eq "no role, no terminal -> clear error, exit 2" 2 "$RC"; has "...tells how to fix" "--role iran|foreign"
gm role iran; eq "role iran remembered" 0 "$RC"
eq "...in $R/etc/gemini-shecan/role" iran "$(tr -d '[:space:]' <"$R/etc/gemini-shecan/role")"
gm status; has "later runs need no --role" "not installed"
gm role; has "role show" "role: iran"
gm --role bogus status; eq "bad role value is refused" 2 "$RC"
new_sandbox
gmi $'zzz\n1\n' status
has "first run asks which server this is" "This server is the"
has "...a typo re-asks" "pick one of the listed options"
eq "...the answer is remembered" iran "$(tr -d '[:space:]' <"$R/etc/gemini-shecan/role")"
gm status
hasnt "...and the next run does NOT ask again (Finding 11)" "This server is the"
has "...it just runs" "Relay service"

printf '\n%d passed, %d failed (iran)\n' "$PASS" "$FAIL"
exit $((FAIL > 0))
