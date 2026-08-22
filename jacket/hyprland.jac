# hyprland.jac — Hyprland IPC source (PLAN Phase 4, Pattern C: GLib IO watch).
# ---------------------------------------------------------------------------
# Watches Hyprland's event socket (.socket2) on the GLib loop (no threads, no
# marshalling — PLAN's C1 design) and re-queries authoritative state on every
# workspace-ish event. Exposes two Signals:
#     workspaces : Signal[list]  — [{id, name, monitor, active, windows}, ...]
#     active_ws  : Signal[int]
# Plus focus(id) for the bar's workspace buttons.
#
# DEGRADATION: with no Hyprland instance (this box runs sway), the source
# creates its signals, finds no socket, and sits quiet — the For renders an
# empty list and the shell keeps working. No exceptions, no spam.
#
# PARSERS ARE PURE: parse_workspaces/parse_active take hyprctl JSON text and
# return plain lists/ints, so the headless tests exercise the real logic.
import from jacket.reactive { signal, Signal }


# ===========================================================================
# ::py:: shim — sockets + JSON walled here, like adapter walls GTK.
# ===========================================================================
::py::
import os
import socket
import json
from gi.repository import GLib


def _runtime_dir():
    uid = os.getuid()
    return os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%d" % uid)


def instance_dir():
    """The Hyprland socket dir ($XDG_RUNTIME_DIR/hypr/$SIG), or None."""
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if sig:
        d = os.path.join(_runtime_dir(), "hypr", sig)
        if os.path.isdir(d):
            return d
    base = os.path.join(_runtime_dir(), "hypr")
    if os.path.isdir(base):
        try:
            for name in os.listdir(base):
                d = os.path.join(base, name)
                if os.path.isdir(d) and os.path.exists(os.path.join(d, ".socket")):
                    return d
        except Exception:
            pass
    return None


def request(cmd, timeout=1.0):
    """One-shot request socket: `j/workspaces` -> reply text, or None."""
    d = instance_dir()
    if d is None:
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(os.path.join(d, ".socket"))
        s.sendall((cmd + "\n").encode())
        s.settimeout(timeout)
        buf = b""
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            pass
        s.close()
        return buf.decode()
    except Exception:
        return None


def watch_events(on_line):
    """Watch .socket2 via a GLib IO watch (ON the main loop — no marshalling).
    `on_line(line)` is a Jac callable. Returns the socket (kept alive by the
    source) or None when there is no Hyprland."""
    d = instance_dir()
    if d is None:
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(os.path.join(d, ".socket2"))
        chan = GLib.IOChannel.unix_new(s.fileno())

        def cb(ch, cond):
            status, line, length = ch.read_line()
            if status == GLib.IOStatus.NORMAL and line:
                on_line(line.decode().strip())
            return True

        GLib.io_add_watch(chan, GLib.PRIORITY_DEFAULT, GLib.IOCondition.IN, cb)
        return s
    except Exception:
        return None


def json_loads(text):
    try:
        return json.loads(text)
    except Exception:
        return None
::py::


# ---------------------------------------------------------------------------
# Pure parsing (the only part worth unit-testing).
# ---------------------------------------------------------------------------
def parse_workspaces(data: any) -> list {
    # `hyprctl j/workspaces` -> JSON array. Keep only what the shell renders.
    out: list = [];
    arr: any = json_loads(data);
    if arr is None { return out; }
    for w in arr {
        out.append({
            "key": int(w.get("id", 0)),        # unique identity for the For (== id here)
            "id": int(w.get("id", 0)),
            "name": str(w.get("name", "")),
            "monitor": str(w.get("monitor", "")),
            "active": bool(w.get("focused", False)),
            "windows": int(w.get("windows", 0)),
        });
    }
    # hyprctl returns them id-sorted already; sort defensively so the keyed
    # diff never churns on order noise.
    out.sort(key=lambda (w: dict) { w["id"]; });
    return out;
}

def parse_active(data: any) -> int {
    # `hyprctl j/activeworkspace` -> {"id": N, ...}. `focused` is per-workspace
    # (parse_workspaces); this request is authoritative for the active one.
    res: any = json_loads(data);
    if res is None { return 0; }
    return int(res.get("id", 0));
}


# ---------------------------------------------------------------------------
# The source. A singleton — get_hyprland() creates it once.
# ---------------------------------------------------------------------------
obj Hyprland {
    has workspaces: Signal = signal([]);
    has active_ws: Signal = signal(0);
    has connected: bool = False;
    has _sock: any = None;          # keeps the event socket fd alive

    def postinit() {
        self._refresh();
        self._sock = watch_events(lambda (line: str) { self._on_event(line); });
        self.connected = self._sock is not None;
    }

    # Event stream lines: "workspace>>2", "createworkspace>>3", "focusedmon>>…"
    # We don't trust event payloads — re-query the authoritative state. Local
    # socket round-trips are microseconds.
    def _on_event(line: str) {
        evt = line.split(">>", 1)[0];
        if evt in ("workspace", "createworkspace", "destroyworkspace", "moveworkspace",
                   "renameworkspace", "focusedmon", "openwindow", "closewindow") {
            self._refresh();
        }
    }

    def _refresh() {
        ws = request("j/workspaces");
        if ws is None { return; }
        # NEW list every set (PLAN open-item #2): the For diff needs `!=` to
        # see the change. Never mutate the cached list in place.
        self.workspaces.set(parse_workspaces(ws));
        act = request("j/activeworkspace");
        if act is not None { self.active_ws.set(parse_active(act)); }
    }

    def focus(ws_id: int) {
        request("dispatch workspace " + str(ws_id));
    }
}

glob _hypr: any = None;

def get_hyprland() -> Hyprland {
    if _hypr is None { _hypr = Hyprland(); }
    return _hypr;
}
