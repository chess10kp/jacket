# bluetooth.jac — Bluetooth via BlueZ D-Bus (Quickshell.Bluetooth-shaped API).
# ---------------------------------------------------------------------------
# Tracks adapters and devices through org.bluez's ObjectManager, with
# PropertiesChanged on each adapter/device and bluetoothctl fallback when the
# bus is unavailable.
#
# Exposes Signals (manager):
#     available         : bool   — at least one adapter present
#     adapters          : list   — adapter dicts (see below)
#     devices           : list   — all tracked devices
#     default_adapter   : dict   — first/default adapter snapshot
#     powered           : bool   — default adapter powered (compat)
#     discovering       : bool   — default adapter scanning (compat)
#     connected         : list   — connected device summaries (compat)
#     primary_device    : str    — first connected name (compat)
#
# Adapter dict: dbus_path, adapter_id, name, state, powered, discovering,
#               discoverable, pairable, devices
# Device dict:  dbus_path, address, name, device_name, icon, connected,
#               paired, bonded, blocked, trusted, pairing, wake_allowed,
#               state, adapter_path, battery_available, battery
#
# DEGRADATION: no BlueZ -> available=False, empty lists / zero defaults.
# PURE LOGIC is unit-tested headless; bus plumbing lives in ::py::.
import from src.reactive { signal, Signal }


# ---------------------------------------------------------------------------
# Pure logic (unit-tested) — bluetoothctl text + BlueZ-shaped reducers.
# ---------------------------------------------------------------------------
# "bluetoothctl devices" / "devices Connected" / "devices Paired":
#     Device AA:BB:CC:DD:EE:FF My Headphones
def parse_bluetoothctl_devices(text: any) -> list {
    out: list = [];
    for line in str(text).splitlines() {
        line = line.strip();
        if not line.startswith("Device ") { continue; }
        parts = line.split(" ", 2);
        if len(parts) < 2 { continue; }
        addr = parts[1];
        name = parts[2] if len(parts) >= 3 else "";
        out.append({"name": name, "address": addr, "alias": name});
    }
    return out;
}

def parse_bluetoothctl_show_powered(text: any) -> bool {
    st = parse_bluetoothctl_show(text);
    return bool(st.get("powered", False));
}

def parse_bluetoothctl_paired(text: any) -> list {
    return parse_bluetoothctl_devices(text);
}

# Parse `bluetoothctl show` adapter fields.
def parse_bluetoothctl_show(text: any) -> dict {
    out = {
        "powered": False,
        "discovering": False,
        "discoverable": False,
        "pairable": False,
        "name": "",
        "adapter_id": "hci0",
    };
    for line in str(text).splitlines() {
        line = line.strip();
        if line.startswith("Powered:") {
            v = line.split(":", 1)[1].strip().lower();
            out["powered"] = v in ["yes", "true", "on"];
        } elif line.startswith("Discovering:") {
            v = line.split(":", 1)[1].strip().lower();
            out["discovering"] = v in ["yes", "true", "on"];
        } elif line.startswith("Discoverable:") {
            v = line.split(":", 1)[1].strip().lower();
            out["discoverable"] = v in ["yes", "true", "on"];
        } elif line.startswith("Pairable:") {
            v = line.split(":", 1)[1].strip().lower();
            out["pairable"] = v in ["yes", "true", "on"];
        } elif line.startswith("Alias:") or line.startswith("Name:") {
            out["name"] = line.split(":", 1)[1].strip();
        } elif line.startswith("Controller ") {
            parts = line.split();
            if len(parts) >= 2 { out["adapter_id"] = parts[1]; }
        }
    }
    return out;
}

def adapter_id_from_path(path: str) -> str {
    parts = str(path).rstrip("/").split("/");
    if len(parts) == 0 { return ""; }
    return parts[-1];
}

def parse_adapter_state(state_wire: any, powered: bool) -> str {
    s = str(state_wire).lower() if state_wire is not None else "";
    if s == "off" { return "disabled"; }
    if s == "on" { return "enabled"; }
    if s == "off-enabling" { return "enabling"; }
    if s == "on-disabling" { return "disabling"; }
    if s == "off-blocked" { return "blocked"; }
    return "enabled" if powered else "disabled";
}

def device_state_from_connected(connected: bool) -> str {
    return "connected" if connected else "disconnected";
}

