"""Shared pty driver for the terminal tests."""
import fcntl, os, pty, re, select, signal, struct, sys, termios, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\r")
results = []


class Term:
    def __init__(self, argv, env_extra=None, rows=40):
        env = dict(os.environ, TERM="xterm", LANG="C.UTF-8", DEMO_DNS_DELAY="0.3")
        env.pop("NO_COLOR", None); env.pop("GM_INPUT", None); env.pop("GM_ASCII", None); env.pop("GM_COLOR", None)
        env.update(env_extra or {})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, 100, 0, 0))
        self.buf = ""
        self.all = ""
        self.raw = ""

    def pump(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                dec = data.decode("utf-8", "replace")
                self.raw += dec
                text = ANSI.sub("", dec)
                self.buf += text
                self.all += text
        return True

    def expect(self, pattern, timeout=8):
        end = time.time() + timeout
        rx = re.compile(pattern)
        while time.time() < end:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return True
            if not self.pump(0.2) and not rx.search(self.buf):
                break
        return bool(rx.search(self.buf))

    CLEAR = "\x1b[H\x1b[2J"

    def clears(self):
        """How many times the screen has been cleared so far."""
        return self.raw.count(self.CLEAR)

    def back(self, timeout=10):
        """An action ended: its output stays until Enter. Wait for the prompt, then press Enter."""
        ok = self.expect(r"Press Enter to return to the menu", timeout)
        self.send("\r")
        return ok

    def send(self, s):
        os.write(self.fd, s.encode())

    def quiet(self, secs):
        """Consume output for a while, return it (used to assert that NOTHING happened)."""
        self.buf = ""
        self.pump(secs)
        out, self.buf = self.buf, ""
        return out

    def finish(self, timeout=6):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.1)
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return None


def check(name, cond, detail=""):
    results.append(cond)
    print(("ok    " if cond else "FAIL  ") + name + ("" if cond else "\n      " + detail))


