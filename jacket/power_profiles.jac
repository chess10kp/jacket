# power_profiles.jac — power profile state via power-profiles-daemon (PLAN).
# ---------------------------------------------------------------------------
# Uses Gio DBus (the GLib stack — "own the logic, use the transport", PLAN §4)
# on the system bus to read net.hadess.PowerProfiles and subscribe to
# PropertiesChanged. Falls back to powerprofilesctl when the proxy is absent.
#
# Exposes Signals:
#     available, profile, has_performance, degradation_reason
#
# DEGRADATION: no daemon -> available=False, profile="balanced", quiet no-ops.
# PURE LOGIC (normalize_profile / parse_profile_properties) is unit-tested.
import from jacket.reactive { signal, Signal }
import from jacket.glib { run_cmd }


::py::
from gi.repository import Gio, GLib

_POWER = "net.hadess.PowerProfiles"
_PATH = "/net/hadess/PowerProfiles"
_IFACE = "net.hadess.PowerProfiles"
_PROP_NAMES = (
    "ActiveProfile",
    "Profiles",
    "PerformanceDegraded",
    "PerformanceInhibited",
)


def _proxy():
    """A DBusProxy on PowerProfiles, or None if the daemon is absent."""
    try:
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None,
            _POWER, _PATH, _IFACE, None)
    except Exception:
        return None


def read_raw(proxy):
    """Property dict from the proxy, or None if unreadable."""
    if proxy is None:
        return None
    try:
        props = {}
        for name in _PROP_NAMES:
            v = proxy.get_cached_property(name)
            if v is not None:
                props[name] = v.unpack()
        if "ActiveProfile" not in props:
            return None
        return props
    except Exception:
        return None


def write_profile(proxy, name):
    """Set ActiveProfile on the daemon. Returns True on success."""
    if proxy is None:
        return False
    try:
        params = GLib.Variant(
            "(ssv)",
            (_IFACE, "ActiveProfile", GLib.Variant("s", name)),
        )
        proxy.get_connection().call_sync(
            proxy.get_name(),
            proxy.get_object_path(),
            "org.freedesktop.DBus.Properties",
            "Set",
            params,
            None,
            Gio.DBusCallFlags.NONE,
            -1,
            None,
        )
        return True
    except Exception:
        return False


def watch(proxy, on_change):
    """Fire on_change() whenever PowerProfiles reports a property change."""
    if proxy is None:
        return
    proxy.connect("g-properties-changed", lambda p, changed, inval: on_change())
::py::


# ---------------------------------------------------------------------------
# Pure logic (unit-tested).
# ---------------------------------------------------------------------------
glob _PROFILE_ORDER: list = ["balanced", "performance", "power-saver"];


def normalize_profile(raw: any) -> str {
    s = str(raw).strip().lower().replace("_", "-");
    if s == "power-save" { return "power-saver"; }
    for p in _PROFILE_ORDER {
        if p == s { return p; }
    }
    return "balanced";
}

def parse_powerprofilesctl_output(text: any) -> str {
    return normalize_profile(str(text));
}

def parse_profile_properties(props: any) -> dict {
    active = normalize_profile(props.get("ActiveProfile", "balanced"));
    profiles_raw: any = props.get("Profiles", []);
    has_perf = False;
    for entry in profiles_raw {
        if isinstance(entry, dict) {
            if normalize_profile(entry.get("Profile", "")) == "performance" {
                has_perf = True;
            }
        }
    }
    degraded = str(props.get("PerformanceDegraded", "") or "");
    inhibited = str(props.get("PerformanceInhibited", "") or "");
    reason = "";
    if degraded != "" { reason = degraded; }
    elif inhibited != "" { reason = inhibited; }
    return {
        "available": True,
        "profile": active,
        "has_performance": has_perf,
        "degradation_reason": reason,
    };
}

def next_profile(current: str) -> str {
    cur = normalize_profile(current);
    for (i, p) in enumerate(_PROFILE_ORDER) {
        if p == cur {
            return _PROFILE_ORDER[(i + 1) % len(_PROFILE_ORDER)];
        }
    }
    return "balanced";
}


# ---------------------------------------------------------------------------
# The source (singleton).
# ---------------------------------------------------------------------------
obj PowerProfiles {
    has available: Signal = signal(False);
    has profile: Signal = signal("balanced");
    has has_performance: Signal = signal(False);
    has degradation_reason: Signal = signal("");
    has _proxy: any = None;

    def postinit() {
        self._proxy = _proxy();
        self._refresh();
        watch(self._proxy, lambda { self._refresh(); });
    }

    def _degrade() {
        self.available.set(False);
        self.profile.set("balanced");
        self.has_performance.set(False);
        self.degradation_reason.set("");
    }

    def _apply(parsed: dict) {
        self.available.set(parsed["available"]);
        self.profile.set(parsed["profile"]);
        self.has_performance.set(parsed["has_performance"]);
        self.degradation_reason.set(parsed["degradation_reason"]);
    }

    def _refresh_from_ctl() -> bool {
        (rc, out) = run_cmd(["powerprofilesctl", "get"]);
        if rc != 0 or str(out).strip() == "" { return False; }
        p = parse_powerprofilesctl_output(out);
        (lrc, list_out) = run_cmd(["powerprofilesctl", "list"]);
        has_perf = lrc == 0 and "performance:" in str(list_out);
        self._apply({
            "available": True,
            "profile": p,
            "has_performance": has_perf,
            "degradation_reason": "",
        });
        return True;
    }

    def _refresh() {
        raw = read_raw(self._proxy);
        if raw is None {
            if not self._refresh_from_ctl() { self._degrade(); }
            return;
        }
        self._apply(parse_profile_properties(raw));
    }

    def set_profile(name: str) {
        if not self.available.peek() { return; }
        norm = normalize_profile(name);
        if self._proxy is not None and write_profile(self._proxy, norm) {
            self._refresh();
            return;
        }
        run_cmd(["powerprofilesctl", "set", norm]);
        self._refresh();
    }

    def cycle() {
        if not self.available.peek() { return; }
        self.set_profile(next_profile(self.profile.peek()));
    }
}

glob _power_profiles: any = None;

def get_power_profiles() -> PowerProfiles {
    if _power_profiles is None { _power_profiles = PowerProfiles(); }
    return _power_profiles;
}
