#!/usr/bin/env python3
"""Real-terminal tests of the FOREIGN menu against the sandbox rig (fake machine, real SQLite panel)."""
import os, shutil, socket, sqlite3, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ptyterm import Term, check, results, ROOT

BUNDLE = os.path.join(ROOT, "dist", "gemini-menu.sh")
FIX = os.path.join(ROOT, "tests", "fixtures", "bin")
base = tempfile.mkdtemp(prefix="pty-foreign.", dir=os.environ.get("TMPDIR"))
sb = os.path.join(base, "sb"); R = os.path.join(sb, "root")
for d in ("etc/x-ui", "usr/local/x-ui/bin"): os.makedirs(os.path.join(R, d))
os.makedirs(os.path.join(sb, "fake"))
DB = os.path.join(R, "etc/x-ui/x-ui.db"); XBIN = os.path.join(R, "usr/local/x-ui/bin/xray-linux-test")
shutil.copy(os.path.join(FIX, "xray"), XBIN)
subprocess.run([sys.executable, os.path.join(ROOT, "tests", "fixtures", "mkpanel.py"), DB], check=True)
s = socket.socket(); s.bind(("127.0.0.1", 0)); PORT = s.getsockname()[1]; s.close()
listener = subprocess.Popen([sys.executable, "-c", "import socket,sys\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',int(sys.argv[1])));s.listen(8)\nwhile True:\n    c,_=s.accept();c.close()", str(PORT)])
key = os.path.join(sb, "ss.key"); subprocess.run(f"openssl rand -base64 16 >{key}; chmod 600 {key}", shell=True, check=True)
time.sleep(0.4)
env = dict(os.environ, PATH=FIX + ":" + os.environ["PATH"], GM_ROOT=R, GM_FAKE=os.path.join(sb, "fake"), GM_ASSUME_ROOT="1",
           XUI_FAKE_DB=DB, XUI_FAKE_DIR=os.path.join(R, "usr/local/x-ui/bin"), GM_WAIT_XRAY="4", GM_XRAY_POLL="0.3", GM_FORCE_LINK="1",
           GM_STATUS_TTL="0", TERM="xterm", LANG="C.UTF-8")
for k in ("GM_INPUT", "GM_ASCII", "GM_COLOR", "NO_COLOR"): env.pop(k, None)


def tpl():
    return sqlite3.connect(DB).execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0]


def off_state():
    return "__gemini_off__" in tpl()


r = subprocess.run(["bash", BUNDLE, "--role", "foreign", "setup", "--iran-ip", "127.0.0.1", "--ss-port", str(PORT), "--key-file", key,
                    "--xray-bin", XBIN, "--yes", "--ascii", "--no-color"], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
check("sandbox setup for the menu tests", r.returncode == 0, r.stdout[-500:])

t = Term(["bash", BUNDLE], env)
check("foreign dashboard", t.expect(r"GEMINI · SHECAN") and t.expect(r"FOREIGN server \(3X-UI\)", 15))
check("...live rows", t.expect(r"\[PRESENT\]") and "REACHABLE" in t.all and "[ON]" in t.all)
t.expect(r"Select an option")
check("no role question (remembered)", "which server" not in t.all)

check("numbered main menu, Setup is 1", "1) Setup / Patch Panel Template" in t.all or t.expect(r"1\) Setup / Patch Panel Template"))
t.send("4\r"); check("Gemini Routing ON / OFF screen", t.expect(r"Foreign server › Gemini Routing ON / OFF")); t.expect(r"Select an option")
t.send("2\r")
check("switching OFF warns about the restart and asks a plain 'Proceed? [y/N]: '", t.expect(r"restart") and t.expect(r"Proceed\? \[y/N\]: "))
t.send("continue\r"); check("'continue' does not abort: it asks again", t.expect(r"please answer y or n \(Enter = no\)"))
t.send("\r"); check("Enter = No: CANCELLED", t.expect(r"\[CANCELLED\]"))
t.back()
check("...the panel template is unchanged", not off_state())
t.expect(r"Select an option")
t.send("2\r"); t.expect(r"Proceed\? \[y/N\]: "); t.send("y\r")
check("y: backup, compare-and-swap write, restart, verify", t.expect(r"Write the template \(compare-and-swap\)") and t.expect(r"\[ OK \]", 20))
check("...the template is OFF now", off_state())
t.back()
t.expect(r"Select an option")
t.send("1\r"); t.expect(r"Proceed\? \[y/N\]: "); t.send("YES\r"); check("switching back ON ('YES' is accepted)", t.expect(r"\[ OK \]", 20) and not off_state())
t.back()
t.expect(r"Select an option"); t.send("0\r"); t.expect(r"Select an option", 20)

# interactive scope picker: junk is rejected, b cancels, nothing applied
sha = tpl()
t.send("6\r"); check("Inbounds: Scope & Sniffing screen", t.expect(r"Inbounds: Scope & Sniffing")); t.expect(r"Select an option")
t.send("1\r")
check("picker lists the inbounds, all ticked", t.expect(r"\[x\] 1") and t.expect(r"\(no name\)"))
t.send("*\r"); check("'*' is rejected, never expanded", t.expect(r"is not valid here"))
t.send("1a\r"); check("'1a' is rejected with a message (no bash error)", t.expect(r"is not valid here") and "value too great" not in t.all)
t.send("2\r"); check("a number toggles", t.expect(r"\[ \] 2"))
t.send("b\r"); check("b cancels the whole action", t.expect(r"\[CANCELLED\]"))
t.back()
check("...no ghost ticks applied", tpl() == sha)
t.expect(r"Select an option"); t.send("0\r"); t.expect(r"Select an option")

t.send("zzz\r"); check("typos give one inline error", t.expect(r'"zzz" is not an option'))
t.send("\x03"); check("Ctrl-C at the prompt does not quit", t.expect(r"Ctrl-C does not quit"))
t.send("0\r"); check("0 exits 0", t.finish() == 0)
check("no stray errors on screen", all(x not in t.all for x in ("Traceback", "command not found", "unbound variable")), t.all[-300:])

# no panel found: items greyed out with the reason
sb2 = os.path.join(base, "sb2"); R2 = os.path.join(sb2, "root"); os.makedirs(os.path.join(R2, "etc/gemini-shecan")); os.makedirs(os.path.join(sb2, "fake"))
open(os.path.join(R2, "etc/gemini-shecan/role"), "w").write("foreign\n")
env2 = dict(env, GM_ROOT=R2, GM_FAKE=os.path.join(sb2, "fake"))
t = Term(["bash", BUNDLE], env2)
check("no panel: dashboard says so", t.expect(r"NO DB", 15))
t.expect(r"Select an option"); t.send("5\r")
check("...and items explain why they are unavailable", t.expect(r"not available right now: 3X-UI database not found"))
t.send("0\r"); t.finish()

listener.kill()
for f in os.listdir(os.path.join(sb, "fake")):
    if f == "xui.pid":
        try: os.kill(int(open(os.path.join(sb, "fake", f)).read()), 9)
        except Exception: pass
failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed (pty, foreign menu)")
shutil.rmtree(base, ignore_errors=True)
sys.exit(1 if failed else 0)
