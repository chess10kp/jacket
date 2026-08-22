# network.jac — network state via NetworkManager D-Bus (PLAN Phase 4).
# ---------------------------------------------------------------------------
# Uses Gio DBus on the system bus for org.freedesktop.NetworkManager, with
# nmcli text parsing as fallback for headless/testing. PropertiesChanged
# drives updates when a proxy is available; otherwise we poll every 3s.
#
# Exposes Signals for availability, wifi radio, connection, scan results, etc.
#
# DEGRADATION: no NM -> available=False, empty/zero defaults.
# PURE LOGIC (parse_nmcli_*) is unit-tested headless.
import from jacket.reactive { signal, Signal }
import from jacket.glib { run_cmd, timeout_add }


::py::
from gi.repository import Gio, GLib

_NM = "org.freedesktop.NetworkManager"
_NM_PATH = "/org/freedesktop/NetworkManager"
_NM_IFACE = "org.freedesktop.NetworkManager"
_DEV_IFACE = "org.freedesktop.NetworkManager.Device"
_DEV_WIFI = "org.freedesktop.NetworkManager.Device.Wireless"
_AP_IFACE = "org.freedesktop.NetworkManager.AccessPoint"
_AC_IFACE = "org.freedesktop.NetworkManager.Connection.Active"
_CONNECTED = {50, 60, 70}
_TYPE_MAP = {"802-11-wireless": "wifi", "802-3-ethernet": "ethernet"}
_SKIP_DEV = {"lo", "docker0"}


def _proxy():
    try:
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None,
            _NM, _NM_PATH, _NM_IFACE, None)
    except Exception:
        return None


def _dev_proxy(conn, path):
    try:
        return Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _NM, path, _DEV_IFACE, None)
    except Exception:
        return None


def _wifi_proxy(conn, path):
    try:
        return Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _NM, path, _DEV_WIFI, None)
    except Exception:
        return None


def _ap_proxy(conn, path):
    try:
        return Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _NM, path, _AP_IFACE, None)
    except Exception:
        return None


def _ac_proxy(conn, path):
    try:
        return Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            _NM, path, _AC_IFACE, None)
    except Exception:
        return None


def _ssid_from_ap(conn, ap_path):
    if not ap_path or ap_path == "/":
        return "", 0
    ap = _ap_proxy(conn, ap_path)
    if ap is None:
        return "", 0
    try:
        ssid_v = ap.get_cached_property("Ssid")
        strength_v = ap.get_cached_property("Strength")
        raw = ssid_v.unpack() if ssid_v is not None else []
        ssid = bytes(raw).decode("utf-8", errors="replace") if raw else ""
        strength = int(strength_v.unpack()) if strength_v is not None else 0
        return ssid, strength
    except Exception:
        return "", 0


def _pick_device(conn, dev_paths):
    best = ("", 0)
    for dp in dev_paths or []:
        dev = _dev_proxy(conn, dp)
        if dev is None:
            continue
        try:
            iface_v = dev.get_cached_property("Interface")
            dtype_v = dev.get_cached_property("DeviceType")
            if iface_v is None:
                continue
            iface = str(iface_v.unpack())
            if iface in _SKIP_DEV or iface.startswith("br-") or iface.startswith("veth"):
                continue
            dtype = int(dtype_v.unpack()) if dtype_v is not None else 0
            pri = 3 if dtype == 2 else (2 if dtype == 1 else 1)
            if pri > best[1]:
                best = (iface, pri)
        except Exception:
            continue
    return best[0]


def read_nm(proxy):
    if proxy is None:
        return None
    try:
        conn = proxy.get_connection()
        wifi_en = proxy.get_cached_property("WirelessEnabled")
        state = proxy.get_cached_property("State")
        ptype = proxy.get_cached_property("PrimaryConnectionType")
        pconn = proxy.get_cached_property("PrimaryConnection")

        wifi_on = bool(wifi_en.unpack()) if wifi_en is not None else False
        st = int(state.unpack()) if state is not None else 0
        connected = st in _CONNECTED
        ptype_s = str(ptype.unpack()) if ptype is not None else ""
        ctype = _TYPE_MAP.get(ptype_s, "none") if connected else "none"

        device = ""
        ssid = ""
        signal = 0
        if connected and pconn is not None:
            path = str(pconn.unpack())
            if path and path != "/":
                ac = _ac_proxy(conn, path)
                if ac is not None:
                    devs_v = ac.get_cached_property("Devices")
                    dev_paths = devs_v.unpack() if devs_v is not None else []
                    device = _pick_device(conn, dev_paths)
                    if ctype == "wifi" and device:
                        for dp in dev_paths:
                            wdev = _wifi_proxy(conn, dp)
                            if wdev is None:
                                continue
                            ap_v = wdev.get_cached_property("ActiveAccessPoint")
                            ap_path = str(ap_v.unpack()) if ap_v is not None else "/"
                            ssid, signal = _ssid_from_ap(conn, ap_path)
                            if ssid:
                                break

        return {
            "available": True,
            "wifi_enabled": wifi_on,
            "connected": connected,
            "connection_type": ctype,
            "ssid": ssid,
            "signal_strength": signal,
            "primary_device": device,
        }
    except Exception:
        return None


