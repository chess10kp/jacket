# tray.jac — StatusNotifierItem (SNI) system tray (PLAN Phase 5).
# ---------------------------------------------------------------------------
# The freedesktop/KDE tray protocol has two roles and we play BOTH:
#
#   Watcher  (org.kde.StatusNotifierWatcher) — a registry. Apps call
#            RegisterStatusNotifierItem; hosts call RegisterStatusNotifierHost.
#            It exposes the current item list + Registered/Unregistered signals.
#            A bare wlroots session has none, so we serve our own.
#   Host     — the consumer that actually draws the icons. It registers with the
#            watcher, reads the item list, and proxies each item's icon/tooltip/
#            Activate. We ALWAYS run as a host, talking to whichever watcher owns
#            the name (ours or a pre-existing waybar/plasma one) — one bus path.
#
# So: try to own the watcher name (serve it if we win, shrug if we don't), then
# unconditionally run the host against org.kde.StatusNotifierWatcher. Everything
# bus-facing lives in the ::py:: seam; the PURE resolution logic (service-string
# -> canonical bus+path, status visibility, icon choice) is unit-tested headless.
#
# DEGRADATION: no session bus -> start_tray() finds nothing, items stays [], the
# bar hides the widget. Exactly like the notification daemon.
import from src.reactive { signal, Signal }


# ---------------------------------------------------------------------------
# PURE LOGIC (unit-tested) — no bus, no GTK.
# ---------------------------------------------------------------------------
# RegisterStatusNotifierItem's argument is ambiguous by spec: it is EITHER a bus
# name (KDE apps: ":1.42", item at /StatusNotifierItem) OR an object path
# (libappindicator/Ayatana: "/org/ayatana/NotificationItem/x", bus = the sender).
# The widely-used host heuristic: a '/' means it's a path (bus := sender), else
# it's a bus name (path := /StatusNotifierItem). Canonical key = bus + path.
def resolve_item(service: str, sender: str) -> str {
    if "/" in service {
        return sender + service;      # bus = sender (empty if unknown) + the path
    }
    return service + "/StatusNotifierItem";
}

# Split a canonical key back into (bus_name, object_path). Bus names never carry
# a '/', so the first one starts the path.
def split_item_key(key: str) -> tuple {
    i = key.find("/");
    if i < 0 { return (key, "/StatusNotifierItem"); }
    return (key[:i], key[i:]);
}

# SNI Status is "Passive" | "Active" | "NeedsAttention". KDE hides Passive; we
# show everything non-empty (many apps sit on Passive forever yet want drawing).
# Kept as a seam so the policy is one testable place.
def should_show(status: str) -> bool {
    return True;
}

# NeedsAttention swaps in the attention icon when the app supplies one.
def pick_icon_name(icon_name: str, attention_name: str, status: str) -> str {
    if status == "NeedsAttention" and attention_name { return attention_name; }
    return icon_name;
}


# --- dbusmenu (com.canonical.dbusmenu) layout parsing -----------------------
# The right-click menu is a SEPARATE object exposed as the SNI item's `Menu`
# property (an object path on the item's own bus). We fetch it with GetLayout
# and trigger entries with Event; both live in the seam. The reply is a
# recursive (id, a{sv} props, av children) tree — the PURE shape work below
# turns one unpacked node into a plain, testable dict tree the widget renders.

# dbusmenu labels carry GTK-style mnemonics: a single '_' marks the accelerator
# char (dropped for display); a doubled '__' is a literal underscore. Strip the
# markers so the popup shows "File", not "_File".
def clean_label(label: str) -> str {
    tmp = label.replace("__", "\x00");     # protect literal underscores
    tmp = tmp.replace("_", "");            # drop mnemonic markers
    return tmp.replace("\x00", "_");       # restore the literals
}

