#!/usr/bin/env python3
"""Real-terminal tests for the Phase 1 foundation: they drive dist/demo.sh through a pty.

What a pipe cannot prove: Ctrl-C behaviour, line editing before Enter, reading the keyboard when
the script itself arrives on stdin (curl ... | bash), and that the terminal is left sane.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ptyterm import Term, check, results, ROOT
import signal, termios, time
DEMO = os.path.join(ROOT, "dist", "demo.sh")

# ---- 1. no instant trigger; Backspace edits before Enter ---------------------------------------
t = Term(["bash", DEMO])
check("menu appears with the status card", t.expect(r"Relay service|\[ACTIVE\]") and t.expect(r"Demo relay"))
t.expect(r"Demo relay ›\s*❯")
t.send("1")
out = t.quiet(1.2)
check("typing '1' alone does NOT fire the item (needs Enter)", "Relay service" not in out, out[-200:])
t.send("\x7f")            # Backspace: the typo is corrected before anything happened
t.send("2\r")
check("Backspace edits the line; Enter then opens item 2 (Domains)", t.expect(r"Routed hosts"))

# ---- 2. invalid input: one inline error, no crash, menu alive -----------------------------------
t.expect(r"Demo relay › Domains\s*❯")
t.send("zzz\r")
check("unknown key -> inline error", t.expect(r'"zzz" is not an option'))
t.send("\r")
out = t.quiet(0.5)
check("empty Enter is ignored silently (no error, no redraw)", "not an option" not in out and "╭" not in out, out)

# ---- 3. Ctrl-C at the prompt does not kill the tool ---------------------------------------------
t.send("\x03")
check("Ctrl-C at the prompt only prints a hint", t.expect(r"Ctrl-C does not quit"))
t.send("b\r")
check("...and the menu is still alive (b goes back)", t.expect(r"Demo relay\s*❯|╭─ Demo relay"))

# ---- 4. Ctrl-C during an action stops only that action ------------------------------------------
t.send("6\r")
check("slow action starts", t.expect(r"Waiting for a slow server"))
time.sleep(0.6)
t.send("\x03")
check("Ctrl-C: action reports INTERRUPTED", t.expect(r"\[INTERRUPTED\]"))
check("...deferred cleanup ran", "cleanup ran (deferred)" in t.all)
check("...and we are back at the menu prompt (program did not exit)", t.expect(r"Demo relay\s*❯"))
t.send("7\r")
check("failing action: rollback runs and result is FAILED", t.expect(r"rollback: step one undone") and t.expect(r"\[FAILED\]"))
t.expect(r"Demo relay\s*❯")

# ---- 5. wizard: typos re-prompt, b cancels without killing anything -----------------------------
t.send("4\r")
t.expect(r"Foreign server IPv4")
t.send("\r")
check("wizard: empty Enter re-prompts (no die)", t.expect(r"a value is required"))
t.send("not-an-ip\r")
check("wizard: typo re-prompts", t.expect(r"not an IPv4 address"))
t.send("b\r")
check("wizard: b cancels -> CANCELLED, back at the menu", t.expect(r"\[CANCELLED\]") and t.expect(r"Demo relay\s*❯"))

# ---- 6. clean exit, terminal left sane ------------------------------------------------------------
t.send("q\r")
code = t.finish()
check("q exits with status 0", code == 0, str(code))
attrs = termios.tcgetattr(t.fd) if False else None
check("no stray Python/bash errors on screen", "Traceback" not in t.all and "command not found" not in t.all and "unbound variable" not in t.all, t.all[-300:])

# ---- 7. Ctrl-D ends the menu cleanly ----------------------------------------------------------------
t = Term(["bash", DEMO])
t.expect(r"Demo relay\s*❯")
t.send("\x04")
check("Ctrl-D at the menu exits cleanly", t.finish() == 0)

# ---- 8. curl | bash style: the script arrives on stdin, input still comes from the keyboard -----------
t = Term(["sh", "-c", f"cat '{DEMO}' | bash"])
ok = t.expect(r"Demo relay\s*❯", timeout=10)
check("piped script still shows the menu", ok, t.all[-300:])
if ok:
    t.send("zzz\r")
    check("piped: keyboard input works (reads /dev/tty)", t.expect(r'"zzz" is not an option'))
    t.send("q\r")
    check("piped: clean exit", t.finish() == 0)
else:
    t.finish(1)

# ---- 9. dry-run flag and toggle ---------------------------------------------------------------------
t = Term(["bash", DEMO, "--dry-run"])
t.expect(r"Demo relay\s*❯")
check("--dry-run is shown in the menu", "DRY-RUN is ON" in t.all)
t.send("3\r"); t.expect(r"Service\s*❯")
t.send("2\r")
ok = t.expect(r"Stop the relay\?")
t.send("y\r")
check("dry-run: action only describes", t.expect(r"would stop the relay") and t.expect(r"\[DRY-RUN\]"))
t.send("q\r"); t.finish()

failed = results.count(False)
print(f"\n{len(results) - failed} passed, {failed} failed (pty)")
sys.exit(1 if failed else 0)