def _empty_adapter() -> dict {
    return {
        "dbus_path": "",
        "adapter_id": "",
        "name": "",
        "state": "disabled",
        "powered": False,
        "discovering": False,
        "discoverable": False,
        "pairable": False,
        "devices": [],
    };
}

def public_adapter_entry(
    path: str, props: dict, adapter_devices: list
) -> dict {
    powered = bool(props.get("Powered", False));
    state_wire = props.get("State", None);
    return {
        "dbus_path": path,
        "adapter_id": adapter_id_from_path(path),
        "name": str(props.get("Name", "") or props.get("Alias", "") or ""),
        "state": parse_adapter_state(state_wire, powered),
        "powered": powered,
        "discovering": bool(props.get("Discovering", False)),
        "discoverable": bool(props.get("Discoverable", False)),
        "pairable": bool(props.get("Pairable", False)),
        "devices": list(adapter_devices),
    };
}

def public_device_entry(
    path: str, props: dict, battery_pct: any, adapter_path: str
) -> dict {
    name = str(props.get("Name", "") or "");
    alias = str(props.get("Alias", "") or name);
    display = alias if alias != "" else name;
    if name == "" { name = alias; }
    connected = bool(props.get("Connected", False));
    batt_avail = battery_pct is not None;
    batt = 0.0;
    if batt_avail {
        try {
            batt = float(battery_pct) / 100.0;
        } except ValueError {
            batt = 0.0;
        }
    }
    return {
        "dbus_path": path,
        "address": str(props.get("Address", "") or ""),
        "name": display,
        "device_name": name,
        "icon": str(props.get("Icon", "") or ""),
        "connected": connected,
        "paired": bool(props.get("Paired", False)),
        "bonded": bool(props.get("Bonded", False)),
        "blocked": bool(props.get("Blocked", False)),
        "trusted": bool(props.get("Trusted", False)),
        "pairing": False,
        "wake_allowed": bool(props.get("WakeAllowed", False)),
        "state": device_state_from_connected(connected),
        "adapter_path": adapter_path,
        "battery_available": batt_avail,
        "battery": batt,
    };
}

def devices_for_adapter(all_devices: list, adapter_path: str) -> list {
    out: list = [];
    for d in all_devices {
        if str(d.get("adapter_path", "")) == adapter_path {
            out.append(d);
        }
    }
    return out;
}

def attach_devices_to_adapters(adapters: list, devices: list) -> list {
    out: list = [];
    for a in adapters {
        path = str(a.get("dbus_path", ""));
        merged = {**a, "devices": devices_for_adapter(devices, path)};
        out.append(merged);
    }
    return out;
}

def connected_devices_summary(devices: list) -> list {
    out: list = [];
    for d in devices {
        if not bool(d.get("connected", False)) { continue; }
        out.append({
            "name": str(d.get("name", "")),
            "address": str(d.get("address", "")),
            "alias": str(d.get("name", "")),
        });
    }
    return out;
}

def primary_device_from_connected(devs: list) -> str {
    if len(devs) == 0 { return ""; }
    d = devs[0];
    name = str(d.get("name", ""));
    if name != "" { return name; }
    return str(d.get("alias", ""));
}

def default_adapter_from_list(adapters: list, path: str) -> dict {
    if len(adapters) == 0 { return _empty_adapter(); }
    if path != "" {
        for a in adapters {
            if str(a.get("dbus_path", "")) == path { return a; }
        }
    }
    return adapters[0];
}

def _addr_set(devs: list) -> dict {
    out: dict = {};
    for d in devs {
        out[str(d.get("address", "")).upper()] = True;
    }
    return out;
}

def devices_from_bluetoothctl_lists(
    all_devs: list, paired_devs: list, connected_devs: list, adapter_path: str
) -> list {
    paired = _addr_set(paired_devs);
    connected = _addr_set(connected_devs);
    out: list = [];
    for d in all_devs {
        addr = str(d.get("address", ""));
        name = str(d.get("name", ""));
        out.append({
            "dbus_path": "",
            "address": addr,
            "name": name,
            "device_name": name,
            "icon": "",
            "connected": addr.upper() in connected,
            "paired": addr.upper() in paired,
            "bonded": addr.upper() in paired,
            "blocked": False,
            "trusted": False,
            "pairing": False,
            "wake_allowed": False,
            "state": device_state_from_connected(addr.upper() in connected),
            "adapter_path": adapter_path,
            "battery_available": False,
            "battery": 0.0,
        });
    }
    return out;
}