# parse_menu_layout(item) -> dict. `item` is ONE unpacked GetLayout node:
# (id: int, props: dict, children: list-of-nodes). Recurses into children.
# Output dict: {id, label, type, separator, enabled, visible, toggle_type,
# toggle_state, children:[...]}. Missing props take dbusmenu's spec defaults
# (enabled/visible True, type "standard"). Pure: no bus, no GTK — unit-tested.
# ('node' is a reserved OSP keyword in Jac, hence 'item'.)
def parse_menu_layout(item: any) -> dict {
    node_id = item[0] if len(item) > 0 else 0;
    props: dict = item[1] if len(item) > 1 else {};
    kids: list = item[2] if len(item) > 2 else [];
    kind = str(props.get("type", "standard") or "standard");
    return {
        "id": int(node_id),
        "label": clean_label(str(props.get("label", "") or "")),
        "type": kind,
        "separator": kind == "separator",
        "enabled": bool(props.get("enabled", True)),
        "visible": bool(props.get("visible", True)),
        "toggle_type": str(props.get("toggle-type", "") or ""),
        "toggle_state": int(props.get("toggle-state", -1)),
        "children": [parse_menu_layout(c) for c in kids],
    };
}


# ===========================================================================
# ::py:: seam — the whole bus dance: watcher server + host client + item proxies
# + ARGB pixmap decode. Names below are callable from Jac.
# ===========================================================================
::py::
# No bare `import gi` here: src.adapter is imported first (above) and does the
# require_version bootstrap, so the sanctioned Gio/GLib transport slice below
# binds cleanly.
import os
from gi.repository import Gio, GLib

_WATCHER_NAME = "org.kde.StatusNotifierWatcher"
_WATCHER_PATH = "/StatusNotifierWatcher"
_WATCHER_IFACE = "org.kde.StatusNotifierWatcher"
_ITEM_IFACE = "org.kde.StatusNotifierItem"
_DBUSMENU_IFACE = "com.canonical.dbusmenu"

# --- Watcher server introspection (the registry side) ----------------------
_WATCHER_XML = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem">
      <arg type="s" name="service" direction="in"/>
    </method>
    <method name="RegisterStatusNotifierHost">
      <arg type="s" name="service" direction="in"/>
    </method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
    <signal name="StatusNotifierHostUnregistered"/>
  </interface>
