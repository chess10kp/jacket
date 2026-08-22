# battery.jac — battery source via UPower on the system bus (PLAN Phase 4).
# ---------------------------------------------------------------------------
# Uses Gio DBus (the GLib stack — "own the logic, use the transport", PLAN §4)
# to read UPower's DisplayDevice and subscribe to PropertiesChanged. The system
# bus is reachable in normal sessions, so this source is LIVE-verifiable.
#
# Exposes one Signal:
#     battery : Signal[dict]  — {"percent": int, "charging": bool, "present": bool}
#
# DEGRADATION: no UPower / no battery -> present=False, the bar hides the widget.
# PURE LOGIC (parse_battery / battery_icon) is unit-tested headless.
import from jacket.reactive { signal, Signal }


::py::
from gi.repository import Gio, GLib

_UPOWER = "org.freedesktop.UPower"
_DISPLAY = "/org/freedesktop/UPower/devices/DisplayDevice"
_DEV_IFACE = "org.freedesktop.UPower.Device"


def _proxy():
    """A DBusProxy on UPower's DisplayDevice, or None if UPower is absent."""
    try:
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None,
            _UPOWER, _DISPLAY, _DEV_IFACE, None)
    except Exception:
        return None


def read_raw(proxy):
    """(percentage: float, state: int, present: bool) from the proxy, or None."""
    if proxy is None:
        return None
    try:
        pct = proxy.get_cached_property("Percentage")
        st = proxy.get_cached_property("State")
        pres = proxy.get_cached_property("IsPresent")
        if pct is None:
            return None
        return (
            float(pct.unpack()),
            int(st.unpack()) if st is not None else 0,
            bool(pres.unpack()) if pres is not None else True,
        )
    except Exception:
        return None


def watch(proxy, on_change):
    """Fire on_change() whenever UPower reports a property change."""
    if proxy is None:
        return
    proxy.connect("g-properties-changed", lambda p, changed, inval: on_change())
::py::


# ---------------------------------------------------------------------------
# Pure logic (unit-tested).
# ---------------------------------------------------------------------------
# UPower State enum: 1=Charging 2=Discharging 3=Empty 4=Fully 5=Pending-charge
def parse_battery(percentage: any, state: any) -> dict {
    charging = state == 1 or state == 4 or state == 5;
    return {
        "percent": int(round(percentage)),
        "charging": charging,
    };
}

# A plain-text meter (no icon font needed): one '#' per 20% bucket, '-' for
# the rest. Charging is the single marker "CHG" regardless of charge level.
def battery_icon(percent: int, charging: bool) -> str {
    if charging { return "CHG"; }
    n = 0;
    if percent >= 90 { n = 5; }
    elif percent >= 70 { n = 4; }
    elif percent >= 50 { n = 3; }
    elif percent >= 30 { n = 2; }
    elif percent >= 10 { n = 1; }
    cells = "#" * n + "-" * (5 - n);
    return "[" + cells + "]";
}


# ---------------------------------------------------------------------------
# The source (singleton).
# ---------------------------------------------------------------------------
obj Battery {
    has battery: Signal = signal({"percent": 0, "charging": False, "present": False});
    has _proxy: any = None;

    def postinit() {
        self._proxy = _proxy();
        self._refresh();
        watch(self._proxy, lambda { self._refresh(); });
    }

    def _refresh() {
        raw = read_raw(self._proxy);
        if raw is None { return; }
        (pct, state, present) = raw;
        b = parse_battery(pct, state);
        b["present"] = present;
        self.battery.set(b);
    }
}

glob _batt: any = None;

def get_battery() -> Battery {
    if _batt is None { _batt = Battery(); }
    return _batt;
}