def state_from_bluetoothctl_raw(raw: any) -> any {
    if raw is None { return None; }
    info = parse_bluetoothctl_show(raw.get("show", ""));
    all_devs = parse_bluetoothctl_devices(raw.get("all", ""));
    paired_devs = parse_bluetoothctl_devices(raw.get("paired", ""));
    connected_devs = parse_bluetoothctl_devices(raw.get("connected", ""));
    adapter_path = "/org/bluez/" + str(info.get("adapter_id", "hci0"));
    devices = devices_from_bluetoothctl_lists(
        all_devs, paired_devs, connected_devs, adapter_path);
    adapter = {
        "dbus_path": adapter_path,
        "adapter_id": str(info.get("adapter_id", "hci0")),
        "name": str(info.get("name", "")),
        "state": parse_adapter_state(None, bool(info.get("powered", False))),
        "powered": bool(info.get("powered", False)),
        "discovering": bool(info.get("discovering", False)),
        "discoverable": bool(info.get("discoverable", False)),
        "pairable": bool(info.get("pairable", False)),
        "devices": devices_for_adapter(devices, adapter_path),
    };
    return {
        "available": True,
        "adapters": [adapter],
        "devices": devices,
        "default_adapter_path": adapter_path,
    };
}

def _apply_bluetooth_state(bt: any, st: any) {
    adapters = attach_devices_to_adapters(
        list(st.get("adapters", [])), list(st.get("devices", [])));
    devices = list(st.get("devices", []));
    default_path = str(st.get("default_adapter_path", ""));
    default_a = default_adapter_from_list(adapters, default_path);
    connected = connected_devices_summary(devices);
    bt.available.set(bool(st.get("available", False)));
    bt.adapters.set(adapters);
    bt.devices.set(devices);
    bt.default_adapter.set(default_a);
    bt.powered.set(bool(default_a.get("powered", False)));
    bt.discovering.set(bool(default_a.get("discovering", False)));
    bt.connected.set(connected);
    bt.primary_device.set(primary_device_from_connected(connected));
}


# ===========================================================================
# ::py:: seam — BlueZ ObjectManager + adapter/device watches + control.
# ===========================================================================
::py::
try:
    from gi.repository import Gio, GLib
except ImportError:
    Gio = None
    GLib = None

_BLUEZ = "org.bluez"
_OM = "org.freedesktop.DBus.ObjectManager"
_ADAPTER = "org.bluez.Adapter1"
_DEVICE = "org.bluez.Device1"
_BATTERY = "org.bluez.Battery1"
_PROPS = "org.freedesktop.DBus.Properties"


def _system():
    if Gio is None:
        return None
    try:
        return Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    except Exception:
        return None


def _managed(conn):
    if conn is None or Gio is None or GLib is None:
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


def _unpack_props(props):
    out = {}
    for k, v in props.items():
        try:
            out[k] = v.unpack() if hasattr(v, "unpack") else v
        except Exception:
            out[k] = v
    return out


def _device_from_managed(path, ifaces):
    if _DEVICE not in ifaces:
        return None
    props = _unpack_props(ifaces[_DEVICE])
    battery_pct = None
    if _BATTERY in ifaces:
        bprops = _unpack_props(ifaces[_BATTERY])
        battery_pct = bprops.get("Percentage")
    adapter_path = str(props.get("Adapter", "") or "")
    name = props.get("Name", "") or ""
    alias = props.get("Alias", "") or name
    display = alias if alias else name
    if not name:
        name = alias
    connected = bool(props.get("Connected", False))
    batt_avail = battery_pct is not None
    battery = float(battery_pct) / 100.0 if batt_avail else 0.0
    return {
        "dbus_path": path,
        "address": str(props.get("Address", "") or ""),
        "name": str(display),
        "device_name": str(name),
        "icon": str(props.get("Icon", "") or ""),
        "connected": connected,
        "paired": bool(props.get("Paired", False)),
        "bonded": bool(props.get("Bonded", False)),
        "blocked": bool(props.get("Blocked", False)),
        "trusted": bool(props.get("Trusted", False)),
        "pairing": False,
        "wake_allowed": bool(props.get("WakeAllowed", False)),
        "state": "connected" if connected else "disconnected",
        "adapter_path": adapter_path,
        "battery_available": batt_avail,
        "battery": battery,
    }