</node>
"""

# Module-level tray state (one shell = one tray). The Jac Tray obj owns only the
# Signal; all the bus bookkeeping lives here so no statement-bodied lambdas nest
# inside a Jac method (codegen bug) and the callbacks stay plain python.
_state = {
    "conn": None,          # session bus connection
    "reg": None,           # our watcher registration id (if we won the name)
    "items": {},           # canonical key -> {proxy, data, sub_ids:[...]}
    "host_registered": False,
    "on_items": None,      # Jac callback(list[dict])
    "own_watcher": False,  # did WE win the watcher name?
}


# --- ARGB (network byte order) -> RGBA pixels + texture ---------------------
# The byte work stays here (pure, headless-testable); the texture creation
# lives behind the adapter seam (adapter.py_make_texture) so no gi tokens
# appear above it. Returns None when the backend can't make textures.
def _largest_argb_as_rgba(pixmaps):
    """SNI IconPixmap is a(iiay): (width, height, ARGB32-big-endian bytes). Take
    the largest frame, swap ARGB->RGBA, return (w, h, rgba_bytes) or None."""
    if not pixmaps:
        return None
    try:
        best = max(pixmaps, key=lambda p: p[0] * p[1])
        w, h, data = best[0], best[1], bytes(best[2])
        if w <= 0 or h <= 0 or len(data) < w * h * 4:
            return None
        out = bytearray(len(data))
        for i in range(0, w * h * 4, 4):
            a, r, g, b = data[i], data[i+1], data[i+2], data[i+3]
            out[i], out[i+1], out[i+2], out[i+3] = r, g, b, a
        return (w, h, bytes(out))
    except Exception:
        return None


def _pixmap_to_texture(pixmaps):
    packed = _largest_argb_as_rgba(pixmaps)
    if packed is None:
        return None
    # Lazy, dynamic import: the texture factory lives in the ACTIVE backend
    # module; tray must stay importable (returning None) without any backend.
    try:
        import importlib
        mod = importlib.import_module("src.adapter")
        return mod.py_make_texture(*packed)
    except Exception:
        return None


def _read_item(proxy):
    """Snapshot an item proxy into a plain dict the widget renders."""
    def prop(name, default):
        try:
            v = proxy.get_cached_property(name)
            return v.unpack() if v is not None else default
        except Exception:
            return default
    status = str(prop("Status", "Active"))
    icon_name = str(prop("IconName", "") or "")
    attn = str(prop("AttentionIconName", "") or "")
    title = str(prop("Title", "") or "")
    tip = prop("ToolTip", None)          # (s, a(iiay), s, s) = icon,pixmap,title,text
    tooltip = title
    if isinstance(tip, tuple) and len(tip) >= 4:
        tooltip = str(tip[2] or tip[3] or title)
    texture = None
    name = pick_icon_name(icon_name, attn, status)
    if not name:
        texture = _pixmap_to_texture(prop("IconPixmap", None))
    if not name and texture is None:
        name = "application-x-executable"     # never an invisible slot
    return {
        "id": str(prop("Id", "") or ""),
        "title": title,
        "icon": name,
        "texture": texture,
        "status": status,
        "tooltip": tooltip or title,
    }


def _emit_items():
    cb = _state["on_items"]
    if cb is None:
        return
    out = []
    for key, rec in _state["items"].items():
        d = dict(rec["data"])
        d["key"] = key
        if should_show(d["status"]):
            out.append(d)
    out.sort(key=lambda d: (d["id"], d["key"]))    # stable order
    cb(out)


def _refresh_item(key):
    rec = _state["items"].get(key)
    if rec is None:
        return
    rec["data"] = _read_item(rec["proxy"])
    _emit_items()


def _add_item(key):
    if key in _state["items"]:
        return
    conn = _state["conn"]
    bus, path = split_item_key(key)
    try:
        proxy = Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None, bus, path, _ITEM_IFACE, None)
    except Exception:
        return
    rec = {"proxy": proxy, "data": None, "sub_ids": []}
    _state["items"][key] = rec
    # Re-read on any NewIcon/NewStatus/NewToolTip/NewTitle.
    def on_signal(p, sender, signal, params):
        _refresh_item(key)
    sid = proxy.connect("g-signal", on_signal)
    rec["sub_ids"].append(sid)
    rec["data"] = _read_item(proxy)
    _emit_items()


def _remove_item(key):
    rec = _state["items"].pop(key, None)
    if rec is None:
        return
    for sid in rec["sub_ids"]:
        try:
            rec["proxy"].disconnect(sid)
        except Exception:
            pass
    _emit_items()


# --- Watcher server: our registry (used when no other watcher exists) -------
def _serve_watcher():
    conn = _state["conn"]
    try:
        node = Gio.DBusNodeInfo.new_for_xml(_WATCHER_XML)
        iface = node.interfaces[0]
    except Exception:
        return

    def method_call(c, sender, path, interface, method, params, invocation):
        if method == "RegisterStatusNotifierItem":
            (service,) = params.unpack()
            key = resolve_item(service, sender)
            _add_item(key)
            c.emit_signal(None, _WATCHER_PATH, _WATCHER_IFACE,
                          "StatusNotifierItemRegistered",
                          GLib.Variant("(s)", (key,)))
            invocation.return_value(None)
        elif method == "RegisterStatusNotifierHost":
            _state["host_registered"] = True
            c.emit_signal(None, _WATCHER_PATH, _WATCHER_IFACE,
                          "StatusNotifierHostRegistered", None)
            invocation.return_value(None)
        else:
            invocation.return_value(None)

    def get_property(c, sender, path, interface, name):
        if name == "RegisteredStatusNotifierItems":
            return GLib.Variant("as", list(_state["items"].keys()))
        if name == "IsStatusNotifierHostRegistered":
            return GLib.Variant("b", True)
        if name == "ProtocolVersion":
            return GLib.Variant("i", 0)
        return None

    try:
        conn.register_object(_WATCHER_PATH, iface, method_call, get_property, None)
        _state["own_watcher"] = True
    except Exception:
        pass


# --- NameOwnerChanged: drop items whose owning app exited -------------------
def _watch_name_losses():
    conn = _state["conn"]

    def on_noc(c, sender, path, iface, signal, params):
        try:
            name, old_owner, new_owner = params.unpack()
        except Exception:
            return
        if new_owner:            # acquired/changed, not a loss
            return
        # An item's bus name vanished -> unregister every key on that bus.
        for key in list(_state["items"].keys()):
            bus, _p = split_item_key(key)
            if bus == name:
                _remove_item(key)
                try:
                    c.emit_signal(None, _WATCHER_PATH, _WATCHER_IFACE,
                                  "StatusNotifierItemUnregistered",
                                  GLib.Variant("(s)", (key,)))
                except Exception:
                    pass

    conn.signal_subscribe(
        "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
        "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE, on_noc)


# --- Host client: consume whatever watcher owns the name --------------------
def _run_host():
    conn = _state["conn"]
    host_name = "org.kde.StatusNotifierHost-%d" % os.getpid()

    def after_own(*a):
        # Register as a host with the live watcher and pull the current list.
        try:
            conn.call_sync(
                _WATCHER_NAME, _WATCHER_PATH, _WATCHER_IFACE,
                "RegisterStatusNotifierHost", GLib.Variant("(s)", (host_name,)),
                None, Gio.DBusCallFlags.NONE, -1, None)
        except Exception:
            pass
        try:
            reply = conn.call_sync(
                _WATCHER_NAME, _WATCHER_PATH, "org.freedesktop.DBus.Properties",
                "Get", GLib.Variant("(ss)", (_WATCHER_IFACE,
                       "RegisteredStatusNotifierItems")),
                None, Gio.DBusCallFlags.NONE, -1, None)
            for key in reply.unpack()[0]:
                _add_item(key)
        except Exception:
            pass

    # Subscribe to the watcher's item add/remove signals (works for our own
    # watcher and a foreign one alike).
    def on_reg(c, sender, path, iface, signal, params):
        (key,) = params.unpack()
        _add_item(key)

    def on_unreg(c, sender, path, iface, signal, params):
        (key,) = params.unpack()
        _remove_item(key)

    conn.signal_subscribe(
        None, _WATCHER_IFACE, "StatusNotifierItemRegistered", _WATCHER_PATH,
        None, Gio.DBusSignalFlags.NONE, on_reg)
    conn.signal_subscribe(
        None, _WATCHER_IFACE, "StatusNotifierItemUnregistered", _WATCHER_PATH,
        None, Gio.DBusSignalFlags.NONE, on_unreg)

    Gio.bus_own_name_on_connection(
        conn, host_name, Gio.BusNameOwnerFlags.NONE, None, None)
    after_own()


def start_tray(on_items):
    """Bring up watcher (best-effort) + host. on_items(list[dict]) fires whenever
    the item set/content changes. No-op with no session bus."""
    _state["on_items"] = on_items
    try:
        conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except Exception:
        conn = None
    if conn is None:
        return
    _state["conn"] = conn

    def on_acquired(c, name):
        _serve_watcher()

    # Try to be the watcher; whether or not we win, run the host afterwards.
    try:
        Gio.bus_own_name(
            Gio.BusType.SESSION, _WATCHER_NAME, Gio.BusNameOwnerFlags.NONE,
            on_acquired, None, None)
    except Exception:
        pass
    _watch_name_losses()
    _run_host()


def activate_item(key, x, y):
    rec = _state["items"].get(key)
    if rec is None:
        return
    try:
        rec["proxy"].call_sync(
            "Activate", GLib.Variant("(ii)", (int(x), int(y))),
            Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass


def context_menu(key, x, y):
    rec = _state["items"].get(key)
    if rec is None:
        return
    try:
        rec["proxy"].call_sync(
            "ContextMenu", GLib.Variant("(ii)", (int(x), int(y))),
            Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass


# --- dbusmenu client: the item's `Menu` object path -> GetLayout / Event -----
def _menu_proxy(key):
    """Lazily build (and cache) a com.canonical.dbusmenu proxy for an item's
    Menu object path. Returns None if the item ships no menu or the bus is gone."""
    rec = _state["items"].get(key)
    if rec is None:
        return None
    if rec.get("menu_proxy") is not None:
        return rec["menu_proxy"]
    conn = _state["conn"]
    if conn is None:
        return None
    bus, _path = split_item_key(key)
    try:
        v = rec["proxy"].get_cached_property("Menu")
        menu_path = v.unpack() if v is not None else None
    except Exception:
        menu_path = None
    if not menu_path or menu_path == "/":
        return None
    try:
        mp = Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None, bus, menu_path,
            _DBUSMENU_IFACE, None)
    except Exception:
        return None
    rec["menu_proxy"] = mp
    return mp


def fetch_menu(key):
    """AboutToShow (lazy-populate) then GetLayout(0, -1, []) the item's dbusmenu;
    return the parsed dict tree (root node) or None. Pure parsing is delegated to
    parse_menu_layout so the shape logic stays testable."""
    mp = _menu_proxy(key)
    if mp is None:
        return None
    try:
        mp.call_sync("AboutToShow", GLib.Variant("(i)", (0,)),
                     Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass
    try:
        reply = mp.call_sync(
            "GetLayout", GLib.Variant("(iias)", (0, -1, [])),
            Gio.DBusCallFlags.NONE, -1, None)
        # reply = (revision: u, root: (i, a{sv}, av))
        root = reply.unpack()[1]
    except Exception:
        return None
    return parse_menu_layout(root)


def menu_event(key, item_id, timestamp=0):
    """Fire Event(id, "clicked", <empty variant>, timestamp) — the dbusmenu
    click trigger. No-op if the item has no menu."""
    mp = _menu_proxy(key)
    if mp is None:
        return
    try:
        mp.call_sync(
            "Event",
            GLib.Variant("(isvu)", (int(item_id), "clicked",
                         GLib.Variant("i", 0), int(timestamp))),
            Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass
::py::


# ---------------------------------------------------------------------------
# The source (singleton). Holds items: Signal[list]; the bar renders it.
# ---------------------------------------------------------------------------
obj Tray {
    has items: Signal = signal([]);

    def postinit() {
        # Pass a bound method (NOT a wrapper lambda): a statement-bodied lambda
        # nested in a method trips the Jac codegen scoping bug.
        start_tray(self._push);
    }

    def _push(items: list) {
        # New list identity each time so the For diff fires (PLAN open-item #2).
        self.items.set(list(items));
    }

    def activate(key: str) { activate_item(key, 0, 0); }
    def menu(key: str) { context_menu(key, 0, 0); }

    # Right-click context menu (com.canonical.dbusmenu). load_menu returns the
    # parsed dict tree the widget builds a popover from; fire triggers an entry.
    def load_menu(key: str) -> any { return fetch_menu(key); }
    def fire(key: str, item_id: int) { menu_event(key, item_id, 0); }
}

glob _tray: any = None;

def get_tray() -> Tray {
    if _tray is None { _tray = Tray(); }
    return _tray;
}
