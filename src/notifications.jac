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
import from src.reactive { signal, Signal }
import from src.glib { timeout_add }


# ---------------------------------------------------------------------------
# Pure reducer over the active-notification list. Each notification:
#   {id, app_name, summary, body, urgency, expire_ms}
# ---------------------------------------------------------------------------
# urgency: 0=low 1=normal 2=critical (from hints["urgency"]).
def make_notification(id: int, app_name: str, summary: str, body: str,
                      urgency: int, expire_ms: int) -> dict {
    return {
        "id": id,
        "app_name": app_name,
        "summary": summary,
        "body": body,
        "urgency": urgency,
        "expire_ms": expire_ms,
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
# ::py:: shim — Gio session-bus ownership + method dispatch, walled off here.
# ===========================================================================
::py::
from gi.repository import Gio, GLib

_NAME = "org.freedesktop.Notifications"
_PATH = "/org/freedesktop/Notifications"

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


def own_name(on_notify, on_close):
    """Claim the daemon name. on_notify(app_name, replaces_id, summary, body,
    hints_dict, expire) -> assigned id (int). on_close(id). Returns the owner
    id, or None when there is no session bus."""
    try:
        node = Gio.DBusNodeInfo.new_for_xml(_XML)
        iface = node.interfaces[0]
    except Exception:
        return None

    def on_bus_acquired(conn, name):
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
        try:
            conn.register_object(_PATH, iface, method_call, None, None)
        except Exception:
            pass

    try:
        return Gio.bus_own_name(
            Gio.BusType.SESSION, _NAME, Gio.BusNameOwnerFlags.NONE,
            on_bus_acquired, None, None)
    except Exception:
        return None
::py::


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
        self._owner = own_name(self._notify, self.close);
    }

    # Returns the assigned id (spec: reuse replaces_id when non-zero).
    def _notify(app: str, replaces: int, summary: str, body: str, hints: dict, expire: int) -> int {
        nid = replaces if replaces != 0 else self._next_id;
        if replaces == 0 { self._next_id += 1; }
        urgency = hint_urgency(hints);
        notif = make_notification(nid, app, summary, body, urgency, expire);
        self.notifications.set(apply_notify(self.notifications.peek(), notif));

        timeout = resolve_timeout(expire, urgency);
        if timeout > 0 {
            timeout_add(timeout, lambda (i: int = nid) {
                self.close(i);
                return False;                          # one-shot
            });
        }
        return nid;
    }

    def close(id: int) {
        self.notifications.set(dismiss(self.notifications.peek(), id));
    }
}

glob _daemon: any = None;

def get_notifications() -> NotificationDaemon {
    if _daemon is None { _daemon = NotificationDaemon(); }
    return _daemon;
}