def read_nm_networks(proxy):
    if proxy is None:
        return None
    try:
        conn = proxy.get_connection()
        reply = proxy.call_sync(
            "GetDevices", None, Gio.DBusCallFlags.NONE, -1, None)
        dev_paths = reply.unpack()[0] if reply is not None else []
        best = {}
        for dp in dev_paths:
            wdev = _wifi_proxy(conn, dp)
            if wdev is None:
                continue
            ap_v = wdev.get_cached_property("AccessPoints")
            active_v = wdev.get_cached_property("ActiveAccessPoint")
            active_path = str(active_v.unpack()) if active_v is not None else "/"
            for ap_path in (ap_v.unpack() if ap_v is not None else []):
                ap = _ap_proxy(conn, ap_path)
                if ap is None:
                    continue
                ssid, strength = _ssid_from_ap(conn, ap_path)
                if not ssid:
                    continue
                flags_v = ap.get_cached_property("Flags")
                wpa_v = ap.get_cached_property("WpaFlags")
                rsn_v = ap.get_cached_property("RsnFlags")
                flags = int(flags_v.unpack()) if flags_v is not None else 0
                wpa = int(wpa_v.unpack()) if wpa_v is not None else 0
                rsn = int(rsn_v.unpack()) if rsn_v is not None else 0
                secured = (wpa | rsn) != 0
                active = str(ap_path) == active_path
                prev = best.get(ssid)
                if prev is None or strength > prev["strength"]:
                    best[ssid] = {
                        "ssid": ssid,
                        "strength": strength,
                        "secured": secured,
                        "active": active or (prev["active"] if prev else False),
                    }
                elif active and prev is not None:
                    prev["active"] = True
        out = list(best.values())
        out.sort(key=lambda n: -n["strength"])
        return out
    except Exception:
        return None


def request_scan(proxy):
    if proxy is None:
        return False
    try:
        conn = proxy.get_connection()
        reply = proxy.call_sync(
            "GetDevices", None, Gio.DBusCallFlags.NONE, -1, None)
        for dp in reply.unpack()[0]:
            wdev = _wifi_proxy(conn, dp)
            if wdev is not None:
                wdev.call_sync(
                    "RequestScan",
                    GLib.Variant("(a{sv})", ([],)),
                    Gio.DBusCallFlags.NONE, -1, None)
                return True
        return False
    except Exception:
        return False


