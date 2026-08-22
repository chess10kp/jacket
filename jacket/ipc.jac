# ipc.jac — graph command dispatcher + legacy getter registry (I4).
# ---------------------------------------------------------------------------
# Transport lives in adapter.jac. Graph-native commands route through
# desktop.handle_graph_command; legacy string getters remain for swaybar compat.
import from jacket.desktop { handle_graph_command, get_desktop }
import from jacket.launcher { get_launcher }
import from jacket.reactive { flush }
import json;


def _safe(getfn: any) -> str {
    try { v = getfn(); } except Exception { return ""; }
    if v is None { return ""; }
    return str(v);
}

def _join_keys(d: dict) -> str {
    out = "";
    for (k, v) in d.items() {
        out = ((out + " ") if out != "" else "") + str(k);
    }
    return out;
}

def _format_json(data: dict) -> str {
    return json.dumps(data, sort_keys=True);
}


obj IPC {
    has _components: dict = {};
    has _bar: any = None;
    has _app: any = None;
    has _use_graph: bool = True;   # graph commands are the default core IPC (PLAN §6)

    def register(name: str, getfn: any) { self._components[name] = getfn; }
    def set_bar(b: any) { self._bar = b; }
    def set_app(a: any) { self._app = a; }
    def enable_graph(on: bool) { self._use_graph = on; }

    def status_line() -> str {
        if self._use_graph and get_desktop() is not None {
            r = handle_graph_command(["status"]);
            if r.get("ok") {
                return _format_json(r["data"]);
            }
        }
        out = "";
        for (name, getfn) in self._components.items() {
            v = _safe(getfn);
            seg = (str(name) + "=" + v) if v != "" else (str(name) + "=");
            out = ((out + "  ") if out != "" else "") + seg;
        }
        return out;
    }

    def handle(argv: list) -> str {
        if len(argv) == 0 { return self.status_line(); }
        want_json = ("--json" in argv);
        clean: list = [];
        for a in argv {
            if str(a) != "--json" { clean.append(a); }
        }
        if self._use_graph and get_desktop() is not None and len(clean) > 0 {
            cmd = str(clean[0]);
            if cmd in ["status", "mode", "why", "affected-by", "quit", "reload"] {
                r = handle_graph_command(clean);
                if want_json or cmd in ["status", "why", "affected-by"] {
                    return _format_json(r);
                }
                if r.get("quit") {
                    if self._app is not None { self._app.quit(); }
                    return "ok";
                }
                if r.get("ok") { return "ok"; }
                return str(r.get("error", "error"));
            }
        }
        cmd = str(clean[0]) if len(clean) > 0 else "";
        if cmd == "status" { return self.status_line(); }
        if cmd == "list" { return _join_keys(self._components); }
        if cmd == "toggle" {
            if self._bar is not None {
                w = self._bar.widget;
                w.set_visible(not bool(w.get_visible()));
            }
            return "ok";
        }
        if cmd == "launcher" {
            l = get_launcher();
            sub = "toggle";
            if len(clean) > 1 { sub = str(clean[1]); }
            if sub == "toggle" { l.toggle(); }
            elif sub == "show" { l.show(); }
            elif sub == "hide" { l.hide(); }
            else { return "unknown launcher action: " + sub; }
            flush();
            return "ok";
        }
        if cmd == "quit" {
            stop_ipc_socket();
            if self._app is not None { self._app.quit(); }
            return "ok";
        }
        if cmd in self._components {
            return _safe(self._components[cmd]);
        }
        return "unknown command: " + cmd;
    }
}

glob _ipc: any = None;

def ipc() -> IPC {
    if _ipc is None { _ipc = IPC(); }
    return _ipc;
}


# ---------------------------------------------------------------------------
# Fast local IPC: $XDG_RUNTIME_DIR/jacket.sock (scroll keybinds, scripts).
# Avoids spawning jac (~8s); replies in milliseconds on the GLib main thread.
# ---------------------------------------------------------------------------
::py::
import os
import socket

_sock_path = None
_listen_sock = None
_watch_id = None


def _ipc_sock_path():
    global _sock_path
    if _sock_path is None:
        base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
        _sock_path = os.path.join(base, "jacket.sock")
    return _sock_path


def stop_ipc_socket():
    global _listen_sock, _watch_id
    from gi.repository import GLib
    path = _ipc_sock_path()
    if _watch_id is not None:
        GLib.source_remove(_watch_id)
        _watch_id = None
    if _listen_sock is not None:
        try:
            _listen_sock.close()
        except Exception:
            pass
        _listen_sock = None
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _start_ipc_socket(handler: any) -> str:
    """handler(argv: list) -> str, on the GLib main thread."""
    global _listen_sock, _watch_id
    from gi.repository import GLib
    path = _ipc_sock_path()
    try:
        if os.path.exists(path):
            os.unlink(path)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(8)
    srv.setblocking(False)
    _listen_sock = srv

    def on_accept(fd, cond):
        conn, _ = srv.accept()
        conn.setblocking(True)
        try:
            data = conn.recv(65536)
            if not data:
                return True
            line = data.decode("utf-8", errors="replace").strip()
            parts = line.split() if line else []
            try:
                resp = handler(parts)
            except Exception as e:
                resp = "error: " + str(e)
            if resp is None:
                resp = "ok"
            conn.sendall((str(resp) + "\n").encode())
        finally:
            conn.close()
        return True

    _watch_id = GLib.io_add_watch(srv.fileno(), GLib.IO_IN, on_accept)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return path
::py::


def start_ipc_socket(handler: any) -> str {
    return _start_ipc_socket(handler) as str;
}
