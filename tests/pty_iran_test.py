#!/usr/bin/env python3
"""Real-terminal tests of the Iran menu (dist/gemini-menu.sh) against the sandbox rig.

The machine is fake (GM_ROOT sandbox + stub commands from tests/fixtures/bin), the terminal is real:
colours, readline editing, Enter-confirmed input, the dashboard, repair flows, role persistence.
"""
import os, shutil, socket, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ptyterm import Term, check, results, ROOT

BUNDLE = os.path.join(ROOT, "dist", "gemini-menu.sh")
FIX = os.path.join(ROOT, "tests", "fixtures", "bin")
base = tempfile.mkdtemp(prefix="pty-iran.", dir=os.environ.get("TMPDIR"))


def port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def sandbox(name):
    sb = os.path.join(base, name)
    os.makedirs(os.path.join(sb, "root")); os.makedirs(os.path.join(sb, "fake"))
    env = dict(os.environ, PATH=FIX + ":" + os.environ["PATH"], GM_ROOT=os.path.join(sb, "root"),
               GM_FAKE=os.path.join(sb, "fake"), GM_ASSUME_ROOT="1", GM_DNS_RETRY_SLEEP="0",
               GM_POLL_SLEEP="0.2", GM_WATCH_SLEEP="0", GM_STATUS_TTL="0", TERM="xterm", LANG="C.UTF-8",
               SHECAN_REGISTER_URL="https://shecan.invalid/register?token=SECRET123", GM_FORCE_LINK="1")
    for k in ("GM_INPUT", "GM_ASCII", "GM_COLOR", "NO_COLOR"):
        env.pop(k, None)
    return sb, env


def menu(env):
    return Term(["bash", BUNDLE], env)


def kill_services(sb):
    d = os.path.join(sb, "fake", "svc")
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.endswith(".pid"):
                try: os.kill(int(open(os.path.join(d, f)).read()), 9)
                except Exception: pass


