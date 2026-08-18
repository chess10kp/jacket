# bluetooth.jac — Bluetooth source via BlueZ on the system bus (PLAN Phase 4).
# ---------------------------------------------------------------------------
# Reads the default adapter (Powered, Discovering) and connected Device1 objects
# through org.bluez's ObjectManager, subscribing to InterfacesAdded/Removed and
# per-device PropertiesChanged when BlueZ is present. Control methods proxy
# straight through (Set Powered, StartDiscovery, StopDiscovery).
#
# Exposes Signals:
#     available       : bool   — BlueZ adapter present
#     powered         : bool
#     discovering     : bool
#     connected       : list   — [{name, address, alias}, ...]
#     primary_device  : str    — first connected name, or ""
#
# DEGRADATION: no BlueZ -> available=False, everything else at defaults.
# PURE LOGIC (bluetoothctl parsers + primary_device_from_connected) is
# unit-tested headless; the bus plumbing lives in ::py::.
import from src.reactive { signal, Signal }


# ---------------------------------------------------------------------------
# Pure logic (unit-tested) — bluetoothctl text parsers + derived fields.
# ---------------------------------------------------------------------------
# "bluetoothctl devices Connected" / "devices Paired":
#     Device AA:BB:CC:DD:EE:FF My Headphones
def parse_bluetoothctl_devices(text: any) -> list {
    out: list = [];
    for line in str(text).splitlines() {
        line = line.strip();
        if not line.startswith("Device ") { continue; }
        parts = line.split(" ", 2);          # "Device", mac, optional name
        if len(parts) < 2 { continue; }
        addr = parts[1];
        name = parts[2] if len(parts) >= 3 else "";
        out.append({"name": name, "address": addr, "alias": name});
    }
    return out;
}

# "bluetoothctl show" -> Powered: yes/no
def parse_bluetoothctl_show_powered(text: any) -> bool {
    for line in str(text).splitlines() {
        line = line.strip();
        if line.startswith("Powered:") {
            v = line.split(":", 1)[1].strip().lower();
            return v == "yes" or v == "true" or v == "on";
        }
    }
    return False;
}

# Same line format as Connected; kept separate so callers/tests can diverge.
def parse_bluetoothctl_paired(text: any) -> list {
    return parse_bluetoothctl_devices(text);
}

# First connected device name for the bar; prefers Name, falls back to Alias.
def primary_device_from_connected(devs: list) -> str {
    if len(devs) == 0 { return ""; }
    d = devs[0];
    name = str(d.get("name", ""));
    if name != "" { return name; }
    return str(d.get("alias", ""));
}


# ===========================================================================
# ::py:: seam — BlueZ ObjectManager + adapter/device watches.
# ===========================================================================
::py::
from gi.repository import Gio, GLib

_BLUEZ = "org.bluez"
_OM = "org.freedesktop.DBus.ObjectManager"
_ADAPTER = "org.bluez.Adapter1"
_DEVICE = "org.bluez.Device1"
_PROPS = "org.freedesktop.DBus.Properties"


def _system():
    try:
        return Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    except Exception:
        return None


def _managed(conn):
    if conn is None:
        return None
    try:
        reply = conn.call_sync(
            _BLUEZ, "/",
            _OM, "GetManagedObjects", None,
            GLib.VariantType("a{oa{sa{sv}}}"),
            Gio.DBusCallFlags.NONE, -1, None)
        return reply.unpack()[0]
    except Exception:
        return None


def _device_entry(props):
    if not props.get("Connected", False):
        return None
    name = props.get("Name", "") or ""
    alias = props.get("Alias", "") or name
    if not name:
        name = alias
    address = props.get("Address", "") or ""
    return {"name": str(name), "address": str(address), "alias": str(alias)}


def read_state(conn):
    """(available, powered, discovering, connected, adapter_path) or None."""
    objects = _managed(conn)
    if objects is None:
        return None
    adapter_path = ""
    powered = False
    discovering = False
    connected = []
    for path, ifaces in objects.items():
        if _ADAPTER in ifaces:
            adapter_path = path
            props = ifaces[_ADAPTER]
            powered = bool(props.get("Powered", False))
            discovering = bool(props.get("Discovering", False))
        if _DEVICE in ifaces:
            entry = _device_entry(ifaces[_DEVICE])
            if entry is not None:
                connected.append(entry)
    return (adapter_path != "", powered, discovering, connected, adapter_path)


