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
               SHECAN_REGISTER_URL="https://shecan.invalid/register?token=SECRET123")
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
t.expect(r"Iran relay\s*❯")
check("first screen did not ask for a role (it is remembered)", "which server" not in t.all)
check("secrets are not on screen", "SECRET123" not in t.all)

t.send("5")
out = t.quiet(1.0)
check("typing '5' alone does not fire anything", "Foreign server IPv4" not in out, out[-200:])
t.send("\r")
check("Enter opens 'Allowed foreign IP'", t.expect(r"Foreign server IPv4 to allow"))
t.send("not-an-ip\r")
check("typo -> inline error, prompt stays", t.expect(r"not an IPv4 address") and t.expect(r"Foreign server IPv4 to allow"))
t.send("\r")
check("Enter takes the current IP: re-check, not 'already set'", t.expect(r"re-checking its firewall rule") and t.expect(r"\[ OK \]"))
t.expect(r"Iran relay\s*❯")

# break the firewall behind its back, refresh, repair from the menu
open(os.path.join(sb, "fake", "iptables.rules"), "w").close()
t.send("r\r")
check("refresh notices the missing rule", t.expect(r"\[PROBLEM\]") and t.expect(r"NO RULE"))
t.expect(r"Iran relay\s*❯")
t.send("2\r")
check("Repair screen opens", t.expect(r"Iran relay › Repair"))
t.expect(r"Repair\s*❯")
t.send("2\r")
check("Repair > Firewall re-adds the rule", t.expect(r"rule was missing - added") and t.expect(r"\[ OK \]"))
t.expect(r"Repair\s*❯")
t.send("b\r")
check("b returns to the dashboard, now healthy", t.expect(r"\[HEALTHY\]", 15))
t.expect(r"Iran relay\s*❯")

# Ctrl-C at the prompt, then a cancelled destructive action
t.send("\x03")
check("Ctrl-C at the prompt does not quit", t.expect(r"Ctrl-C does not quit"))
t.send("u\r")
check("Uninstall asks for a typed confirmation", t.expect(r"Type yes to continue"))
t.send("maybe\r")
check("a wrong word is not a confirmation", t.expect(r"not confirmed"))
t.send("b\r")
check("b cancels: CANCELLED, nothing removed", t.expect(r"\[CANCELLED\]"))
check("...the relay config is still there",
      os.path.exists(os.path.join(sb, "root", "usr/local/etc/xray-gemini/config.json")))
t.expect(r"Iran relay\s*❯")
t.send("q\r")
check("q exits with 0", t.finish() == 0)
kill_services(sb)

# ============ not installed: items are greyed out with a reason ====================================
sb, env = sandbox("empty")
os.makedirs(os.path.join(sb, "root/etc/gemini-shecan"))
open(os.path.join(sb, "root/etc/gemini-shecan/role"), "w").write("iran\n")
t = menu(env)
check("empty server: dashboard says the relay is missing", t.expect(r"\[PROBLEM\]", 15) and t.expect(r"MISSING"))
t.expect(r"Iran relay\s*❯")
t.send("6\r")
check("a disabled item explains why", t.expect(r"not available right now: the relay is not installed"))
t.send("s")
t.send("\x7f")
t.send("q\r")
check("Backspace edits before Enter (s deleted, q quits)", t.finish() == 0)

# ============ first run: asked ONCE, remembered ===================================================
sb, env = sandbox("first")
t = menu(env)
check("first run asks which server this is", t.expect(r"This server is the"))
t.send("zzz\r")
check("...a typo re-asks", t.expect(r"pick one of the listed options"))
t.send("1\r")
check("...then the menu opens", t.expect(r"Iran relay\s*❯", 15))
t.send("q\r"); t.finish()
role = open(os.path.join(sb, "root/etc/gemini-shecan/role")).read().strip()
check("the answer is remembered on disk", role == "iran", role)
t = menu(env)
check("second start goes straight to the menu", t.expect(r"Iran relay\s*❯", 15) and "which server" not in t.all)
t.send("q\r"); t.finish()

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed (pty, iran menu)")
shutil.rmtree(base, ignore_errors=True)
sys.exit(1 if failed else 0)
