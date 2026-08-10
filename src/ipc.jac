# ipc.jac — graph command dispatcher + legacy getter registry (I4).
# ---------------------------------------------------------------------------
# Transport lives in adapter.jac. Graph-native commands route through
# desktop.handle_graph_command; legacy string getters remain for swaybar compat.
import from src.desktop { handle_graph_command, get_desktop }
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
            if cmd in ["status", "mode", "why", "affected-by", "quit"] {
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
        if cmd == "quit" {
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