def _adapter_from_managed(path, ifaces, devices):
    if _ADAPTER not in ifaces:
        return None
    props = _unpack_props(ifaces[_ADAPTER])
    powered = bool(props.get("Powered", False))
    state_wire = props.get("State", None)
    state = "enabled" if powered else "disabled"
    if state_wire is not None:
        s = str(state_wire).lower()
        mapping = {
            "off": "disabled",
            "on": "enabled",
            "off-enabling": "enabling",
            "on-disabling": "disabling",
            "off-blocked": "blocked",
        }
        state = mapping.get(s, state)
    adapter_devices = [d for d in devices if d.get("adapter_path") == path]
    parts = path.rstrip("/").split("/")
    adapter_id = parts[-1] if parts else ""
    return {
        "dbus_path": path,
        "adapter_id": adapter_id,
        "name": str(props.get("Name", "") or props.get("Alias", "") or ""),
        "state": state,
        "powered": powered,
        "discovering": bool(props.get("Discovering", False)),
        "discoverable": bool(props.get("Discoverable", False)),
        "pairable": bool(props.get("Pairable", False)),
        "devices": adapter_devices,
    }


def read_state(conn):
    """Full manager snapshot or None."""
    objects = _managed(conn)
    if objects is None:
        return None
    devices = []
    adapters = []
    adapter_paths = []
    for path, ifaces in objects.items():
        if _DEVICE in ifaces:
            entry = _device_from_managed(path, ifaces)
            if entry is not None:
                devices.append(entry)
    for path, ifaces in objects.items():
        if _ADAPTER in ifaces:
            adapter_paths.append(path)
            entry = _adapter_from_managed(path, ifaces, devices)
            if entry is not None:
                adapters.append(entry)
    adapter_paths.sort()
    default_path = adapter_paths[0] if adapter_paths else ""
    return {
        "available": len(adapter_paths) > 0,
        "adapters": adapters,
        "devices": devices,
        "default_adapter_path": default_path,
    }


def _watch_iface(conn, path, iface, on_change, tracker, bucket):
    key = (path, iface)
    if key in tracker[bucket]:
        return
    try:
        proxy = Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _BLUEZ, path, iface, None)
        proxy.connect("g-properties-changed",
                      lambda p, changed, inval: on_change())
        tracker[bucket][key] = proxy
    except Exception:
        pass


def _seed_watches(conn, on_change, tracker):
    objects = _managed(conn)
    if objects is None:
        return
    live_adapters = set()
    live_devices = set()
    for path, ifaces in objects.items():
        if _ADAPTER in ifaces:
            live_adapters.add(path)
            _watch_iface(conn, path, _ADAPTER, on_change, tracker, "adapters")
        if _DEVICE in ifaces:
            live_devices.add(path)
            _watch_iface(conn, path, _DEVICE, on_change, tracker, "devices")
            if _BATTERY in ifaces:
                _watch_iface(conn, path, _BATTERY, on_change, tracker, "devices")
    for key in list(tracker["adapters"].keys()):
        if key[0] not in live_adapters:
            tracker["adapters"].pop(key, None)
    for key in list(tracker["devices"].keys()):
        if key[0] not in live_devices:
            tracker["devices"].pop(key, None)


def watch(conn, on_change):
    if conn is None or Gio is None:
        return None
    tracker = {"adapters": {}, "devices": {}}

    def _on_added(proxy, sender, signal, params):
        try:
            path, ifaces = params.unpack()
            if _ADAPTER in ifaces:
                _watch_iface(conn, path, _ADAPTER, on_change, tracker, "adapters")
            if _DEVICE in ifaces:
                _watch_iface(conn, path, _DEVICE, on_change, tracker, "devices")
                if _BATTERY in ifaces:
                    _watch_iface(conn, path, _BATTERY, on_change, tracker, "devices")
        except Exception:
            pass
        on_change()

    def _on_removed(proxy, sender, signal, params):
        try:
            path, ifaces = params.unpack()
            for bucket in ("adapters", "devices"):
                for key in list(tracker[bucket].keys()):
                    if key[0] == path:
                        tracker[bucket].pop(key, None)
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

    _seed_watches(conn, on_change, tracker)
    return tracker


