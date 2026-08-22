# notifications.jac — org.freedesktop.Notifications daemon (PLAN Phase 5).
# ---------------------------------------------------------------------------
# We OWN the daemon: claim the well-known name on the session bus via Gio and
# service Notify/CloseNotification/GetCapabilities/GetServerInformation. Every
# accepted notification flows into a Signal[list] the shell renders. ("Own the
# logic, use the transport" — PLAN §4.)
#
# The reducer (apply_notify / dismiss / expire_after) is PURE and unit-tested;
# only the bus plumbing touches Gio. The session bus is unreachable in some
# headless setups — there the daemon fails to own the name and stays quiet, but
# the reducer (and its tests) still exercise all the real logic.
import from jacket.reactive { signal, Signal }
import from jacket.glib { timeout_add }
import from jacket.busname { own_name as bus_own_name }
import json;
import os;


# ---------------------------------------------------------------------------
# Pure reducer over the active-notification list. Each notification:
#   {id, app_name, summary, body, urgency, expire_ms, closing}
# ---------------------------------------------------------------------------
# urgency: 0=low 1=normal 2=critical (from hints["urgency"]).
# closing: True once the row started its exit animation — the UI tweens the
# bubble out while the daemon waits EXIT_GRACE_MS before real removal.
def make_notification(id: int, app_name: str, summary: str, body: str,
                      urgency: int, expire_ms: int) -> dict {
    return {
        "id": id,
        "app_name": app_name,
        "summary": summary,
        "body": body,
        "urgency": urgency,
        "expire_ms": expire_ms,
        "closing": False,
    };
}

# Insert or replace (spec: replaces_id != 0 updates an existing bubble in place).
# Returns a NEW list (For diff needs identity change — PLAN open-item #2).
def apply_notify(active: list, notif: dict) -> list {
    out: list = [];
    replaced = False;
    for n in active {
        if n["id"] == notif["id"] {
            out.append(notif);
            replaced = True;
        } else {
            out.append(n);
        }
    }
    if not replaced { out.append(notif); }
    return out;
}

# Remove by id (CloseNotification / user dismiss / expiry). New list.
def dismiss(active: list, id: int) -> list {
    return [n for n in active if n["id"] != id];
}

# Flag a row as closing (UI plays its exit tween). New list; no-op when the id
# is missing or already closing. The exit-grace clock lives in the daemon —
# the reducer stays pure.
def mark_closing(active: list, id: int) -> list {
    out: list = [];
    for n in active {
        if n["id"] == id and not n["closing"] {
            c = dict(n);
            c["closing"] = True;
            out.append(c);
        } else {
            out.append(n);
        }
    }
    return out;
}

# Is this id currently mid-exit? (Guards the grace timeout: a re-Notify that
# replaces a closing row un-flags it, so the stale timeout must not remove it.)
def is_closing(active: list, id: int) -> bool {
    for n in active {
        if n["id"] == id { return bool(n["closing"]); }
    }
    return False;
}

# Resolve the effective auto-dismiss delay (ms). Spec: expire_ms == 0 means
# "never", -1 means "server decides". Critical urgency never auto-expires.
def resolve_timeout(expire_ms: int, urgency: int) -> int {
    if urgency >= 2 { return 0; }                 # critical: sticky
    if expire_ms == 0 { return 0; }               # explicit never
    if expire_ms < 0 { return 5000; }             # server default
    return expire_ms;
}

# Pull urgency out of the DBus hints dict (defaults to normal).
def hint_urgency(hints: dict) -> int {
    u: any = hints.get("urgency");
    if u is None { return 1; }
    return int(u);
}


# ===========================================================================
# Crash persistence: the active list survives a restart.
# ---------------------------------------------------------------------------
# Every change writes $XDG_STATE_HOME/jacket/notifications.json; startup
# restores it. The "closing" flag is deliberately dropped — a crash mid-exit
# tween must not replay half-finished removals.
# ===========================================================================
def state_path() -> str {
    base = os.environ.get("XDG_STATE_HOME");
    if base is None or base == "" {
        home = os.environ.get("HOME", "");
        if home == "" { return ""; }
        base = os.path.join(home, ".local", "state");
    }
    return os.path.join(base, "jacket", "notifications.json");
}


def serialize_active(active: list) -> str {
    keep = [{
        "id": n["id"], "app_name": n["app_name"], "summary": n["summary"],
        "body": n["body"], "urgency": n["urgency"], "expire_ms": n["expire_ms"],
    } for n in active];
    return json.dumps(keep);
}


def deserialize_active(text: str) -> list {
    try {
        raw: any = json.loads(text);
    } except Exception {
        return [];
    }
    out: list = [];
    if not isinstance(raw, list) { return out; }
    for d in raw {
        try {
            out.append(make_notification(int(d["id"]), str(d["app_name"]),
                                         str(d["summary"]), str(d["body"]),
                                         int(d["urgency"]), int(d["expire_ms"])));
        } except Exception {
            continue;
        }
    }
    return out;
}


def load_saved() -> list {
    p = state_path();
    if p == "" { return []; }
    try {
        with open(p) as f {
            text = f.read();
        }
        return deserialize_active(text);
    } except Exception {
        return [];
    }
}


# ===========================================================================
# ::py:: shim — notification-protocol dispatch only. Name ownership, object
# registration and re-acquire-on-holder-exit live in jacket/busname.jac (shared
# with any future well-known-name service).
# ===========================================================================
::py::
from gi.repository import GLib

