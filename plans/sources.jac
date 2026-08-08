# sources.jac  —  DESIGN SKETCH (illustrative pseudo-Jac)
# ---------------------------------------------------------------------------
# THE OTHER HALF of the shell: plain imperative Jac that watches the system and
# feeds Signals. This is the "sources" side — no OSP graph, no reconciler, no
# GTK. Each source owns a socket / poll loop / DBus subscription and calls
# `.set()` on signals. The reactive engine (the other files) does the rest.
#
# Companion to reactive_core.jac (Signal), scheduler.jac (flush), builders.jac.
#
# THE ONE HARD RULE — threading:
#   GTK's main loop is single-threaded. Signals may ONLY be written on the main
#   loop thread, because .set() -> mark_stale -> schedule_flush touches shared
#   scheduler state and ultimately GTK. Any source running off-thread (a
#   blocking socket read, a subprocess) MUST marshal its .set() back onto the
#   loop via GLib.idle_add. Sources that use Gio async / GLib watches are
#   already ON the loop and can .set() directly.
#
#   Helper `on_main(fn)` centralizes this so no source gets it wrong.
#
# Real imports (illustrative):
#   import from gi.repository { Gio, GLib, GObject }
# ===========================================================================


# ---------------------------------------------------------------------------
# on_main — marshal a call onto the GTK main loop. The single choke point that
# keeps every off-thread source correct. On-loop sources can skip it.
# ---------------------------------------------------------------------------
def on_main(fn: any) {
    GLib.idle_add(lambda: (fn(), False)[1]);   # returns False = one-shot
}


# ===========================================================================
# PATTERN A — GLib timeout source (clock, battery poll). Already on the loop.
# ===========================================================================

# ticker(ms) -> a Signal of a monotonically-updating tick, used by clocks.
def ticker(interval_ms: int) -> Signal {
    sig = signal(now());
    def tick() -> bool {
        sig.set(now());       # on-loop already: GLib timeout runs on main loop
        return True;          # True = keep firing
    }
    GLib.timeout_add(interval_ms, tick);
    return sig;
}

# clock text: derive from the ticker, format in the reactive graph (not here).
#   let time = ticker(1000);
#   Label(text = time.map(lambda t: strftime("%H:%M", t)))


# ===========================================================================
# PATTERN B — Gio DBus (system state: MPRIS, UPower battery, logind).
# Gio integrates with the GLib loop natively — subscriptions fire ON the loop,
# so .set() is direct, no on_main needed. This is why we chose Gio over
# dbus-next: transport for free, no second event loop.
# ===========================================================================

obj Battery {
    has percent: Signal;
    has charging: Signal;

    def init() {
        self.percent  = signal(0.0);
        self.charging = signal(False);

        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None);
        # subscribe to PropertiesChanged on the UPower device
        bus.signal_subscribe(
            "org.freedesktop.UPower", "org.freedesktop.DBus.Properties",
            "PropertiesChanged", UPOWER_DEVICE_PATH, None,
            Gio.DBusSignalFlags.NONE, self._on_props);
        self._refresh(bus);       # prime initial values
    }

    def _on_props(self, conn, sender, path, iface, sig, params) {
        # fires ON the main loop (Gio) -> direct .set() is safe
        changed = params.unpack()[1];       # a{sv} of changed props
        if "Percentage" in changed { self.percent.set(changed["Percentage"] / 100.0); }
        if "State" in changed { self.charging.set(changed["State"] == 1); }
    }

    def _refresh(self, bus: any) {
        # one-shot Get for initial state (GLib.Variant unpack — the marshalling
        # swamp; keep it walled in the source, like adapter walls GTK's).
        pass;   # bus.call_sync(... "Get" ...) -> unpack -> .set()
    }
}


# ===========================================================================
# PATTERN C — raw socket, OFF-loop read (Hyprland IPC event stream).
# Hyprland's socket2 emits a line per event. Two correct designs:
#   C1. GLib IO watch on the fd  -> stays ON the loop (preferred).
#   C2. background thread blocking-read -> MUST on_main() every .set().
# Prefer C1: no thread, no marshalling. Shown here.
# ===========================================================================

obj Hyprland {
    has workspaces: Signal;      # Signal[list] -> drives the first real `For`
    has active_ws: Signal;

    def init() {
        self.workspaces = signal([]);
        self.active_ws  = signal(0);
        self._connect_events();
        self._refresh();         # prime via one-shot request socket
    }

    def _connect_events() {
        # open socket2 (event stream), watch its fd on the GLib loop
        sock = open_hypr_socket("socket2");
        chan = GLib.IOChannel.unix_new(sock.fileno());
        GLib.io_add_watch(chan, GLib.IOCondition.IN, self._on_event);
    }

    def _on_event(self, chan, cond) -> bool {
        # ON the loop (io watch) -> direct .set()
        line = chan.readline();                  # "workspace>>2", "createworkspace>>3"...
        evt = line.split(">>", 1)[0];
        if evt in ("workspace", "createworkspace", "destroyworkspace", "focusedmon") {
            self._refresh();                     # re-query authoritative state
        }
        return True;                             # keep watching
    }

    def _refresh() {
        # one-shot request socket: `j/workspaces` -> JSON -> set the list signal.
        # Setting the WHOLE list is fine: the `For` keyed diff computes the delta.
        # NOTE container-equality caveat (PLAN #2): build a NEW list so `!=`
        # detects the change — never mutate the old list in place.
        data = hypr_request("j/workspaces");     # blocking but instant (local socket)
        self.workspaces.set(parse_workspaces(data));
        self.active_ws.set(parse_active(data));
    }

    def focus(self, ws_id: int) {
        hypr_request(f"dispatch workspace {ws_id}");   # write command socket
    }
}


# ===========================================================================
# PATTERN D — PulseAudio / WirePlumber volume. Native libs are off-loop /
# callback-driven; wrap and marshal with on_main to be safe.
# ===========================================================================

obj Audio {
    has volume: Signal;      # 0.0..1.0
    has muted: Signal;

    def init() {
        self.volume = signal(0.0);
        self.muted  = signal(False);
        # pa/wp callback fires on ITS thread -> marshal onto the main loop
        subscribe_pulse(lambda v, m: on_main(lambda: self._apply(v, m)));
    }
    def _apply(self, v: float, m: bool) {
        self.volume.set(v);
        self.muted.set(m);
    }
    def set_volume(self, v: float) { pulse_set_volume(v); }
}


# ===========================================================================
# WIRING — sources are singletons created once at startup, before build_root.
# Components read their signals; the reactive graph does everything else.
# ===========================================================================
#
#   glob battery = Battery();
#   glob hypr    = Hyprland();
#   glob audio   = Audio();
#
#   @component
#   def Bar(monitor: int) -> ViewNode {
#       let time = ticker(1000);
#       return Box(class="bar", orientation=H, children=[
#           Label(text = time.map(lambda t: strftime("%H:%M", t))),
#           Label(text = fmt("{:.0%}", audio.volume)),
#           Icon(hidden = battery.percent > 0.8),
#           For(hypr.workspaces, key=|w| w["id"], row=|w| Button(
#               class = when(w["active"], "ws active", "ws"),
#               child = Label(text = str(w["idx"])),
#               on_click = || hypr.focus(w["id"]),
#           )),
#       ]);
#   }
#
# ===========================================================================
# THE CONTRACT, restated: sources are DUMB and imperative. They know nothing
# about OSP, reconciliation, or GTK. Their entire job is: watch a thing, and
# .set() a Signal on the main loop. That single boundary — on_main() — is the
# only threading discipline the whole shell requires.
# ===========================================================================