def set_wifi_nm(proxy, on):
    if proxy is None:
        return False
    try:
        proxy.call_sync(
            "org.freedesktop.DBus.Properties.Set",
            GLib.Variant("(ssv)", (
                _NM_IFACE, "WirelessEnabled", GLib.Variant("b", bool(on)))),
            Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def watch(proxy, on_change):
    if proxy is None:
        return
    proxy.connect("g-properties-changed", lambda p, c, i: on_change())
::py::


# ---------------------------------------------------------------------------
# Pure logic (unit-tested) — nmcli -t text -> structured data.
# ---------------------------------------------------------------------------
# `nmcli -t -f WIFI,STATE general` -> "enabled:connected"
def parse_nmcli_general_status(text: any) -> dict {
    t = str(text).strip();
    if t == "" {
        return {"available": False, "wifi_enabled": False, "connected": False, "state": ""};
    }
    parts = t.split(":");
    wifi = parts[0] if len(parts) > 0 else "";
    state = parts[1] if len(parts) > 1 else "";
    st = state.lower();
    connected = st == "connected" or st.startswith("connected ");
    return {
        "available": True,
        "wifi_enabled": wifi.lower() == "enabled",
        "connected": connected,
        "state": state,
    };
}

# `nmcli -t -f ACTIVE,SSID,SIGNAL,SECURITY device wifi list`
def parse_nmcli_wifi_list(text: any) -> list {
    out: list = [];
    seen: dict = {};
    for line in str(text).strip().split("\n") {
        if line.strip() == "" { continue; }
        parts = line.split(":");
        if len(parts) < 4 { continue; }
        active = parts[0].lower() == "yes";
        ssid = parts[1];
        if ssid == "" or ssid == "--" { continue; }
        strength = 0;
        try {
            strength = int(parts[2]);
        } except ValueError {
            strength = 0;
        }
        security = parts[3];
        secured = security != "" and security != "--";
        entry = {"ssid": ssid, "strength": strength, "secured": secured, "active": active};
        if ssid in seen {
            idx = seen[ssid];
            if strength > out[idx]["strength"] { out[idx]["strength"] = strength; }
            if active { out[idx]["active"] = True; }
        } else {
            seen[ssid] = len(out);
            out.append(entry);
        }
    }
    out.sort(key=lambda (n: dict) { -n["strength"]; });
    return out;
}

# `nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active`
def parse_nmcli_active_connection(text: any) -> dict {
    empty = {
        "connected": False, "connection_type": "none",
        "device": "", "ssid": "", "name": "",
    };
    lines = [ln for ln in str(text).strip().split("\n") if ln.strip() != ""];
    if len(lines) == 0 { return empty; }
    best: any = None;
    best_pri = -1;
    for line in lines {
        parts = line.split(":");
        if len(parts) < 4 { continue; }
        name = parts[0];
        typ = parts[1];
        device = parts[2];
        state = parts[3].lower();
        if not state.startswith("activated") { continue; }
        if device in ["lo", "docker0"] or device.startswith("br-") or device.startswith("veth") {
            continue;
        }
        if typ in ["loopback", "bridge"] { continue; }
        pri = 0;
        ctype = "none";
        if typ == "802-11-wireless" {
            pri = 3;
            ctype = "wifi";
        } elif typ == "802-3-ethernet" {
            pri = 2;
            ctype = "ethernet";
        } else {
            pri = 1;
        }
        if pri > best_pri {
            best_pri = pri;
            best = {
                "connected": True,
                "connection_type": ctype,
                "device": device,
                "ssid": name if ctype == "wifi" else "",
                "name": name,
            };
        }
    }
    if best is None { return empty; }
    return best;
}

def _signal_for_ssid(networks: list, ssid: str) -> int {
    best: int = 0;
    for n in networks {
        s: int = int(n["strength"]);
        if n["ssid"] == ssid and s > best { best = s; }
    }
    return best;
}

def _apply_state(net: any, st: any) {
    net.available.set(st.get("available", False));
    net.wifi_enabled.set(st.get("wifi_enabled", False));
    net.connected.set(st.get("connected", False));
    net.connection_type.set(st.get("connection_type", "none"));
    net.ssid.set(st.get("ssid", ""));
    net.signal_strength.set(st.get("signal_strength", 0));
    net.primary_device.set(st.get("primary_device", ""));
}

def _state_from_nmcli() -> any {
    (rc, gen) = run_cmd(["nmcli", "-t", "-f", "WIFI,STATE", "general"]);
    if rc != 0 { return None; }
    general = parse_nmcli_general_status(gen);
    (rc2, act) = run_cmd(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE,STATE", "connection", "show", "--active"]);
    active = parse_nmcli_active_connection(act) if rc2 == 0 else {
        "connected": False, "connection_type": "none", "device": "", "ssid": "", "name": "",
    };
    (rc3, wifi) = run_cmd(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL,SECURITY", "device", "wifi", "list"]);
    networks = parse_nmcli_wifi_list(wifi) if rc3 == 0 else [];
    ctype = active.get("connection_type", "none");
    if not general.get("connected", False) { ctype = "none"; }
    ssid = active.get("ssid", "") if ctype == "wifi" else "";
    signal = _signal_for_ssid(networks, ssid) if ssid != "" else 0;
    return {
        "available": general.get("available", False),
        "wifi_enabled": general.get("wifi_enabled", False),
        "connected": general.get("connected", False),
        "connection_type": ctype,
        "ssid": ssid,
        "signal_strength": signal,
        "primary_device": active.get("device", ""),
        "networks": networks,
    };
}


# ---------------------------------------------------------------------------
# The source (singleton).
# ---------------------------------------------------------------------------
obj Network {
    has available: Signal = signal(False);
    has wifi_enabled: Signal = signal(False);
    has connected: Signal = signal(False);
    has connection_type: Signal = signal("none");
    has ssid: Signal = signal("");
    has signal_strength: Signal = signal(0);
    has primary_device: Signal = signal("");
    has networks: Signal = signal([]);
    has _proxy: any = None;
    has _use_poll: bool = False;

    def postinit() {
        self._proxy = _proxy();
        self._use_poll = self._proxy is None;
        self._refresh();
        if self._proxy is not None {
            watch(self._proxy, lambda { self._refresh(); });
        }
        timeout_add(3000, lambda {
            if self._use_poll { self._refresh(); }
            return True;
        });
    }

    def _refresh() {
        st: any = None;
        nets: any = None;
        st = read_nm(self._proxy);
        if st is not None {
            nets = read_nm_networks(self._proxy);
        } else {
            nmcli = _state_from_nmcli();
            if nmcli is None { return; }
            st = nmcli;
            nets = nmcli.get("networks", []);
        }
        _apply_state(self, st);
        if nets is not None { self.networks.set(nets); }
    }

    def set_wifi_enabled(on: bool) {
        if not set_wifi_nm(self._proxy, on) {
            cmd = "on" if on else "off";
            run_cmd(["nmcli", "radio", "wifi", cmd]);
        }
        self._refresh();
    }

    def scan() {
        if not request_scan(self._proxy) {
            run_cmd(["nmcli", "device", "wifi", "rescan"]);
        }
        self._refresh();
    }
}

glob _net: any = None;

def get_network() -> Network {
    if _net is None { _net = Network(); }
    return _net;
}
