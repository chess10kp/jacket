# sway.jac — workspace source for sway/i3-family compositors (SWAYSOCK i3-ipc).
# ---------------------------------------------------------------------------
# The plan targets Hyprland, but many machines (this one runs the sway fork
# "scroll") speak the i3-ipc protocol over $SWAYSOCK instead. Same shape as
# hyprland.jac — a workspaces Signal + focus(id) — so the bar is WM-agnostic
# (see wm.jac). Event-driven: SUBSCRIBE to workspace events on a GLib IO watch,
# re-query authoritative state (GET_WORKSPACES) on each. No polling.
#
# i3-ipc framing: b"i3-ipc" + u32 payload-length + u32 type, little-endian,
# then a JSON payload. Event replies have the high bit set on the type.
#
# PURE PARSING (parse_sway_workspaces) is unit-tested headless.
import from src.reactive { signal, Signal }


::py::
import os
import socket
import struct
import json

_MAGIC = b"i3-ipc"
_GET_WORKSPACES = 1
_SUBSCRIBE = 2
_RUN_COMMAND = 0
_EVENT_BIT = 0x80000000

from gi.repository import GLib


def _connect():
    p = os.environ.get("SWAYSOCK") or os.environ.get("I3SOCK")
    if not p:
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(p)
        return s
    except Exception:
        return None


def _send(s, mtype, payload=""):
    data = payload.encode()
    s.sendall(_MAGIC + struct.pack("=II", len(data), mtype) + data)


def _recvn(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def _recv_frame(s):
    hdr = _recvn(s, 14)                       # 6 magic + 4 len + 4 type
    if hdr is None:
        return None
    length, mtype = struct.unpack("=II", hdr[6:14])
    body = _recvn(s, length) if length else b""
    if body is None:
        return None
    return (mtype, body.decode())


def get_workspaces_json():
    """One-shot GET_WORKSPACES -> JSON text, or None when there is no sway."""
    s = _connect()
    if s is None:
        return None
    try:
        _send(s, _GET_WORKSPACES)
        frame = _recv_frame(s)
        s.close()
        return frame[1] if frame is not None else None
    except Exception:
        return None


def run_command(cmd):
    s = _connect()
    if s is None:
        return
    try:
        _send(s, _RUN_COMMAND, cmd)
        _recv_frame(s)
        s.close()
    except Exception:
        pass


def watch_events(on_event):
    """SUBSCRIBE to workspace events; call on_event() per event (not the ack).
    Returns the live socket (source keeps it alive) or None."""
    s = _connect()
    if s is None:
        return None
    try:
        _send(s, _SUBSCRIBE, '["workspace"]')
        chan = GLib.IOChannel.unix_new(s.fileno())
        state = {"buf": b""}

        def cb(ch, cond):
            try:
                data = os.read(s.fileno(), 65536)
            except Exception:
                return True
            if not data:
                return True
            state["buf"] += data
            # drain every complete frame in the buffer
            while len(state["buf"]) >= 14:
                length, mtype = struct.unpack("=II", state["buf"][6:14])
                if len(state["buf"]) < 14 + length:
                    break
                state["buf"] = state["buf"][14 + length:]
                if mtype & _EVENT_BIT:            # an event, not the subscribe ack
                    on_event()
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
# Pure parse of GET_WORKSPACES JSON -> the shell's workspace shape (matches
# hyprland's). sway has no per-workspace window count; report 0.
# ---------------------------------------------------------------------------
def parse_sway_workspaces(data: any) -> list {
    out: list = [];
    arr: any = json_loads(data);
    if arr is None { return out; }
    for w in arr {
        out.append({
            # `key` is the stable unique identity for the For (sway's container
            # id); `id` is the focus/display number (num, not unique for named
            # workspaces, which report -1).
            "key": int(w.get("id", 0)),
            "id": int(w.get("num", 0)),
            "name": str(w.get("name", "")),
            "monitor": str(w.get("output", "")),
            "active": bool(w.get("focused", False)),
            "windows": 0,
        });
    }
    out.sort(key=lambda (x: dict) { x["id"]; });
    return out;
}


# ---------------------------------------------------------------------------
# The source (singleton). Same interface as Hyprland: workspaces + focus(id).
# ---------------------------------------------------------------------------
obj Sway {
    has workspaces: Signal = signal([]);
    has active_ws: Signal = signal(0);
    has _sock: any = None;

    def postinit() {
        self._refresh();
        self._sock = watch_events(self._refresh);
    }

    def _refresh() {
        j = get_workspaces_json();
        if j is None { return; }
        ws = parse_sway_workspaces(j);
        self.workspaces.set(ws);
        for w in ws {
            if w["active"] { self.active_ws.set(w["id"]); }
        }
    }

    def focus(ws_id: int) {
        run_command("workspace number " + str(ws_id));
    }
}

glob _sway: any = None;

def get_sway() -> Sway {
    if _sway is None { _sway = Sway(); }
    return _sway;
}
