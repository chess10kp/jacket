# glib.jac — GLib main-loop helpers, shared by sources and main.
# A thin ::py:: shim: these are module-level callables importable by any module.
# (Gtk/GLib bootstrap; GLib needs no require_version.)
::py::
from gi.repository import GLib

def idle_add(fn):
    return GLib.idle_add(fn)

def timeout_add(ms, fn):
    return GLib.timeout_add(ms, fn)

def source_remove(sid):
    return GLib.source_remove(sid)

def run_for(ms):
    """Run the GLib main loop for `ms` ms, then quit. Lets headless probes pump
    timeouts/idle callbacks (and reactive flushes) without a Gtk.Application."""
    loop = GLib.MainLoop()
    GLib.timeout_add(ms, lambda: (loop.quit(), False)[1])
    loop.run()

def run_cmd(args):
    """Run a command (list) and return (returncode, stdout). Walled here so
    sources never touch subprocess themselves. (Named run_cmd, not spawn —
    `spawn` is a reserved Jac walker keyword.)"""
    return _spawn(args)

def spawn_detached(args):
    """Start args and return immediately. The child gets its own session and
    stdio to /dev/null: unlike run_cmd, nothing ever waits on it (not even for
    pipe EOF — a detached `sh -c 'app &'` under run_cmd blocks until app exits
    because app inherits the capture pipe)."""
    import subprocess
    try:
        subprocess.Popen(args, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        return 0
    except Exception as e:
        return -1

def _spawn(args):
    import subprocess
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=5)
        return (p.returncode, p.stdout)
    except Exception as e:
        return (-1, str(e))
::py::
