# pipewire.jac — PipeWire/WirePlumber source via wpctl (PLAN Phase 4+).
# ---------------------------------------------------------------------------
# Reactive view of sinks/sources and defaults, comparable to Quickshell's
# Quickshell.Services.Pipewire. Reads `wpctl status` for device lists and
# `wpctl get-volume` for accurate default mute/volume; polls on the GLib loop.
#
# Exposes:
#     ready           : Signal[bool]
#     default_sink    : Signal[dict]  — {id, name, percent, muted}
#     default_source  : Signal[dict]
#     sinks           : Signal[list]  — [{id, name, percent, muted, description}]
#     sources         : Signal[list]
#
# DEGRADATION: no wpctl / empty status -> ready=False, empty defaults.
# PURE LOGIC (parse_wpctl_status, parse_device_line, …) is unit-tested headless.
import from jacket.reactive { signal, Signal }
import from jacket.glib { run_cmd, timeout_add }
import from jacket.audio { parse_volume }


# ---------------------------------------------------------------------------
# Pure: parse "[vol: 0.28]" / "Audio/Source" bracket text from wpctl status.
# ---------------------------------------------------------------------------
def parse_vol_from_desc(desc: any) -> dict {
    d = str(desc);
    muted = "MUTED" in d.upper();
    percent = 0;
    lower = d.lower();
    idx = lower.find("vol:");
    if idx >= 0 {
        rest = d[idx + 4:].strip();
        tok = "";
        for ch in rest {
            if (ch >= "0" and ch <= "9") or ch == "." {
                tok += ch;
            } elif tok != "" {
                break;
            }
        }
        if tok != "" {
            try {
                percent = int(round(float(tok) * 100.0));
            } except ValueError {
                percent = 0;
            }
        }
    }
    return {"percent": percent, "muted": muted};
}

# Pure: one indented wpctl status line -> device dict or None.
# Lines look like: " │  *   93. soundcore Life Q20 [vol: 0.28]"
def parse_device_line(line: any) -> dict | None {
    t = str(line).rstrip();
    if t == "" { return None; }
    parsed = _parse_device_id_prefix(t);
    if parsed is None { return None; }
    id_val = parsed["id"];
    dot_i = parsed["dot"];
    is_default = "*" in t[:dot_i];
    rest = t[dot_i + 2:].strip();
    name = rest;
    desc = "";
    bracket_start = rest.find("[");
    if bracket_start >= 0 {
        bracket_end = rest.rfind("]");
        if bracket_end > bracket_start {
            name = rest[:bracket_start].strip();
            desc = rest[bracket_start + 1:bracket_end].strip();
        }
    }
    vol = parse_vol_from_desc(desc);
    return {
        "id": id_val,
        "name": name,
        "percent": vol["percent"],
        "muted": vol["muted"],
        "description": desc,
        "default": is_default,
    };
}

def _parse_device_id_prefix(t: str) -> dict | None {
    i = 0;
    while i < len(t) {
        if t[i] >= "0" and t[i] <= "9" {
            start = i;
            while i < len(t) and t[i] >= "0" and t[i] <= "9" { i += 1; }
            if i < len(t) and t[i] == "." and i + 1 < len(t) and t[i + 1] == " " {
                return {"id": int(t[start:i]), "dot": i};
            }
        }
        i += 1;
    }
    return None;
}

def _empty_endpoint() -> dict {
    return {"id": 0, "name": "", "percent": 0, "muted": False};
}

def _public_endpoint(dev: dict) -> dict {
    return {
        "id": dev["id"],
        "name": dev["name"],
        "percent": dev["percent"],
        "muted": dev["muted"],
    };
}

def _public_device(dev: dict) -> dict {
    return {
        "id": dev["id"],
        "name": dev["name"],
        "percent": dev["percent"],
        "muted": dev["muted"],
        "description": dev.get("description", ""),
    };
}

# Pure: merge wpctl get-volume output into a parsed default device.
def merge_device_volume(device: dict, volume_text: any) -> dict {
    v = parse_volume(volume_text);
    return {
        "id": device["id"],
        "name": device["name"],
        "percent": v["percent"],
        "muted": v["muted"],
        "description": device.get("description", ""),
    };
}

