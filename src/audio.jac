# audio.jac — volume source via wpctl (PipeWire/WirePlumber) (PLAN Phase 4).
# ---------------------------------------------------------------------------
# wpctl is the simplest correct read of the default sink; we poll it on the
# GLib loop (no thread — spawn() is a short blocking subprocess, sub-ms) and
# .set() a Signal. Writes go straight through set-volume/set-mute.
#
# Exposes one Signal:
#     volume : Signal[dict]  — {"percent": int, "muted": bool}
#
# PURE LOGIC (parse_volume) is unit-tested headless. The wpctl round-trip and
# polling are the untestable-here parts.
import from src.reactive { signal, Signal }
import from src.glib { run_cmd, timeout_add }


# ---------------------------------------------------------------------------
# Pure parse of `wpctl get-volume @DEFAULT_AUDIO_SINK@`:
#     "Volume: 0.65"          -> 65%, not muted
#     "Volume: 0.30 [MUTED]"  -> 30%, muted
# ---------------------------------------------------------------------------
def parse_volume(text: any) -> dict {
    t = str(text);
    muted = "[MUTED]" in t;
    frac = 0.0;
    parts = t.strip().split();
    # find the token after "Volume:" that parses as a float
    for tok in parts {
        try {
            frac = float(tok);
            break;
        } except ValueError {
            continue;
        }
    }
    return {"percent": int(round(frac * 100.0)), "muted": muted};
}

def _read() -> dict {
    (rc, out) = run_cmd(["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]);
    if rc != 0 { return {"percent": 0, "muted": False}; }
    return parse_volume(out);
}


# ---------------------------------------------------------------------------
# The source (singleton). wpctl has no event stream, so poll at 500ms — cheap,
# and volume changes are user-paced anyway.
# ---------------------------------------------------------------------------
obj Audio {
    has volume: Signal = signal({"percent": 0, "muted": False});

    def postinit() {
        self._refresh();
        timeout_add(500, lambda {
            self._refresh();
            return True;
        });
    }

    def _refresh() {
        self.volume.set(_read());
    }

    def set_volume(percent: int) {
        f = str(max(0, min(100, percent)) / 100.0);
        run_cmd(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f]);
        self._refresh();
    }

    def toggle_mute() {
        run_cmd(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]);
        self._refresh();
    }
}

glob _audio: any = None;

def get_audio() -> Audio {
    if _audio is None { _audio = Audio(); }
    return _audio;
}