# ============ installed relay: dashboard + repair flows ==========================================
sb, env = sandbox("installed")
p = port()
r = subprocess.run(["bash", BUNDLE, "--role", "iran", "setup", "--foreign-ip", "203.0.113.9", "--ss-port", str(p),
                    "--xray-bin", os.path.join(FIX, "xray"), "--yes", "--ascii", "--no-color"],
                   env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
check("sandbox setup for the menu tests", r.returncode == 0, r.stdout[-400:] + r.stderr[-200:])

t = menu(env)
check("dashboard shows the status card", t.expect(r"GEMINI · SHECAN") and t.expect(r"\[HEALTHY\]", 15))
check("...with live probe rows", "Relay" in t.all and "[ACTIVE]" in t.all and "[GUARDED]" in t.all)
t.expect(r"Select an option")
check("first screen did not ask for a role (it is remembered)", "which server" not in t.all)
check("secrets are not on screen", "SECRET123" not in t.all)

check("numbered list with Setup as item 1", "1) Setup / Reconfigure Relay" in t.all or t.expect(r"1\) Setup / Reconfigure Relay"))
check("exactly the requested footer", "r) Refresh" in t.all and "0) Exit" in t.all)
check("no [x]-bracket keys, no letter shortcuts", "[s]" not in t.all and "[q]" not in t.all and "Dry-run" not in t.all)
t.send("4")
out = t.quiet(1.0)
check("typing '4' alone does not fire anything", "Foreign server IPv4" not in out, out[-200:])
t.send("\r")
check("Enter opens 'Change Allowed Foreign IP'", t.expect(r"Foreign server IPv4 to allow"))
t.send("not-an-ip\r")
check("typo -> inline error, prompt stays", t.expect(r"not an IPv4 address") and t.expect(r"Foreign server IPv4 to allow"))
t.send("\r")
check("Enter takes the current IP: re-check, not 'already set'", t.expect(r"re-checking its firewall rule") and t.expect(r"\[ OK \]"))
check("the result stays on screen until Enter", t.back())
check("...then the dashboard is back with a 'Last action' line", t.expect(r"Last action: \[OK\] Change Allowed Foreign IP"))
t.expect(r"Select an option")

# break the firewall behind its back, refresh, repair from the menu
open(os.path.join(sb, "fake", "iptables.rules"), "w").close()
t.send("r\r")
check("refresh notices the missing rule", t.expect(r"\[PROBLEM\]") and t.expect(r"NO RULE"))
t.expect(r"Select an option")
t.send("2\r")
check("Health Check & Status screen opens", t.expect(r"Iran relay › Health Check & Status"))
t.expect(r"Select an option")
t.send("3\r")
check("...'Repair the firewall rule' re-adds it", t.expect(r"rule was missing - added") and t.expect(r"\[ OK \]"))
t.back()
t.expect(r"Select an option")
t.send("0\r")
check("0 returns to the dashboard, now healthy", t.expect(r"\[HEALTHY\]", 15))
t.expect(r"Select an option")

# Ctrl-C at the prompt, then a cancelled destructive action
t.send("\x03")
check("Ctrl-C at the prompt does not quit", t.expect(r"Ctrl-C does not quit"))
t.send("9\r")
check("Uninstall (a purge) asks for a typed word, and says Enter cancels", t.expect(r"Type yes to confirm, or press Enter to cancel"))
t.send("continue\r")
check("'continue' does not abort: it explains what to type", t.expect(r"type 'yes' to go ahead"))
t.send("\r")
check("Enter cancels: CANCELLED, nothing removed", t.expect(r"\[CANCELLED\]"))
t.back()
check("...the relay config is still there",
      os.path.exists(os.path.join(sb, "root", "usr/local/etc/xray-gemini/config.json")))
t.expect(r"Select an option")
t.send("0\r")
check("0 exits with 0", t.finish() == 0)

# the Shecan URL is typed VISIBLY and can be edited with Backspace
os.remove(os.path.join(sb, "root/etc/gemini-shecan/shecan-url"))
env_nourl = {k: v for k, v in env.items() if k != "SHECAN_REGISTER_URL"}
t = Term(["bash", BUNDLE, "--role", "iran", "register"], env_nourl)
check("register asks for the URL as 'Label: '", t.expect(r"Shecan registration URL \(paste it here\): "))
t.send("https://shecan.invalid/typo")
t.pump(0.4)
check("the URL is ECHOED while typing (not hidden)", "https://shecan.invalid/typo" in t.buf + t.all)
t.send("\x7f" * 4 + "ok")
t.pump(0.4)
t.send("\r")
check("...and Backspace edits it; the corrected URL is accepted", t.expect(r"Register this server's IP with Shecan now\? \[y/N\]: ", 10))
t.send("continue\r")
check("'continue' at a [y/N] prompt asks again instead of aborting", t.expect(r"please answer y or n \(Enter = no\)"))
t.send("\r")
check("Enter = No: cancelled, nothing registered", t.expect(r"\[CANCELLED\]"))
t.finish()
kill_services(sb)

# ============ a short terminal gets a COMPACT dashboard ===========================================
t = Term(["bash", BUNDLE], env, rows=24)
check("24-line terminal: passing checks collapse into one row", t.expect(r"Checks\s+\[OK\] \d+ of \d+ fine", 15))
check("...instead of one row per probe", "[GUARDED]" not in t.all and "[LISTENING]" not in t.all)
t.expect(r"Select an option"); t.send("0\r"); t.finish()
t = Term(["bash", BUNDLE], env, rows=40)
check("40-line terminal: the full card (a row per probe)", t.expect(r"\[GUARDED\]", 15))
t.expect(r"Select an option"); t.send("0\r"); t.finish()

# ============ not installed: items are greyed out with a reason ====================================
sb, env = sandbox("empty")
os.makedirs(os.path.join(sb, "root/etc/gemini-shecan"))
open(os.path.join(sb, "root/etc/gemini-shecan/role"), "w").write("iran\n")
t = menu(env)
check("first run as root installs the tool and the 'gemini' command by itself", t.expect(r"Select an option", 20)
      and os.path.islink(os.path.join(sb, "root/usr/local/bin/gemini"))
      and os.access(os.path.join(sb, "root/usr/local/bin/gemini-menu"), os.X_OK))
check("...the dashboard says so ('Last action' line)", "just type  gemini" in t.all)
t.send("0\r"); t.finish()
t = Term(["bash", BUNDLE], env)
check("empty server: dashboard says the relay is missing", t.expect(r"\[PROBLEM\]", 15) and t.expect(r"MISSING"))
check("...and Setup is item 1, enabled", "1) Setup / Reconfigure Relay" in t.all or t.expect(r"1\) Setup / Reconfigure Relay"))
t.expect(r"Select an option")
t.send("6\r")
check("a disabled item explains why", t.expect(r"not available right now: needs the relay: choose 1 first"))
t.send("1")
t.send("\x7f")
t.send("0\r")
check("Backspace edits before Enter ('1' deleted, then 0 exits)", t.finish() == 0)

# ============ first run: asked ONCE, remembered ===================================================
sb, env = sandbox("first")
t = menu(env)
check("first run asks which server this is", t.expect(r"This server is the"))
t.send("zzz\r")
check("...a typo re-asks", t.expect(r"pick one of the listed options"))
t.send("1\r")
check("...then the menu opens", t.expect(r"Select an option", 15))
t.send("0\r"); t.finish()
role = open(os.path.join(sb, "root/etc/gemini-shecan/role")).read().strip()
check("the answer is remembered on disk", role == "iran", role)
t = menu(env)
check("second start goes straight to the menu", t.expect(r"Select an option", 15) and "which server" not in t.all)
t.send("0\r"); t.finish()

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed (pty, iran menu)")
shutil.rmtree(base, ignore_errors=True)
sys.exit(1 if failed else 0)
