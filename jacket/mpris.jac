# mpris.jac — now-playing source via MPRIS on the session bus (PLAN Phase 5).
# ---------------------------------------------------------------------------
# Finds the first org.mpris.MediaPlayer2.* peer, reads PlaybackStatus + Metadata,
# and tracks changes via PropertiesChanged. Controls (PlayPause/Next/Previous)
# proxy straight through. ("Own the logic, use the transport" — PLAN §4.)
#
# Exposes one Signal:
#     player : Signal[dict] — {"playing": bool, "title": str, "artist": str,
#                              "has_player": bool}
#
# PURE LOGIC (parse_metadata / format_status) is unit-tested; the bus discovery
# + proxy live behind the ::py:: seam.
import from jacket.reactive { signal, Signal }


# ---------------------------------------------------------------------------
# Pure: normalize MPRIS metadata (a{sv}, already unpacked to a dict) into the
# two fields the bar shows. Artist is xesam:artist (an array of strings).
# ---------------------------------------------------------------------------
def parse_metadata(meta: any) -> dict {
    title: any = meta.get("xesam:title", "");
    artists: any = meta.get("xesam:artist", []);
    artist = "";
    if isinstance(artists, list) and len(artists) > 0 {
        artist = str(artists[0]);
    } elif isinstance(artists, str) {
        artist = artists;
    }
    return {"title": str(title), "artist": artist};
}

# Pure: PlaybackStatus string -> bool (spec: "Playing"/"Paused"/"Stopped").
def is_playing(status: any) -> bool {
    return status == "Playing";
}

# Pure: compact "artist — title" (or just title) for the bar; "" when idle.
def format_status(player: dict) -> str {
    if not player.get("has_player", False) { return ""; }
    title = str(player.get("title", ""));
    artist = str(player.get("artist", ""));
    if title == "" { return ""; }
    mark = "|| " if player.get("playing", False) else "> ";
    if artist != "" { return mark + artist + " — " + title; }
    return mark + title;
}


# ===========================================================================
# ::py:: shim — session-bus discovery + proxy, walled off here.
# ===========================================================================
::py::
from gi.repository import Gio, GLib

_PREFIX = "org.mpris.MediaPlayer2."
_PATH = "/org/mpris/MediaPlayer2"
_IFACE = "org.mpris.MediaPlayer2.Player"


def _session():
    try:
        return Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except Exception:
        return None


def find_player(conn):
    """First bus name under org.mpris.MediaPlayer2.*, or None."""
    if conn is None:
        return None
    try:
        reply = conn.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "ListNames", None,
            GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, -1, None)
        for name in reply.unpack()[0]:
            if name.startswith(_PREFIX):
                return name
    except Exception:
        pass
    return None


def make_proxy(conn, name):
    if conn is None or name is None:
        return None
    try:
        return Gio.DBusProxy.new_sync(
            conn, Gio.DBusProxyFlags.NONE, None,
            name, _PATH, _IFACE, None)
    except Exception:
        return None


def read_state(proxy):
    """(status: str, metadata: dict) from a player proxy, or None."""
    if proxy is None:
        return None
    try:
        st = proxy.get_cached_property("PlaybackStatus")
        md = proxy.get_cached_property("Metadata")
        status = st.unpack() if st is not None else "Stopped"
        meta = md.unpack() if md is not None else {}
        return (status, meta)
    except Exception:
        return None


def watch(proxy, on_change):
    if proxy is not None:
        proxy.connect("g-properties-changed", lambda p, c, i: on_change())


def control(proxy, method):
    if proxy is None:
        return
    try:
        proxy.call_sync(method, None, Gio.DBusCallFlags.NONE, -1, None)
    except Exception:
        pass
::py::


# ---------------------------------------------------------------------------
# The source (singleton).
# ---------------------------------------------------------------------------
obj Mpris {
    has player: Signal = signal({"playing": False, "title": "", "artist": "", "has_player": False});
    has _proxy: any = None;

    def postinit() {
        conn = _session();
        name = find_player(conn);
        self._proxy = make_proxy(conn, name);
        self._refresh();
        watch(self._proxy, self._refresh);
    }

    def _refresh() {
        state = read_state(self._proxy);
        if state is None {
            self.player.set({"playing": False, "title": "", "artist": "", "has_player": False});
            return;
        }
        (status, meta) = state;
        md = parse_metadata(meta);
        self.player.set({
            "playing": is_playing(status),
            "title": md["title"],
            "artist": md["artist"],
            "has_player": True,
        });
    }

    def play_pause() { control(self._proxy, "PlayPause"); self._refresh(); }
    def next() { control(self._proxy, "Next"); self._refresh(); }
    def previous() { control(self._proxy, "Previous"); self._refresh(); }
}

glob _mpris: any = None;

def get_mpris() -> Mpris {
    if _mpris is None { _mpris = Mpris(); }
    return _mpris;
}