def _watch_device(conn, path, on_change, tracker):
    if path in tracker["devices"]:
        return
    try:
        proxy = Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _BLUEZ, path, _DEVICE, None)
        proxy.connect("g-properties-changed",
                      lambda p, changed, inval: on_change())
        tracker["devices"][path] = proxy
    except Exception:
        pass


def _ensure_adapter_watch(conn, adapter_path, on_change, tracker):
    if not adapter_path or adapter_path == tracker.get("adapter_path"):
        return
    tracker["adapter_path"] = adapter_path
    try:
        proxy = Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _BLUEZ, adapter_path, _ADAPTER, None)
        proxy.connect("g-properties-changed",
                      lambda p, changed, inval: on_change())
        tracker["adapter_proxy"] = proxy
    except Exception:
        pass


def _seed_device_watches(conn, on_change, tracker):
    objects = _managed(conn)
    if objects is None:
        return
    live = set()
    for path, ifaces in objects.items():
        if _DEVICE in ifaces:
            live.add(path)
            _watch_device(conn, path, on_change, tracker)
    for path in list(tracker["devices"].keys()):
        if path not in live:
            tracker["devices"].pop(path, None)


def watch(conn, on_change):
    """Subscribe to ObjectManager + adapter/device property changes."""
    if conn is None:
        return None
    tracker = {"devices": {}, "adapter_path": "", "adapter_proxy": None}

    def _on_added(proxy, sender, signal, params):
        try:
            path, ifaces = params.unpack()
            if _DEVICE in ifaces:
                _watch_device(conn, path, on_change, tracker)
        except Exception:
            pass
        on_change()

    def _on_removed(proxy, sender, signal, params):
        try:
            path, ifaces = params.unpack()
            tracker["devices"].pop(path, None)
        except Exception:
            pass
        on_change()

    try:
        om = Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _BLUEZ, "/", _OM, None)
        om.connect("g-signal", lambda p, s, sig, par: (
            _on_added(p, s, sig, par) if sig == "InterfacesAdded"
            else _on_removed(p, s, sig, par) if sig == "InterfacesRemoved"
            else None))
    except Exception:
        return tracker

    state = read_state(conn)
    if state is not None:
        _ensure_adapter_watch(conn, state[4], on_change, tracker)
    _seed_device_watches(conn, on_change, tracker)
    return tracker


def _set_powered(conn, adapter_path, on):
    if conn is None or not adapter_path:
        return
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _PROPS, "Set",
            GLib.Variant("(ssv)", (_ADAPTER, "Powered", GLib.Variant("b", bool(on)))),
            None, Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass


def _start_discovery(conn, adapter_path):
    if conn is None or not adapter_path:
        return
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _ADAPTER, "StartDiscovery",
            None, None, Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass


def _stop_discovery(conn, adapter_path):
    if conn is None or not adapter_path:
        return
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _ADAPTER, "StopDiscovery",
            None, None, Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass
::py::


# ---------------------------------------------------------------------------
# The source (singleton).
# ---------------------------------------------------------------------------
obj Bluetooth {
    has available: Signal = signal(False);
    has powered: Signal = signal(False);
    has discovering: Signal = signal(False);
    has connected: Signal = signal([]);
    has primary_device: Signal = signal("");
    has _conn: any = None;
    has _adapter_path: any = "";
    has _tracker: any = None;

    def postinit() {
        self._conn = _system();
        if self._conn is not None {
            self._tracker = watch(self._conn, lambda { self._refresh(); });
        }
        self._refresh();
    }

    def _refresh() {
        state = read_state(self._conn);
        if state is None { return; }
        (avail, pwr, disc, devs, adapter_path) = state;
        self._adapter_path = adapter_path;
        if self._tracker is not None and str(adapter_path) != "" {
            _ensure_adapter_watch(self._conn, adapter_path,
                lambda { self._refresh(); }, self._tracker);
        }
        self.available.set(bool(avail));
        self.powered.set(bool(pwr));
        self.discovering.set(bool(disc));
        self.connected.set(list(devs));
        self.primary_device.set(primary_device_from_connected(list(devs)));
    }

    def set_powered(on: bool) {
        _set_powered(self._conn, self._adapter_path, on);
        self._refresh();
    }

    def start_discovery() {
        _start_discovery(self._conn, self._adapter_path);
        self._refresh();
    }

    def stop_discovery() {
        _stop_discovery(self._conn, self._adapter_path);
        self._refresh();
    }
}

glob _bt: any = None;

def get_bluetooth() -> Bluetooth {
    if _bt is None { _bt = Bluetooth(); }
    return _bt;
}