def _adapter_path_for(conn, path_or_default):
    if path_or_default and str(path_or_default).startswith("/"):
        return str(path_or_default)
    st = read_state(conn)
    if st is None:
        return ""
    return str(st.get("default_adapter_path", ""))


def _set_powered(conn, adapter_path, on):
    if conn is None or not adapter_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _PROPS, "Set",
            GLib.Variant("(ssv)", (_ADAPTER, "Powered", GLib.Variant("b", bool(on)))),
            None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _set_discoverable(conn, adapter_path, on):
    if conn is None or not adapter_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _PROPS, "Set",
            GLib.Variant("(ssv)", (_ADAPTER, "Discoverable", GLib.Variant("b", bool(on)))),
            None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _set_pairable(conn, adapter_path, on):
    if conn is None or not adapter_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _PROPS, "Set",
            GLib.Variant("(ssv)", (_ADAPTER, "Pairable", GLib.Variant("b", bool(on)))),
            None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _start_discovery(conn, adapter_path):
    if conn is None or not adapter_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _ADAPTER, "StartDiscovery",
            None, None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _stop_discovery(conn, adapter_path):
    if conn is None or not adapter_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _ADAPTER, "StopDiscovery",
            None, None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _device_method(conn, device_path, method):
    if conn is None or not device_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, device_path,
            _DEVICE, method,
            None, None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _set_device_prop(conn, device_path, key, variant):
    if conn is None or not device_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, device_path,
            _PROPS, "Set",
            GLib.Variant("(ssv)", (_DEVICE, key, variant)),
            None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _remove_device(conn, adapter_path, device_path):
    if conn is None or not adapter_path or not device_path:
        return False
    try:
        conn.call_sync(
            _BLUEZ, adapter_path,
            _ADAPTER, "RemoveDevice",
            GLib.Variant("(o)", (device_path,)),
            None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def _set_device_trusted(conn, device_path, trusted):
    return _set_device_prop(
        conn, device_path, "Trusted", GLib.Variant("b", bool(trusted)))


def _set_device_blocked(conn, device_path, blocked):
    return _set_device_prop(
        conn, device_path, "Blocked", GLib.Variant("b", bool(blocked)))


def _set_device_alias(conn, device_path, name):
    return _set_device_prop(
        conn, device_path, "Alias", GLib.Variant("s", str(name)))


def _run_cmd(args):
    import subprocess
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
        return p.returncode, p.stdout or ""
    except Exception:
        return 1, ""


def read_bluetoothctl_state():
    """Fallback snapshot via bluetoothctl when D-Bus is unavailable."""
    rc, show = _run_cmd(["bluetoothctl", "show"])
    if rc != 0:
        return None
    rc2, all_txt = _run_cmd(["bluetoothctl", "devices"])
    rc3, paired_txt = _run_cmd(["bluetoothctl", "devices", "Paired"])
    rc4, conn_txt = _run_cmd(["bluetoothctl", "devices", "Connected"])
    return {
        "show": show,
        "all": all_txt if rc2 == 0 else "",
        "paired": paired_txt if rc3 == 0 else "",
        "connected": conn_txt if rc4 == 0 else "",
    }


def btctl(args):
    _run_cmd(["bluetoothctl"] + list(args))
::py::


# ---------------------------------------------------------------------------
# The source (singleton) — Quickshell.Bluetooth-shaped manager.
# ---------------------------------------------------------------------------
obj Bluetooth {
    has available: Signal = signal(False);
    has adapters: Signal = signal([]);
    has devices: Signal = signal([]);
    has default_adapter: Signal = signal(_empty_adapter());
    has powered: Signal = signal(False);
    has discovering: Signal = signal(False);
    has connected: Signal = signal([]);
    has primary_device: Signal = signal("");
    has _conn: any = None;
    has _tracker: any = None;

    def postinit() {
        self._conn = _system();
        if self._conn is not None {
            self._tracker = watch(self._conn, lambda { self._refresh(); });
        }
        self._refresh();
    }

    def _default_adapter_path() -> str {
        da = self.default_adapter.get();
        return str(da.get("dbus_path", ""));
    }

    def _resolve_device_path(path_or_address: str) -> str {
        key = str(path_or_address).strip();
        if key == "" { return ""; }
        if key.startswith("/") { return key; }
        upper = key.upper();
        for d in self.devices.get() {
            if str(d.get("address", "")).upper() == upper {
                return str(d.get("dbus_path", ""));
            }
        }
        return "";
    }

    def _refresh() {
        st: any = read_state(self._conn);
        if st is None {
            st = state_from_bluetoothctl_raw(read_bluetoothctl_state());
            if st is None { return; }
        }
        _apply_bluetooth_state(self, st);
    }

    def _adapter_path(adapter_path: str) -> str {
        path = str(adapter_path).strip();
        if path != "" { return path; }
        return self._default_adapter_path();
    }

    def set_powered(on: bool, adapter_path: str = "") {
        path = self._adapter_path(adapter_path);
        if not _set_powered(self._conn, path, on) {
            cmd = "on" if on else "off";
            btctl(["power", cmd]);
        }
        self._refresh();
    }

    def set_discoverable(on: bool, adapter_path: str = "") {
        path = self._adapter_path(adapter_path);
        if not _set_discoverable(self._conn, path, on) {
            cmd = "on" if on else "off";
            btctl(["discoverable", cmd]);
        }
        self._refresh();
    }

    def set_pairable(on: bool, adapter_path: str = "") {
        path = self._adapter_path(adapter_path);
        if not _set_pairable(self._conn, path, on) {
            cmd = "on" if on else "off";
            btctl(["pairable", cmd]);
        }
        self._refresh();
    }

    def start_discovery(adapter_path: str = "") {
        path = self._adapter_path(adapter_path);
        if not _start_discovery(self._conn, path) {
            btctl(["scan", "on"]);
        }
        self._refresh();
    }

    def stop_discovery(adapter_path: str = "") {
        path = self._adapter_path(adapter_path);
        if not _stop_discovery(self._conn, path) {
            btctl(["scan", "off"]);
        }
        self._refresh();
    }

    def connect_device(path_or_address: str) {
        path = self._resolve_device_path(path_or_address);
        if path != "" {
            _device_method(self._conn, path, "Connect");
        } else {
            btctl(["connect", str(path_or_address)]);
        }
        self._refresh();
    }

    def disconnect_device(path_or_address: str) {
        path = self._resolve_device_path(path_or_address);
        if path != "" {
            _device_method(self._conn, path, "Disconnect");
        } else {
            btctl(["disconnect", str(path_or_address)]);
        }
        self._refresh();
    }

    def pair_device(path_or_address: str) {
        path = self._resolve_device_path(path_or_address);
        if path != "" {
            _device_method(self._conn, path, "Pair");
        } else {
            btctl(["pair", str(path_or_address)]);
        }
        self._refresh();
    }

    def cancel_pair_device(path_or_address: str) {
        path = self._resolve_device_path(path_or_address);
        if path != "" {
            _device_method(self._conn, path, "CancelPairing");
        }
        self._refresh();
    }

    def forget_device(path_or_address: str) {
        path = self._resolve_device_path(path_or_address);
        addr = str(path_or_address);
        if path != "" {
            adapter_path = "";
            for d in self.devices.get() {
                if str(d.get("dbus_path", "")) == path {
                    adapter_path = str(d.get("adapter_path", ""));
                    break;
                }
            }
            if adapter_path == "" { adapter_path = self._default_adapter_path(); }
            if not _remove_device(self._conn, adapter_path, path) {
                btctl(["remove", addr]);
            }
        } else {
            btctl(["remove", addr]);
        }
        self._refresh();
    }

    def set_device_trusted(path_or_address: str, trusted: bool) {
        path = self._resolve_device_path(path_or_address);
        if path != "" { _set_device_trusted(self._conn, path, trusted); }
        self._refresh();
    }

    def set_device_blocked(path_or_address: str, blocked: bool) {
        path = self._resolve_device_path(path_or_address);
        if path != "" { _set_device_blocked(self._conn, path, blocked); }
        self._refresh();
    }

    def set_device_name(path_or_address: str, name: str) {
        path = self._resolve_device_path(path_or_address);
        if path != "" { _set_device_alias(self._conn, path, name); }
        self._refresh();
    }
}

glob _bt: any = None;

def get_bluetooth() -> Bluetooth {
    if _bt is None { _bt = Bluetooth(); }
    return _bt;
}