# Minimal introspection for the four methods the spec requires.
_XML = """
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg type="s" name="app_name" direction="in"/>
      <arg type="u" name="replaces_id" direction="in"/>
      <arg type="s" name="app_icon" direction="in"/>
      <arg type="s" name="summary" direction="in"/>
      <arg type="s" name="body" direction="in"/>
      <arg type="as" name="actions" direction="in"/>
      <arg type="a{sv}" name="hints" direction="in"/>
      <arg type="i" name="expire_timeout" direction="in"/>
      <arg type="u" name="id" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="GetCapabilities">
      <arg type="as" name="caps" direction="out"/>
    </method>
    <method name="GetServerInformation">
      <arg type="s" name="name" direction="out"/>
      <arg type="s" name="vendor" direction="out"/>
      <arg type="s" name="version" direction="out"/>
      <arg type="s" name="spec_version" direction="out"/>
    </method>
  </interface>
</node>
"""


def serve(on_notify, on_close):
    """Serve org.freedesktop.Notifications via the shared bus-name owner.
    on_notify(app_name, replaces_id, summary, body, hints_dict, expire) ->
    assigned id (int). on_close(id). Returns the owner handle (opaque dict),
    or None when there is no session bus."""
    def method_call(c, sender, path, interface, method, params, invocation):
        if method == "Notify":
            app_name, replaces_id, app_icon, summary, body, actions, hints, expire = params.unpack()
            nid = on_notify(app_name, int(replaces_id), summary, body, hints, int(expire))
            invocation.return_value(GLib.Variant("(u)", (nid,)))
        elif method == "CloseNotification":
            (cid,) = params.unpack()
            on_close(int(cid))
            invocation.return_value(None)
        elif method == "GetCapabilities":
            invocation.return_value(GLib.Variant("(as)", (["body", "actions", "body-markup"],)))
        elif method == "GetServerInformation":
            invocation.return_value(GLib.Variant("(ssss)", ("jacket", "jaseci", "0.1", "1.2")))
        else:
            invocation.return_value(None)

    return bus_own_name(
        "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        _XML, method_call, None, None)
::py::


# How long a closing row stays in the list so the UI exit tween is seen.
glob EXIT_GRACE_MS: int = 240;


# ---------------------------------------------------------------------------
# The daemon (singleton). Holds the active list + a monotonic id counter.
# ---------------------------------------------------------------------------
obj NotificationDaemon {
    has notifications: Signal = signal([]);
    has _next_id: int = 1;
    has _owner: any = None;

    def postinit() {
        # Pass bound methods (NOT wrapper lambdas): nesting statement-bodied
        # lambdas inside a method trips a Jac codegen scoping bug.
        self._owner = serve(self._notify, self.close);
        self._restore();
    }

    # Replay notifications saved by a previous (crashed) incarnation: bubbles
    # reappear with their original ids and remaining timeout semantics.
    def _restore() {
        saved: list = load_saved();
        if saved == [] { return; }
        top = 0;
        for n in saved {
            rec: dict = n;
            if int(rec["id"]) > top { top = int(rec["id"]); }
        }
        if top >= self._next_id { self._next_id = top + 1; }
        self.notifications.set(saved);
        for n in saved {
            rec: dict = n;
            nid = int(rec["id"]);
            t = resolve_timeout(int(rec["expire_ms"]), int(rec["urgency"]));
            if t > 0 {
                timeout_add(t, lambda (i: int = nid) {
                    self.begin_close(i);
                    return False;
                });
            }
        }
        self._persist();
    }

    # Snapshot the active list to the state file. Best-effort: persistence
    # must never take the daemon down.
    def _persist() {
        p = state_path();
        if p == "" { return; }
        try {
            os.makedirs(p.rsplit("/", 1)[0], exist_ok=True);
            with open(p, "w") as f {
                f.write(serialize_active(self.notifications.peek()));
            }
        } except Exception as e {
            _ = e;
        }
    }

    # Returns the assigned id (spec: reuse replaces_id when non-zero).
    def _notify(app: str, replaces: int, summary: str, body: str, hints: dict, expire: int) -> int {
        nid = replaces if replaces != 0 else self._next_id;
        if replaces == 0 { self._next_id += 1; }
        urgency = hint_urgency(hints);
        notif = make_notification(nid, app, summary, body, urgency, expire);
        self.notifications.set(apply_notify(self.notifications.peek(), notif));
        self._persist();

        timeout = resolve_timeout(expire, urgency);
        if timeout > 0 {
            timeout_add(timeout, lambda (i: int = nid) {
                self.begin_close(i);               # grace first, so rows exit
                return False;                      # one-shot
            });
        }
        return nid;
    }

    # Immediate removal (bus CloseNotification keeps spec-fast semantics).
    def close(id: int) {
        self.notifications.set(dismiss(self.notifications.peek(), id));
        self._persist();
    }

    # Graceful removal: flag the row closing (UI tweens it out), then remove
    # after EXIT_GRACE_MS. Idempotent; missing ids no-op.
    def begin_close(id: int) {
        active = self.notifications.peek();
        if is_closing(active, id) { return; }
        if dismiss(active, id) == active { return; }   # id not in list
        self.notifications.set(mark_closing(active, id));
        self._persist();
        timeout_add(EXIT_GRACE_MS, lambda (i: int = id) {
            self._finish_close(i);
            return False;                          # one-shot
        });
    }

    # A re-Notify during the grace window replaces the row with a fresh
    # (non-closing) dict — the stale timeout must leave it alone.
    def _finish_close(id: int) {
        if is_closing(self.notifications.peek(), id) {
            self.close(id);
        }
    }
}

glob _daemon: any = None;

def get_notifications() -> NotificationDaemon {
    if _daemon is None { _daemon = NotificationDaemon(); }
    return _daemon;
}
