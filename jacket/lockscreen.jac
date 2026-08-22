# lockscreen.jac — session lock daemon (library module).
# ---------------------------------------------------------------------------
# A lockscreen has three parts and only one of them is interesting:
#
#   1. STATE MACHINE (pure, unit-tested): locked -> checking -> unlocked|failed,
#      plus clear_error and re-lock. Mirrors the notifications.jac split — the
#      reducer is pure, the daemon is a thin shell around it.
#   2. AUTH (::py::, subprocess-isolated): PAM verification runs in a throwaway
#      python interpreter — the password never lives in the shell process past
#      the pipe write, and a missing python-pam fails CLOSED. The worker thread
#      keeps the UI responsive; results marshal back on GLib.idle.
#   3. UI (examples/reference/lock_ui.jac): fullscreen overlay window bound to
#      the daemon's state Signal.
#
# State semantics: "unlocked" is the resting state (session open, layer
# hidden). lock() flips to "locked" (prompt shows); submit() moves to
# "checking"; resolution lands on "unlocked" (exit tween) or "failed" (error
# hint; typing clears back to "locked").
import from jacket.reactive { signal, Signal }


# ---------------------------------------------------------------------------
# Pure state machine over {"locked", "checking", "failed", "unlocked"}
# ---------------------------------------------------------------------------
def check_lock(st: str) -> str {
    # prompt accepted for verification (locked/failed both allow retry)
    if st == "locked" or st == "failed" { return "checking"; }
    return st;
}

def resolve_lock(st: str, ok: bool) -> str {
    # a verdict only lands on a pending check (stale results dropped)
    if st == "checking" { return "unlocked" if ok else "failed"; }
    return st;
}

def clear_error(st: str) -> str {
    # typing again after a failure: back to a clean prompt
    if st == "failed" { return "locked"; }
    return st;
}

def is_session_open(st: str) -> bool {
    return st == "unlocked";
}


::py::
import getpass
import subprocess
import sys
import threading

# NOTE: no top-level GLib import here — this block runs at module import and
# lockscreen must import clean in headless/no-gi contexts (pure reducer use).
# The idle marshal-back imports it lazily instead.


def py_current_user() -> str:
    return getpass.getuser()


# Runs in a THROWAWAY interpreter: `import pam` failing there exits 3, which we
# treat like any auth failure (fail-closed) rather than crashing the shell.
_PAM_PROG = (
    "import sys\n"
    "try:\n"
    "    import pam\n"
    "except ImportError:\n"
    "    sys.exit(3)\n"
    "u, p = sys.argv[1], sys.stdin.read()\n"
    "c = pam.pam()\n"
    "try:\n"
    "    sys.exit(0 if c.authenticate(u, p, service=sys.argv[2]) else 1)\n"
    "except Exception:\n"
    "    sys.exit(2)\n"
)


def py_pam_verify(username: str, password: str, service: str) -> bool:
    """PAM check in a subprocess. The password crosses via stdin (never argv,
    never this process's heap after the write). Any failure — missing python-pam,
    PAM error, timeout — is a rejection."""
    try:
        r = subprocess.run(
            [sys.executable, "-c", _PAM_PROG, username, service],
            input=password.encode(), capture_output=True, timeout=15)
        return r.returncode == 0
    except Exception:
        return False


def py_verify_async(verify_fn, password, on_done):
    """Run verify_fn off the UI thread; marshal the bool back on GLib idle."""
    from gi.repository import GLib
    def work():
        try:
            ok = bool(verify_fn(password))
        except Exception:
            ok = False
        GLib.idle_add(lambda: (on_done(ok), False)[1])
    threading.Thread(target=work, daemon=True).start()
::py::


# ---------------------------------------------------------------------------
# Daemon (singleton). Holds the state Signal; verification is pluggable so
# headless tests inject a fake and never touch PAM.
# ---------------------------------------------------------------------------
obj LockDaemon {
    has state: Signal = signal("unlocked");     # session open at rest
    has user: str = "";
    has pam_service: str = "login";
    has verify: any = None;                     # None -> PAM subprocess

    def postinit() {
        if self.user == "" { self.user = str(py_current_user()); }
    }

    def session_open() -> bool { return is_session_open(self.state.peek()); }

    # Show the lock layer.
    def lock() { self.state.set("locked"); }

    # A keystroke landed in the entry: drop any stale failure hint.
    # (Named reset_prompt: a method name equal to the module fn it wraps
    # shadows the global inside the obj scope.)
    def reset_prompt() { self.state.set(clear_error(self.state.peek())); }

    # Entry activated: start an async check. Re-entrant submits and empty
    # passwords are ignored.
    def submit(password: str) {
        nxt = check_lock(self.state.peek());
        if nxt == self.state.peek() { return; }
        if password == "" { self.state.set("locked"); return; }
        self.state.set(nxt);
        py_verify_async(self._verify_fn(), password, self._finish);
    }

    def _verify_fn() -> any {
        if self.verify is not None { return self.verify; }
        return lambda (pw: str) { return py_pam_verify(self.user, pw, self.pam_service); };
    }

    # Called on the GLib idle once the worker resolves.
    def _finish(ok: bool) {
        self.state.set(resolve_lock(self.state.peek(), ok));
    }
}

glob _lock: any = None;

def get_lockscreen() -> LockDaemon {
    if _lock is None { _lock = LockDaemon(); }
    return _lock;
}
