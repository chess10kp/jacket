# sources.jac — plain imperative Jac that watches the system and feeds Signals.
# (PLAN Phase 4, partial — clock + a manual source for the demo.)
# ---------------------------------------------------------------------------
# Sources are DUMB and imperative. They know nothing about OSP, reconciliation,
# or GTK. Their job: watch a thing, and .set() a Signal ON the main loop. The
# reactive engine does the rest. (Full Hyprland/audio/battery sources come in
# Phase 4; this file ships the clock ticker used by the Phase-3 demo.)
import from time { time, localtime, strftime }
import from src.reactive { signal, Signal }
import from src.glib { timeout_add }


# ticker(ms) -> a Signal of epoch seconds, updated every `ms` by a GLib timeout
# (which already runs ON the main loop, so .set() is safe — no marshalling).
def ticker(interval_ms: int) -> Signal {
    s = signal(time());
    timeout_add(interval_ms, lambda {
        s.set(time());
        return True;                 # True = keep firing
    });
    return s;
}
