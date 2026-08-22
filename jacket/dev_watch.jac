# dev_watch.jac — file watching for CSS hot reload and .jac dev restart.
# ---------------------------------------------------------------------------
import os;


glob WATCH_DEBOUNCE_MS: int = 400;


def is_ignored_watch_path(path: str) -> bool {
    if path == "" { return True; }
    if "__pycache__" in path { return True; }
    if ".jacir" in path { return True; }
    if path.endswith("~") { return True; }
    if path.endswith(".swp") { return True; }
    return False;
}


# ===========================================================================
# ::py:: seam — Gio.FileMonitor for theme.css and config-dir .jac files.
# ===========================================================================
::py::
import sys
from gi.repository import GLib, Gio

_WATCH = {"jac_sid": None}


def _run_jac_check(entry_jac):
    import subprocess
    try:
        p = subprocess.run(
            ["jac", "check", entry_jac],
            capture_output=True,
            text=True,
            timeout=30,
        )
        out = (p.stderr or "") + (p.stdout or "")
        return (p.returncode, out.strip())
    except Exception as e:
        return (-1, str(e))


def _schedule_jac_reload(entry_jac, on_reload, debounce_ms):
    sid = _WATCH.get("jac_sid")
    if sid is not None:
        GLib.source_remove(sid)

    def fire():
        _WATCH["jac_sid"] = None
        rc, out = _run_jac_check(entry_jac)
        if rc != 0:
            sys.stderr.write("jacket watch: check failed, keeping running bar:\n")
            if out:
                sys.stderr.write(out + "\n")
            return False
        on_reload()
        return False

    _WATCH["jac_sid"] = GLib.timeout_add(debounce_ms, fire)


def py_watch_config(config_dir, entry_jac, theme_css, on_css, on_reload, debounce_ms):
    # CSS file monitor — hot apply without restart.
    if os.path.isfile(theme_css):
        tf = Gio.File.new_for_path(theme_css)

        def on_css_changed(mon, f, other, event):
            if event in (
                Gio.FileMonitorEvent.CHANGES_DONE_HINT,
                Gio.FileMonitorEvent.CHANGED,
            ):
                GLib.idle_add(lambda: (on_css(), False)[1])

        css_mon = tf.monitor(Gio.FileMonitorFlags.NONE, None)
        css_mon.connect("changed", on_css_changed)

    # Config directory — .jac edits debounce into jac check + restart.
    df = Gio.File.new_for_path(config_dir)

    def on_dir_changed(mon, f, other, event):
        path = f.get_path() if f is not None else ""
        if not path.endswith(".jac"):
            return
        if "__pycache__" in path or ".jacir" in path:
            return
        if path.endswith("~") or path.endswith(".swp"):
            return
        if event not in (
            Gio.FileMonitorEvent.CHANGES_DONE_HINT,
            Gio.FileMonitorEvent.CHANGED,
        ):
            return
        _schedule_jac_reload(entry_jac, on_reload, debounce_ms)

    dir_mon = df.monitor_directory(Gio.FileMonitorFlags.NONE, None)
    dir_mon.connect("changed", on_dir_changed)
::py::


def watch_config(
    config_dir: str,
    entry_jac: str,
    theme_css: str,
    on_css: any,
    on_reload: any,
) -> None {
    py_watch_config(
        config_dir, entry_jac, theme_css, on_css, on_reload, WATCH_DEBOUNCE_MS
    );
}
