# brightness.jac — display backlight via brightnessctl (PLAN Phase 4).
# ---------------------------------------------------------------------------
# Primary path: brightnessctl (machine-readable -m, or get+max). Optional
# fallback: systemd-logind GetBrightness/SetBrightness + sysfs when ctl absent.
# Polls on the GLib loop (1.5s); no thread.
#
# Exposes Signals on Brightness:
#     available, percent, raw, max, device
#
# DEGRADATION: no backlight device -> available=False, bar hides the widget.
# PURE LOGIC (parse_brightnessctl_*) is unit-tested headless.
import from src.reactive { signal, Signal }
import from src.glib { run_cmd, timeout_add }


# ---------------------------------------------------------------------------
# Pure: machine-readable (`brightnessctl -m`) or human list (`brightnessctl -l`).
# ---------------------------------------------------------------------------
def _empty_brightness() -> dict {
    return {"available": False, "device": "", "raw": 0, "percent": 0, "max": 0};
}

def _parse_current_line(line: str) -> list {
    # "Current brightness: 340 (85%)" -> [raw, percent]
    if ":" not in line { return [0, 0]; }
    rest = line.split(":", 1)[1].strip();
    raw = 0;
    pct = 0;
    if "(" in rest {
        raw_part = rest.split("(")[0].strip();
        pct_part = rest.split("(")[1].split("%")[0].strip();
        try { raw = int(raw_part); } except ValueError { raw = 0; }
        try { pct = int(pct_part); } except ValueError { pct = 0; }
    } else {
        try { raw = int(rest); } except ValueError { raw = 0; }
    }
    return [raw, pct];
}

def parse_brightnessctl_info(text: any) -> dict {
    t = str(text);
    if t.strip() == "" { return _empty_brightness(); }
    # Machine-readable: device,class,raw,percent%,max
    for line in t.split("\n") {
        line = line.strip();
        if line == "" or line.startswith("Available") { continue; }
        if "," not in line { continue; }
        parts = [p.strip() for p in line.split(",")];
        if len(parts) < 5 { continue; }
        if parts[1] != "backlight" { continue; }
        pct_s = parts[3];
        if pct_s.endswith("%") { pct_s = pct_s[:-1]; }
        try {
            return {
                "available": True,
                "device": parts[0],
                "raw": int(parts[2]),
                "percent": int(pct_s),
                "max": int(parts[4]),
            };
        } except ValueError {
            continue;
        }
    }
    # Human list: Device 'intel_backlight' of class 'backlight':
    device = "";
    raw = 0;
    pct = 0;
    mx = 0;
    in_bl = False;
    for line in t.split("\n") {
        line = line.strip();
        if line.startswith("Device '") and "of class 'backlight'" in line {
            i = line.index("Device '") + len("Device '");
            j = line.index("'", i);
            device = line[i:j];
            in_bl = True;
            raw = 0;
            pct = 0;
            mx = 0;
            continue;
        }
        if not in_bl { continue; }
        if line.startswith("Device '") and "of class '" in line { break; }
        if line.startswith("Current brightness:") {
            (raw, pct) = _parse_current_line(line);
        } elif line.startswith("Max brightness:") {
            try { mx = int(line.split(":", 1)[1].strip()); } except ValueError { mx = 0; }
        }
    }
    if device != "" and mx > 0 {
        if pct == 0 and raw > 0 { pct = int(round(raw * 100.0 / mx)); }
        return {"available": True, "device": device, "raw": raw, "percent": pct, "max": mx};
    }
    return _empty_brightness();
}

# Pure: `brightnessctl get` stdout, optionally followed by max on the next line.
def parse_brightnessctl_get(text: any) -> dict {
    lines: list = [];
    for line in str(text).split("\n") {
        s = line.strip();
        if s != "" { lines.append(s); }
    }
    if len(lines) == 0 { return _empty_brightness(); }
    raw = 0;
    mx = 0;
    first = lines[0];
    if "/" in first and len(lines) == 1 {
        parts = first.split("/");
        try { raw = int(parts[0].strip()); } except ValueError { raw = 0; }
        try { mx = int(parts[1].strip()); } except ValueError { mx = 0; }
    } else {
        try { raw = int(first); } except ValueError { raw = 0; }
        if len(lines) >= 2 {
            try { mx = int(lines[1]); } except ValueError { mx = 0; }
        }
    }
    if mx <= 0 { return _empty_brightness(); }
    pct = int(round(raw * 100.0 / mx));
    return {"available": True, "device": "", "raw": raw, "percent": pct, "max": mx};
}


# ===========================================================================
# ::py:: shim — logind + sysfs fallback, walled off here.
# ===========================================================================
::py::
from gi.repository import Gio, GLib
import glob
import os

_LOGIN1 = "org.freedesktop.login1"
_LOGIN1_PATH = "/org/freedesktop/login1"
_LOGIN1_IFACE = "org.freedesktop.login1.Manager"


def _logind_proxy():
    try:
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, None,
            _LOGIN1, _LOGIN1_PATH, _LOGIN1_IFACE, None)
    except Exception:
        return None


def discover_backlight():
    """First sysfs backlight device name, or ''."""
    paths = sorted(glob.glob("/sys/class/backlight/*"))
    if not paths:
        return ""
    return os.path.basename(paths[0])