# Pure: map user-facing id_or_default to a wpctl target token.
def resolve_wpctl_id(id_or_default: str, kind: str) -> str {
    t = str(id_or_default).strip();
    if t == "" or t.lower() == "default" {
        if kind == "source" { return "@DEFAULT_AUDIO_SOURCE@"; }
        return "@DEFAULT_AUDIO_SINK@";
    }
    if t.startswith("@") { return t; }
    return t;
}

# Pure: parse `wpctl status` into sinks, sources, and default endpoints.
def parse_wpctl_status(text: any) -> dict {
    empty = _empty_endpoint();
    result = {
        "ready": False,
        "default_sink": empty,
        "default_source": empty,
        "sinks": [],
        "sources": [],
    };
    in_audio = False;
    section = "";
    default_sink = empty;
    default_source = empty;
    sinks: list = [];
    sources: list = [];
    for raw in str(text).splitlines() {
        line = raw.rstrip();
        if line.startswith("Audio") {
            in_audio = True;
            continue;
        }
        if in_audio and line.startswith("Video") { break; }
        if not in_audio { continue; }
        if "Sinks:" in line {
            section = "sinks";
            continue;
        }
        if "Sources:" in line {
            section = "sources";
            continue;
        }
        if "Filters:" in line {
            section = "filters";
            continue;
        }
        if "Streams:" in line or "Devices:" in line {
            if section != "sinks" and section != "sources" and section != "filters" {
                section = "";
            }
            continue;
        }
        dev = parse_device_line(line);
        if dev is None { continue; }
        pub = _public_device(dev);
        if section == "sinks" {
            sinks.append(pub);
            if dev.get("default", False) { default_sink = _public_endpoint(dev); }
        } elif section == "sources" or section == "filters" {
            sources.append(pub);
            if dev.get("default", False) { default_source = _public_endpoint(dev); }
        }
    }
    result["sinks"] = sinks;
    result["sources"] = sources;
    result["default_sink"] = default_sink;
    result["default_source"] = default_source;
    result["ready"] = len(sinks) > 0 or len(sources) > 0;
    return result;
}


# ---------------------------------------------------------------------------
# The source (singleton). wpctl has no event stream, so poll at 500ms.
# ---------------------------------------------------------------------------
obj Pipewire {
    has ready: Signal = signal(False);
    has default_sink: Signal = signal(_empty_endpoint());
    has default_source: Signal = signal(_empty_endpoint());
    has sinks: Signal = signal([]);
    has sources: Signal = signal([]);

    def postinit() {
        self._refresh();
        timeout_add(500, lambda {
            self._refresh();
            return True;
        });
    }

    def _refresh() {
        (rc, out) = run_cmd(["wpctl", "status"]);
        if rc != 0 {
            self.ready.set(False);
            return;
        }
        parsed = parse_wpctl_status(out);
        ds = parsed["default_sink"];
        if ds["id"] > 0 {
            (vrc, vout) = run_cmd(["wpctl", "get-volume", str(ds["id"])]);
            if vrc == 0 { ds = merge_device_volume(ds, vout); }
        }
        src = parsed["default_source"];
        if src["id"] > 0 {
            (vrc, vout) = run_cmd(["wpctl", "get-volume", str(src["id"])]);
            if vrc == 0 { src = merge_device_volume(src, vout); }
        }
        self.ready.set(parsed["ready"]);
        self.default_sink.set(_public_endpoint(ds));
        self.default_source.set(_public_endpoint(src));
        self.sinks.set(parsed["sinks"]);
        self.sources.set(parsed["sources"]);
    }

    def set_sink_volume(id_or_default: str, percent: int) {
        target = resolve_wpctl_id(id_or_default, "sink");
        f = str(max(0, min(100, percent)) / 100.0);
        run_cmd(["wpctl", "set-volume", target, f]);
        self._refresh();
    }

    def set_sink_mute(id_or_default: str, muted: bool) {
        target = resolve_wpctl_id(id_or_default, "sink");
        flag = "1" if muted else "0";
        run_cmd(["wpctl", "set-mute", target, flag]);
        self._refresh();
    }

    def set_default_sink(id: int) {
        if id <= 0 { return; }
        run_cmd(["wpctl", "set-default", str(id)]);
        self._refresh();
    }
}

glob _pipewire: any = None;

def get_pipewire() -> Pipewire {
    if _pipewire is None { _pipewire = Pipewire(); }
    return _pipewire;
}