def read_sysfs(device=None):
    name = device or discover_backlight()
    if not name:
        return None
    base = f"/sys/class/backlight/{name}"
    try:
        with open(os.path.join(base, "brightness")) as f:
            raw = int(f.read().strip())
        with open(os.path.join(base, "max_brightness")) as f:
            mx = int(f.read().strip())
    except Exception:
        return None
    pct = int(round(raw * 100.0 / mx)) if mx > 0 else 0
    return {"available": True, "device": name, "raw": raw, "percent": pct, "max": mx}


def read_logind(proxy, device):
    if proxy is None or not device:
        return None
    try:
        v = proxy.call_sync(
            "GetBrightness",
            GLib.Variant("(ss)", ("backlight", device)),
            Gio.DBusCallFlags.NONE, -1, None)
        raw = int(v.unpack())
    except Exception:
        return None
    # logind has no max query — pair with sysfs max_brightness.
    base = f"/sys/class/backlight/{device}"
    try:
        with open(os.path.join(base, "max_brightness")) as f:
            mx = int(f.read().strip())
    except Exception:
        return None
    pct = int(round(raw * 100.0 / mx)) if mx > 0 else 0
    return {"available": True, "device": device, "raw": raw, "percent": pct, "max": mx}


def write_logind(proxy, device, raw):
    if proxy is None or not device:
        return False
    try:
        proxy.call_sync(
            "SetBrightness",
            GLib.Variant("(ssi)", ("backlight", device, int(raw))),
            Gio.DBusCallFlags.NONE, -1, None)
        return True
    except Exception:
        return False


def write_sysfs(device, raw):
    if not device:
        return False
    path = f"/sys/class/backlight/{device}/brightness"
    try:
        with open(path, "w") as f:
            f.write(str(int(raw)))
        return True
    except Exception:
        return False


def watch_logind(proxy, on_change):
    """Subscribe to BrightnessChanged when the running logind exposes it."""
    if proxy is None:
        return
    try:
        proxy.connect("g-signal", lambda p, sender, signal, params: (
            on_change() if signal == "BrightnessChanged" else None))
    except Exception:
        pass
::py::


def _read_brightnessctl() -> any {
    (rc, out) = run_cmd(["brightnessctl", "-m", "-c", "backlight"]);
    if rc == 0 and str(out).strip() != "" {
        info = parse_brightnessctl_info(out);
        if info.get("available", False) { return info; }
    }
    (rc_g, raw_out) = run_cmd(["brightnessctl", "-c", "backlight", "get"]);
    (rc_m, max_out) = run_cmd(["brightnessctl", "-c", "backlight", "max"]);
    if rc_g == 0 and rc_m == 0 {
        combined = str(raw_out).strip() + "\n" + str(max_out).strip();
        info = parse_brightnessctl_get(combined);
        if info.get("available", False) { return info; }
    }
    return None;
}

def _read_fallback(logind: any, dev: str) -> dict {
    if dev != "" {
        raw: any = read_logind(logind, dev);
        if raw is not None { return raw; }
        raw = read_sysfs(dev);
        if raw is not None { return raw; }
    }
    return _empty_brightness();
}

def _write_percent(logind: any, device: str, percent: int, mx: int) -> None {
    pct = max(0, min(100, percent));
    (rc, _) = run_cmd(["brightnessctl", "-c", "backlight", "set", str(pct) + "%"]);
    if rc == 0 { return; }
    raw = int(round(pct * mx / 100.0)) if mx > 0 else 0;
    if write_logind(logind, device, raw) { return; }
    write_sysfs(device, raw);
}


# ---------------------------------------------------------------------------
# The source (singleton). brightnessctl has no event stream, so poll at 1.5s.
# ---------------------------------------------------------------------------
obj Brightness {
    has available: Signal = signal(False);
    has percent: Signal = signal(0);
    has raw: Signal = signal(0);
    has max: Signal = signal(0);
    has device: Signal = signal("");
    has _logind: any = None;
    has _dev: str = "";

    def postinit() {
        self._logind = _logind_proxy();
        self._dev = str(discover_backlight());
        watch_logind(self._logind, lambda { self._refresh(); });
        self._refresh();
        timeout_add(1500, lambda {
            self._refresh();
            return True;
        });
    }

    def _apply(info: dict) {
        self.available.set(info.get("available", False));
        self.percent.set(info.get("percent", 0));
        self.raw.set(info.get("raw", 0));
        self.max.set(info.get("max", 0));
        dev = str(info.get("device", ""));
        if dev != "" { self._dev = dev; }
        self.device.set(self._dev);
    }

    def _refresh() {
        info = _read_brightnessctl();
        if info is None { info = _read_fallback(self._logind, self._dev); }
        self._apply(info);
    }

    def set_percent(percent: int) {
        if not self.available() and self._dev == "" { return; }
        mx = self.max();
        dev = self._dev;
        if dev == "" { dev = str(discover_backlight()); }
        _write_percent(self._logind, dev, percent, mx);
        self._refresh();
    }

    def step_up(step: int = 5) {
        self.set_percent(self.percent() + step);
    }

    def step_down(step: int = 5) {
        self.set_percent(self.percent() - step);
    }
}

glob _bright: any = None;

def get_brightness() -> Brightness {
    if _bright is None { _bright = Brightness(); }
    return _bright;
}
